"""
HttpsDown measured fragment gate for native HLS and DASH downloads.

One job-scoped controller limits how many fragment HTTP receives are actually in flight across ALL streams of the
job. It starts at 1 and raises the limit by 1 ONLY when the measured aggregate throughput (received fragment file
sizes / monotonic time, all streams together) of the trial N+1 is meaningfully higher than that of the stable N:

  * a measurement starts after a 2 s settling time, at the first fragment completion after it, and ends when at
    least 6 s have passed and at least 3 further fragments completed (rate = bytes of those fragments / time);
  * the trial N+1 is accepted only if its rate >= 1.10 x the stable rate (10 % gain); the accepted trial becomes the
    new stable capacity and baseline and the next +1 trial follows;
  * no gain, a trial that never actually had N+1 receives in flight, an error or a resource problem -> back to the
    last stable capacity and no more growth. A job too short to finish the first measurement simply stays at 1.

No fixed maximum exists in the policy. The only ceilings are the capacity of yt-dlp's native thread pool (read once
by yt-dlp; chosen from the OS file-descriptor budget, see native_pool_capacity) and an emergency fuse of 64 that
only protects resources.

A temporary wrapper around yt-dlp's FragmentFD._download_fragment acquires/releases the gate around the ORIGINAL
receive; yt-dlp's own scheduling (ThreadPool.map), ordering, decryption, append and integrity code stay untouched.
The first failed fragment freezes growth and aborts every NOT-yet-started receive; receives already in flight end by
themselves within the existing socket timeout. Exactly one retry per job is allowed, only for a clearly typed
transient failure (see _transient), on the same fragment at the stable capacity; yt-dlp's own retries stay 0.
"""

import errno
import math
import os
import threading
import time

# Diagnostic snapshot vocabulary (get_diagnostic_snapshot): internal Korean notes -> fixed enum ids.
_DIAG_REASONS = {"탐색·기준속도측정": "baseline", "탐색": "trial", "복귀": "rollback", "안정유지": "stable",
                 "자원한계": "resourceLimit"}
_DIAG_RATE_CAP = 1e12

_WAIT_SLICE = 0.1
_SETTLE_SECONDS = 2.0
_WINDOW_SECONDS = 6.0
_WINDOW_MIN_FRAGMENTS = 3
_GAIN_FACTOR = 1.10
_EMERGENCY_FUSE = 64
_FD_RESERVE = 64
_FD_PER_RECEIVE = 4
_RETRY_DELAY = 1.0
_TRANSIENT_HTTP = frozenset((408, 500, 502, 503, 504))


class FragmentAborted(Exception):
    """Raised for a fragment that never started because the job already failed or was closed."""


def native_pool_capacity():
    """
    (capacity, fuse_reached) for yt-dlp's native fragment thread pool, which yt-dlp reads once.
    capacity = (RLIMIT_NOFILE soft limit - file descriptors open now - 64 reserve) // 4 per receive
    (socket + fragment file + slack), at least 1, at most the emergency fuse of 64 (resource protection only).
    An unlimited soft limit gives the fuse; an unreadable limit gives 1 (unknown resources are not assumed).
    """
    try:
        import resource
        soft = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
    except Exception:
        return 1, False
    if soft == resource.RLIM_INFINITY or soft < 0:
        return _EMERGENCY_FUSE, True
    try:
        used = len(os.listdir("/dev/fd"))
    except OSError:
        used = 32
    budget = (soft - used - _FD_RESERVE) // _FD_PER_RECEIVE
    if budget > _EMERGENCY_FUSE:
        return _EMERGENCY_FUSE, True
    return max(1, budget), False


def _chain(exc):
    """The exception and its typed causes (__cause__/__context__/cause/exc_info), bounded and cycle-safe."""
    out, queue = [], [exc]
    while queue and len(out) < 8:
        e = queue.pop(0)
        if not isinstance(e, BaseException) or any(e is seen for seen in out):
            continue
        out.append(e)
        queue.extend((e.__cause__, e.__context__, getattr(e, "cause", None)))
        info = getattr(e, "exc_info", None)
        if isinstance(info, tuple) and len(info) > 1:
            queue.append(info[1])
    return out


