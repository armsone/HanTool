"""
HttpsDown progressive HTTP multi-connection adaptive byte-range downloader for direct media.

Implements concurrent HTTP byte ranges for direct media using yt-dlp's existing network stack
(ydl.urlopen) and progress/file semantics. Reuses AdaptiveFragmentController for dynamic capacity
scaling (starting at 1 connection, probing N+1, rolling back to stable capacity on no gain or error).
Only intercepts exact HttpFD instances for non-live HTTP/HTTPS downloads.
"""

from email.utils import parsedate_to_datetime
import os
import re
import threading
import time

try:
    from yt_dlp.networking import Request
except ImportError:
    try:
        from yt_dlp.utils.networking import Request
    except ImportError:
        from urllib.request import Request

try:
    from yt_dlp.networking.exceptions import IncompleteRead
except ImportError:
    try:
        from http.client import IncompleteRead
    except ImportError:
        class IncompleteRead(Exception):
            pass


class RangeIntegrityError(IncompleteRead):
    """Dedicated fixed error for byte-range integrity failures."""

    def __init__(self, reason_id):
        super().__init__(f"range_integrity:{reason_id}")
        self.reason_id = str(reason_id)


try:
    from fragments import FragmentAborted
except ImportError:
    class FragmentAborted(Exception):
        """Raised for a download that never started or was aborted because the job was stopped or failed."""

CHUNK_SIZE = 4 * 1024 * 1024  # 4 MiB chunks
_PROGRESS_INTERVAL = 0.2


def probe_progressive(ydl, info_dict):
    """
    Probe the media URL for byte range support, exact total length, identity encoding and validator.
    Returns dict with total_bytes, validator, final_url, or None if ranges are unsupported or validator is missing.
    """
    url = info_dict.get("url")
    if not url:
        return None
    headers = dict(info_dict.get("http_headers") or {})
    headers["Range"] = "bytes=0-0"
    headers["Accept-Encoding"] = "identity"

    req = Request(url, headers=headers)
    try:
        resp = ydl.urlopen(req)
    except Exception:
        return None

    try:
        status = getattr(resp, "status", None) or getattr(resp, "code", None)
        if status != 206:
            return None

        cr = resp.headers.get("Content-Range") or ""
        m = re.match(r"^bytes\s+0-0/(\d+)$", cr.strip())
        if not m:
            return None
        total_bytes = int(m.group(1))
        if total_bytes <= 0:
            return None

        cl = resp.headers.get("Content-Length")
        if cl is None:
            return None
        cl_str = cl.strip()
        if not cl_str.isdigit() or int(cl_str) != 1:
            return None

        ce = resp.headers.get("Content-Encoding")
        if ce and ce.strip().lower() not in ("", "identity"):
            return None

        final_url = resp.geturl() if hasattr(resp, "geturl") else (getattr(resp, "url", None) or url)
        if not final_url:
            final_url = url

        etag = resp.headers.get("ETag")
        last_modified = resp.headers.get("Last-Modified")

        validator = None
        if etag:
            etag_s = etag.strip()
            # Validate quoted strong syntax (RFC 7232: strong, enclosed in DQUOTE)
            if not etag_s.startswith(("W/", "w/")) and len(etag_s) >= 2 and etag_s.startswith('"') and etag_s.endswith('"'):
                validator = ("ETag", etag_s)

        if validator is None and last_modified:
            lm_str = last_modified.strip()
            date_hdr = resp.headers.get("Date")
            if date_hdr:
                try:
                    lm_dt = parsedate_to_datetime(lm_str)
                    date_dt = parsedate_to_datetime(date_hdr.strip())
                    if lm_dt is not None and date_dt is not None:
                        # Demonstrably strong/reliable fallback: Date >= Last-Modified + 60s
                        if date_dt.timestamp() >= lm_dt.timestamp() + 60:
                            validator = ("Last-Modified", lm_str)
                except Exception:
                    pass

        if validator is None:
            return None

        return {
            "total_bytes": total_bytes,
            "validator": validator,
            "final_url": final_url,
        }
    except Exception:
        return None
    finally:
        try:
            resp.close()
        except Exception:
            pass


