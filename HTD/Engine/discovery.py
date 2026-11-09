"""
HttpsDown embedded-player HLS discovery (fallback for pages yt-dlp's Generic extractor cannot resolve).

Used only when Generic returned a playlist of page media / no formats / "Unsupported URL" for the job address.
Everything is bounded and goes through the job's own YoutubeDL opener (proxy, cookie jar, TLS verification, default
headers stay exactly as configured), never urllib/requests directly.

What is read (structure only; titles and body text are never interpreted):
  * <iframe src|data-src> of the page and of fetched frames: nesting depth <= 2, at most 4 frames fetched
  * <video src>/<source src> inside fetched frames (the page's own HTML5 media were already judged by Generic)
  * literal URL values of player-config fields inside inline <script> blocks (file/src/url/hls/... keys,
    hls.loadSource("...")); external scripts are not fetched
Candidates are classified by the server's answer, not by the URL's extension: HEAD Content-Type first, then (only
for mpegurl/text/html/octet/unknown types) a bounded GET whose body must start with #EXTM3U. Exactly one distinct
HLS manifest and no other actual media must remain, otherwise the caller gets a truthful "choose in the browser" reason.

URL safety: discovery runs ONLY when the job goes through the app's own authenticated loopback connection helper
(trusted_helper_proxy); the helper's public-DNS / exact-host / port validation is the network boundary (no local DNS,
no extra request handlers, no direct route). Without it the caller reports "turn on connection help or choose in the
in-app browser" instead. On top of that: the job address and its exact origin keep the existing behavior; every other
URL (frames, candidates, redirect results, manifest references) must be https on port 443/8443 with a syntactically
valid DNS name (no IP literals, no localhost/.local/... suffixes). Redirect hops are followed by yt-dlp's own handler;
their final URL is re-checked before any byte of the response is used.
Signed manifest URLs live in memory for one attempt only and are never put into events, errors or files.
"""

import contextlib
import hashlib
import html
from html.parser import HTMLParser
import http.cookiejar
import json
import re
import secrets
import signal
import threading
import time
from urllib.parse import urljoin, urlsplit

import connection
import keys

MEDIA_ID_PREFIX = "pageembed-"
MAX_FRAMES = 4
MAX_DEPTH = 2
MAX_PROBES = 12
MAX_PAGE_BYTES = 1_500_000
MAX_SCRIPT_CHARS = 600_000
MAX_MANIFEST_BYTES = 4_000_000
MAX_REF_HOSTS = 16
DEADLINE = 30.0
HARD_DEADLINE = DEADLINE + 2.0
REQUEST_TIMEOUT = 10.0
READ_CHUNK = 65536
SAFE_PORTS = (None, 443, 8443)

_IFRAME_RE = re.compile(r"<iframe\b[^>]*>", re.I)
_IFRAME_SCAN_RE = re.compile(r"<iframe\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", re.I)
_MEDIA_TAG_RE = re.compile(r"<(?:video|source)\b[^>]*>", re.I)
_MEDIA_TAG_SCAN_RE = re.compile(r"<(?:video|source)\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", re.I)
_DIV_TAG_RE = re.compile(r"<div\b[^>]*>", re.I)
_DIV_TAG_SCAN_RE = re.compile(r"<div\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>", re.I)
_SCRIPT_RE = re.compile(r"<script\b([^>]*)>(.*?)</script\s*>", re.I | re.S)
_ATTR_RE = r"""(?:^|\s){name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"""
_CONFIG_RE = re.compile(
    r"""(?<![\w$.\-])["']?(?:file|src|source|url|hls|hlsUrl|hls_url|m3u8|manifest|manifestUrl|playlist|stream|"""
    r"""streamUrl|videoUrl|video_url)["']?\s*[:=]\s*["']([^"'\s<>]{1,2048})["']"""
    r"""|\.loadSource\(\s*["']([^"'\s<>]{1,2048})["']""")
_HLS_TYPES = ("application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl")
_MAGIC_TYPES = _HLS_TYPES + ("text/html", "text/plain", "application/octet-stream", "binary/octet-stream", "")


def stable_media_id(page_url):
    """Query-stable identity of the job address itself (never of a signed manifest URL)."""
    p = urlsplit(page_url)
    base = f"{p.scheme.lower()}://{(p.hostname or '').lower()}{':%d' % p.port if p.port else ''}{p.path}" \
           f"{'?' + p.query if p.query else ''}"
    return MEDIA_ID_PREFIX + hashlib.sha256(base.encode("utf-8", "replace")).hexdigest()[:20]


def trusted_helper_proxy(proxy):
    """The app's own connection helper: http://user:pass@127.0.0.1:<ephemeral port>, nothing else (no secrets logged)."""
    try:
        p = urlsplit(str(proxy or ""))
        port = p.port
    except ValueError:
        return False
    return (p.scheme == "http" and p.hostname == "127.0.0.1" and bool(p.username) and bool(p.password)
            and port is not None and 1024 <= port <= 65535 and p.path in ("", "/") and not p.query and not p.fragment)


def is_embed_identity(extractor, media_id, page_url):
    return str(extractor or "").lower() == "generic" and str(media_id or "") == stable_media_id(page_url)


def generic_unsupported(exc):
    """True when yt-dlp's Generic extractor gave up on the address ("Unsupported URL")."""
    from yt_dlp.utils import UnsupportedError
    seen = [exc, (getattr(exc, "exc_info", None) or (None, None, None))[1], getattr(exc, "__context__", None)]
    return any(isinstance(x, UnsupportedError) for x in seen)


def eligible(info):
    """Generic result that the app cannot use as is: page media playlist or no formats at all."""
    if not isinstance(info, dict) or str(info.get("extractor_key") or "") != "Generic":
        return False
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
        return False
    if info.get("_type") in ("playlist", "multi_video"):
        return True
    if info.get("entries") is not None and not info.get("formats"):
        return True
    return not info.get("formats") and not info.get("url")


# ----------------------------------------------------------------------------
# URL safety
# ----------------------------------------------------------------------------

def _origin(url):
    p = urlsplit(url)
    return (p.scheme.lower(), (p.hostname or "").lower().rstrip("."), p.port)


def _origin_text(url):
    s, h, port = _origin(url)
    return f"{s}://{h}{':%d' % port if port else ''}"


class _Guard:
    def __init__(self, page_url, proxied):
        self.page_origin = _origin(page_url)
        self.proxied = proxied

    def host_ok(self, host, port):
        host = str(host or "").lower().rstrip(".")
        if connection._ip_literal(host) is not None or not connection.valid_hostname(host):
            return False
        if host == "localhost" or host.endswith(connection._BLOCKED_SUFFIXES):
            return False
        # The app's connection helper vets every resolved address itself (public only, no rebinding).
        # Without it there is no off-route request at all (no local DNS check is attempted here).
        return bool(self.proxied)

    def ok(self, url, allow_page_origin=True):
        try:
            p = urlsplit(url)
            port = p.port
        except ValueError:
            return False
        if p.username or p.password or not p.hostname:
            return False
        if allow_page_origin and _origin(url) == self.page_origin:
            return True   # same trust as the job address the user entered (existing behavior)
        if p.scheme.lower() != "https" or port not in SAFE_PORTS:
            return False
        return self.host_ok(p.hostname, port)


def _referer_headers(src_url, dst_url, origin_header=False):
    """Browser default policy (strict-origin-when-cross-origin): full URL same-origin, origin only cross-origin."""
    src_scheme = _origin(src_url)[0]
    if src_scheme == "https" and _origin(dst_url)[0] != "https":
        return {}
    if _origin(src_url) == _origin(dst_url):
        return {"Referer": src_url.split("#", 1)[0]}
    out = {"Referer": _origin_text(src_url) + "/"}
    if origin_header:
        out["Origin"] = _origin_text(src_url)
    return out


# ----------------------------------------------------------------------------
# Bounded network through the job's YoutubeDL
# ----------------------------------------------------------------------------

