#!/usr/bin/env python3
"""
HttpsDown local development engine helper (yt-dlp + FFmpeg stack).

The Swift app spawns this script in its own process group and talks to it through
line-delimited JSON events on the original stdout. After startup fd 1 is redirected
to fd 2, so stray prints from libraries or child processes can never forge events.

Event line: {"jobID": str, "generation": int, "event": str, "payload": dict}

Request data (URL, spec, connection/session context) arrives on stdin as JSON and never appears in argv.
Terminal events: formatsExtracted+extractCompleted, verified, selectionChanged,
verificationIncomplete, verificationFailed, error. Exit status 0 means "the outcome
was reported"; the app only treats `verified` + exit 0 + clean group as success.

Commands: health | extract | download | record (live, see live.py) | proxy (connection assist, see connection.py)
| speed (user-started speed check, see speed.py; the request carries no address, only the optional proxy context).
Request "context" (optional, memory only): {"proxy": "http://user:pass@127.0.0.1:port",
"session": {"site", "userAgent", "cookies"}, "referer": page address of a browser-chosen video}
— see session.py for the cookie scope rules.
"""

import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit, urlunsplit

PROTO = None
_EMIT_LOCK = threading.RLock()   # re-entrant: flag checks and the event write they guard share it
MAX_EVENT_CHARS = 200_000
# Set by SIGUSR1 from the app ("녹화 마치고 저장"). Never set by cancel, which is SIGTERM to the whole group.
STOP_EVENT = threading.Event()


# ----------------------------------------------------------------------------
# Process hygiene
# ----------------------------------------------------------------------------

def _setup_streams():
    """Keep the original stdout for events only; everything else goes to stderr."""
    global PROTO
    PROTO = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)


def _start_parent_watchdog():
    """If the app dies without cleaning up (crash/SIGKILL), do not linger as an orphan."""
    ppid = os.getppid()

    def watch():
        while True:
            time.sleep(1.0)
            if os.getppid() != ppid:
                try:
                    if os.getpgrp() == os.getpid():
                        os.killpg(os.getpgrp(), signal.SIGKILL)
                except Exception:
                    pass
                os._exit(137)

    threading.Thread(target=watch, daemon=True).start()


def _install_stop_handler():
    """Installed before the `ready` handshake, so the app never signals a process without the handler."""
    signal.signal(signal.SIGUSR1, lambda _sig, _frame: STOP_EVENT.set())


# ----------------------------------------------------------------------------
# Connection / session context (memory only)
# ----------------------------------------------------------------------------

def context_problem(url, ctx):
    """Requests that must be refused before any network access. Returns (code, message) or None."""
    if (ctx or {}).get("proxy") and urlsplit(url).scheme.lower() == "http":
        return ("assist_http_unsupported",
                "연결 도움을 켠 상태에서는 암호화되지 않은 http:// 주소를 받을 수 없습니다. "
                "연결 도움을 끄거나 https 주소를 사용해 주세요.")
    return None


def _safe_referer(value):
    """Page address of a video chosen in the app's browser (memory/stdin only). http(s), no userinfo/fragment."""
    if not isinstance(value, str) or len(value) > 2048 or any(c in value for c in "\r\n\t "):
        return None
    try:
        p = urlsplit(value)
    except ValueError:
        return None
    if p.scheme.lower() not in ("http", "https") or not p.hostname or p.username or p.password or p.fragment:
        return None
    return value


def _safe_page_context(value, url):
    """Canonical page of a browser-chosen direct media (memory/stdin only): https, no userinfo/fragment, not the media itself."""
    page = _safe_referer(value)
    if not page or urlsplit(page).scheme.lower() != "https" or not _safe_referer(url):
        return None
    if page.split("#", 1)[0] == str(url).split("#", 1)[0]:
        return None
    return page


def _is_direct_hls(info):
    """Generic result that is itself an HLS media (not a page playlist / no-formats page)."""
    if not isinstance(info, dict) or str(info.get("extractor_key") or "") != "Generic":
        return False
    return any(str(f.get("protocol") or "").startswith("m3u8") for f in _info_formats(info) if isinstance(f, dict))


def apply_context_opts(opts, ctx):
    ctx = ctx or {}
    proxy = ctx.get("proxy")
    if proxy:
        opts["proxy"] = proxy   # every yt-dlp request goes through the app's own proxy; no direct fallback
    headers = {}
    ua = (ctx.get("session") or {}).get("userAgent")
    if ua and "\r" not in ua and "\n" not in ua:
        headers["User-Agent"] = str(ua)[:400]
    # Only this job's requests carry it; the app sends it for browser-chosen media like the browser would.
    referer = _safe_referer(ctx.get("referer"))
    if referer:
        headers["Referer"] = referer
    if headers:
        opts["http_headers"] = headers


def apply_context_cookies(ydl, ctx, url):
    """Raises ValueError (safe message) when the session does not belong to this address."""
    sess = (ctx or {}).get("session")
    if not sess:
        return 0, 0
    import session as session_mod
    return session_mod.install(ydl, sess, url)


_CCMA_PAGE_HOSTS = frozenset(("3cat.cat", "www.3cat.cat", "ccma.cat", "www.ccma.cat"))
_CCMA_API_HOST = "api-media.3cat.cat"
_CCMA_API_PATH = "/pvideo/media.jsp"


def _ccma_public_page(url):
    """True only for a plain public http(s) 3cat/ccma page address (no userinfo, no custom port)."""
    try:
        parts = urlsplit(url)
        return (parts.scheme in ("http", "https") and (parts.hostname or "") in _CCMA_PAGE_HOSTS
                and "@" not in parts.netloc and parts.port in (None, 80, 443)
                and parts.netloc.lower() == parts.hostname)
    except (ValueError, TypeError, AttributeError):
        return False


def _ccma_https_api_url(target):
    """Return the https form of the exact CCMA media API GET address, else None."""
    if not isinstance(target, str):
        return None
    try:
        parts = urlsplit(target)
        if (parts.scheme != "http" or parts.hostname != _CCMA_API_HOST or parts.path != _CCMA_API_PATH
                or "@" in parts.netloc or parts.netloc.lower() not in (_CCMA_API_HOST, _CCMA_API_HOST + ":80")):
            return None
    except (ValueError, TypeError, AttributeError):
        return None
    return urlunsplit(("https", _CCMA_API_HOST, parts.path, parts.query, parts.fragment))


def install_ccma_https_compat(ydl, url):
    """The CCMA extractor still asks its media API over plain http. For original 3cat/ccma page
    addresses only, upgrade that one exact GET to https on the same host/path/query. The request
    still goes through this ydl instance (proxy, cookies, headers, guards); nothing else changes."""
    if not _ccma_public_page(url):
        return False
    try:
        ie = ydl.get_info_extractor("CCMA")
    except Exception:
        return False
    original = getattr(ie, "_download_json", None)
    if original is None or getattr(ie, "_ccma_https_compat", False):
        return False

    def _download_json(url_or_request, *args, **kwargs):
        if kwargs.get("data") is None and kwargs.get("method") is None:
            upgraded = _ccma_https_api_url(url_or_request)
            if upgraded:
                url_or_request = upgraded
        return original(url_or_request, *args, **kwargs)

    ie._download_json = _download_json   # this instance only
    ie._ccma_https_compat = True
    return True


# ----------------------------------------------------------------------------
# Redaction: nothing from remote servers is persisted raw
# ----------------------------------------------------------------------------

_URL_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.\-]*://[^\s\"'<>)\]]+")


def _url_origin(match):
    try:
        p = urlsplit(match.group(0))
        host = p.hostname or ""
        port = f":{p.port}" if p.port else ""
        return f"{p.scheme}://{host}{port}/…"
    except Exception:
        return "[주소]"