def real_download_progressive(fd_self, filename, info_dict, controller, orig):
    """
    Concurrently download direct HTTP(S) media using adaptive byte ranges when supported.
    Falls back safely to the original native single-connection download on probe rejection or range error.
    """
    ydl = fd_self.ydl
    probe = probe_progressive(ydl, info_dict)
    if not probe:
        info_dict["_progressive_fallback"] = "probe_failed"
        info_dict["progressive_error"] = "probe_failed"
        return orig(fd_self, filename, info_dict)

    total_bytes = probe["total_bytes"]
    validator = probe["validator"]
    final_url = probe.get("final_url") or info_dict.get("url")

    pool_cap = getattr(controller, "pool_capacity", 1)
    if total_bytes <= CHUNK_SIZE or pool_cap <= 1:
        info_dict["_progressive_fallback"] = "single_chunk_or_pool_1"
        info_dict["progressive_error"] = "single_chunk_or_pool_1"
        return orig(fd_self, filename, info_dict)

    chunks = []
    offset = 0
    while offset < total_bytes:
        end = min(offset + CHUNK_SIZE - 1, total_bytes - 1)
        chunks.append((offset, end))
        offset = end + 1

    num_chunks = len(chunks)
    if num_chunks < 2:
        info_dict["_progressive_fallback"] = "few_chunks"
        info_dict["progressive_error"] = "few_chunks"
        return orig(fd_self, filename, info_dict)

    part_filename = fd_self.temp_name(filename) if hasattr(fd_self, "temp_name") else filename + ".part"
    if os.path.exists(part_filename):
        try:
            os.remove(part_filename)
        except OSError:
            pass

    try:
        part_file = open(part_filename, "wb+")
    except Exception:
        info_dict["_progressive_fallback"] = "part_file_error"
        info_dict["progressive_error"] = "part_file_error"
        return orig(fd_self, filename, info_dict)

    file_lock = threading.Lock()
    progress_lock = threading.Lock()
    queue_lock = threading.Lock()

    next_idx = [0]
    committed_bytes = [0]
    active_worker_bytes = {}
    last_progress_time = [0.0]
    start_time = time.time()

    stop_event = getattr(controller, "stop_event", None)
    aborted = threading.Event()
    error_ref = [None]

    def report_progress(force=False):
        now = time.time()
        if not force and now - last_progress_time[0] < _PROGRESS_INTERVAL:
            return
        last_progress_time[0] = now
        done = committed_bytes[0] + sum(active_worker_bytes.values())
        done = min(done, total_bytes)
        elapsed = max(0.001, now - start_time)
        speed = done / elapsed
        eta = (total_bytes - done) / speed if speed > 0 else 0.0

        status_dict = {
            "status": "downloading",
            "downloaded_bytes": done,
            "total_bytes": total_bytes,
            "filename": filename,
            "tmpfilename": part_filename,
            "speed": speed,
            "eta": eta,
            "elapsed": elapsed,
            "info_dict": info_dict,
            "progressive": True,
        }
        if hasattr(fd_self, "_hook_progress"):
            fd_self._hook_progress(status_dict, info_dict)

    base_headers = dict(fd_self.params.get("http_headers") or {})
    base_headers.update(info_dict.get("http_headers") or {})
    val_type, val_value = validator

    def fetch_range_data(worker_id, start, end):
        headers = dict(base_headers)
        headers["Range"] = f"bytes={start}-{end}"
        headers["Accept-Encoding"] = "identity"
        headers["If-Range"] = val_value

        req = Request(final_url, headers=headers)
        resp = ydl.urlopen(req)
        try:
            resp_url = resp.geturl() if hasattr(resp, "geturl") else getattr(resp, "url", None)
            if resp_url and final_url and resp_url != final_url:
                raise RangeIntegrityError("url_mismatch")

            status = getattr(resp, "status", None) or getattr(resp, "code", None)
            if status != 206:
                raise RangeIntegrityError("status_not_206")

            cr = resp.headers.get("Content-Range") or ""
            m = re.match(r"^bytes\s+(\d+)-(\d+)/(\d+)$", cr.strip())
            if not m:
                raise RangeIntegrityError("invalid_content_range")
            r_start, r_end, r_total = int(m.group(1)), int(m.group(2)), int(m.group(3))
            if r_start != start or r_end != end or r_total != total_bytes:
                raise RangeIntegrityError("content_range_mismatch")

            expected_len = end - start + 1
            cl = resp.headers.get("Content-Length")
            if cl is None:
                raise RangeIntegrityError("missing_content_length")
            try:
                cl_int = int(cl.strip())
            except ValueError:
                raise RangeIntegrityError("invalid_content_length")
            if cl_int != expected_len:
                raise RangeIntegrityError("content_length_mismatch")

            ce = resp.headers.get("Content-Encoding")
            if ce and ce.strip().lower() not in ("", "identity"):
                raise RangeIntegrityError("content_encoding_unsupported")

            if val_type == "ETag":
                cur_etag = resp.headers.get("ETag")
                if not cur_etag:
                    raise RangeIntegrityError("missing_etag")
                if cur_etag.strip() != val_value:
                    raise RangeIntegrityError("etag_mismatch")
            elif val_type == "Last-Modified":
                cur_lm = resp.headers.get("Last-Modified")
                if not cur_lm:
                    raise RangeIntegrityError("missing_last_modified")
                if cur_lm.strip() != val_value:
                    raise RangeIntegrityError("last_modified_mismatch")

            buffers = []
            received = 0
            while received < expected_len:
                if (stop_event is not None and stop_event.is_set()) or aborted.is_set():
                    raise FragmentAborted("다운로드가 중단되었습니다.")
                chunk = resp.read(min(65536, expected_len - received))
                if not chunk:
                    break
                buffers.append(chunk)
                received += len(chunk)
                with progress_lock:
                    active_worker_bytes[worker_id] = received
                    report_progress()

            data = b"".join(buffers)
            if len(data) != expected_len:
                raise RangeIntegrityError("short_body")
            return data
        finally:
            try:
                resp.close()
            except Exception:
                pass

    def worker_loop(worker_id):
        while not aborted.is_set():
            if stop_event is not None and stop_event.is_set():
                aborted.set()
                break

            with queue_lock:
                if next_idx[0] >= num_chunks:
                    break
                idx = next_idx[0]
                next_idx[0] += 1

            start, end = chunks[idx]
            expected_len = end - start + 1

            try:
                controller.acquire()
            except Exception as e:
                aborted.set()
                if error_ref[0] is None:
                    error_ref[0] = e
                break

            if aborted.is_set():
                controller.release(ok=False, error=error_ref[0])
                break

            attempt = 0
            success = False
            while attempt < 2 and not success and not aborted.is_set():
                attempt += 1
                try:
                    data = fetch_range_data(worker_id, start, end)
                    with file_lock:
                        part_file.seek(start)
                        part_file.write(data)
                        part_file.flush()
                    with progress_lock:
                        committed_bytes[0] += expected_len
                        active_worker_bytes[worker_id] = 0
                        report_progress()
                    success = True
                    controller.release(ok=True, nbytes=expected_len)
                except Exception as exc:
                    with progress_lock:
                        active_worker_bytes[worker_id] = 0
                    can_retry = (attempt == 1 and not (stop_event and stop_event.is_set()) and not aborted.is_set())
                    retry_allowed = controller.fail(exc, can_retry)
                    if retry_allowed and not (stop_event and stop_event.is_set()):
                        try:
                            controller.acquire()
                        except Exception as acq_err:
                            aborted.set()
                            if error_ref[0] is None:
                                error_ref[0] = acq_err
                            break
                        continue
                    else:
                        aborted.set()
                        if error_ref[0] is None:
                            error_ref[0] = exc
                        break

    worker_count = max(1, min(pool_cap, num_chunks))
    workers = []
    start_failed = False
    try:
        try:
            for wid in range(worker_count):
                t = threading.Thread(target=worker_loop, args=(wid,), name=f"htd-prog-{wid}")
                t.daemon = True
                workers.append(t)
                t.start()
        except BaseException as start_err:
            start_failed = True
            aborted.set()
            if error_ref[0] is None:
                error_ref[0] = start_err
            if hasattr(controller, "cond"):
                try:
                    with controller.cond:
                        controller._frozen = controller._aborted = True
                        controller.cond.notify_all()
                except Exception:
                    pass
        finally:
            for w in workers:
                try:
                    w.join()
                except Exception:
                    pass
    finally:
        try:
            part_file.close()
        except Exception:
            pass

    for w in workers:
        if w.is_alive():
            try:
                w.join(timeout=1.0)
            except Exception:
                pass

    if stop_event is not None and stop_event.is_set():
        if os.path.exists(part_filename):
            try:
                os.remove(part_filename)
            except OSError:
                pass
        raise FragmentAborted("다운로드가 중단되었습니다.")

    if start_failed or aborted.is_set() or error_ref[0] is not None:
        if os.path.exists(part_filename):
            try:
                os.remove(part_filename)
            except OSError:
                pass
        err = error_ref[0]
        reason = getattr(err, "reason_id", None) or (type(err).__name__ if err else "aborted")
        info_dict["_progressive_fallback"] = str(reason)
        info_dict["progressive_error"] = str(reason)
        return orig(fd_self, filename, info_dict)

    try:
        actual_size = os.path.getsize(part_filename)
    except OSError:
        actual_size = -1

    if actual_size != total_bytes:
        if os.path.exists(part_filename):
            try:
                os.remove(part_filename)
            except OSError:
                pass
        info_dict["_progressive_fallback"] = "size_mismatch"
        info_dict["progressive_error"] = "size_mismatch"
        return orig(fd_self, filename, info_dict)

    if hasattr(fd_self, "try_rename"):
        fd_self.try_rename(part_filename, filename)
    else:
        if os.path.exists(filename):
            try:
                os.remove(filename)
            except OSError:
                pass
        os.replace(part_filename, filename)

    report_progress(force=True)

    finished_dict = {
        "status": "finished",
        "filename": filename,
        "downloaded_bytes": total_bytes,
        "total_bytes": total_bytes,
        "info_dict": info_dict,
    }
    if hasattr(fd_self, "_hook_progress"):
        fd_self._hook_progress(finished_dict, info_dict)

    info_dict["filepath"] = filename
    return True