class DiscoveryDiagnostics:
    def __init__(self):
        self.version = 1
        self.terminal = None
        self.last_stage = None
        self.last_completed_stage = None
        self.frames = 0
        self.candidates = 0
        self.probes = 0
        self.network_errors = 0
        self.rejected = 0
        self.truncated = False
        self.steps = []

    def record_stage(self, stage, depth=None):
        if stage in ("page", "frame", "scan", "candidate_head", "candidate_get", "manifest", "references", "format_parse", "terminal"):
            self.last_stage = stage

    def record_completed(self, stage):
        if stage in ("page", "frame", "scan", "candidate_head", "candidate_get", "manifest", "references", "format_parse", "terminal"):
            self.last_completed_stage = stage

    def add_step(self, stage, result="ok", depth=None, http_status=None, mime=None, error=None, scan=None):
        self.record_stage(stage, depth=depth)
        valid_stages = ("page", "frame", "scan", "candidate_head", "candidate_get", "manifest", "references", "format_parse", "terminal")
        valid_results = ("ok", "error", "none", "hls", "media", "other", "rejected", "limit", "found", "ambiguous", "unbounded", "unreachable", "unsupported", "unsafe", "assist", "browser_required")
        valid_mimes = ("html", "hls", "json", "media", "image", "other", "unknown")
        valid_errors = ("http", "dns", "tls", "proxy", "timeout", "network", "unsafe", "other")
        st = stage if stage in valid_stages else "terminal"
        res = result if result in valid_results else "other"
        step = {"stage": st, "result": res}
        if depth is not None and isinstance(depth, int) and 0 <= depth <= 2:
            step["depth"] = depth
        if http_status is not None and isinstance(http_status, int) and 100 <= http_status <= 599:
            step["httpStatus"] = http_status
        if mime in valid_mimes:
            step["mime"] = mime
        if error in valid_errors:
            step["error"] = error
        if scan is not None and isinstance(scan, dict) and st == "scan":
            step["scan"] = scan

        if len(self.steps) < 23:
            self.steps.append(step)
        else:
            self.truncated = True
            if len(self.steps) == 23:
                self.steps.append(step)
            else:
                self.steps[23] = step

    def finish(self, terminal_reason):
        valid_terminals = ("none", "ambiguous", "unbounded", "unreachable", "unsupported", "unsafe", "assist", "browser_required", "found", "error")
        term = terminal_reason if terminal_reason in valid_terminals else "error"
        self.terminal = term
        res = term if term in ("ok", "error", "none", "hls", "media", "other", "rejected", "limit", "found", "ambiguous", "unbounded", "unreachable", "unsupported", "unsafe", "assist", "browser_required") else "other"
        terminal_step = {"stage": "terminal", "result": res}
        if len(self.steps) < 23:
            self.steps.append(terminal_step)
        else:
            if len(self.steps) == 23 and not self.truncated:
                self.steps.append(terminal_step)
            else:
                self.truncated = True
                if len(self.steps) < 24:
                    self.steps.append(terminal_step)
                else:
                    self.steps[23] = terminal_step

    def snapshot(self):
        raw = {
            "version": 1,
            "terminal": self.terminal,
            "lastStage": self.last_stage,
            "lastCompletedStage": self.last_completed_stage,
            "counts": {
                "frames": self.frames,
                "candidates": self.candidates,
                "probes": self.probes,
                "networkErrors": self.network_errors,
                "rejected": self.rejected,
                "truncated": self.truncated,
            },
            "steps": list(self.steps[:24])
        }
        return sanitize_discovery_diagnostics(raw)


def _classify_mime(ctype):
    if not ctype or not isinstance(ctype, str):
        return "unknown"
    ct = ctype.strip().lower()
    if ct == "text/html" or "html" in ct:
        return "html"
    if "mpegurl" in ct or ct in _HLS_TYPES:
        return "hls"
    if ct.startswith("application/json") or "json" in ct:
        return "json"
    if ct.startswith(("video/", "audio/")):
        return "media"
    if ct.startswith("image/"):
        return "image"
    return "other"


def _classify_error(exc):
    import socket
    import ssl
    try:
        from yt_dlp.networking.exceptions import (HTTPError, ProxyError, SSLError, TransportError)
    except ImportError:
        HTTPError = ProxyError = SSLError = TransportError = ()
    if isinstance(exc, PermissionError):
        return "unsafe", None
    if isinstance(exc, HTTPError):
        status = getattr(exc, "status", None)
        status = status if isinstance(status, int) and 100 <= status <= 599 else None
        return "http", status
    if isinstance(exc, (SSLError, ssl.SSLError)):
        return "tls", None
    if isinstance(exc, ProxyError):
        return "proxy", None
    if isinstance(exc, (socket.gaierror, socket.herror)):
        return "dns", None
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return "timeout", None
    if isinstance(exc, (TransportError, ConnectionError)):
        return "network", None
    return "other", None


def _safe_int(val, default=0, low=0, high=None):
    if isinstance(val, bool) or not isinstance(val, int):
        return default
    if high is not None:
        return max(low, min(high, val))
    return max(low, val)

def sanitize_discovery_diagnostics(raw):
    if not isinstance(raw, dict):
        return None
    valid_terminals = ("none", "ambiguous", "unbounded", "unreachable", "unsupported", "unsafe", "assist", "browser_required", "found", "error")
    valid_stages = ("page", "frame", "scan", "candidate_head", "candidate_get", "manifest", "references", "format_parse")
    valid_results = ("ok", "error", "none", "hls", "media", "other", "rejected", "limit", "found", "ambiguous", "unbounded", "unreachable", "unsupported", "unsafe", "assist", "browser_required")
    valid_mimes = ("html", "hls", "json", "media", "image", "other", "unknown")
    valid_errors = ("http", "dns", "tls", "proxy", "timeout", "network", "unsafe", "other")

    terminal = raw.get("terminal")
    last_stage = raw.get("lastStage")
    last_completed = raw.get("lastCompletedStage")
    counts_in = raw.get("counts") if isinstance(raw.get("counts"), dict) else {}

    raw_steps = raw.get("steps") if isinstance(raw.get("steps"), list) else []
    input_truncated = counts_in.get("truncated") is True or len(raw_steps) > 24

    counts = {
        "frames": _safe_int(counts_in.get("frames"), 0, 0, 4),
        "candidates": _safe_int(counts_in.get("candidates"), 0, 0, 64),
        "probes": _safe_int(counts_in.get("probes"), 0, 0, 12),
        "networkErrors": _safe_int(counts_in.get("networkErrors"), 0, 0, 32),
        "rejected": _safe_int(counts_in.get("rejected"), 0, 0, 64),
        "truncated": input_truncated
    }

    if len(raw_steps) > 24:
        has_term = isinstance(raw_steps[-1], dict) and raw_steps[-1].get("stage") == "terminal"
        steps_to_process = raw_steps[:23] + ([raw_steps[-1]] if has_term else [raw_steps[23]])
    else:
        steps_to_process = raw_steps

    steps = []
    for s in steps_to_process[:24]:
        if not isinstance(s, dict):
            continue
        stage = s.get("stage")
        result = s.get("result")
        is_valid_stage = stage in valid_stages or stage == "terminal"
        if not is_valid_stage or result not in valid_results:
            continue
        clean_step = {"stage": stage, "result": result}
        d = s.get("depth")
        if not isinstance(d, bool) and isinstance(d, int) and 0 <= d <= 2:
            clean_step["depth"] = d
        hs = s.get("httpStatus")
        if not isinstance(hs, bool) and isinstance(hs, int) and 100 <= hs <= 599:
            clean_step["httpStatus"] = hs
        m = s.get("mime")
        if m in valid_mimes:
            clean_step["mime"] = m
        err = s.get("error")
        if err in valid_errors:
            clean_step["error"] = err
        if stage == "scan" and isinstance(s.get("scan"), dict):
            raw_scan = s.get("scan")
            scan_keys = ("iframeTags", "mediaTags", "dataAttributes", "scriptValues",
                         "empty", "scheme", "tooLong", "notURLLike", "invalid", "accepted")
            clean_scan = {}
            for k in scan_keys:
                val = raw_scan.get(k)
                if not isinstance(val, bool) and isinstance(val, int):
                    clean_scan[k] = max(0, min(64, val))
            raw_html = raw_scan.get("html")
            if isinstance(raw_html, dict):
                clean_html = {}
                for k in ("tagsSeen", "srcSeen", "nonemptySrcSeen"):
                    v = raw_html.get(k)
                    if not isinstance(v, bool) and isinstance(v, int) and 0 <= v <= 64:
                        clean_html[k] = v
                pe = raw_html.get("parseError")
                if type(pe) is bool:
                    clean_html["parseError"] = pe
                if len(clean_html) == 4:
                    if "inputTruncated" in raw_html:
                        it = raw_html.get("inputTruncated")
                        if type(it) is bool:
                            clean_html["inputTruncated"] = it
                    clean_scan["html"] = clean_html
            if clean_scan:
                clean_step["scan"] = clean_scan
        steps.append(clean_step)

    out = {
        "version": 1,
        "counts": counts,
        "steps": steps
    }
    if terminal in valid_terminals:
        out["terminal"] = terminal
    if last_stage in valid_stages:
        out["lastStage"] = last_stage
    if last_completed in valid_stages and last_completed != "terminal":
        out["lastCompletedStage"] = last_completed
    return out