def redact(text, limit=240):
    """Strip URLs down to origin, headers, bearer/JWT tokens, long opaque tokens, key=value secrets."""
    if not text:
        return ""
    t = str(text)
    t = _URL_RE.sub(_url_origin, t)
    t = re.sub(r"(?i)\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key)\s*[:=]\s*[^\r\n]+",
               r"\1: [가림]", t)
    t = re.sub(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+", "Bearer [가림]", t)
    t = re.sub(r"(?i)([\w\-]*(?:token|sig|signature|key|secret|auth|session|policy|credential|password|passwd|"
               r"expires|hmac|jwt|cookie)[\w\-]*\s*[=:]\s*)[^\s&\"',;]+", r"\1[가림]", t)
    t = re.sub(r"\beyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{3,}\.?[A-Za-z0-9_\-]*", "[가림]", t)
    t = re.sub(r"\b[A-Za-z0-9_\-+/=]{32,}\b", "[가림]", t)
    home = os.path.expanduser("~")
    if home and home != "/":
        t = t.replace(home, "~")
    t = " ".join(t.split())
    return t[:limit]


def safe_token(s, limit=24):
    return re.sub(r"[^A-Za-z0-9_\-]", "", str(s or ""))[:limit]


def emit_event(job_id, generation, event, payload):
    msg = {"jobID": str(job_id or ""), "generation": int(generation or 0), "event": event, "payload": payload}
    line = json.dumps(msg, ensure_ascii=False)
    if len(line) > MAX_EVENT_CHARS:
        msg["payload"] = {"message": "이벤트가 너무 커서 생략되었습니다."}
        line = json.dumps(msg, ensure_ascii=False)
    with _EMIT_LOCK:
        PROTO.write(line + "\n")
        PROTO.flush()


_DIAG_HOST_RE = re.compile(r"^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))*$")


def _is_dns_host(host):
    if not isinstance(host, str) or not host.isascii() or len(host) > 253:
        return False
    if not _DIAG_HOST_RE.match(host):
        return False
    # DNS hostname must contain at least one alphabetical character and TLD cannot be purely numeric (no IP)
    labels = host.split(".")
    if not any(c.isalpha() for c in host) or labels[-1].isdigit():
        return False
    return True


def _diag_request_host(http_error):
    """Hostname only of the URL that actually answered (HTTPError.response.url); None unless a strict ASCII DNS name (no IP)."""
    try:
        from urllib.parse import urlsplit
        url = getattr(getattr(http_error, "response", None), "url", None)
        if not isinstance(url, str) or len(url) > 4096:
            return None
        host = urlsplit(url).hostname
        if not isinstance(host, str):
            return None
        host = host.lower()
        if not _is_dns_host(host):
            return None
        return host
    except Exception:
        return None


_SAFE_MIME_TYPES = frozenset((
    "text/html", "text/plain", "text/xml", "application/json", "application/xml",
    "application/xhtml+xml", "application/octet-stream", "application/vnd.apple.mpegurl",
    "application/x-mpegurl", "application/dash+xml", "video/mp4", "video/webm",
    "audio/mp4", "audio/webm", "image/jpeg", "image/png", "image/gif", "image/webp"
))


def _get_response_header(response, name):
    if response is None:
        return None
    headers = getattr(response, "headers", None)
    if headers is not None:
        if hasattr(headers, "get"):
            v = headers.get(name)
            if v is not None:
                return str(v)
            name_lower = name.lower()
            if hasattr(headers, "items"):
                for k, val in headers.items():
                    if str(k).lower() == name_lower:
                        return str(val)
    if hasattr(response, "getheader"):
        try:
            v = response.getheader(name)
            if v is not None:
                return str(v)
        except Exception:
            pass
    return None


def _safe_content_type(raw):
    if not isinstance(raw, str):
        return None
    token = raw.split(";")[0].strip().lower()
    return token if token in _SAFE_MIME_TYPES else None


def _safe_server_product(raw):
    if not isinstance(raw, str):
        return None
    s = raw.lower()
    if "cloudflare" in s:
        return "cloudflare"
    if "nginx" in s:
        return "nginx"
    if "apache" in s:
        return "apache"
    if "envoy" in s:
        return "envoy"
    if "amazons3" in s or "amazon s3" in s:
        return "AmazonS3"
    if s.strip():
        return "other"
    return None


def _safe_retry_after(raw):
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if s.isdigit():
        try:
            val = int(s)
            if 0 <= val <= 86400:
                return val
        except ValueError:
            return None
    return None


def _safe_cf_mitigated(raw):
    if not isinstance(raw, str):
        return None
    s = raw.strip().lower()
    return "challenge" if s == "challenge" else None


def _extract_http_response_meta(http_error):
    resp = getattr(http_error, "response", None)
    if resp is None:
        return None
    meta = {}
    ct = _safe_content_type(_get_response_header(resp, "Content-Type"))
    if ct:
        meta["contentType"] = ct
    srv = _safe_server_product(_get_response_header(resp, "Server"))
    if srv:
        meta["server"] = srv
    ra = _safe_retry_after(_get_response_header(resp, "Retry-After"))
    if ra is not None:
        meta["retryAfterSeconds"] = ra
    cf = _safe_cf_mitigated(_get_response_header(resp, "cf-mitigated"))
    if cf:
        meta["cfMitigated"] = cf
    return meta if meta else None


def _make_request_options_snapshot(scope, headers_or_keys):
    if not scope or headers_or_keys is None:
        return None
    if isinstance(headers_or_keys, dict):
        keys = headers_or_keys.keys()
    elif isinstance(headers_or_keys, (set, frozenset, list, tuple)):
        keys = headers_or_keys
    else:
        return None
    keys_lower = {str(k).lower() for k in keys}
    return {
        "scope": scope,
        "referer": "referer" in keys_lower,
        "origin": "origin" in keys_lower,
        "cookie": "cookie" in keys_lower,
        "userAgent": "user-agent" in keys_lower,
    }


def _extract_format_headers(info_dict):
    if not isinstance(info_dict, dict):
        return None
    candidates = info_dict.get("requested_formats") or [info_dict]
    header_keys = set()
    found = False
    for c in candidates:
        if isinstance(c, dict):
            hh = c.get("http_headers")
            if isinstance(hh, dict):
                found = True
                header_keys.update(hh.keys())
    top_hh = info_dict.get("http_headers")
    if isinstance(top_hh, dict):
        found = True
        header_keys.update(top_hh.keys())
    return header_keys if found else None


def diag_error(exc, meta=None):
    """
    Finite error classification for the diagnostic trace, from the TYPES in the exception chain only (never from
    message text): {"category": enum id, "httpStatus": int | None}.
    """
    out = {"category": "other", "httpStatus": None}
    try:
        from http.client import IncompleteRead as HTTPIncompleteRead
        import socket
        import ssl
        import fragments
        from yt_dlp.networking.exceptions import (
            HTTPError, IncompleteRead, ProxyError, SSLError, TransportError, UnsupportedRequest)
        from yt_dlp.utils import ContentTooShortError, UnsupportedError
        try:
            from yt_dlp.utils import PostProcessingError
        except ImportError:
            class PostProcessingError(Exception):
                pass
        chain = fragments._chain(exc)

        def has(*types):
            return any(isinstance(e, types) for e in chain)

        http = next((e for e in chain if isinstance(e, HTTPError)), None)
        if http is not None:
            status = getattr(http, "status", None)
            out = {"category": "http", "httpStatus": status if isinstance(status, int) and 100 <= status <= 599 else None}
            host = _diag_request_host(http)
            if host:
                out["requestHost"] = host
            resp_meta = _extract_http_response_meta(http)
            if resp_meta:
                out["httpResponse"] = resp_meta
        elif has(SSLError, ssl.SSLError):
            out["category"] = "tls"
        elif has(ProxyError):
            out["category"] = "proxy"
        elif has(socket.gaierror, socket.herror):
            out["category"] = "dns"
        elif has(UnsupportedRequest, UnsupportedError):
            out["category"] = "unsupported"
        elif fragments._resource_problem(exc):
            out["category"] = "resource"
        elif has(TimeoutError, socket.timeout):
            out["category"] = "timeout"
        elif has(IncompleteRead, ContentTooShortError, HTTPIncompleteRead):
            out["category"] = "incomplete"
        elif has(TransportError, ConnectionError):
            out["category"] = "network"
        elif has(PostProcessingError):
            out["category"] = "process"
        elif has(OSError):
            out["category"] = "filesystem"
    except Exception:
        pass

    if isinstance(meta, dict):
        if out.get("category") == "other":
            typed_failure = meta.get("_typedFailure")
            if isinstance(typed_failure, dict):
                cat = typed_failure.get("category")
                if cat in ("http", "tls", "proxy", "dns", "network", "timeout", "incomplete", "unsupported", "resource", "filesystem", "process"):
                    for k in ("category", "httpStatus", "requestHost", "httpResponse"):
                        if k in typed_failure:
                            out[k] = typed_failure[k]
        stage = meta.get("failureStage")
        if stage in ("extraction", "download"):
            out["failureStage"] = stage
        req_opts = meta.get("requestOptions")
        if isinstance(req_opts, dict):
            out["requestOptions"] = req_opts
        disc = meta.get("discovery")
        if isinstance(disc, dict):
            import discovery
            clean_disc = discovery.sanitize_discovery_diagnostics(disc)
            if clean_disc:
                out["discovery"] = clean_disc

    return out


def emit_error(job_id, gen, code, message, detail="", exc=None, tuning=None, meta=None):
    payload = {"code": code, "message": message, "detail": redact(detail, 200)}
    if exc is not None:
        payload["diag"] = diag_error(exc, meta=meta)   # typed classification only (see diag_error)
    elif meta:
        diag = {}
        stage = meta.get("failureStage")
        if stage in ("extraction", "download"):
            diag["failureStage"] = stage
        req_opts = meta.get("requestOptions")
        if isinstance(req_opts, dict):
            diag["requestOptions"] = req_opts
        disc_reason = meta.get("discoveryReason")
        if disc_reason in ("none", "ambiguous", "unbounded", "unreachable", "unsupported", "unsafe", "assist", "browser_required"):
            diag["discoveryReason"] = disc_reason
        disc = meta.get("discovery")
        if isinstance(disc, dict):
            import discovery
            clean_disc = discovery.sanitize_discovery_diagnostics(disc)
            if clean_disc:
                diag["discovery"] = clean_disc
        if diag:
            payload["diag"] = diag
    if tuning:
        payload["tuning"] = tuning          # fixed-key controller snapshot (fragments.get_diagnostic_snapshot)
    emit_event(job_id, gen, "error", payload)


class QuietLogger:
    """yt-dlp's default logger prints URLs to stderr. Swallow everything, keep one redacted line."""

    def __init__(self):
        self.last_error = ""
        self.last_diag = None

    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        pass

    def capture_exception(self, exc):
        if isinstance(exc, BaseException):
            captured = diag_error(exc)
            if captured.get("category") != "other":
                self.last_diag = captured

    def error(self, msg):
        self.last_error = redact(msg, 200)
        self.capture_exception(sys.exc_info()[1])


# ----------------------------------------------------------------------------
# Tool discovery / health
# ----------------------------------------------------------------------------

def _bundled_tools_dir():
    """<runtime>/_internal/tools inside the frozen portable engine, else None (development stack)."""
    if getattr(sys, "frozen", False):
        return os.path.join(getattr(sys, "_MEIPASS", "") or "", "tools")
    return None


def _tool(name):
    bundled = _bundled_tools_dir()
    if bundled is not None:
        # The portable engine never silently falls back to external tools: a missing one reads as unavailable.
        return os.path.join(bundled, name)
    return shutil.which(name) or f"/opt/homebrew/bin/{name}"


def _prepare_environment():
    """Portable engine: a controlled PATH (bundled tools first, system dirs only) for yt-dlp's own runtime lookup."""
    bundled = _bundled_tools_dir()
    if bundled is not None:
        os.environ["PATH"] = bundled + os.pathsep + "/usr/bin" + os.pathsep + "/bin"


def _tool_version(path, args, timeout=4):
    try:
        p = subprocess.run([path] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, timeout=timeout)
        first = (p.stdout or "").strip().splitlines()
        return first[0][:120] if first else ""
    except Exception:
        return ""


def check_health():
    ytdlp_ok, ytdlp_ver = False, ""
    try:
        import yt_dlp  # noqa: F401
        from yt_dlp.version import __version__ as ytdlp_ver_
        ytdlp_ok, ytdlp_ver = True, str(ytdlp_ver_)
    except Exception:
        pass

    ejs_ok = False
    try:
        import importlib.util
        ejs_ok = importlib.util.find_spec("yt_dlp_ejs") is not None
    except Exception:
        pass

    def probe(name, args):
        path = _tool(name)
        ok = os.path.isfile(path) and os.access(path, os.X_OK)
        return ok, (path if ok else None), (_tool_version(path, args) if ok else "")

    ffmpeg_ok, ffmpeg_path, ffmpeg_ver = probe("ffmpeg", ["-version"])
    ffprobe_ok, ffprobe_path, ffprobe_ver = probe("ffprobe", ["-version"])
    deno_ok, deno_path, deno_ver = probe("deno", ["--version"])

    emit_event("", 0, "health", {
        "healthy": bool(ytdlp_ok and ffmpeg_ok and ffprobe_ok),
        "python": sys.executable,
        "python_version": sys.version.split()[0],
        "ytdlp_available": ytdlp_ok,
        "ytdlp_version": ytdlp_ver,
        "ffmpeg_available": ffmpeg_ok, "ffmpeg_path": ffmpeg_path, "ffmpeg_version": ffmpeg_ver,
        "ffprobe_available": ffprobe_ok, "ffprobe_path": ffprobe_path, "ffprobe_version": ffprobe_ver,
        "deno_available": deno_ok, "deno_path": deno_path, "deno_version": deno_ver,
        "ejs_available": ejs_ok,
        "engine_type": ("PORTABLE (PyInstaller arm64 번들 엔진)" if _bundled_tools_dir() is not None
                        else "DEVELOPMENT (Local Homebrew Stack, GPL-enabled)"),
    })


# ----------------------------------------------------------------------------
# Extraction
# ----------------------------------------------------------------------------

def _norm_codec(v):
    if v is None:
        return None
    return str(v)


def _info_formats(info):
    """
    Same rule as yt-dlp's own _get_formats: a single-format result (e.g. a Generic direct media link) carries no
    "formats" list; the info dict itself is the one format (format_id "0"). Its codecs are often unknown (None) and
    stay unknown here -> nothing about them is expected at selection, the downloaded file is verified locally.
    """
    if info.get("formats") is not None:
        return info.get("formats") or []
    if info.get("url") and info.get("format_id") and info.get("_type", "video") == "video":
        return [info]
    return []


_VIMEO_LOGIN_ONLY = "web client only works when logged-in"


def public_vimeo_embed(url, exc, last_error=""):
    """
    A plain public address https://vimeo.com/<numeric id> (no hash/unlisted path, query, fragment, port, userinfo)
    whose web-page client refuses anonymous access with exactly the login-only message: the same video id through
    its public player address, tried once (same Vimeo extractor + id, so the selection identity is unchanged).
    Any other address or failure (private/password/hash links, other auth errors) -> None: the original error stands.
    """
    try:
        p = urlsplit(url)
        port = p.port
    except ValueError:
        return None
    m = re.fullmatch(r"/(\d{1,15})/?", p.path or "")
    if (not m or p.scheme != "https" or (p.hostname or "") != "vimeo.com" or port is not None or p.username
            or p.password or p.query or p.fragment or "?" in url or "#" in url):
        return None
    if _VIMEO_LOGIN_ONLY not in (str(exc) + " " + str(last_error or "")).lower():
        return None
    return "https://player.vimeo.com/video/" + m.group(1)


def run_extract(job_id, generation, url, ctx=None):
    emit_event(job_id, generation, "progress", {"phase": "extracting", "message": "주소 메타데이터 및 화질 목록 분석 중..."})
    problem = context_problem(url, ctx)
    if problem:
        emit_error(job_id, generation, *problem)
        return 1
    try:
        import yt_dlp
    except ImportError:
        emit_error(job_id, generation, "engine_missing", "yt-dlp 모듈을 불러올 수 없습니다. 엔진 환경을 확인하세요.")
        return 1

    logger = QuietLogger()
    opts = {
        "quiet": True, "no_warnings": True, "logger": logger,
        "extract_flat": False, "noplaylist": True,
        "socket_timeout": 20, "retries": 0, "extractor_retries": 0, "cachedir": False,
        "skip_download": True,
    }
    apply_context_opts(opts, ctx)

    discovery_diag = None

    def _extract_meta():
        meta = {"failureStage": "extraction", "_typedFailure": logger.last_diag}
        if isinstance(opts.get("http_headers"), dict):
            ro = _make_request_options_snapshot("request-options", opts["http_headers"])
            if ro:
                meta["requestOptions"] = ro
        if discovery_diag is not None:
            snap = discovery_diag.snapshot()
            if snap:
                meta["discovery"] = snap
        return meta

    import discovery
    dependency_hosts = None
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            try:
                apply_context_cookies(ydl, ctx, url)
            except ValueError as e:
                emit_error(job_id, generation, "session_mismatch", str(e))
                return 1
            install_ccma_https_compat(ydl, url)
            canon_page = _safe_page_context((ctx or {}).get("pageURL"), url)
            canon_proxy = discovery.trusted_helper_proxy((ctx or {}).get("proxy"))
            canon_done = False
            if canon_page and canon_proxy and urlsplit(url).path.lower().endswith(".m3u8"):
                # Optional exact-match lookup for a known HLS alias of a canonical page: only a clean result is used;
                # any reason is ignored and the originally selected address goes through the normal path below.
                canon_info, canon_hosts, canon_reason = discovery.build_info(
                    ydl, canon_page, None, canon_proxy, selected_media_url=url)
                if canon_reason is None:
                    info, dependency_hosts = canon_info, canon_hosts
                    info, base_code = ydl.process_ie_result(info, download=False), None
                    canon_done = True
            if not canon_done:
                try:
                    info, base_code = ydl.extract_info(url, download=False), None
                except Exception as e:
                    embed = public_vimeo_embed(url, e, logger.last_error)
                    if embed:
                        logger.last_error = ""
                        logger.last_diag = None
                        info, base_code = ydl.extract_info(embed, download=False), None
                    elif not discovery.generic_unsupported(e):
                        raise
                    else:
                        info, base_code = None, "extract_failed"
            if base_code is None and not canon_done and discovery.eligible(info):
                base_code = "no_formats" if info.get("_type") not in ("playlist", "multi_video") \
                    and info.get("entries") is None else "playlist_unsupported"
            if base_code:
                # Generic gave up / only page media: bounded embedded-player HLS fallback (see discovery.py)
                discovery_diag = discovery.DiscoveryDiagnostics()
                info, dependency_hosts, reason = discovery.build_info(
                    ydl, url, info, discovery.trusted_helper_proxy((ctx or {}).get("proxy")), diagnostics=discovery_diag)
                if reason:
                    # unreachable is retryable via helper auto-recovery; ambiguous/unsafe/assist must not auto-recover
                    if reason == discovery.REASONS["unreachable"]:
                        base_code = "extract_failed"
                    elif reason in (discovery.REASONS["ambiguous"], discovery.REASONS["unbounded"],
                                    discovery.REASONS["unsafe"], discovery.REASONS["assist"]):
                        base_code = "playlist_unsupported"
                    elif reason == discovery.REASONS.get("browser_required"):
                        base_code = "browser_required"
                    meta = _extract_meta()
                    for r_key in ("none", "ambiguous", "unbounded", "unreachable", "unsupported", "unsafe", "assist", "browser_required"):
                        if reason == discovery.REASONS.get(r_key):
                            meta["discoveryReason"] = r_key
                            break
                    emit_error(job_id, generation, base_code, reason, meta=meta)
                    return 1
                info = ydl.process_ie_result(info, download=False)
            elif not canon_done and _is_direct_hls(info):
                page = _safe_page_context((ctx or {}).get("pageURL"), url)
                proxied_now = discovery.trusted_helper_proxy((ctx or {}).get("proxy"))
                if page and proxied_now:
                    res = discovery.resolve_direct(ydl, page, url, proxied_now)
                    discovery.apply_direct(info, res, url)
    except Exception as e:
        emit_error(job_id, generation, "extract_failed", "영상 정보를 분석하지 못했습니다.", logger.last_error or str(e), exc=e, meta=_extract_meta())
        return 1

    if not info:
        emit_error(job_id, generation, "extract_empty", "미디어 정보를 추출하지 못했습니다.")
        return 1
    if info.get("_type") in ("playlist", "multi_video") or info.get("entries") is not None and not info.get("formats"):
        emit_error(job_id, generation, "playlist_unsupported", "재생목록 주소는 아직 지원하지 않습니다. 영상 한 개의 주소를 입력해 주세요.")
        return 1

    live_status = str(info.get("live_status") or "")
    is_live = bool(info.get("is_live")) or live_status == "is_live"
    if live_status == "is_upcoming":
        emit_error(job_id, generation, "live_upcoming", "아직 시작하지 않은 방송입니다. 방송이 시작된 뒤 다시 분석해 주세요.")
        return 1

    formats = []
    drm_skipped = 0
    for f in _info_formats(info):
        fid = str(f.get("format_id") or "")
        if not fid:
            continue
        vc, ac = f.get("vcodec"), f.get("acodec")
        if vc == "none" and ac == "none":
            continue  # storyboards and other non-media entries
        if f.get("has_drm"):
            drm_skipped += 1
            continue
        proto = str(f.get("protocol") or "")
        if is_live and not (proto.startswith("m3u8") or proto == "http_dash_segments"):
            continue  # live recording is only offered for HLS/DASH streams FFmpeg can follow
        if not is_live and proto == "http_dash_segments_generator":
            continue  # generator manifests have no fixed fragment list -> no completeness evidence
        fs = f.get("filesize") or f.get("filesize_approx")
        formats.append({
            "formatId": fid,
            "ext": str(f.get("ext") or "mp4"),
            "vcodec": _norm_codec(vc), "acodec": _norm_codec(ac),
            "width": f.get("width"), "height": f.get("height"),
            "fps": float(f["fps"]) if f.get("fps") else None,
            "filesize": int(fs) if fs else None,
            "tbr": float(f["tbr"]) if f.get("tbr") else None,
            "formatNote": redact(f.get("format_note"), 60) or None,
            "protocolName": f.get("protocol"),
        })

    if not formats:
        if drm_skipped:
            emit_error(job_id, generation, "drm", "DRM(저작권 보호 암호화)이 적용된 영상이라 저장할 수 없습니다.")
        elif is_live:
            emit_error(job_id, generation, "live_protocol", "이 실시간 방송은 녹화할 수 있는 형식(HLS/DASH)을 제공하지 않습니다.")
        else:
            emit_error(job_id, generation, "no_formats", "저장할 수 있는 영상 형식을 찾지 못했습니다.")
        return 1

    def sub_list(src, is_auto):
        out = []
        for lang, items in (src or {}).items():
            if not isinstance(items, list) or not any(isinstance(i, dict) and i.get("ext") in ("vtt", "srt") for i in items):
                continue
            lang_s = safe_token(lang, 24)
            if not lang_s:
                continue
            nm = next((i.get("name") for i in items if isinstance(i, dict) and i.get("name")), None)
            out.append({"lang": lang_s, "name": redact(nm, 40) or lang_s, "isAuto": is_auto})
        return out

    subtitles = (sub_list(info.get("subtitles"), False) + sub_list(info.get("automatic_captions"), True))[:80]
    duration = info.get("duration")
    payload = {
        "title": redact(info.get("title") or "알 수 없는 제목", 160),
        "extractor": safe_token(info.get("extractor_key") or info.get("extractor") or "", 40),
        "mediaId": str(info.get("id") or "")[:120],
        "duration": float(duration) if duration and not is_live else None,
        "formats": formats,
        "subtitles": [] if is_live else subtitles,
        "isLive": is_live,
        "liveStatus": safe_token(live_status, 20) or None,
    }
    if dependency_hosts:
        # Optional hint (exact public hostnames referenced by the manifest, no paths/tokens); the app may ignore it.
        payload["dependencyHosts"] = list(dependency_hosts)
    emit_event(job_id, generation, "formatsExtracted", payload)
    emit_event(job_id, generation, "extractCompleted", {})
    return 0


# ----------------------------------------------------------------------------
# Media verification
# ----------------------------------------------------------------------------

def mp4_merge_pair(components):
    """True for exactly one selected video-only H.264 plus one audio-only Opus/AAC format (copy-mergeable into MP4)."""
    if len(components) != 2:
        return False
    def fam(c, key):
        return codec_family(c.get(key)) if str(c.get(key) or "none").lower() != "none" else None
    video = [c for c in components if fam(c, "vcodec") and not fam(c, "acodec")]
    audio = [c for c in components if fam(c, "acodec") and not fam(c, "vcodec")]
    return (len(video) == 1 and len(audio) == 1
            and fam(video[0], "vcodec") == "h264" and fam(audio[0], "acodec") in ("opus", "aac"))


BAD_CONTAINERS = {"gif", "image2", "image2pipe", "png_pipe", "jpeg_pipe", "webp_pipe", "bmp_pipe", "tiff_pipe",
                  "apng", "svg_pipe", "jpegls_pipe", "pgm_pipe", "ppm_pipe", "pam_pipe", "tty", "ansi", "pdf_pipe"}
CORRUPT_MARKERS = ("partial file", "truncated", "moov atom not found", "invalid data found", "error reading header",
                   "packet corrupt", "corrupt", "error while decoding", "end of file", "premature end",
                   "invalid nal", "missing picture", "could not find codec parameters")

_FAMILY = [("avc1", "h264"), ("avc3", "h264"), ("h264", "h264"), ("hev1", "hevc"), ("hvc1", "hevc"),
           ("h265", "hevc"), ("hevc", "hevc"), ("vp09", "vp9"), ("vp9", "vp9"), ("vp08", "vp8"), ("vp8", "vp8"),
           ("av01", "av1"), ("av1", "av1"), ("mp4a", "aac"), ("aac", "aac"), ("opus", "opus"), ("vorbis", "vorbis"),
           ("mp3", "mp3"), ("ac-3", "ac3"), ("ac3", "ac3"), ("ec-3", "eac3"), ("eac3", "eac3"), ("flac", "flac"),
           ("alac", "alac")]


def codec_family(name):
    n = str(name or "").lower()
    for prefix, fam in _FAMILY:
        if n.startswith(prefix):
            return fam
    return None


def sniff_header(head):
    """Reject images/documents masquerading as media. Returns a Korean reason or None."""
    if head.startswith((b"GIF87a", b"GIF89a")):
        return "영상 파일 대신 GIF 이미지가 저장되었습니다."
    if head.startswith(b"\xff\xd8\xff"):
        return "영상 파일 대신 JPEG 이미지가 저장되었습니다."
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "영상 파일 대신 PNG 이미지가 저장되었습니다."
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "영상 파일 대신 WebP 이미지가 저장되었습니다."
    if head.startswith((b"II*\x00", b"MM\x00*")):
        return "영상 파일 대신 TIFF 이미지가 저장되었습니다."
    if head.startswith(b"%PDF"):
        return "영상 파일 대신 PDF 문서가 저장되었습니다."
    if head.startswith(b"PK\x03\x04"):
        return "영상 파일 대신 압축 파일이 저장되었습니다."
    body = head[3:] if head.startswith(b"\xef\xbb\xbf") else head
    low = body.lstrip().lower()
    if low.startswith((b"<!doctype", b"<html", b"<head", b"<body", b"<script", b"<?xml", b"<svg", b"<error")):
        return "영상 파일 대신 HTML/XML 문서가 저장되었습니다."
    if low[:1] in (b"{", b"[") and sum(1 for c in low[:512] if 32 <= c < 127 or c in (9, 10, 13)) >= 0.95 * min(len(low), 512):
        return "영상 파일 대신 JSON 응답이 저장되었습니다."
    sample = body[:2048]
    if sample and b"\x00" not in sample and sum(1 for c in sample if 32 <= c < 127 or c in (9, 10, 13) or c >= 0xC2) >= 0.97 * len(sample):
        return "영상 파일 대신 텍스트 문서가 저장되었습니다."
    return None


def owned_regular(path, root):
    """True/False + reason: real regular file owned by us, directly inside a real path under root."""
    try:
        st = os.lstat(path)
    except OSError:
        return False, "산출물 파일이 존재하지 않습니다."
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        return False, "산출물이 일반 파일이 아니거나 심볼릭 링크입니다."
    if st.st_uid != os.geteuid():
        return False, "산출물 소유자가 올바르지 않습니다."
    if st.st_nlink != 1:
        return False, "산출물이 하드링크로 연결되어 있습니다."
    real_root = os.path.realpath(root)
    real_parent = os.path.realpath(os.path.dirname(path))
    if real_parent != real_root and not real_parent.startswith(real_root + os.sep):
        return False, "산출물이 작업 폴더 밖에 있습니다."
    return True, ""


def _run(cmd, timeout):
    return subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, errors="replace", timeout=timeout)