def _transient(exc):
    """
    True only for a clearly typed transient failure: yt-dlp IncompleteRead / ContentTooShortError, a plain
    TransportError caused by a timeout or connection reset/abort, or HTTPError 408/500/502/503/504.
    Anything with an HTTP status outside that set (401/403/404/407/429...), TLS/certificate, proxy, DNS/private
    host or unknown reason anywhere in the chain is never retried.
    """
    try:
        from yt_dlp.networking.exceptions import (
            HTTPError, IncompleteRead, ProxyError, SSLError, TransportError, UnsupportedRequest)
        from yt_dlp.utils import ContentTooShortError, DownloadError, UnsupportedError
    except Exception:
        return False
    import socket
    net_ok = (TimeoutError, ConnectionResetError, ConnectionAbortedError, BrokenPipeError)
    # Fail closed: these anywhere in the chain (even as an old __context__) forbid the retry. Every OSError other
    # than the plain network ones (permission, filesystem, DNS/gaierror, ssl, ...) is rejected as well.
    for e in _chain(exc):
        if isinstance(e, (SSLError, ProxyError, UnsupportedRequest, UnsupportedError, socket.gaierror,
                          socket.herror)):
            return False
        if isinstance(e, OSError) and not isinstance(e, net_ok):
            return False
        if isinstance(e, HTTPError) and e.status not in _TRANSIENT_HTTP:
            return False
    # Positive path: only recognized native wrappers (DownloadError) may be unwrapped to reach a typed transient leaf.
    # An unknown wrapper type is never retried, whatever its old context says.
    e = exc
    for _ in range(4):
        if type(e) is not DownloadError:
            break
        info = getattr(e, "exc_info", None)
        nxt = info[1] if isinstance(info, tuple) and len(info) > 1 else e.__cause__
        if not isinstance(nxt, BaseException):
            return False
        e = nxt
    if isinstance(e, HTTPError):
        return e.status in _TRANSIENT_HTTP
    if isinstance(e, (IncompleteRead, ContentTooShortError)):
        return True
    if type(e) is TransportError:
        return any(isinstance(c, net_ok) for c in _chain(e)[1:])
    return False


def _resource_problem(exc):
    for e in _chain(exc):
        if isinstance(e, MemoryError):
            return True
        if isinstance(e, OSError) and e.errno in (errno.EMFILE, errno.ENFILE, errno.ENOMEM, errno.EAGAIN):
            return True
        if isinstance(e, RuntimeError) and "start new thread" in str(e):
            return True
    return False