class _Net:
    def __init__(self, ydl, guard, diagnostics=None):
        from yt_dlp.networking import HEADRequest, Request
        self.ydl, self.guard = ydl, guard
        self.Request, self.HEADRequest = Request, HEADRequest
        self.deadline = time.monotonic() + DEADLINE
        self.probes = 0
        self.diagnostics = diagnostics
        self.current_stage = "page"
        self.current_depth = 0

    def set_context(self, stage, depth=0):
        self.current_stage = stage
        self.current_depth = min(2, max(0, depth))

    def _timeout(self):
        left = self.deadline - time.monotonic()
        if left <= 1.0:
            raise TimeoutError("discovery deadline")
        return min(REQUEST_TIMEOUT, left)

    def open(self, url, headers, head=False):
        cls = self.HEADRequest if head else self.Request
        resp = self.ydl.urlopen(cls(url, headers=headers, extensions={"timeout": self._timeout()}))
        if not self.guard.ok(resp.url):
            resp.close()
            raise PermissionError("redirected to an unsafe address")
        return resp

    def read(self, url, headers, limit):
        stage = self.current_stage
        depth = self.current_depth
        if self.diagnostics:
            self.diagnostics.record_stage(stage, depth=depth)
        resp = None
        try:
            resp = self.open(url, headers)
            ctype = (resp.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            # Chunked so the overall deadline is checked between chunks (a trickling server cannot extend it
            # indefinitely); within one chunk only the socket timeout / the alarm of _hard_deadline applies.
            parts, size = [], 0
            while size <= limit:
                self._timeout()
                chunk = resp.read(min(READ_CHUNK, limit + 1 - size))
                if not chunk:
                    break
                parts.append(chunk)
                size += len(chunk)
            if self.diagnostics:
                status = getattr(resp, "status", None) or getattr(resp, "code", None)
                status_val = status if (not isinstance(status, bool) and isinstance(status, int) and 100 <= status <= 599) else None
                self.diagnostics.add_step(stage, result="ok", depth=depth, http_status=status_val, mime=_classify_mime(ctype))
                self.diagnostics.record_completed(stage)
            return resp.url, ctype, b"".join(parts)
        except PermissionError:
            raise
        except Exception as e:
            if self.diagnostics:
                self.diagnostics.network_errors = min(32, self.diagnostics.network_errors + 1)
                err_cat, err_stat = _classify_error(e)
                err_mime = None
                resp_obj = getattr(e, "response", None)
                if resp_obj is not None:
                    err_ct = (getattr(resp_obj, "headers", {}).get("Content-Type") or "").split(";", 1)[0].strip().lower()
                    if err_ct:
                        err_mime = _classify_mime(err_ct)
                self.diagnostics.add_step(stage, result="error", depth=depth, http_status=err_stat, mime=err_mime, error=err_cat)
            raise
        finally:
            if resp is not None:
                resp.close()


class _DeadlineHit(BaseException):
    """Raised by the discovery alarm; BaseException so no yt-dlp/network layer converts or swallows it."""


@contextlib.contextmanager
def _hard_deadline(seconds):
    """
    Whole-discovery wall-clock bound via SIGALRM (ITIMER_REAL), only on the main thread (where the engine runs jobs).
    Only SIGALRM is touched (SIGUSR1 stop / SIGTERM behavior unchanged); a previously installed SIGALRM handler and
    pending timer are restored afterwards (an earlier outer timer still fires, at most shortly after this scope).
    Off the main thread no alarm is possible and only the per-request/per-chunk deadline checks apply.
    """
    if threading.current_thread() is not threading.main_thread() or not hasattr(signal, "setitimer"):
        yield
        return

    def fire(_sig, _frame):
        raise _DeadlineHit()

    prev_handler = signal.signal(signal.SIGALRM, fire)
    prev_left, _interval = signal.setitimer(signal.ITIMER_REAL, 0)
    start = time.monotonic()
    signal.setitimer(signal.ITIMER_REAL, min(seconds, prev_left) if prev_left > 0 else seconds)
    try:
        yield
    finally:
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)   # one-shot: once this ran (or fired) nothing else is pending
        finally:
            signal.signal(signal.SIGALRM, prev_handler if prev_handler is not None else signal.SIG_DFL)
            if prev_left > 0:
                signal.setitimer(signal.ITIMER_REAL, max(prev_left - (time.monotonic() - start), 0.001))


def _attr(tag, name):
    m = re.search(_ATTR_RE.format(name=name), tag[1:], re.I)
    if not m:
        return None
    return html.unescape(next(g for g in m.groups() if g is not None)).strip()


def _abs(base, value):
    if not value or len(value) > 2048 or value.lower().startswith(("javascript:", "data:", "blob:", "about:", "#")):
        return None
    try:
        u = urljoin(base, value.replace("\\/", "/").replace("\\u0026", "&").replace("&amp;", "&"))
    except ValueError:
        return None
    return u.split("#", 1)[0] if u.lower().startswith(("http://", "https://")) else None


def _url_like(value):
    v = value.replace("\\/", "/")
    if v.lower().startswith(("http://", "https://", "//", "/")):
        return True
    return bool(re.match(r"^[\w.~%\-/]+\.[A-Za-z0-9]{1,6}(?:[?/][^\s]*)?$", v)) and "." in v.split("?", 1)[0]


_JS_ID_RE = re.compile(r"[A-Za-z_$][\w$]*")
_JS_NUM_RE = re.compile(r"\d[\w.]*")
_JS_REGEX_PRECEDERS = ("return", "typeof", "case", "in", "of", "delete", "void", "throw", "new", "else", "do")
_JS_URL_VALUE_RE = re.compile(r"[^\"'\s<>]{1,2048}")
MAX_JS_TOKENS = 100_000
MAX_LOADSOURCE_CALLS = 16


def _js_tokens(src):
    """
    Minimal comment/string-aware token list [(kind, value, block)] of one inline script, or None (fail closed) for
    anything not understood: template literals, regex literals, unterminated strings/comments, unbalanced braces,
    token overflow. kind: id|num|str|p; a str value is None when it holds an escape other than \\/ (not decoded).
    Nothing is executed; fake declarations inside comments/strings are never seen as code.
    """
    toks, parents, stack, n, i = [], {0: None}, [0], len(src), 0
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j + 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                return None
            i = j + 2
        elif c == "`":
            return None
        elif c in "\"'":
            j, parts, ok = i + 1, [], True
            while True:
                if j >= n or src[j] in "\r\n":
                    return None
                ch = src[j]
                if ch == c:
                    break
                if ch == "\\":
                    if src.startswith("\\/", j):
                        parts.append("/")
                        j += 2
                        continue
                    ok = False
                    j += 2
                    continue
                parts.append(ch)
                j += 1
            toks.append(("str", "".join(parts) if ok else None, stack[-1]))
            i = j + 1
        elif (m := _JS_ID_RE.match(src, i)):
            toks.append(("id", m.group(), stack[-1]))
            i = m.end()
        elif (m := _JS_NUM_RE.match(src, i)):
            toks.append(("num", m.group(), stack[-1]))
            i = m.end()
        else:
            if c == "/":
                prev = toks[-1] if toks else None
                if not prev or not (prev[0] == "num" or prev[0] == "id" and prev[1] not in _JS_REGEX_PRECEDERS
                                    or prev[0] == "p" and prev[1] in ")]"):
                    return None   # possible regex literal: its content could hide quotes/declarations
            elif c == "{":
                parents[len(parents)] = stack[-1]
                stack.append(len(parents) - 1)
            elif c == "}":
                if len(stack) < 2:
                    return None
                stack.pop()
            toks.append(("p", c, stack[-1]))
            i += 1
        if len(toks) > MAX_JS_TOKENS:
            return None
    return (toks, parents) if len(stack) == 1 else None


