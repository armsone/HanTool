"""
HttpsDown HLS key protocol compatibility for embedded players whose AES-128 key URI answers with a small JSON document
instead of the raw 16 key bytes. The page's own public player turns that JSON into the key with its published
wasm-bindgen module pair (runtime + core, decode_session); this module runs exactly that public pair, nothing else.

Scope (all of it must hold, otherwise nothing here is active):
  * only a fresh embedded-player fallback job (Generic + stable page identity) that goes through the app's own helper
  * only the AES-128 identity key URIs of the manifest that already passed the fallback download checks
  * only a non-16-byte HTTP 200 answer shaped exactly like the known JSON schema; raw 16-byte keys pass through
    untouched, everything else fails with a plain Korean reason (nothing is guessed, truncated or retried)
No authentication, captcha, license server or EME is involved. The public module pair is fetched per job through the
job's own YoutubeDL opener (proxy, cookies, headers) from the player's own https origin, size/time bounded, and only
ever executed when its SHA-256 equals the pinned release below; a changed release fails closed (update the pins).
It is executed by the trusted keydecode.mjs under Deno with every permission denied except reading the two public
files. The JSON goes in on stdin, exactly 16 bytes come back on a private pipe. Key bytes, the JSON body and signed
URLs are never written to files, logs, events or argv; the only files are the public module copies in a 0700 temp dir.
"""

import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urljoin, urlsplit

import connection

# Pinned public release of the player's decoder pair (advertised vendor protocol defaults).
PINNED_RUNTIME_SHA256 = "804452aa7903fd7a15e53ae057e8f9514dd02017625b2ac9c435e90e7c7e055a"
PINNED_RUNTIME_SIZE = 9662
PINNED_CORE_SHA256 = "03a8f0704fbadf9f3c36bff667b53c441435ad271191b4c2e60b1f09e6d5af09"
PINNED_CORE_SIZE = 178418
DEFAULT_RUNTIME_PATH = "/assets/runtime"   # player option wasmJs default
DEFAULT_CORE_PATH = "/assets/core"         # player option wasmBin default

MAX_KEY_JSON = 4096
KEY_LENGTH = 16
MODULE_FETCH_BUDGET = 15.0
MODULE_REQUEST_TIMEOUT = 8.0
DECODE_TIMEOUT = 5.0
READ_CHUNK = 65536
SAFE_PORTS = (None, 443, 8443)
_RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "keydecode.mjs")

_FIELD_TYPES = {"encrypted_key": str, "bytecode_cipher": str, "bytecode_nonce": str, "session_seed": str,
                "version": int, "key_length": int}
_OPTION_NAMES = ("wasmJs", "wasmBin", "expectedWasmHash")
# A declaration of one of the options (object key or assignment, not a comparison) ...
_DECL_RE = re.compile(r"""(?<![\w$\-])(["']?)(wasmJs|wasmBin|expectedWasmHash)\1\s*[:=](?!=)""")
# ... and the plain string literal that must follow it (possibly empty; only "\/" is accepted as an escape).
_LITERAL_RE = re.compile(r"""\s*(["'])((?:[^"'\\\s<>]|\\/){0,512})\1\s*(?=[,;}\])]|$)""")

MSG_FORMAT = "키 응답이 알려진 형식(JSON)과 달라 해석하지 않았습니다. 이 영상의 키 방식은 지원하지 않습니다."
MSG_OVERSIZE = "키 응답이 허용 크기(4KiB)를 넘어 해석하지 않았습니다."
MSG_MODULE_FETCH = "페이지 플레이어의 공개 키 처리 모듈을 가져오지 못했습니다."
MSG_MODULE_PIN = ("페이지 플레이어의 키 처리 모듈이 앱이 확인한 버전과 달라 실행하지 않았습니다. "
                  "앱 업데이트가 필요할 수 있습니다.")
MSG_MODULE_URL = "키 처리 모듈 주소가 플레이어와 같은 공개 https 출처가 아니어서 사용하지 않았습니다."
MSG_RUNTIME = "키 처리 도구(Deno)를 실행하지 못했습니다."
MSG_DECODE = "공개 키 처리 모듈이 키 응답을 해석하지 못했습니다."
MSG_BINDING = ("페이지 플레이어의 키 모듈 설정(wasmJs/wasmBin/expectedWasmHash)이 고정된 문자열 값으로 확인되지 않아 "
               "지원하지 않는 방식입니다.")
MSG_MODULE_HASH = "페이지 플레이어가 선언한 키 처리 모듈 무결성 값(expectedWasmHash)과 실제 모듈이 달라 실행하지 않았습니다."