class ScopedProgressiveHook:
    """Temporarily hooks direct HTTP receives and preserves typed retry diagnostics for one job."""

    def __init__(self, controller):
        self.controller = controller
        self._http = None
        self._orig_http = None
        self._common = None
        self._orig_retry = None

    def __enter__(self):
        try:
            from yt_dlp.downloader import common, http
            orig_http = http.HttpFD.__dict__["real_download"]
            orig_retry = common.FileDownloader.__dict__["report_retry"]
            controller = self.controller

            def progressive_download(fd_self, filename, info_dict):
                if type(fd_self) is not http.HttpFD:
                    return orig_http(fd_self, filename, info_dict)
                if "frag_resume_len" in info_dict:
                    return orig_http(fd_self, filename, info_dict)
                if info_dict.get("request_data") is not None:
                    return orig_http(fd_self, filename, info_dict)
                method = str(info_dict.get("http_method") or "GET").upper()
                if method != "GET":
                    return orig_http(fd_self, filename, info_dict)
                proto = str(info_dict.get("protocol") or "").lower()
                if proto not in ("http", "https"):
                    return orig_http(fd_self, filename, info_dict)
                is_live = bool(info_dict.get("is_live") or info_dict.get("is_from_start"))
                if is_live:
                    return orig_http(fd_self, filename, info_dict)
                return real_download_progressive(fd_self, filename, info_dict, controller, orig_http)

            def typed_retry(fd_self, err, *args, **kwargs):
                params = getattr(getattr(fd_self, "ydl", None), "params", {})
                logger = params.get("logger") if isinstance(params, dict) else None
                if isinstance(err, BaseException) and logger is not None:
                    cap = getattr(logger, "capture_exception", None)
                    if callable(cap):
                        cap(err)
                return orig_retry(fd_self, err, *args, **kwargs)

            http.HttpFD.real_download = progressive_download
            self._http, self._orig_http = http, orig_http
            common.FileDownloader.report_retry = typed_retry
            self._common, self._orig_retry = common, orig_retry
        except Exception as exc:
            self._cleanup()
            raise RuntimeError(f"점진적 HTTP 다운로드 훅 설치 실패: {type(exc).__name__}") from exc
        return self

    def _cleanup(self):
        try:
            if self._http is not None and self._orig_http is not None:
                self._http.HttpFD.real_download = self._orig_http
        finally:
            self._http = self._orig_http = None
        try:
            if self._common is not None and self._orig_retry is not None:
                self._common.FileDownloader.report_retry = self._orig_retry
        finally:
            self._common = self._orig_retry = None

    def __exit__(self, exc_type, exc_val, exc_tb):
        self._cleanup()