def _loadsource_literals(body):
    """
    URL literals of `.loadSource(IDENT)` where IDENT has exactly one `var|let|const IDENT = "literal";` in the same
    script (declared earlier, in an enclosing block) and no other use except further loadSource(IDENT) calls and
    `x.prop = IDENT;`, and the read-only guard `if (!IDENT) {`. Reassignment, shadowing, concatenation, calls, templates, unsupported escapes -> skipped.
    """
    parsed = _js_tokens(body)
    if not parsed:
        return []
    toks, parents = parsed
    n = len(toks)

    def is_p(k, v):
        return 0 <= k < n and toks[k][0] == "p" and toks[k][1] == v

    def is_id(k, v=None):
        return 0 <= k < n and toks[k][0] == "id" and (v is None or toks[k][1] == v)

    def decl_at(j):
        return (is_id(j - 1) and toks[j - 1][1] in ("var", "let", "const") and not is_p(j - 2, ".")
                and is_p(j + 1, "=") and j + 2 < n and toks[j + 2][0] == "str" and is_p(j + 3, ";"))

    def resolve(name, use):
        decl = None
        for j, t in enumerate(toks):
            if t[0] != "id" or t[1] != name or is_p(j - 1, ".") or j == use:
                continue
            if decl_at(j):
                if decl is not None:
                    return None   # duplicate declaration
                decl = j
            elif not ((is_p(j - 1, "(") and is_id(j - 2, "loadSource")
                       and is_p(j - 3, ".") and is_p(j + 1, ")"))
                      or (is_p(j - 1, "=") and is_id(j - 2) and is_p(j - 3, ".") and is_p(j + 1, ";"))
                      or (is_p(j - 1, "!") and is_p(j - 2, "(") and is_id(j - 3, "if")
                          and is_p(j + 1, ")") and is_p(j + 2, "{"))):
                return None   # reassignment, parameter, property key, operator use, ...
        if decl is None or decl > use:
            return None
        value = toks[decl + 2][1]
        block, scope = toks[use][2], toks[decl][2]
        while block is not None and block != scope:
            block = parents[block]
        if block is None or value is None or not _JS_URL_VALUE_RE.fullmatch(value):
            return None
        return value

    out, calls = [], 0
    for i in range(n - 4):
        if is_p(i, ".") and is_id(i + 1, "loadSource") and is_p(i + 2, "(") and is_id(i + 3) and is_p(i + 4, ")"):
            calls += 1
            if calls > MAX_LOADSOURCE_CALLS:
                break
            value = resolve(toks[i + 3][1], i + 3)
            if value and value not in out:
                out.append(value)
    return out


def _mount_literals(body):
    """
    URL literal of `VideoApiPlayer.mount(<any balanced first arg>, "literal", "hls", ...)`: the second top-level
    argument must be exactly one str token and the third exactly one str token `hls`. Later arguments (poster, array)
    are ignored. Variables, concatenation, templates, malformed calls and `obj.VideoApiPlayer` are skipped.
    """
    parsed = _js_tokens(body)
    if not parsed:
        return []
    toks, n = parsed[0], len(parsed[0])
    pairs = {")": "(", "]": "[", "}": "{"}
    out, calls = [], 0
    for i in range(n - 3):
        if not (toks[i][:2] == ("id", "VideoApiPlayer") and toks[i + 1][:2] == ("p", ".")
                and toks[i + 2][:2] == ("id", "mount") and toks[i + 3][:2] == ("p", "(")):
            continue
        if i and toks[i - 1][:2] == ("p", "."):
            continue
        calls += 1
        if calls > MAX_LOADSOURCE_CALLS:
            break
        args, cur, stack, closed = [], [], [], False
        for t in toks[i + 4:]:
            if t[0] == "p" and t[1] in "([{":
                stack.append(t[1])
            elif t[0] == "p" and t[1] in ")]}":
                if not stack:
                    if t[1] == ")":
                        args.append(cur)
                        closed = True
                    break
                if stack.pop() != pairs[t[1]]:
                    break
            elif t[0] == "p" and t[1] == "," and not stack:
                args.append(cur)
                cur = []
                continue
            cur.append(t)
        if not closed or len(args) < 3:
            continue
        a2, a3 = args[1], args[2]
        if len(a2) == 1 and a2[0][0] == "str" and len(a3) == 1 and a3[0][0] == "str" and a3[0][1] == "hls":
            value = a2[0][1]
            if value and _JS_URL_VALUE_RE.fullmatch(value) and value not in out:
                out.append(value)
    return out


def _observe_html(text, input_truncated=None):
    class _MediaObserver(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.tags_seen = 0
            self.src_seen = 0
            self.nonempty_src_seen = 0

        def handle_starttag(self, tag, attrs):
            if tag not in ("video", "source"):
                return
            self.tags_seen = min(64, self.tags_seen + 1)
            for k, v in attrs:
                if k == "src":
                    self.src_seen = min(64, self.src_seen + 1)
                    if v and v.strip():
                        self.nonempty_src_seen = min(64, self.nonempty_src_seen + 1)
                    break

    observer = None
    parse_error = False
    try:
        observer = _MediaObserver()
        observer.feed(text)
        observer.close()
    except TimeoutError:
        raise
    except Exception:
        parse_error = True

    summary = {
        "tagsSeen": max(0, min(64, getattr(observer, "tags_seen", 0))),
        "srcSeen": max(0, min(64, getattr(observer, "src_seen", 0))),
        "nonemptySrcSeen": max(0, min(64, getattr(observer, "nonempty_src_seen", 0))),
        "parseError": parse_error,
    }
    if isinstance(input_truncated, bool):
        summary["inputTruncated"] = input_truncated
    return summary


def _scan(page_url, text, frame_level, scan_stats=None, input_truncated=None):
    """Returns (iframe URLs, candidate URLs) from tags/attributes and inline-script config fields only."""
    if frame_level and isinstance(scan_stats, dict):
        scan_stats["html"] = _observe_html(text, input_truncated=input_truncated)
    if isinstance(scan_stats, dict):
        for k in ("iframeTags", "mediaTags", "dataAttributes", "scriptValues", "empty", "scheme",
                  "tooLong", "notURLLike", "invalid", "accepted"):
            scan_stats[k] = _safe_int(scan_stats.get(k), 0, 0, 64)

    def _obs_abs(url, val):
        u = _abs(url, val)
        if isinstance(scan_stats, dict):
            if u:
                scan_stats["accepted"] = min(64, scan_stats["accepted"] + 1)
            elif not val:
                scan_stats["empty"] = min(64, scan_stats["empty"] + 1)
            elif len(val) > 2048:
                scan_stats["tooLong"] = min(64, scan_stats["tooLong"] + 1)
            elif val.lower().startswith(("javascript:", "data:", "blob:", "about:", "#")):
                scan_stats["scheme"] = min(64, scan_stats["scheme"] + 1)
            else:
                scan_stats["invalid"] = min(64, scan_stats["invalid"] + 1)
        return u

    frames, cands = [], []
    for tag in _IFRAME_SCAN_RE.findall(text):
        if isinstance(scan_stats, dict):
            scan_stats["iframeTags"] = min(64, scan_stats["iframeTags"] + 1)
        src = _attr(tag, "src")
        u = _obs_abs(page_url, src) if src else None
        if not u:
            dsrc = _attr(tag, "data-src")
            u = _obs_abs(page_url, dsrc) if dsrc else None
        if u and u not in frames:
            frames.append(u)
    if frame_level:
        for tag in _MEDIA_TAG_SCAN_RE.findall(text):
            if isinstance(scan_stats, dict):
                scan_stats["mediaTags"] = min(64, scan_stats["mediaTags"] + 1)
            u = _obs_abs(page_url, _attr(tag, "src"))
            if u and u not in cands:
                cands.append(u)
    for tag in _DIV_TAG_SCAN_RE.findall(text):
        val = _attr(tag, "data-video-url")
        if val is not None and isinstance(scan_stats, dict):
            scan_stats["dataAttributes"] = min(64, scan_stats["dataAttributes"] + 1)
        u = _obs_abs(page_url, val) if val is not None else _abs(page_url, val)
        if u and u not in cands:
            cands.append(u)
    budget = MAX_SCRIPT_CHARS
    for attrs, body in _SCRIPT_RE.findall(text):
        stype = (_attr("<s " + attrs + ">", "type") or "").lower()
        if re.search(r"(?:^|\s)src\s*=", attrs, re.I) or budget <= 0 or \
                stype and "javascript" not in stype and stype != "module":
            continue   # external scripts are not fetched; JSON-LD/templates are content, not player config
        body = body[:budget]
        budget -= len(body)
        values = [m.group(1) or m.group(2) for m in _CONFIG_RE.finditer(body)]
        if ".loadSource" in body:
            values += _loadsource_literals(body)
        if "VideoApiPlayer" in body:
            values += _mount_literals(body)
        for value in values:
            if isinstance(scan_stats, dict):
                scan_stats["scriptValues"] = min(64, scan_stats["scriptValues"] + 1)
            if not _url_like(value):
                if isinstance(scan_stats, dict):
                    scan_stats["notURLLike"] = min(64, scan_stats["notURLLike"] + 1)
                continue
            u = _obs_abs(page_url, value)
            if u and u not in cands:
                cands.append(u)
    return frames, cands


def _decode(body):
    if body.startswith(b"\xef\xbb\xbf"):
        body = body[3:]
    return body.decode("utf-8", "ignore")


_META_TAG_RE = re.compile(r"<meta\b[^>]*>", re.I)
_TITLE_RE = re.compile(r"<title\b[^>]*>(.*?)</title\s*>", re.I | re.S)
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f​-‏‪-‮⁦-⁩﻿]")
MAX_TITLE_CHARS = 200
_PLACEHOLDER_TITLE = "내장 플레이어 영상"
_GENERIC_TITLES = frozenset(("index", "master", "playlist", "video", "stream", "chunklist", "manifest", "main",
                             "media", "hls", "m3u8", "video.m3u8", "playlist.m3u8", "index.m3u8", "master.m3u8"))