def verify_media_file(path, expected, root):
    """
    Returns {"ok": True, info...} or {"ok": False, "kind": "failed"|"incomplete", "reason": str}.
    Structure/intent/codec/decode checks only; transfer completeness is assessed separately.
    """
    ok, why = owned_regular(path, root)
    if not ok:
        return {"ok": False, "kind": "failed", "reason": why}
    size = os.path.getsize(path)
    if size == 0:
        return {"ok": False, "kind": "failed", "reason": "산출물 파일 크기가 0바이트입니다."}
    with open(path, "rb") as f:
        head = f.read(4096)
    why = sniff_header(head)
    if why:
        return {"ok": False, "kind": "failed", "reason": why}

    ffprobe, ffmpeg = _tool("ffprobe"), _tool("ffmpeg")
    if not (os.path.isfile(ffprobe) and os.path.isfile(ffmpeg)):
        return {"ok": False, "kind": "incomplete", "reason": "ffprobe/FFmpeg를 찾을 수 없어 검증을 마치지 못했습니다."}

    target = "file:" + path
    try:
        p = _run([ffprobe, "-v", "error", "-protocol_whitelist", "file", "-show_entries",
                  "format=format_name,duration,size:stream=index,codec_type,codec_name,width,height,duration:stream_disposition=attached_pic",
                  "-of", "json", target], 40)
    except subprocess.TimeoutExpired:
        return {"ok": False, "kind": "incomplete", "reason": "ffprobe 검증 시간이 초과되어 검증을 마치지 못했습니다."}
    if p.returncode != 0:
        return {"ok": False, "kind": "failed", "reason": "미디어 구조를 읽을 수 없어 손상되었거나 영상이 아닌 파일로 판정했습니다."}
    try:
        data = json.loads(p.stdout)
    except Exception:
        return {"ok": False, "kind": "failed", "reason": "ffprobe 결과를 해석할 수 없습니다."}

    fmt = data.get("format") or {}
    fmt_names = set(str(fmt.get("format_name") or "").split(","))
    if fmt_names & BAD_CONTAINERS:
        return {"ok": False, "kind": "failed", "reason": "영상 컨테이너가 아니라 이미지 형식(" + ",".join(sorted(fmt_names & BAD_CONTAINERS)) + ")입니다."}

    streams = data.get("streams") or []
    vstreams = [s for s in streams if s.get("codec_type") == "video" and not (s.get("disposition") or {}).get("attached_pic")]
    astreams = [s for s in streams if s.get("codec_type") == "audio"]
    intent = (expected or {}).get("intent") or "media"
    if intent == "video" and not vstreams:
        return {"ok": False, "kind": "failed", "reason": "영상을 선택했지만 산출물에 영상 트랙이 없습니다."}
    if intent == "audio" and not astreams:
        return {"ok": False, "kind": "failed", "reason": "음원을 선택했지만 산출물에 오디오 트랙이 없습니다."}
    if not vstreams and not astreams:
        return {"ok": False, "kind": "failed", "reason": "산출물에 재생 가능한 영상/오디오 트랙이 없습니다."}

    # Selected-codec / dimension intent (only conditions that were known at selection time)
    for comp in (expected or {}).get("components") or []:
        evc, eac = comp.get("vcodec"), comp.get("acodec")
        if evc and evc != "none":
            fam = codec_family(evc)
            if fam and vstreams and fam not in {codec_family(s.get("codec_name")) or s.get("codec_name") for s in vstreams}:
                return {"ok": False, "kind": "failed", "reason": f"선택한 영상 코덱({fam})과 실제 산출물 코덱이 다릅니다."}
        if eac and eac != "none":
            fam = codec_family(eac)
            if fam and astreams and fam not in {codec_family(s.get("codec_name")) or s.get("codec_name") for s in astreams}:
                return {"ok": False, "kind": "failed", "reason": f"선택한 오디오 코덱({fam})과 실제 산출물 코덱이 다릅니다."}
        eh = comp.get("height")
        if eh and vstreams and vstreams[0].get("height"):
            ah, aw = int(vstreams[0]["height"]), int(vstreams[0].get("width") or 0)
            tol = max(16, int(eh * 0.10))
            if abs(ah - int(eh)) > tol and abs(aw - int(eh)) > tol:
                return {"ok": False, "kind": "failed", "reason": f"선택한 해상도({eh}p)와 실제 산출물({ah}p)이 다릅니다."}

    # Full decode (not a sample). Timeouts are "unknown", not "ok".
    timeout = min(900, 120 + size // (4 * 1024 * 1024) * 5)
    try:
        d = _run([ffmpeg, "-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "file", "-i", target,
                  "-map", "0:v?", "-map", "0:a?", "-f", "null", "-"], timeout)
    except subprocess.TimeoutExpired:
        return {"ok": False, "kind": "incomplete", "reason": "전체 디코딩 검증 시간이 초과되어 검증을 마치지 못했습니다."}
    err = (d.stderr or "").lower()
    if d.returncode != 0 or any(m in err for m in CORRUPT_MARKERS):
        return {"ok": False, "kind": "failed", "reason": "미디어 전체 디코딩에 실패하여 손상되었거나 잘린 파일로 판정했습니다."}

    v = vstreams[0] if vstreams else None
    a = astreams[0] if astreams else None
    dur = fmt.get("duration")
    try:
        dur = float(dur) if dur not in (None, "N/A") else None
    except ValueError:
        dur = None
    return {
        "ok": True, "size": size, "format": ",".join(sorted(fmt_names))[:60], "duration": dur,
        "width": v.get("width") if v else None, "height": v.get("height") if v else None,
        "vcodec": v.get("codec_name") if v else None, "acodec": a.get("codec_name") if a else None,
        "hasVideo": bool(v), "hasAudio": bool(a),
    }


def assess_completeness(evidence, hls_seen, expected_ids, dash_seen=None):
    """
    Transfer completeness from observed downloader facts only.
    HTTP: Content-Length (identity encoding) == bytes received == bytes on disk.
    HLS native: playlist had #EXT-X-ENDLIST (fixed VOD) and every fragment finished (no skipping).
    DASH native: a fixed (non-live, non-generator) fragment list of N entries (the initialization segment is the
    first entry when the manifest has one), fragments 1..N appended exactly once in order, the downloader's own
    count reached N, and appended bytes == component file size on disk.
    Anything else is unknown -> caller reports verificationIncomplete.
    Returns (True, basis) or (False, reason).
    """
    if not expected_ids:
        return False, "선택한 형식 정보를 알 수 없어 전송 완전성을 판단할 수 없습니다."
    dash_seen = dash_seen or {}
    bases = []
    for fid in expected_ids:
        comps = [(fn, e) for fn, e in evidence.items() if e.get("format_id") == fid and e.get("finished")]
        if len(comps) != 1:
            return False, "형식 " + safe_token(fid) + "의 수신 완료 기록을 확인할 수 없어 전송 완전성을 판단할 수 없습니다."
        fn, e = comps[0]
        proto = str(e.get("protocol") or "")
        if proto == "http_dash_segments":
            d = dash_seen.get(fn)
            if not d:
                return False, "DASH 조각 목록 기록을 얻지 못해 전송 완전성을 확인할 수 없습니다."
            if not d.get("static"):
                return False, "DASH 목록이 고정된 VOD가 아니어서(실시간/생성형 목록) 전송 완전성을 확인할 수 없습니다."
            n = d.get("total") or 0
            if n <= 0 or d.get("appended") != list(range(1, n + 1)):
                return False, "DASH 조각이 순서대로 빠짐없이 모두 수신되었는지 확인할 수 없습니다."
            if e.get("fragment_count") != n or e.get("fragment_index") != n:
                return False, "DASH 다운로더의 조각 수신 기록이 목록과 일치하지 않습니다."
            if not (d.get("bytes") and d.get("bytes") == e.get("disk_size") == e.get("final_downloaded")):
                return False, "DASH 조각 수신 바이트와 저장된 구성 파일 크기가 일치하지 않습니다."
            bases.append(f"DASH 고정 VOD 조각 {n}개 순서대로 모두 수신·구성 파일 {d['bytes']}바이트 일치")
            continue
        if proto in ("http", "https"):
            tb, got, disk = e.get("total_bytes"), e.get("final_downloaded"), e.get("disk_size")
            if not tb:
                return False, "서버가 전체 크기(Content-Length)를 알려주지 않아 전송 완전성을 확인할 수 없습니다."
            if not (tb == got == disk):
                return False, "서버가 알린 크기와 실제 수신/저장 크기가 일치하지 않습니다."
            bases.append(f"HTTP 응답 길이 {tb}바이트 일치")
        elif proto in ("m3u8_native", "m3u8", "hls"):
            h = hls_seen.get(fid)
            if proto != "m3u8_native" or not h:
                return False, "HLS 조각 목록 기록을 얻지 못해 전송 완전성을 확인할 수 없습니다."
            if not h.get("endlist"):
                return False, "HLS 목록에 종료 표시(#EXT-X-ENDLIST)가 없어 고정된 VOD임을 확인할 수 없습니다."
            fc, fi = e.get("fragment_count"), e.get("fragment_index")
            maps = h.get("maps", 0)
            if maps not in (0, 1) or not fc or fi != fc + maps or fc < h.get("frags", 0):
                return False, "HLS 조각이 모두 수신되었는지 확인할 수 없습니다."
            bases.append(f"HLS 고정 VOD 조각 {fc}개 모두 수신" + (" (초기화 조각 포함)" if maps else ""))
        else:
            return False, f"이 전송 방식({safe_token(proto) or '알 수 없음'})은 완전성 근거를 확인할 수 없습니다."
    return True, "; ".join(bases)


def conversion_reporter(job_id, generation, job_terminal=None):
    """Progress callback for mp4.finalize: phase "converting" (Korean text explains the conversion) or "verifying"."""
    def report(phase, pct, message):
        payload = {"phase": phase, "message": message}
        if pct is not None:
            payload["percent"] = round(pct, 2)
        with _EMIT_LOCK:
            if job_terminal is not None and job_terminal.is_set():
                return
            emit_event(job_id, generation, "progress", payload)
    return report


def verify_subtitle_file(path, root):
    ok, why = owned_regular(path, root)
    if not ok:
        return False, why
    size = os.path.getsize(path)
    if size == 0 or size > 20 * 1024 * 1024:
        return False, "자막 파일 크기가 올바르지 않습니다."
    with open(path, "rb") as f:
        raw = f.read(min(size, 65536))
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return False, "자막 파일이 UTF-8 텍스트가 아닙니다."
    low = text.lstrip().lower()
    if low.startswith(("<!doctype", "<html", "{", "[")):
        return False, "자막 대신 오류 문서가 저장되었습니다."
    if path.lower().endswith(".vtt") and not text.lstrip().startswith("WEBVTT"):
        return False, "WebVTT 형식이 아닙니다."
    return True, ""


# ----------------------------------------------------------------------------
# Download
# ----------------------------------------------------------------------------

def _install_hls_probe(hls_seen, embed_check=None):
    """
    Record what the native HLS downloader actually parsed (is the playlist a closed VOD?).
    embed_check(manifest, info_dict, native_ok) may raise to stop an embedded-player fallback format before any
    segment/key request (it is never delegated to FFmpeg).
    """
    from yt_dlp.downloader import hls
    orig = hls.HlsFD.can_download.__func__

    def patched(cls, manifest, info_dict, allow_unplayable_formats=False):
        try:
            hls_seen[str(info_dict.get("format_id"))] = {
                "endlist": "#EXT-X-ENDLIST" in manifest,
                "frags": len(re.findall(r"^#EXTINF", manifest, re.M)),
                # The native downloader fetches an #EXT-X-MAP init section as an extra counted fragment that is not
                # part of fragment_count (media fragments only).
                "maps": len(re.findall(r"^#EXT-X-MAP", manifest, re.M)),
            }
        except Exception:
            pass
        result = orig(cls, manifest, info_dict, allow_unplayable_formats)
        if embed_check is not None:
            embed_check(manifest, info_dict, result)
        return result

    hls.HlsFD.can_download = classmethod(patched)


def _install_dash_probe(dash_seen):
    """
    Record what the native DASH downloader was given (a fixed fragment list?) and what it actually appended
    (fragment indices in order + bytes), keyed by the component's final filename (same key as progress evidence).
    """
    from yt_dlp.downloader import dash
    orig_download = dash.DashSegmentsFD.real_download
    orig_append = dash.DashSegmentsFD._append_fragment

    def patched_download(self, filename, info_dict):
        try:
            for fmt in [{**info_dict, **f} for f in info_dict.get("requested_formats", [])] or [info_dict]:
                frags = fmt.get("fragments")
                key = fmt.get("filepath") or filename
                dash_seen[key] = {
                    "static": isinstance(frags, list) and not fmt.get("is_live") and not fmt.get("is_from_start")
                              and "generator" not in str(fmt.get("protocol") or ""),
                    "total": len(frags) if isinstance(frags, list) else None,
                    "appended": [], "bytes": 0,
                }
        except Exception:
            pass
        return orig_download(self, filename, info_dict)

    def patched_append(self, ctx, frag_content):
        result = orig_append(self, ctx, frag_content)
        rec = dash_seen.get(ctx.get("filename"))
        if rec is not None:
            rec["appended"].append(ctx.get("fragment_index"))
            rec["bytes"] += len(frag_content or b"")
        return result

    dash.DashSegmentsFD.real_download = patched_download
    dash.DashSegmentsFD._append_fragment = patched_append


def run_download(job_id, generation, request):
    job_terminal = threading.Event()   # a terminal outcome was (or is being) reported
    download_done = threading.Event()  # media download ended; only silences native downloader hooks

    def emit_job_event(event, payload):
        with _EMIT_LOCK:
            if event == "progress" and job_terminal.is_set():
                return
            if event in ("verified", "verificationFailed", "verificationIncomplete", "selectionChanged", "error"):
                job_terminal.set()
            emit_event(job_id, generation, event, payload)

    controller_ref = [None]   # set once the measured gate exists, so an error always carries its latest state
    selected_format_headers = [None]
    opts = {}

    def _download_diag_meta():
        meta = {"failureStage": "download", "_typedFailure": logger.last_diag}
        if selected_format_headers[0] is not None:
            ro = _make_request_options_snapshot("selected-format-options", selected_format_headers[0])
            if ro:
                meta["requestOptions"] = ro
        else:
            th = opts.get("http_headers") if isinstance(opts, dict) else None
            if isinstance(th, dict):
                ro = _make_request_options_snapshot("request-options", th)
                if ro:
                    meta["requestOptions"] = ro
        return meta

    def emit_job_error(code, message, detail="", exc=None):
        with _EMIT_LOCK:
            job_terminal.set()
            controller = controller_ref[0]
            emit_error(job_id, generation, code, message, detail, exc=exc,
                       tuning=controller.get_diagnostic_snapshot() if controller is not None else None,
                       meta=_download_diag_meta())

    url = request.get("url") or ""
    spec = request.get("spec") or {}
    ctx = request.get("context") or {}
    output_dir = spec.get("outputDir") or ""
    if not url or not output_dir or not os.path.isdir(output_dir) or os.path.islink(output_dir):
        emit_job_error("bad_request", "유효한 작업 폴더 또는 주소가 지정되지 않았습니다.")
        return 1
    output_dir = os.path.realpath(output_dir)
    problem = context_problem(url, ctx)
    if problem:
        emit_job_error(*problem)
        return 1

    try:
        import yt_dlp
        from yt_dlp.postprocessor.common import PostProcessor
    except ImportError:
        emit_job_error("engine_missing", "yt-dlp 모듈을 찾을 수 없습니다.")
        return 1

    mode = spec.get("mode") or "full"
    expected = spec.get("expected") or {}
    exp_components = {str(c.get("formatId")): c for c in (expected.get("components") or []) if c.get("formatId")}
    exp_extractor, exp_media_id = expected.get("extractor"), expected.get("mediaId")
    requested_subs = [s for s in (spec.get("subtitles") or []) if safe_token(s.get("lang"))]

    state = {"rejection": None}
    evidence, hls_seen, dash_seen = {}, {}, {}
    cap = {"filepath": None, "subs": {}}
    logger = QuietLogger()
    last_progress = [0.0]
    download_lock = threading.Lock()
    latest_download = {"total": 0, "done": 0, "speed": 0.0, "eta": 0.0, "pct": 0.0, "is_frag": False}

    def differs(exp, act, label):
        if exp is None:
            return None
        if act is None:
            return f"{label}을(를) 확인할 수 없게 되었습니다."
        if str(exp) != str(act):
            return f"{label}이(가) 선택 시점과 다릅니다."
        return None

    def identity_reason(info):
        if exp_extractor and str(info.get("extractor_key") or "").lower() != str(exp_extractor).lower():
            return "원본 사이트 정보(추출기)가 선택 시점과 다릅니다."
        if exp_media_id and str(info.get("id") or "") != str(exp_media_id):
            return "원본 미디어 식별자가 선택 시점과 다릅니다."
        return None

    def check_selection(info):
        reason = identity_reason(info)
        if reason or not exp_components:
            return reason
        if info.get("is_live"):
            return "실시간 방송으로 바뀌어 일반 다운로드로 받을 수 없습니다. 다시 분석한 뒤 녹화로 받아 주세요."
        comps = info.get("requested_formats") or ([info] if info.get("format_id") else [])
        actual = {str(c.get("format_id")): c for c in comps}
        if set(actual) != set(exp_components):
            return "서버가 제공한 형식 구성이 선택한 구성과 다릅니다."
        for fid, exp in exp_components.items():
            act = actual[fid]
            for key, label in (("height", "해상도"), ("width", "가로 크기"), ("vcodec", "영상 코덱"),
                               ("acodec", "오디오 코덱"), ("protocol", "전송 방식")):
                r = differs(exp.get(key), act.get(key), label)
                if r:
                    return r
        return None

    def match_filter(info_dict, *, incomplete):
        # Probe showed `incomplete` is a set of field names before format selection and False at the end.
        if incomplete is not False:
            return None
        hdrs = _extract_format_headers(info_dict)
        if hdrs is not None:
            selected_format_headers[0] = hdrs
        reason = check_selection(info_dict)
        if reason:
            state["rejection"] = reason
            return reason  # string => yt-dlp skips the video before any media GET (exit status stays 0)
        return None

    def progress_hook(d):
        if job_terminal.is_set():
            return
        info = d.get("info_dict") or {}
        fn = d.get("filename") or d.get("tmpfilename") or ""
        ev = evidence.setdefault(fn, {"format_id": str(info.get("format_id")) if info.get("format_id") is not None else None,
                                      "protocol": info.get("protocol")})
        status = d.get("status")
        if status == "downloading":
            tb = d.get("total_bytes")  # exact length only; estimates are not evidence
            if tb:
                ev["total_bytes"] = int(tb)
            ev["downloaded_bytes"] = int(d.get("downloaded_bytes") or 0)
            if d.get("fragment_count"):
                ev["fragment_count"], ev["fragment_index"] = d.get("fragment_count"), d.get("fragment_index")
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            done = d.get("downloaded_bytes") or 0
            pct = (float(done) / float(total) * 100.0) if total else 0.0
            proto = (ev.get("protocol") or "").lower()
            is_frag = proto in ("m3u8_native", "m3u8", "hls", "http_dash_segments") or bool(d.get("fragment_count"))

            with download_lock:
                latest_download["total"] = int(total)
                latest_download["done"] = int(done)
                latest_download["speed"] = float(d.get("speed") or 0.0)
                latest_download["eta"] = float(d.get("eta") or 0.0)
                latest_download["pct"] = round(min(pct, 100.0), 2)
                latest_download["is_frag"] = is_frag
                speed = latest_download["speed"]
                eta = latest_download["eta"]
                pct_val = latest_download["pct"]
                now = time.time()
                due = now - last_progress[0] >= 0.2
                if due:
                    last_progress[0] = now

            if due:
                tuning = None
                if is_frag:
                    curr, stable, reason = frag_controller.get_status()
                    status_text = f" · 동시 조각 {curr}/안정 {stable} ({reason})"
                    tuning = frag_controller.get_diagnostic_snapshot()
                elif d.get("progressive"):
                    curr, stable, reason = frag_controller.get_status()
                    status_text = f" · 동시 연결 {curr}/안정 {stable} ({reason})"
                    tuning = frag_controller.get_diagnostic_snapshot()
                else:
                    status_text = ""
                with _EMIT_LOCK:
                    if not (job_terminal.is_set() or download_done.is_set()):
                        progress = {
                            "phase": "downloading", "downloadedBytes": int(done), "totalBytes": int(total),
                            "speed": speed, "eta": eta,
                            "percent": pct_val,
                            "message": f"다운로드 중 ({round(pct, 1)}%){status_text}"}
                        if tuning is not None:
                            progress["tuning"] = tuning
                        emit_job_event("progress", progress)
        elif status == "finished":
            ev["finished"] = True
            ev["final_downloaded"] = int(d.get("downloaded_bytes") or 0)
            if d.get("fragment_count"):
                ev["fragment_count"], ev["fragment_index"] = d.get("fragment_count"), d.get("fragment_index")
            try:
                ev["disk_size"] = os.path.getsize(fn)
            except OSError:
                ev["disk_size"] = None
            with _EMIT_LOCK:
                if not (job_terminal.is_set() or download_done.is_set()):
                    emit_job_event("progress", {"phase": "downloading", "percent": 100.0,
                                                "message": "파일 수신 완료. 후처리 준비 중..."})

    def pp_hook(d):
        with _EMIT_LOCK:
            if not (job_terminal.is_set() or download_done.is_set()):
                emit_job_event("processing", {"message": "오디오/비디오 병합 및 스트림 변환 중..."})

    class CapturePP(PostProcessor):
        def run(self, info):
            cap["filepath"] = info.get("filepath")
            for lang, s in (info.get("requested_subtitles") or {}).items():
                if isinstance(s, dict) and s.get("filepath"):
                    cap["subs"][lang] = s["filepath"]
            return [], info

    manual_subs = any(not s.get("isAuto") for s in requested_subs)
    auto_subs = any(s.get("isAuto") for s in requested_subs)

    # Deprecated spec values (maxConcurrentFragments / concurrentFragmentDownloads / concurrent_fragment_downloads)
    # are ignored. yt-dlp's native pool capacity comes from the OS resource budget (fragments.native_pool_capacity);
    # the measured gate below decides how many receives actually run, starting at 1.
    import fragments
    pool_capacity, fuse_reached = fragments.native_pool_capacity()

    # Always present (even with pool 1) so the actual in-flight fragment receives of all streams stay within the limit.
    frag_controller = fragments.AdaptiveFragmentController(
        pool_capacity=pool_capacity, fuse_reached=fuse_reached, stop_event=STOP_EVENT)
    controller_ref[0] = frag_controller

    ffdir = os.path.dirname(_tool("ffmpeg"))
    opts = {
        "quiet": True, "no_warnings": True, "noprogress": True, "logger": logger,
        "retries": 0, "fragment_retries": 0, "file_access_retries": 0, "extractor_retries": 0,
        "skip_unavailable_fragments": False, "continuedl": False, "noplaylist": True, "cachedir": False,
        "concurrent_fragment_downloads": pool_capacity, "socket_timeout": 30, "updatetime": False,
        "hls_prefer_native": True, "ffmpeg_location": ffdir,
        "format": spec.get("formatId") or "bestvideo*+bestaudio/best",
        "outtmpl": {"default": os.path.join(output_dir, "%(title).120s.%(ext)s")},
        "match_filter": match_filter,
        "progress_hooks": [progress_hook], "postprocessor_hooks": [pp_hook],
    }
    apply_context_opts(opts, ctx)
    if mp4_merge_pair(list(exp_components.values())):
        # yt-dlp would merge H.264 + Opus/AAC into MKV, which fails on HLS (MPEG-TS) video without packet timestamps.
        # The same pair stream-copies into MP4; mp4.finalize later converts Opus to AAC as usual.
        opts["merge_output_format"] = "mp4"

    def fetch_subtitles():
        """
        Subtitles are a separate, failure-isolated pass (yt-dlp aborts the whole job when a subtitle download fails),
        so a subtitle problem can never cost the already verified video, and a retry never touches the video.
        manual/auto is part of the request: only the requested kind is enabled, there is no silent swap.
        """
        out, failed = [], []
        if not requested_subs:
            return out, failed
        rejection = {"r": None}

        def ident_filter(info_dict, *, incomplete):
            if incomplete is not False:
                return None
            r = identity_reason(info_dict)
            if r:
                rejection["r"] = r
            return r

        sopts = {
            "quiet": True, "no_warnings": True, "noprogress": True, "logger": QuietLogger(),
            "retries": 0, "extractor_retries": 0, "noplaylist": True, "cachedir": False, "socket_timeout": 30,
            "updatetime": False, "skip_download": True, "ignore_no_formats_error": True,
            "writesubtitles": manual_subs, "writeautomaticsub": auto_subs,
            "subtitleslangs": [safe_token(s["lang"]) for s in requested_subs], "subtitlesformat": "vtt/srt",
            "outtmpl": {"default": os.path.join(output_dir, "%(title).120s.%(ext)s")},
            "match_filter": ident_filter,
        }
        apply_context_opts(sopts, ctx)
        paths = {}
        try:
            with yt_dlp.YoutubeDL(sopts) as sy:
                apply_context_cookies(sy, ctx, url)
                install_ccma_https_compat(sy, url)
                try:
                    sinfo = sy.extract_info(url, download=True)
                except Exception as e:
                    vimeo_embed = public_vimeo_embed(url, e)
                    if not vimeo_embed or rejection["r"]:
                        raise
                    sinfo = sy.extract_info(vimeo_embed, download=True)
            for lang, s in ((sinfo or {}).get("requested_subtitles") or {}).items():
                if isinstance(s, dict) and s.get("filepath"):
                    paths[lang] = s["filepath"]
        except Exception:
            paths = {}
        if rejection["r"]:
            paths = {}   # the page now describes different content: never attach these subtitles
        for s in requested_subs:
            lang = safe_token(s["lang"], 24)
            p = paths.get(lang)
            good, _ = verify_subtitle_file(os.path.abspath(p), output_dir) if p else (False, "")
            if good:
                out.append({"path": os.path.abspath(p), "lang": lang, "isAuto": bool(s.get("isAuto")),
                            "ext": os.path.splitext(p)[1].lstrip(".").lower(), "size": os.path.getsize(p)})
            else:
                failed.append(lang)
        return out, failed

    if mode == "subtitlesOnly":
        subs_out, failed_langs = fetch_subtitles()
        if not subs_out:
            emit_job_event("verificationFailed", {"reason": "선택한 자막을 가져오지 못했습니다."})
            return 0
        emit_job_event("verified", {
            "primary": None, "subtitles": subs_out, "subtitlesFailed": bool(failed_langs),
            "subtitleError": ("자막(" + ", ".join(failed_langs) + ")을 가져오지 못했습니다.") if failed_langs else None,
        })
        return 0

    import discovery
    # A selection made from the embedded-player fallback (Generic + query-stable page identity) is resolved afresh.
    embed_job = discovery.is_embed_identity(exp_extractor, exp_media_id, url)
    proxied = discovery.trusted_helper_proxy(ctx.get("proxy"))

    # In-memory only: the key adapter of this fresh fallback attempt (see keys.py) and its static Korean failure reason.
    key_state = {"adapter": None, "error": None}
    # Attempt-local (extractor_key, id) of a browser-chosen direct HLS whose player context matched exactly; set only
    # after discovery.resolve_direct returned a context for this very media URL.
    direct_owner = {"id": None}
    probe_state = {"ok": False}

    def embed_check(manifest, info_dict, native_ok):
        owned = direct_owner["id"] is not None and direct_owner["id"] == (
            str(info_dict.get("extractor_key") or ""), str(info_dict.get("id") or ""))
        if owned or discovery.is_embed_identity(info_dict.get("extractor_key"), info_dict.get("id"), url):
            discovery.check_download_manifest(manifest, info_dict, native_ok, proxied)
            if key_state["adapter"] is not None:
                key_state["adapter"].register_manifest(manifest, info_dict.get("url") or "")

    def install_key_adapter(ydl, key_ctx):
        if proxied and key_ctx.get("player"):
            import keys
            key_state["adapter"] = keys.KeyAdapter(
                ydl, key_ctx["player"], key_ctx.get("bindings"),
                on_error=lambda reason: key_state.__setitem__("error", reason))

    try:
        _install_hls_probe(hls_seen, embed_check)
        probe_state["ok"] = True
    except Exception:
        if embed_job:
            emit_job_error("download_failed", "내장 플레이어 HLS 검사 준비에 실패해 받지 않았습니다.")
            return 1
        # otherwise: without the probe HLS evidence stays unknown -> verificationIncomplete
    try:
        _install_dash_probe(dash_seen)
    except Exception:
        pass  # without the probe DASH evidence stays unknown -> verificationIncomplete

    info_out = None
    import progressive
    hook = fragments.ScopedAdaptiveHook(frag_controller)
    prog_hook = progressive.ScopedProgressiveHook(frag_controller)

    try:
        hook.__enter__()
        prog_hook.__enter__()
        with yt_dlp.YoutubeDL(opts) as ydl:
            try:
                apply_context_cookies(ydl, ctx, url)
            except ValueError as e:
                emit_job_error("session_mismatch", str(e))
                return 1
            install_ccma_https_compat(ydl, url)
            ydl.add_post_processor(CapturePP(ydl), when="after_move")
            direct_page = None if embed_job else _safe_page_context(ctx.get("pageURL"), url)
            direct_done = False
            if direct_page and proxied:
                # Browser-chosen direct media: re-resolve its player context from the canonical page for this attempt.
                try:
                    raw = ydl.extract_info(url, download=False, process=False)
                except Exception:
                    raw = None
                if raw is not None and not discovery.eligible(raw) and _is_direct_hls(raw):
                    direct_ctx = discovery.resolve_direct(ydl, direct_page, url, proxied)
                    if direct_ctx:
                        raw_key, raw_id = str(raw.get("extractor_key") or ""), str(raw.get("id") or "")
                        if not raw_key or not raw_id or not probe_state["ok"]:
                            # Without the HLS guard (or a stable owner identity) a matched player context must not run.
                            emit_job_error("download_failed", "내장 플레이어 HLS 검사 준비에 실패해 받지 않았습니다.")
                            return 1
                        direct_owner["id"] = (raw_key, raw_id)
                        install_key_adapter(ydl, direct_ctx)
                    discovery.apply_direct(raw, direct_ctx, url)
                    info_out = ydl.process_ie_result(raw, download=True)
                    direct_done = True
            canon_page = _safe_page_context(ctx.get("pageURL"), url) if embed_job and proxied else None
            canonical_done = False
            if canon_page and not direct_done:
                # Optional exact-match lookup: only a clean result is used, otherwise the legacy branches below run.
                key_ctx = {}
                built, _hosts, reason = discovery.build_info(
                    ydl, canon_page, None, proxied, key_ctx, selected_media_url=url)
                if reason is None:
                    install_key_adapter(ydl, key_ctx)
                    logger.last_error = ""
                    logger.last_diag = None
                    info_out = ydl.process_ie_result(built, download=True)
                    canonical_done = True
            if direct_done or canonical_done:
                pass
            elif not embed_job:
                try:
                    info_out = ydl.extract_info(url, download=True)
                except Exception as e:
                    vimeo_embed = public_vimeo_embed(url, e, logger.last_error)
                    if not vimeo_embed or state["rejection"]:
                        raise
                    logger.last_error = ""
                    logger.last_diag = None
                    info_out = ydl.extract_info(vimeo_embed, download=True)   # match_filter re-checks identity
            else:
                # Same trigger as extraction: only while Generic still cannot use the page. Any other result is
                # processed normally, so match_filter's strict identity/selection checks decide (selectionChanged).
                try:
                    raw = ydl.extract_info(url, download=False, process=False)
                except Exception as e:
                    if not discovery.generic_unsupported(e):
                        raise
                    raw = None
                if raw is not None and not discovery.eligible(raw):
                    info_out = ydl.process_ie_result(raw, download=True)
                else:
                    key_ctx = {}
                    built, _hosts, reason = discovery.build_info(ydl, url, raw, proxied, key_ctx)
                    if reason:
                        code = "browser_required" if reason == discovery.REASONS.get("browser_required") else "download_failed"
                        emit_job_error(code, reason)
                        return 1
                    install_key_adapter(ydl, key_ctx)
                    logger.last_error = ""
                    logger.last_diag = None
                    info_out = ydl.process_ie_result(built, download=True)
    except Exception as e:
        with _EMIT_LOCK:
            job_terminal.set()
        if state["rejection"]:
            emit_job_event("selectionChanged", {"reason": state["rejection"]})
            return 0
        if key_state["error"]:
            emit_job_error("download_failed", key_state["error"])
            return 1
        if fragments._resource_problem(e):
            # Native pool creation/submit can fail outside a gated receive; in-flight receives still end by their timeouts.
            frag_controller.external_resource_failure(e)
            emit_job_error("download_failed", "맥의 연결 자원 한도에 도달해 다운로드를 중단했습니다. 다른 다운로드나 앱을 줄인 뒤 다시 시도해 주세요.",
                           type(e).__name__, exc=e)
            return 1
        text = (logger.last_error or str(e)).lower()
        if "requested format is not available" in text:
            # The chosen format ids vanished; never fall back to another format.
            emit_job_event("selectionChanged", {"reason": "선택한 형식이 서버 응답에서 사라졌습니다. 다시 선택해 주세요."})
            return 0
        emit_job_error("download_failed", "다운로드 중 오류가 발생했습니다.", logger.last_error or str(e), exc=e)
        return 1
    finally:
        with _EMIT_LOCK:
            download_done.set()
        try:
            prog_hook.__exit__(None, None, None)
        finally:
            hook.__exit__(None, None, None)

    if state["rejection"]:
        emit_job_event("selectionChanged", {"reason": state["rejection"]})
        return 0
    if key_state["error"]:   # a key failure is never hidden by a downloader that swallowed the exception
        emit_job_error("download_failed", key_state["error"])
        return 1

    # Final paths come from yt-dlp's after_move/info data, never from globbing the directory.
    media_path = cap["filepath"]
    if isinstance(info_out, dict):
        for rd in info_out.get("requested_downloads") or []:
            media_path = media_path or rd.get("filepath")

    emit_job_event("progress", {"phase": "verifying", "message": "파일 무결성, 형식, 전송 완전성 검증 중..."})

    primary = None
    if mode == "full":
        if not media_path:
            emit_job_error("no_output", "다운로드 후 산출물 경로를 확인하지 못했습니다.")
            return 1
        media_path = os.path.abspath(media_path)
        v = verify_media_file(media_path, expected, output_dir)
        if not v.get("ok"):
            emit_job_event("verificationIncomplete" if v.get("kind") == "incomplete" else "verificationFailed",
                           {"reason": v.get("reason")})
            return 0
        complete, basis = assess_completeness(evidence, hls_seen, list(exp_components), dash_seen)
        if not complete:
            emit_job_event("verificationIncomplete", {"reason": basis})
            return 0
        if v.get("hasVideo") and expected.get("intent") != "audio":
            # Video is always saved as a real MP4, only after the source passed every check above (see mp4.py).
            import mp4
            r = mp4.finalize(sys.modules[__name__], media_path, expected, output_dir,
                             conversion_reporter(job_id, generation, job_terminal))
            if not r["ok"]:
                emit_job_event("verificationIncomplete" if r["kind"] == "incomplete" else "verificationFailed",
                               {"reason": r["reason"]})
                return 0
            v, media_path, basis = r["verified"] or v, r["path"], f"{basis} · {r['note']}"
        primary = dict(v, path=media_path, completeness=basis)

    subs_out, failed_langs = fetch_subtitles()

    emit_job_event("verified", {
        "primary": primary, "subtitles": subs_out,
        "subtitlesFailed": bool(failed_langs),
        "subtitleError": ("영상은 받았지만 자막(" + ", ".join(failed_langs) + ")을 가져오지 못했습니다.") if failed_langs else None,
    })
    return 0


# ----------------------------------------------------------------------------
# Entry
# ----------------------------------------------------------------------------

def _read_request():
    raw = sys.stdin.read(2_000_000)
    return json.loads(raw) if raw.strip() else {}


def main():
    _setup_streams()
    _prepare_environment()
    _start_parent_watchdog()
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    job_id, generation = "", 0
    args = sys.argv[2:]
    for i, a in enumerate(args):
        if a == "--job-id" and i + 1 < len(args):
            job_id = args[i + 1]
        elif a == "--generation" and i + 1 < len(args):
            try:
                generation = int(args[i + 1])
            except ValueError:
                pass

    _install_stop_handler()
    emit_event(job_id, generation, "ready", {"pid": os.getpid(), "pgid": os.getpgrp()})
    try:
        if cmd == "health":
            check_health()
            return 0
        if cmd == "proxy":
            import connection
            return connection.run_proxy(
                lambda ev, payload: emit_event(job_id, generation, ev, payload),
                lambda code, message: emit_error(job_id, generation, code, message))
        if cmd == "speed":
            import speed   # user-started network speed check against fixed Cloudflare endpoints (speed.py)
            return speed.run_speed(sys.modules[__name__], job_id, generation, _read_request())
        if cmd in ("extract", "download", "record"):
            req = _read_request()
            if cmd == "extract":
                return run_extract(job_id, generation, req.get("url") or "", req.get("context") or {})
            if cmd == "record":
                import live
                return live.run_record(sys.modules[__name__], job_id, generation, req)
            return run_download(job_id, generation, req)
    except Exception as e:  # last resort; never leak raw text
        emit_error(job_id, generation, "engine_exception", "엔진에서 예기치 않은 오류가 발생했습니다.", f"{type(e).__name__}", exc=e)
        return 1
    emit_error(job_id, generation, "bad_command", "알 수 없는 엔진 명령입니다.")
    return 2


if __name__ == "__main__":
    sys.exit(main())