class KeyProtocolError(Exception):
    """Carries a static Korean reason (never remote text, never key material)."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


# ----------------------------------------------------------------------------
# Bounded, sandboxed decode of one key response
# ----------------------------------------------------------------------------

def _deno():
    if getattr(sys, "frozen", False):
        # Portable engine: only the bundled runtime, never an external one.
        path = os.path.join(getattr(sys, "_MEIPASS", "") or "", "tools", "deno")
    else:
        path = shutil.which("deno") or "/opt/homebrew/bin/deno"
    if not (os.path.isfile(path) and os.access(path, os.X_OK)) or not os.path.isfile(_RUNNER):
        raise KeyProtocolError(MSG_RUNTIME)
    return path


def parse_key_json(text):
    """Recognized schema only: exactly the known fields with the known types. Returns the dict or raises."""
    if not isinstance(text, str):
        raise KeyProtocolError(MSG_FORMAT)
    try:
        raw = text.encode("utf-8")
    except UnicodeError:
        raise KeyProtocolError(MSG_FORMAT) from None
    if len(raw) > MAX_KEY_JSON:
        raise KeyProtocolError(MSG_OVERSIZE)
    try:
        data = json.loads(text)
    except ValueError:
        raise KeyProtocolError(MSG_FORMAT) from None
    if not isinstance(data, dict) or set(data) != set(_FIELD_TYPES):
        raise KeyProtocolError(MSG_FORMAT)
    for name, kind in _FIELD_TYPES.items():
        value = data[name]
        if type(value) is not kind or (kind is str and not value):
            raise KeyProtocolError(MSG_FORMAT)
    if data["key_length"] != KEY_LENGTH:
        raise KeyProtocolError(MSG_FORMAT)
    return data


def verify_pins(runtime_bytes, core_bytes, expected_wasm_hash=""):
    ok = (isinstance(runtime_bytes, bytes) and isinstance(core_bytes, bytes)
          and len(runtime_bytes) == PINNED_RUNTIME_SIZE and len(core_bytes) == PINNED_CORE_SIZE
          and hashlib.sha256(runtime_bytes).hexdigest() == PINNED_RUNTIME_SHA256
          and hashlib.sha256(core_bytes).hexdigest() == PINNED_CORE_SHA256)
    if not ok:
        raise KeyProtocolError(MSG_MODULE_PIN)
    # The player's own integrity option (original: truthy -> SHA-384 of the core as lowercase hex, strict compare):
    # no prefix stripping, base64 or case normalization; an empty value is ignored like the player does. The
    # hexdigest is always 96 lowercase hex, so any other literal simply cannot match. Checked before the core runs.
    if expected_wasm_hash and (not isinstance(expected_wasm_hash, str)
                               or hashlib.sha384(core_bytes).hexdigest() != expected_wasm_hash):
        raise KeyProtocolError(MSG_MODULE_HASH)


def _write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def decode_json_key(json_text, runtime_bytes, core_bytes, expected_wasm_hash=""):
    """
    json_text (the key URI's JSON answer) -> the exact 16 key bytes. Verifies the bounded input and the pinned public
    code (plus the player's expectedWasmHash when it declares one), then runs keydecode.mjs under Deno with no
    permission except reading the two public module copies.
    Raises KeyProtocolError (static Korean reason) on any problem.
    """
    parse_key_json(json_text)
    verify_pins(runtime_bytes, core_bytes, expected_wasm_hash)
    deno = _deno()
    work = tempfile.mkdtemp(prefix="httpsdown-keymod-")   # 0700; public module copies only, removed below
    proc = None
    try:
        runtime_path, core_path = os.path.join(work, "runtime.mjs"), os.path.join(work, "core.wasm")
        _write_private(runtime_path, runtime_bytes)
        _write_private(core_path, core_bytes)
        deno_dir = os.path.join(work, "deno")
        os.mkdir(deno_dir, 0o700)
        env = {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "DENO_DIR": deno_dir,
               "DENO_NO_UPDATE_CHECK": "1", "NO_COLOR": "1"}
        cmd = [deno, "run", "--no-config", "--no-npm", "--no-remote", "--no-prompt", "--no-lock",
               "--deny-net", "--deny-env", "--deny-sys", "--deny-run", "--deny-ffi", "--deny-write", "--deny-import",
               f"--allow-read={runtime_path},{core_path}",
               "--v8-flags=--max-old-space-size=64,--wasm-max-mem-pages=256",
               _RUNNER, runtime_path, core_path]
        try:
            # No new session/group: the child stays in the engine's process group (cancel/watchdog kill it too).
            proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    env=env, cwd=work, close_fds=True)
            try:
                out, _ = proc.communicate(json_text.encode("utf-8"), timeout=DECODE_TIMEOUT)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()
                raise KeyProtocolError(MSG_DECODE) from None
        except OSError:
            raise KeyProtocolError(MSG_RUNTIME) from None
        if proc.returncode != 0 or len(out) != KEY_LENGTH:
            raise KeyProtocolError(MSG_DECODE)
        return out
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait()
        shutil.rmtree(work, ignore_errors=True)


# ----------------------------------------------------------------------------
# Public module pair (fetched per job through the job's own opener)
# ----------------------------------------------------------------------------

def merge_bindings(into, new):
    """Union of binding dicts; a name declared twice with different values (or not as a literal) becomes None."""
    for name, value in new.items():
        if name not in into:
            into[name] = value
        elif into[name] != value:
            into[name] = None
    return into


def extract_bindings(script_text):
    """
    wasmJs/wasmBin/expectedWasmHash option declarations of a player config, memory only, no JS evaluation.
    name -> plain string literal (may be empty: the player treats "" as "use the default" / "no integrity value"),
    or None when the option is declared but not as a plain literal (variable, concatenation, template, escapes, ...)
    or declared with conflicting values; the adapter then fails closed instead of ignoring an override/constraint.
    """
    out = {}
    text = script_text or ""
    for m in _DECL_RE.finditer(text):
        lit = _LITERAL_RE.match(text, m.end())
        merge_bindings(out, {m.group(2): lit.group(2).replace("\\/", "/") if lit else None})
    return out


def _origin(url):
    p = urlsplit(url)
    return (p.scheme.lower(), (p.hostname or "").lower().rstrip("."), p.port or (443 if p.scheme.lower() == "https" else None))


def module_url_ok(url, player_url):
    """Public https URL on exactly the player frame's own origin."""
    try:
        p = urlsplit(url)
        port = p.port
        host = (p.hostname or "").lower().rstrip(".")
        if (p.scheme.lower() != "https" or p.username or p.password or not host or port not in SAFE_PORTS
                or connection._ip_literal(host) is not None or not connection.valid_hostname(host)
                or host == "localhost" or host.endswith(connection._BLOCKED_SUFFIXES)):
            return False
        return _origin(url) == _origin(player_url)
    except ValueError:
        return False


class KeyAdapter:
    """
    Per-job (per YoutubeDL instance) hook around ydl.urlopen: answers for the AES-128 identity key URIs of the
    registered manifest only; every other request goes straight through. Plain 16-byte keys are returned unchanged.
    """

    def __init__(self, ydl, player_url, bindings=None, on_error=None):
        self.ydl = ydl
        self.player_url = player_url
        self.bindings = dict(bindings or {})
        self.on_error = on_error
        self._manifest_urls = set()
        self._bases = set()
        self._refs = []
        self._modules = None
        self._lock = threading.Lock()
        self._orig = ydl.urlopen
        ydl.urlopen = self._urlopen

    # -- registration -------------------------------------------------------

    def register_manifest(self, manifest, manifest_url):
        """Remember the identity AES-128 key URIs of a manifest that already passed the download checks."""
        from yt_dlp.utils import parse_m3u8_attributes
        for line in manifest.splitlines():
            line = line.strip()
            if not line.startswith("#EXT-X-KEY:"):
                continue
            attrs = parse_m3u8_attributes(line[len("#EXT-X-KEY:"):])
            if attrs.get("METHOD") == "AES-128" and attrs.get("URI") and \
                    str(attrs.get("KEYFORMAT") or "identity").lower() == "identity":
                self._refs.append(attrs["URI"])
        self._manifest_urls.add(manifest_url)
        self._bases.add(manifest_url)

    def _is_key(self, url):
        if not self._refs:
            return False
        for base in self._bases:
            for ref in self._refs:
                try:
                    if urljoin(base, ref) == url:
                        return True
                except ValueError:
                    continue
        return False

    # -- opener hook ----------------------------------------------------------

    def _urlopen(self, req, *args, **kwargs):
        url = getattr(req, "url", req)
        resp = self._orig(req, *args, **kwargs)
        if url in self._manifest_urls:
            final = getattr(resp, "url", None)
            if final:
                self._bases.add(final)   # the downloader resolves key URIs against the redirected manifest address
            return resp
        if isinstance(url, str) and self._is_key(url):
            try:
                return self._adapt(resp)
            except KeyProtocolError as e:
                if self.on_error:
                    self.on_error(e.reason)
                raise
        return resp

    def _adapt(self, resp):
        from yt_dlp.networking.common import Response
        try:
            status = getattr(resp, "status", 200)
            body = b""
            while len(body) <= MAX_KEY_JSON:
                chunk = resp.read(MAX_KEY_JSON + 1 - len(body))
                if not chunk:
                    break
                body += chunk
        finally:
            resp.close()

        def rebuilt(data):
            return Response(io.BytesIO(data), resp.url, resp.headers, status=status)

        if len(body) == KEY_LENGTH:
            return rebuilt(body)            # ordinary raw key: unchanged
        if len(body) > MAX_KEY_JSON:
            raise KeyProtocolError(MSG_OVERSIZE)
        head = body.lstrip(b"\xef\xbb\xbf \t\r\n")[:1]
        if status == 200 and head == b"{":
            try:
                text = body.decode("utf-8")
            except UnicodeDecodeError:
                raise KeyProtocolError(MSG_FORMAT) from None
            parse_key_json(text)
            expected = self._check_options()
            runtime_bytes, core_bytes = self._load_modules()
            return rebuilt(decode_json_key(text, runtime_bytes, core_bytes, expected))
        # Only the 16-byte AES-128 identity key (above) or the known JSON schema is valid; no other length is
        # passed on (AES-192/256 sizes are not valid input for this AES-128 target), guessed or truncated.
        raise KeyProtocolError(MSG_FORMAT)

    # -- module pair --------------------------------------------------------------

    def _check_options(self):
        """Fails closed if a module option was declared but is not a plain literal; returns expectedWasmHash ("" = none)."""
        for name in _OPTION_NAMES:
            if name in self.bindings and self.bindings[name] is None:
                raise KeyProtocolError(MSG_BINDING)
        return self.bindings.get("expectedWasmHash") or ""

    def _load_modules(self):
        with self._lock:
            if self._modules is None:
                expected = self._check_options()
                # Imported at call time: discovery imports this module at load time. The alarm-based bound covers a
                # slow trickle inside one read chunk, but only on the main thread (where the engine runs jobs);
                # off the main thread only the per-request timeout and the between-chunk deadline checks apply.
                import discovery
                try:
                    with discovery._hard_deadline(MODULE_FETCH_BUDGET):
                        deadline = time.monotonic() + MODULE_FETCH_BUDGET
                        runtime_url = urljoin(self.player_url, self.bindings.get("wasmJs") or DEFAULT_RUNTIME_PATH)
                        core_url = urljoin(self.player_url, self.bindings.get("wasmBin") or DEFAULT_CORE_PATH)
                        runtime_bytes = self._fetch(runtime_url, PINNED_RUNTIME_SIZE, deadline)
                        core_bytes = self._fetch(core_url, PINNED_CORE_SIZE, deadline)
                except discovery._DeadlineHit:
                    raise KeyProtocolError(MSG_MODULE_FETCH) from None
                verify_pins(runtime_bytes, core_bytes, expected)
                self._modules = (runtime_bytes, core_bytes)
            return self._modules

    def _fetch(self, url, expected_size, deadline):
        """One public module file: same-origin https, redirects re-checked, at most expected_size+1 bytes read."""
        from yt_dlp.networking import Request
        if not module_url_ok(url, self.player_url):
            raise KeyProtocolError(MSG_MODULE_URL)
        left = deadline - time.monotonic()
        if left <= 1.0:
            raise KeyProtocolError(MSG_MODULE_FETCH)
        # Referer is the player's origin only: the full player URL (query included) must not cross a redirect.
        ref = urlsplit(self.player_url)
        referer = f"{ref.scheme.lower()}://{ref.netloc.rsplit('@', 1)[-1]}/"
        try:
            resp = self._orig(Request(url, headers={"Referer": referer},
                                      extensions={"timeout": min(MODULE_REQUEST_TIMEOUT, left)}))
        except Exception:
            raise KeyProtocolError(MSG_MODULE_FETCH) from None
        try:
            if not module_url_ok(resp.url, self.player_url):
                raise KeyProtocolError(MSG_MODULE_URL)
            if getattr(resp, "status", 200) != 200:
                raise KeyProtocolError(MSG_MODULE_FETCH)
            parts, size = [], 0
            while size <= expected_size:
                if time.monotonic() > deadline:
                    raise KeyProtocolError(MSG_MODULE_FETCH)
                chunk = resp.read(min(READ_CHUNK, expected_size + 1 - size))
                if not chunk:
                    break
                parts.append(chunk)
                size += len(chunk)
        except KeyProtocolError:
            raise
        except Exception:
            raise KeyProtocolError(MSG_MODULE_FETCH) from None
        finally:
            resp.close()
        data = b"".join(parts)
        if len(data) != expected_size:
            raise KeyProtocolError(MSG_MODULE_PIN)
        return data