def _clean_title(value):
    t = _CONTROL_RE.sub(" ", html.unescape(str(value or "")))
    return " ".join(t.split())[:MAX_TITLE_CHARS].strip()


def _page_title(text):
    """Metadata title of the top-level page only (og:title > twitter:title > <title>); body text is never read."""
    head = text[:200_000]
    m_end = re.search(r"</head", head, re.I)
    if m_end:
        head = head[:m_end.start()]
    found = {}
    for tag in _META_TAG_RE.findall(head):
        key = (_attr(tag, "property") or _attr(tag, "name") or "").lower()
        if key in ("og:title", "twitter:title") and key not in found:
            found[key] = _clean_title(_attr(tag, "content"))
    for t in (found.get("og:title"), found.get("twitter:title")):
        if t:
            return t
    m = _TITLE_RE.search(head)
    return _clean_title(m.group(1)) if m else ""


def pick_title(base, source_url, page_title):
    """Existing meaningful title wins; absent / placeholder / Generic URL-basename titles use the page title."""
    base = base if isinstance(base, dict) else {}
    cur = str(base.get("title") or "").strip()
    stem = ""
    try:
        from urllib.parse import unquote
        stem = unquote(urlsplit(source_url or "").path.rsplit("/", 1)[-1]).strip()
    except ValueError:
        pass
    stem_noext = stem.rsplit(".", 1)[0] if "." in stem else stem
    generic_ie = str(base.get("extractor_key") or "").lower() == "generic" or not base
    placeholder = (not cur or cur == _PLACEHOLDER_TITLE
                   or generic_ie and (cur.lower() in _GENERIC_TITLES or cur in (stem, stem_noext)))
    if placeholder and page_title:
        return page_title
    return cur or _PLACEHOLDER_TITLE


def _frame_bindings(text):
    """
    Explicit public key-module options (wasmJs/wasmBin/expectedWasmHash) of the player's inline JS config; memory
    only. Same script filter as _scan; a name that is declared but not a plain literal (or conflicts) maps to None.
    """
    out = {}
    budget = MAX_SCRIPT_CHARS
    for attrs, body in _SCRIPT_RE.findall(text):
        stype = (_attr("<s " + attrs + ">", "type") or "").lower()
        if re.search(r"(?:^|\s)src\s*=", attrs, re.I) or budget <= 0 or \
                stype and "javascript" not in stype and stype != "module":
            continue   # external scripts are not fetched; JSON-LD/templates are content, not player config
        body = body[:budget]
        budget -= len(body)
        keys.merge_bindings(out, keys.extract_bindings(body))
    return out