class AdaptiveFragmentController:
    def __init__(self, pool_capacity=1, fuse_reached=False, stop_event=None):
        self.pool_capacity = max(1, int(pool_capacity))
        self.fuse_reached = bool(fuse_reached)
        self.stop_event = stop_event
        self.cond = threading.Condition()
        self._limit = 1
        self._stable = 1
        self._active = 0
        self._peak = 0
        self._phase = "baseline"   # baseline: measuring stable N | trial: measuring N+1 | hold: no more growth
        self._note = "탐색·기준속도측정"
        self._phase_start = time.monotonic()
        self._w_first = None       # monotonic time of the first completion of the current measurement
        self._w_bytes = 0
        self._w_frags = 0
        self._base_rate = 0.0
        self._trial_rate = 0.0     # diagnostics only: rate of the last finished trial window
        self._rolled_back = False  # diagnostics only
        self._resource_hit = False  # diagnostics only: a real resource failure happened
        self._retry_used = False   # diagnostics only
        self._frozen = False
        self._aborted = False
        self._retries_left = 1
        self._root_detail = None
        self._root_exc = None
        if self.pool_capacity <= 1:
            self._hold("자원한계")

    def is_adaptive(self):
        return self.pool_capacity > 1

    def get_status(self):
        """(current limit, stable limit, reason text) snapshot."""
        with self.cond:
            note = self._note
            if note == "자원한계":   # internal id; shown as the Mac's connection-resource limit, never as a speed optimum
                note = "맥의 연결자원한도·안정수유지"
                if self.fuse_reached:
                    note += f" · 비상상한 {_EMERGENCY_FUSE}"
            return self._limit, self._stable, note

    def get_diagnostic_snapshot(self):
        """
        Fixed-key, finite, bounded view for the diagnostic trace: enum ids, small integers, booleans and byte rates only
        (no URL, no exception text, no Korean display text).
        """
        def rate(value):
            try:
                v = float(value)
            except (TypeError, ValueError):
                return 0.0
            return round(min(max(v, 0.0), _DIAG_RATE_CAP), 1) if math.isfinite(v) else 0.0

        with self.cond:
            return {
                "phase": self._phase if self._phase in ("baseline", "trial", "hold") else "hold",
                "current": int(self._limit), "stable": int(self._stable), "pool": int(self.pool_capacity),
                "reason": _DIAG_REASONS.get(self._note, "other"),
                "resource": bool(self._resource_hit), "rollback": bool(self._rolled_back),
                "retryUsed": bool(self._retry_used), "fuse": bool(self.fuse_reached),
                "baselineRate": rate(self._base_rate), "trialRate": rate(self._trial_rate),
            }

    def _abort_error(self):
        err = FragmentAborted(self._root_detail or "조각 다운로드가 중단되었습니다.")
        err.__cause__ = self._root_exc
        return err

    def _reset_window(self, now):
        self._phase_start = now
        self._w_first = None
        self._w_bytes = 0
        self._w_frags = 0

    def _hold(self, note):
        self._phase = "hold"
        self._note = note

    def _rollback(self, note):
        self._rolled_back = True
        self._limit = self._stable
        self._frozen = True
        self._hold(note)

    def _next_trial(self, now):
        if self._stable + 1 > self.pool_capacity:
            self._hold("자원한계")
            return
        self._limit = self._stable + 1
        self._phase = "trial"
        self._note = "탐색"
        self._reset_window(now)

    def acquire(self):
        """Block until a receive slot is free. Raises FragmentAborted instead of starting a new receive."""
        with self.cond:
            while True:
                if self._aborted:
                    raise self._abort_error()
                if self.stop_event is not None and self.stop_event.is_set():
                    self._frozen = self._aborted = True
                    self.cond.notify_all()
                    raise self._abort_error()
                if self._active < self._limit:
                    self._active += 1
                    self._peak = max(self._peak, self._active)
                    return
                self.cond.wait(_WAIT_SLICE)

    def _sample(self, nbytes, now):
        if self._phase == "hold" or self._frozen or now - self._phase_start < _SETTLE_SECONDS:
            return
        if self._w_first is None:
            self._w_first, self._peak = now, self._active   # peak = most receives in flight inside this window
            return
        self._w_bytes += nbytes
        self._w_frags += 1
        elapsed = now - self._w_first
        if elapsed < _WINDOW_SECONDS or self._w_frags < _WINDOW_MIN_FRAGMENTS:
            return
        rate = self._w_bytes / elapsed
        if self._phase != "baseline":
            self._trial_rate = rate
        if self._phase == "baseline":
            self._base_rate = rate
            if rate <= 0:
                self._hold("안정유지")
            else:
                self._next_trial(now)
        elif self._peak < self._limit:
            self._rollback("복귀")   # the trial never had N+1 receives in flight: nothing was measured
        elif rate >= self._base_rate * _GAIN_FACTOR:
            self._stable, self._base_rate = self._limit, rate
            self._next_trial(now)
        else:
            self._rollback("복귀")

    def release(self, ok, nbytes=0, error=None):
        """Call exactly once per successful acquire() that did not go through fail()."""
        with self.cond:
            self._active -= 1
            if ok:
                if not self._frozen:
                    self._sample(nbytes, time.monotonic())
            else:
                self._abort_with(error)
            self.cond.notify_all()

    def _abort_with(self, error):
        if self._root_detail is None:
            self._root_detail = (str(error) if error is not None else "") or "조각 다운로드에 실패했습니다."
            self._root_exc = error if isinstance(error, BaseException) else None
        if not self._frozen:
            self._rollback("복귀")
        self._frozen = self._aborted = True

    def fail(self, exc, can_retry):
        """
        A receive raised. Rolls back to the stable capacity and freezes growth; returns True when this exact fragment
        may be received once more (the single per-job retry for a typed transient failure), else the job is aborted.
        """
        resource = _resource_problem(exc)
        with self.cond:
            self._active -= 1
            if resource:
                self._resource_hit = True
            if not self._frozen:
                self._rollback("자원한계" if resource else "복귀")
            elif resource:
                self._note = "자원한계"
            stopped = self.stop_event is not None and self.stop_event.is_set()
            retry = (can_retry and isinstance(exc, Exception) and not resource and not stopped and not self._aborted
                     and self._retries_left > 0 and _transient(exc))
            if retry:
                self._retries_left -= 1
                self._retry_used = True
            else:
                self._abort_with(exc)
            self.cond.notify_all()
        if retry:
            if self.stop_event is not None:
                if self.stop_event.wait(_RETRY_DELAY):
                    with self.cond:
                        self._abort_with(exc)
                        self.cond.notify_all()
                    return False
            else:
                time.sleep(_RETRY_DELAY)
        return retry

    def external_resource_failure(self, exc):
        """
        A resource error raised OUTSIDE a gated receive (native pool creation/submit): same rollback/hold/abort as
        fail(), but no receive slot was acquired, so the active counter is not touched.
        """
        with self.cond:
            self._resource_hit = True
            if not self._frozen:
                self._rollback("자원한계")
            else:
                self._note = "자원한계"
            self._abort_with(exc)
            self.cond.notify_all()

    def close(self):
        with self.cond:
            self._frozen = self._aborted = True
            self.cond.notify_all()