def _classify(net, src_page, url):
    """('hls', final_url, text) | ('media', None, None) | ('other', None, None); raises on network problems."""
    net.probes += 1
    if net.diagnostics:
        net.diagnostics.probes = min(12, net.diagnostics.probes + 1)
        net.diagnostics.record_stage("candidate_head")
    hdrs = _referer_headers(src_page, url, origin_header=True)
    ctype = None
    try:
        resp = net.open(url, hdrs, head=True)
        try:
            status = getattr(resp, "status", None) or getattr(resp, "code", None)
            status_val = status if (not isinstance(status, bool) and isinstance(status, int) and 100 <= status <= 599) else None
            ctype = (resp.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            length = resp.headers.get("Content-Length")
            if net.diagnostics:
                net.diagnostics.add_step("candidate_head", result="ok", http_status=status_val, mime=_classify_mime(ctype))
                net.diagnostics.record_completed("candidate_head")
        finally:
            resp.close()
        if ctype.startswith(("video/", "audio/")) and ctype not in _HLS_TYPES:
            return "media", None, None
        if ctype not in _MAGIC_TYPES:
            return "other", None, None   # images, scripts, styles, ... (by the server's answer, not the extension)
        if length and length.isdigit() and int(length) > MAX_MANIFEST_BYTES:
            return "other", None, None
    except PermissionError:
        if net.diagnostics:
            net.diagnostics.add_step("candidate_head", result="unsafe", error="unsafe")
        raise
    except Exception as e:
        if net.diagnostics:
            net.diagnostics.network_errors = min(32, net.diagnostics.network_errors + 1)
            err_cat, err_stat = _classify_error(e)
            net.diagnostics.add_step("candidate_head", result="error", http_status=err_stat, error=err_cat)
        ctype = None   # HEAD refused (405 etc.): decide by the body's magic below
    if net.diagnostics:
        net.set_context("candidate_get", depth=net.current_depth)
    final, gtype, body = net.read(url, hdrs, MAX_MANIFEST_BYTES)
    if _decode(body[:512]).lstrip().startswith("#EXTM3U"):
        if len(body) > MAX_MANIFEST_BYTES:
            raise ValueError("manifest too large")
        if net.diagnostics:
            net.diagnostics.record_stage("manifest")
            net.diagnostics.add_step("manifest", result="hls", mime="hls")
            net.diagnostics.record_completed("manifest")
        return "hls", final, _decode(body)
    if gtype.startswith(("video/", "audio/")) and gtype not in _HLS_TYPES:
        if net.diagnostics:
            net.diagnostics.record_stage("manifest")
            net.diagnostics.add_step("manifest", result="media", mime=_classify_mime(gtype))
            net.diagnostics.record_completed("manifest")
        return "media", None, None
    if net.diagnostics:
        net.diagnostics.record_stage("manifest")
        net.diagnostics.add_step("manifest", result="other", mime=_classify_mime(gtype))
        net.diagnostics.record_completed("manifest")
    return "other", None, None


# ----------------------------------------------------------------------------
# Manifest references (no media/key/segment is ever fetched here)
# ----------------------------------------------------------------------------

def manifest_refs(text, base):
    """Absolute URLs referenced by an HLS playlist: variant/segment lines and URI="..." attributes."""
    out = []
    for line in text.splitlines()[:200_000]:
        line = line.strip()
        if not line:
            continue
        values = re.findall(r'URI="([^"]*)"', line) if line.startswith("#") else [line]
        for v in values:
            try:
                out.append(urljoin(base, v))
            except ValueError:
                out.append("invalid:")
    return out


def check_refs(text, base, guard):
    """Returns (ok, sorted exact public hosts). Every reference must pass the off-route URL rule."""
    hosts = set()
    for u in manifest_refs(text, base):
        if not guard.ok(u, allow_page_origin=False):
            return False, []
        hosts.add((urlsplit(u).hostname or "").lower().rstrip("."))
        if len(hosts) > MAX_REF_HOSTS:
            return False, []
    return True, sorted(hosts)


def aes_without_crypto(text):
    if "#EXT-X-KEY:METHOD=AES-128" not in text:
        return False
    try:
        from yt_dlp.dependencies import Cryptodome
        return not getattr(Cryptodome, "AES", None)
    except Exception:
        return True


def runtime_guard(manifest, info_dict, proxied):
    """Called from the HLS downloader probe for fallback formats: same reference rule, native-only."""
    guard = _Guard(info_dict.get("webpage_url") or "", proxied)
    ok, _hosts = check_refs(manifest, info_dict.get("url") or "", guard)
    if not ok:
        raise ValueError("HLS 목록이 안전하지 않은 주소(공개 https가 아닌 주소)를 참조합니다.")
    if aes_without_crypto(manifest):
        raise ValueError("AES-128 HLS를 내장 다운로더로 복호화할 모듈이 없어 받지 않았습니다.")


# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------

REASONS = {
    "none": "페이지에서 내장 플레이어의 HLS 영상 주소를 찾지 못했습니다.",
    "ambiguous": "페이지에 영상 후보가 여러 개 있어 하나를 확정할 수 없습니다. 앱 브라우저에서 재생할 영상을 직접 선택해 주세요.",
    "unbounded": "내장 플레이어 후보가 검사 한도를 넘어 하나로 확정할 수 없습니다. 앱 브라우저에서 영상을 직접 선택해 주세요.",
    "unreachable": "내장 플레이어 또는 영상 목록 주소에 접근하지 못했습니다.",
    "unsupported": "내장 플레이어의 영상이 이 기능이 지원하는 HLS(내장 다운로더) 형식이 아닙니다.",
    "unsafe": "내장 플레이어가 안전하지 않은 주소(공개 https가 아닌 주소)를 참조해 사용하지 않았습니다.",
    "assist": "이 페이지의 영상은 기본 분석으로 확정할 수 없습니다(페이지 내장 플레이어). "
              "연결 도움을 켠 뒤 다시 분석하거나, 앱 브라우저에서 영상을 재생해 직접 선택해 주세요.",
    "browser_required": "웹브라우저 확인이 필요한 페이지입니다. 앱 브라우저에서 영상을 직접 선택해 주세요.",
}


_SPA_HOSTS = frozenset(("yadongkorea11.com", "www.yadongkorea11.com"))
_SPA_ROUTE_RE = re.compile(r"^/korea/([1-9][0-9]{0,11})/?$")

_COOKIE_GATE_RE = re.compile(
    r"""(?s)^\s*try\s*\{\s*"""
    r"""(?:var|let)\s+([A-Za-z_$][\w$]*)\s*=\s*["']([0-9a-fA-F]{16})["']\s*(?:,\s*|;\s*(?:var|let)\s+)([A-Za-z_$][\w$]*)\s*=\s*["']["']\s*;\s*"""
    r"""for\s*\(\s*(?:var|let)\s+([A-Za-z_$][\w$]*)\s*=\s*0\s*;\s*\4\s*<\s*32\s*;\s*(?:\4\+\+|\+\+\4)\s*\)\s*\{\s*"""
    r"""\3\s*\+=\s*\1\s*\[\s*Math\s*\.\s*floor\s*\(\s*Math\s*\.\s*random\s*\(\s*\)\s*\*\s*16\s*\)\s*\]\s*;\s*\}\s*"""
    r"""document\s*\.\s*cookie\s*=\s*["']([a-zA-Z0-9_\-]+)=\s*["']\s*\+\s*\3\s*\+\s*["']\s*;\s*([^"']+)["']\s*;\s*"""
    r"""if\s*\(\s*document\s*\.\s*cookie\s*\.\s*indexOf\s*\(\s*["']([a-zA-Z0-9_\-]+)=\s*["']\s*\)\s*<\s*0\s*\)\s*"""
    r"""\{\s*document\s*\.\s*getElementById\s*\([^)]*\)\s*\.\s*(?:textContent|innerHTML)\s*=\s*[^;]+;\s*\}\s*"""
    r"""else\s*\{\s*(?:window\s*\.\s*)?location\s*\.\s*replace\s*\(\s*(?:window\s*\.\s*)?location\s*\.\s*href\s*\)\s*;\s*\}\s*"""
    r"""\}\s*catch\s*\(\s*([A-Za-z_$][\w$]*)\s*\)\s*\{\s*"""
    r"""document\s*\.\s*getElementById\s*\([^)]*\)\s*\.\s*(?:textContent|innerHTML)\s*=\s*[^;]+;\s*\}\s*$"""
)


def _strip_js_comments(src):
    toks = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j + 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                return ""
            i = j + 2
        elif src[i] in "\"'":
            q = src[i]
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    j += 1
                    break
                j += 1
            toks.append(src[i:j])
            i = j
        else:
            toks.append(src[i])
            i += 1
    return "".join(toks)


def _match_cookie_gate(text):
    if not text or len(text) > 4096:
        return False, None
    if _IFRAME_RE.search(text) or _MEDIA_TAG_RE.search(text) or re.search(r"<form\b", text, re.I):
        return False, None
    scripts = _SCRIPT_RE.findall(text)
    if len(scripts) != 1:
        return False, None
    attrs, body = scripts[0]
    if re.search(r"(?:^|\s)src\s*=", attrs, re.I):
        return False, None
    if len(body) > 2048:
        return False, None

    clean_body = _strip_js_comments(body).strip()
    m = _COOKIE_GATE_RE.match(clean_body)
    if not m:
        return False, None

    alphabet = m.group(2)
    if len(alphabet) != 16 or len(set(alphabet.lower())) != 16:
        return False, None
    if not all(c in "0123456789abcdef" for c in alphabet.lower()):
        return False, None

    cname1 = m.group(5)
    cname2 = m.group(7)
    if cname1 != cname2:
        return False, None

    attrs_str = m.group(6)
    parts = [p.strip() for p in attrs_str.split(";") if p.strip()]
    parsed_attrs = {}
    for p in parts:
        if "=" not in p:
            return False, None
        k, v = p.split("=", 1)
        parsed_attrs[k.strip().lower()] = v.strip()

    if parsed_attrs.get("path") != "/":
        return False, None
    max_age = parsed_attrs.get("max-age")
    if not max_age or not max_age.isdigit() or int(max_age) <= 0:
        return False, None
    if parsed_attrs.get("samesite", "").lower() != "lax":
        return False, None
    if "domain" in parsed_attrs or "secure" in parsed_attrs:
        return False, None
    if len(parsed_attrs) != 3:
        return False, None

    return True, cname1


def _is_suspected_cookie_gate(text):
    if not text or len(text) > 4096:
        return False
    if _IFRAME_RE.search(text) or _MEDIA_TAG_RE.search(text) or re.search(r"<form\b", text, re.I):
        return False
    if len(_SCRIPT_RE.findall(text)) != 1:
        return False
    frames, candidates = _scan("https://placeholder.invalid/", text, True)
    return (not frames and not candidates
            and bool(re.search(r"\bdocument\s*\.\s*cookie\b", text))
            and bool(re.search(r"\blocation\s*\.\s*replace\b", text)))


def _fail(status):
    return {"status": status, "reason": REASONS[status]}


def discover(ydl, page_url, proxied, diagnostics=None):
    """
    Returns {"status": "found", "manifest_url", "manifest_text", "headers", "hosts"} (signed URL in memory only) or
    {"status": none|ambiguous|unbounded|unreachable|unsupported|unsafe, "reason": Korean text}.
    """
    if not proxied:
        if diagnostics:
            diagnostics.finish("assist")
        return _fail("assist")   # no off-route request without the app's connection helper
    try:
        with _hard_deadline(HARD_DEADLINE):
            res = _discover(ydl, page_url, proxied, diagnostics=diagnostics)
            if diagnostics and diagnostics.terminal is None:
                diagnostics.finish(res.get("status", "error"))
            return res
    except _DeadlineHit:
        if diagnostics:
            diagnostics.finish("unbounded")
        return _fail("unbounded")
    except BaseException as e:
        if diagnostics and diagnostics.terminal is None:
            diagnostics.finish("unbounded" if isinstance(e, TimeoutError) else "error")
        raise


def _discover(ydl, page_url, proxied, diagnostics=None):
    guard = _Guard(page_url, proxied)
    net = _Net(ydl, guard, diagnostics=diagnostics)
    errors, unsafe, overflow = 0, False, False
    hls, media = {}, set()
    page_title = ""
    queue = [(page_url, 0, None)]
    seen_frames = {page_url.split("#", 1)[0]}
    fetched = 0
    bootstrap_retried = False
    while queue:
        url, depth, parent = queue.pop(0)
        stage_name = "page" if depth == 0 else "frame"
        net.set_context(stage_name, depth=depth)
        if depth > 0 and fetched >= MAX_FRAMES:
            overflow = True
            if diagnostics:
                diagnostics.add_step(stage_name, result="limit", depth=min(2, depth))
            break
        if depth > 0:
            fetched += 1   # every frame attempt counts, including failed/refused ones
            if diagnostics:
                diagnostics.frames = min(4, diagnostics.frames + 1)
        try:
            hdrs = _referer_headers(parent, url) if parent else {}
            final, ctype, body = net.read(url, hdrs, MAX_PAGE_BYTES)
        except TimeoutError:
            overflow = True
            break
        except PermissionError:
            unsafe = True
            if diagnostics:
                diagnostics.rejected = min(64, diagnostics.rejected + 1)
                diagnostics.add_step(stage_name, result="unsafe", depth=min(2, depth), error="unsafe")
            continue
        except Exception:
            errors += 1
            continue

        decoded_text = _decode(body[:MAX_PAGE_BYTES])

        # Cookie bootstrap gate detection
        html_response = ctype in ("text/html", "application/xhtml+xml")
        is_gate, cname = _match_cookie_gate(decoded_text) if html_response else (False, None)
        if html_response and not is_gate and _is_suspected_cookie_gate(decoded_text):
            return _fail("browser_required")

        if is_gate:
            if bootstrap_retried:
                return _fail("browser_required")
            p = urlsplit(final)
            host = (p.hostname or "").lower()
            if not host:
                return _fail("unsafe")
            if ydl.params.get("cookiefile") or ydl.params.get("cookiesout"):
                return _fail("browser_required")
            jar = getattr(ydl, "cookiejar", None)
            if jar is None:
                return _fail("browser_required")
            for c in jar:
                if c.name == cname:
                    return _fail("browser_required")

            val = secrets.token_hex(16)
            cookie = http.cookiejar.Cookie(
                version=0,
                name=cname,
                value=val,
                port=None,
                port_specified=False,
                domain=host,
                domain_specified=False,
                domain_initial_dot=False,
                path="/",
                path_specified=True,
                secure=True,
                expires=None,
                discard=True,
                comment=None,
                comment_url=None,
                rest={"HttpOnly": None},
                rfc2109=False,
            )
            setattr(cookie, "_bootstrap_scoped", True)

            policy = getattr(jar, "_policy", None)
            if policy is not None and not getattr(policy, "_bootstrap_scoped_enforced", False):
                orig_return_ok = policy.return_ok
                def scoped_return_ok(c, req):
                    if getattr(c, "_bootstrap_scoped", False):
                        parsed = urlsplit(req.get_full_url() or "")
                        req_host = (parsed.hostname or "").lower()
                        if req_host != (c.domain or "").lower().lstrip("."):
                            return False
                        if (parsed.scheme or "").lower() != "https":
                            return False
                    return orig_return_ok(c, req)
                policy.return_ok = scoped_return_ok
                policy._bootstrap_scoped_enforced = True

            jar.set_cookie(cookie)
            bootstrap_retried = True

            try:
                final, ctype, body = net.read(url, hdrs, MAX_PAGE_BYTES)
            except TimeoutError:
                overflow = True
                break
            except PermissionError:
                unsafe = True
                continue
            except Exception:
                errors += 1
                continue

            decoded_text = _decode(body[:MAX_PAGE_BYTES])
            repeat_gate, _ = _match_cookie_gate(decoded_text)
            if ctype in ("text/html", "application/xhtml+xml") and (repeat_gate or _is_suspected_cookie_gate(decoded_text)):
                return _fail("browser_required")

        if depth == 0 and ctype in ("text/html", "application/xhtml+xml"):
            page_title = _page_title(decoded_text)

        # Direct manifest check
        if _decode(body[:512]).lstrip().startswith("#EXTM3U"):
            if len(body) > MAX_MANIFEST_BYTES:
                raise ValueError("manifest too large")
            hls[url] = (final, _decode(body), final, {})
            break

        if ctype and ctype.startswith(("video/", "audio/")) and ctype not in _HLS_TYPES:
            media.add(url)
            continue

        if ctype and ctype not in ("text/html", "application/xhtml+xml"):
            continue

        if diagnostics:
            diagnostics.record_stage("scan", depth=min(2, depth))
        scan_stats = {} if diagnostics else None
        is_truncated = len(body) > MAX_PAGE_BYTES
        frames, cands = _scan(final, decoded_text, depth > 0, scan_stats=scan_stats, input_truncated=is_truncated)
        if diagnostics:
            diagnostics.candidates = min(64, diagnostics.candidates + len(cands))
            diagnostics.add_step("scan", result="ok", depth=min(2, depth), scan=scan_stats)
            diagnostics.record_completed("scan")
        # Use the API only when the page has no existing static player route.
        if depth == 0 and not frames and not cands:
            p_final = urlsplit(final)
            host_final = (p_final.hostname or "").lower()
            m_route = _SPA_ROUTE_RE.match(p_final.path)
            if host_final in _SPA_HOSTS and m_route:
                route_id_str = m_route.group(1)
                route_id = int(route_id_str)
                api_url = f"{p_final.scheme.lower()}://{host_final}{':%d' % p_final.port if p_final.port else ''}/ydapi/item/{route_id_str}"
                if not guard.ok(api_url):
                    return _fail("browser_required")
                api_hdrs = {"Referer": _origin_text(final) + "/"}
                try:
                    _api_final, _api_ctype, api_body = net.read(api_url, api_hdrs, 65536)
                    if (_origin(_api_final) != _origin(final) or _api_ctype != "application/json"
                            or len(api_body) > 65536):
                        return _fail("browser_required")
                    api_data = json.loads(_decode(api_body))
                except Exception:
                    return _fail("browser_required")

                if not isinstance(api_data, dict) or api_data.get("ok") is not True:
                    return _fail("browser_required")
                item = api_data.get("item")
                if not isinstance(item, dict):
                    return _fail("browser_required")
                item_id = item.get("id")
                if type(item_id) is not int or item_id != route_id:
                    return _fail("browser_required")
                embed_url = item.get("embed_url")
                if not isinstance(embed_url, str) or len(embed_url) > 2048 or not embed_url.lower().startswith("https://"):
                    return _fail("browser_required")
                if not guard.ok(embed_url, allow_page_origin=False):
                    return _fail("browser_required")

                if embed_url not in seen_frames:
                    seen_frames.add(embed_url)
                    if depth < MAX_DEPTH:
                        queue.append((embed_url, depth + 1, final))

        if depth < MAX_DEPTH:
            for f in frames:
                if f in seen_frames:
                    continue
                seen_frames.add(f)
                if guard.ok(f):
                    queue.append((f, depth + 1, final))
                else:
                    unsafe = True
                    if diagnostics:
                        diagnostics.rejected = min(64, diagnostics.rejected + 1)
        else:
            if any(f not in seen_frames for f in frames):
                overflow = True
                if diagnostics:
                    diagnostics.add_step("frame", result="limit", depth=min(2, depth))
        for c in cands:
            if c in hls or c in media:
                continue
            if net.probes >= MAX_PROBES:
                overflow = True
                if diagnostics:
                    diagnostics.add_step("candidate_head", result="limit")
                break
            if not guard.ok(c):
                unsafe = True
                if diagnostics:
                    diagnostics.rejected = min(64, diagnostics.rejected + 1)
                    diagnostics.add_step("candidate_head", result="rejected")
                continue
            try:
                kind, man_url, text = _classify(net, final, c)
            except TimeoutError:
                overflow = True
                break
            except PermissionError:
                unsafe = True
                if diagnostics:
                    diagnostics.rejected = min(64, diagnostics.rejected + 1)
                    diagnostics.add_step("candidate_head", result="unsafe", error="unsafe")
                continue
            except Exception:
                errors += 1
                continue
            if kind == "hls":
                hls[c] = (man_url, text, final, _frame_bindings(_decode(body[:MAX_PAGE_BYTES])))
            elif kind == "media":
                media.add(c)
        if overflow:
            break

    if len(hls) + len(media) > 1:
        return _fail("ambiguous")
    if overflow:
        return _fail("unbounded")
    if media:
        return _fail("unsupported")
    if not hls:
        return _fail("unreachable" if errors else ("unsafe" if unsafe else "none"))
    candidate_url, (man_url, text, player, bindings) = next(iter(hls.items()))
    if diagnostics:
        diagnostics.record_stage("references")
    ok, hosts = check_refs(text, man_url, guard)
    if diagnostics:
        diagnostics.add_step("references", result="ok" if ok else "rejected")
        if ok:
            diagnostics.record_completed("references")
    if not ok or not guard.ok(man_url, allow_page_origin=False) and _origin(man_url) != guard.page_origin:
        return _fail("unsafe")
    if aes_without_crypto(text):
        return _fail("unsupported")
    host = (urlsplit(man_url).hostname or "").lower().rstrip(".")
    return {"status": "found", "manifest_url": man_url, "manifest_text": text,
            "headers": _referer_headers(player, man_url, origin_header=True),
            "hosts": sorted(set(hosts) | {host})[:MAX_REF_HOSTS],
            "player": player, "bindings": bindings, "candidate_url": candidate_url, "title": page_title}


def resolve_direct(ydl, page_url, media_url, proxied):
    """
    Fresh per-attempt player context for a browser-chosen direct HLS media URL, from its canonical page. Returns
    {"headers", "title", "player", "bindings"} (memory only) only when discovery found exactly one HLS whose original
    candidate address (or final manifest address) equals the chosen media URL (fragment ignored); otherwise None and
    the direct flow stays as it is. A different video of the page is never substituted.
    """
    media = str(media_url or "").split("#", 1)[0]
    if not media or not page_url:
        return None
    found = discover(ydl, page_url, proxied)
    if found.get("status") != "found" or media not in (found.get("candidate_url"), found.get("manifest_url")):
        return None
    return {"headers": dict(found["headers"]), "title": found.get("title") or "", "player": found["player"],
            "bindings": dict(found["bindings"])}


def apply_direct(info, ctx_res, source_url):
    """Per-format player Referer/Origin (other headers of the format kept) and the page title when the base is a placeholder."""
    if not isinstance(info, dict) or not ctx_res:
        return
    hdrs = ctx_res["headers"]
    targets = [f for f in info["formats"] if isinstance(f, dict)] if isinstance(info.get("formats"), list) else [info]
    for f in targets:
        if not hdrs:
            continue
        merged = {k: v for k, v in (f.get("http_headers") or {}).items() if str(k).lower() not in
                  {str(h).lower() for h in hdrs}}
        merged.update(hdrs)
        f["http_headers"] = merged
    info["title"] = pick_title(info, source_url, ctx_res["title"])


@contextlib.contextmanager
def _canonical_lookup_scope(ydl):
    """
    Canonical-page lookup of a direct-media alias must not carry the media request's inherited default Referer/Origin.
    Only those two are removed (params and the already built handlers' cached defaults); UA, proxy, TLS, cookie jar,
    every other header and the explicit per-frame discovery headers stay. The original objects are restored afterwards.
    """
    def strip(h):
        return {k: v for k, v in h.items() if str(k).lower() not in ("referer", "origin")}

    params = ydl.params
    missing = object()
    saved_params = params.get("http_headers", missing)
    saved_handlers = []
    director = ydl._request_director   # built (if still lazy) while the original default headers are in params
    try:
        if isinstance(saved_params, dict):
            params["http_headers"] = strip(saved_params)
        for handler in director.handlers.values():
            current = getattr(handler, "headers", None)
            if current is not None and hasattr(current, "items"):
                saved_handlers.append((handler, current))
                handler.headers = strip(current)
        yield
    finally:
        for handler, current in saved_handlers:
            handler.headers = current
        if saved_params is missing:
            params.pop("http_headers", None)
        else:
            params["http_headers"] = saved_params


def build_info(ydl, page_url, base, proxied, key_ctx=None, selected_media_url=None, diagnostics=None):
    """
    Fresh resolution for this attempt -> (info, dependency hosts, None) or (None, None, Korean reason).
    The identity is the query-stable job address (Generic + stable_media_id), never the signed manifest URL, so the
    same format ids / identity come back on every attempt. Formats are native HLS only (m3u8_native).
    key_ctx (optional dict, filled in memory only; never part of info/events): the player frame address and its
    explicit key-module options, for keys.KeyAdapter of this attempt.
    """
    identity_url = page_url
    if selected_media_url is None:
        found = discover(ydl, page_url, proxied, diagnostics=diagnostics)
    else:
        # Browser-chosen alias of this canonical page: only the page's one HLS that IS the alias may be used.
        identity_url = str(selected_media_url)
        selected = identity_url.split("#", 1)[0]
        with _canonical_lookup_scope(ydl):
            found = discover(ydl, page_url, proxied, diagnostics=None)
        if found["status"] == "found" and (not selected or selected not in
                                           (found.get("candidate_url"), found.get("manifest_url"))):
            return None, None, REASONS["ambiguous"]
    if found["status"] != "found":
        return None, None, found["reason"]
    if key_ctx is not None:
        key_ctx.update(player=found["player"], bindings=dict(found["bindings"]))
    ie = ydl.get_info_extractor("Generic")
    media_id = stable_media_id(identity_url)
    if diagnostics:
        diagnostics.record_stage("format_parse")
    formats, _subs = ie._parse_m3u8_formats_and_subtitles(
        found["manifest_text"], found["manifest_url"], ext="mp4", entry_protocol="m3u8_native", m3u8_id="hls",
        video_id=media_id, fatal=False)
    formats = [f for f in formats or [] if not f.get("has_drm")]
    if not formats:
        if diagnostics:
            diagnostics.add_step("format_parse", result="unsupported")
            diagnostics.finish("unsupported")
        return None, None, REASONS["unsupported"]
    if diagnostics:
        diagnostics.add_step("format_parse", result="ok")
        diagnostics.record_completed("format_parse")
        diagnostics.finish("found")
    for f in formats:
        f["http_headers"] = dict(found["headers"])   # player-scoped Referer/Origin only for this format's requests
    info = {"id": media_id, "title": pick_title(base, identity_url, found.get("title")), "formats": formats}
    ydl.add_default_extra_info(info, ie, identity_url)
    return info, found["hosts"], None


def check_download_manifest(manifest, info_dict, native_ok, proxied):
    """Download-time rule for fallback formats: native HLS only (never delegated to FFmpeg) + reference rule."""
    if not native_ok:
        raise ValueError("내장 플레이어 HLS를 내장 다운로더로 받을 수 없는 형식이라 받지 않았습니다.")
    runtime_guard(manifest, info_dict, proxied)