def _received_size(ctx):
    """Size of the just received fragment file (metadata only, never its content); 0 when unknown."""
    try:
        return max(0, os.path.getsize(ctx.get("fragment_filename_sanitized")))
    except Exception:
        return 0


class ScopedAdaptiveHook:
    """Temporarily wraps FragmentFD._download_fragment for one job; always restores the original on exit."""

    def __init__(self, controller):
        self.controller = controller
        self._fragment = None
        self._orig = None

    def __enter__(self):
        try:
            from yt_dlp.downloader import dash, fragment, hls
            orig = fragment.FragmentFD.__dict__["_download_fragment"]
            controller = self.controller
            native_types = (hls.HlsFD, dash.DashSegmentsFD)

            def gated(fd_self, ctx, frag_url, info_dict, headers=None, request_data=None):
                try:
                    live = bool(info_dict.get("is_live") or info_dict.get("is_from_start") or ctx.get("live"))
                except Exception:
                    live = True
                if live or not isinstance(fd_self, native_types):
                    return orig(fd_self, ctx, frag_url, info_dict, headers, request_data)
                while True:
                    controller.acquire()
                    try:
                        result = orig(fd_self, ctx, frag_url, info_dict, headers, request_data)
                    except BaseException as exc:
                        try:
                            # continuedl is False: a retry restarts this same fragment from byte 0 (no partial reuse)
                            can_retry = not ctx["dl"].params.get("continuedl", True)
                        except Exception:
                            can_retry = False
                        if controller.fail(exc, can_retry):
                            continue
                        raise
                    ok = bool(result)
                    controller.release(ok, _received_size(ctx) if ok else 0,
                                       None if ok else RuntimeError("조각 다운로드에 실패했습니다."))
                    return result

            fragment.FragmentFD._download_fragment = gated
            self._fragment, self._orig = fragment, orig
        except Exception as exc:
            self.controller.close()
            raise RuntimeError(f"적응형 다운로드 훅 설치 실패: {type(exc).__name__}") from exc
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            if self._fragment is not None:
                self._fragment.FragmentFD._download_fragment = self._orig
        finally:
            self._fragment = self._orig = None
            self.controller.close()
