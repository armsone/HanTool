"""
HttpsDown "연결 도움": app-only authenticated loopback CONNECT proxy (Python stdlib only).

Started by the app as `engine.py proxy`. The first stdin line is the JSON config:
  {"username": str, "password": str, "domains": [str], "hosts": [str], "splitTLS": bool, "autoAllowPublic": bool, "autoRetryTLS": bool}
Later stdin lines may switch {"op": "config", "autoRetryTLS": bool} live (tunnels already running are untouched).
Later stdin lines are policy updates: {"op": "allow", "id": int, "domains": [...], "hosts": [...]}; each is
acknowledged with a `policyApplied` {"id"} event once it is in force.
stdin EOF (the app closed the pipe) stops the proxy.

Guarantees:
  * binds 127.0.0.1 on an ephemeral port only; every request must carry the session Basic credentials (407 otherwise).
    The username may carry a client tag (`<username>-<tag>`, tag [a-z0-9]{1,24}) chosen by the app (e.g. one per job
    run, one for the browser); the password must match exactly. The tag only labels `blocked` events so the app can
    bind a refusal to the job or page that caused it.
  * CONNECT tunnels (no TLS interception, no certificates) plus one narrow plain-HTTP path: an absolute-form
    `http://host[:port]/...` GET/HEAD/POST is rewritten to origin-form and sent to that origin only, one request per
    connection (`Connection: close`), through the same destination checks as CONNECT. It rejects credentials in the
    URL, Host mismatch, Transfer-Encoding/Upgrade/Expect, duplicate or invalid Content-Length, pipelined bytes, other
    schemes and methods; Proxy-Authorization and hop-by-hop headers are never forwarded. It is not an open proxy.
  * destination host must be a syntactically valid DNS name (or an explicitly allowed public IP literal) on an
    allowed port, allowed by the session policy, and every resolved address must be public (no private, loopback,
    link-local, multicast, reserved, CGNAT, IPv4-mapped tricks). Only those vetted addresses are connected to
    (no second DNS lookup), so a second DNS answer cannot rebind the tunnel.
  * connecting tries at most 6 vetted addresses, IPv6/IPv4 interleaved, a new attempt every 250 ms or right after a
    failure, first success wins, all other sockets are closed; the whole connect is bounded to 15 s.
  * blocked destinations are reported as `blocked` events (hostname + reason code only, never paths or secrets)
  * TLS first-record split (on whenever the app's "HTTPS 연결 도움" is on): the client's first TLS handshake record
    (ClientHello) is re-framed into two records and written with two sends. Reading it is bounded by a real deadline;
    if it is not a complete ClientHello record in time, every byte read is forwarded unchanged and a `splitFallback`
    event says why. It does not alter certificate validation and does not guarantee anything.
  * opt-in pre-request TLS retry (`autoRetryTLS`, default off, browser client tag "web", port 443 only): after the
    split ClientHello was sent and before any other client byte is sent, if the upstream closes/resets with no
    byte at all, the identical complete unsplit ClientHello is sent once on a new socket to the SAME already vetted
    peer address. Any server byte (alerts too), extra client bytes, early_data, an unparsable hello, a timeout or
    any other error keeps the normal relay. No HTTP is replayed; no second CONNECT reply; no re-resolution.
"""

import base64
import binascii
import errno
import hmac
import ipaddress
import json
import re
import select
import selectors
import socket
import sys
import threading
import time

MAX_HEADER = 16384
MAX_CONNECTIONS = 256
ALLOWED_PORTS = {80, 443, 8080, 8443}
CONNECT_BUDGET = 15.0
CONNECT_ATTEMPT_DELAY = 0.25
CONNECT_MAX_ATTEMPTS = 6
SPLIT_BUDGET = 5.0
RETRY_PROBE_BUDGET = 1.5
RETRY_CONNECT_BUDGET = 5.0
RETRY_CLIENT = "web"
IDLE_TIMEOUT = 300
PLAIN_METHODS = {"GET", "HEAD", "POST"}
MAX_PLAIN_BODY = 16 * 1024 * 1024
PLAIN_IO_TIMEOUT = 60
_HOP_HEADERS = {"proxy-authorization", "proxy-connection", "connection", "keep-alive", "te", "trailer",
                "upgrade", "proxy-authenticate", "host", "content-length"}
_LABEL_RE = re.compile(r"^(?!-)[a-z0-9-]{1,63}(?<!-)$")
_TAG_RE = re.compile(rb"^[a-z0-9]{1,24}$")
_IN_PROGRESS = {errno.EINPROGRESS, errno.EALREADY, errno.EWOULDBLOCK, errno.EAGAIN}
_BLOCKED_SUFFIXES = (".local", ".localhost", ".internal", ".home.arpa", ".lan", ".intranet", ".corp")


class Policy:
    def __init__(self):
        self._lock = threading.Lock()
        self._domains = set()
        self._hosts = set()

    @staticmethod
    def _norm(name):
        n = str(name or "").strip().lower().rstrip(".")
        return n if n and len(n) <= 253 else ""

    def update(self, domains=(), hosts=()):
        with self._lock:
            for d in domains or ():
                n = self._norm(d)
                if n and "." in n and valid_hostname(n):
                    self._domains.add(n)
            for h in hosts or ():
                n = self._norm(h)
                if n:
                    self._hosts.add(n)

    def allows(self, host):
        with self._lock:
            if host in self._hosts:
                return True
            return any(host == d or host.endswith("." + d) for d in self._domains)


def valid_hostname(host):
    if not host or len(host) > 253 or "." not in host:
        return False
    return all(_LABEL_RE.match(label) for label in host.split("."))


def _ip_literal(host):
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        return None


def _public(ip):
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return _public(ip.ipv4_mapped)
        if ip.sixtofour is not None or ip.teredo is not None:
            return False
    if ip.is_multicast or ip.is_unspecified or ip.is_loopback or ip.is_link_local or ip.is_private or ip.is_reserved:
        return False
    if isinstance(ip, ipaddress.IPv4Address) and ip in ipaddress.ip_network("100.64.0.0/10"):
        return False
    return bool(ip.is_global)


def _interleave(addrs):
    """Alternates address families, starting with the family of the first (resolver-preferred) address."""
    if not addrs:
        return []
    first = [a for a in addrs if a[0] == addrs[0][0]]
    other = [a for a in addrs if a[0] != addrs[0][0]]
    out = []
    for i in range(max(len(first), len(other))):
        out.extend(group[i] for group in (first, other) if i < len(group))
    return out


def connect_staggered(addrs, port, budget=CONNECT_BUDGET, delay=CONNECT_ATTEMPT_DELAY,
                      max_attempts=CONNECT_MAX_ATTEMPTS):
    """Happy-Eyeballs-style connect to already vetted (family, ip) pairs. Returns a blocking socket or None.

    A new attempt starts every `delay` seconds, or at once when the previous one failed; the first completed
    connection wins and every other socket (losing, pending or failed) is closed. Bounded by `budget` seconds.
    """
    order = _interleave(list(addrs))[:max_attempts]
    sel = selectors.DefaultSelector()
    pending = []
    winner = None
    deadline = time.monotonic() + budget
    next_start = 0.0
    idx = 0
    try:
        while winner is None:
            now = time.monotonic()
            if now >= deadline:
                break
            if idx < len(order) and (now >= next_start or not pending):
                family, ip = order[idx]
                idx += 1
                s = None
                try:
                    s = socket.socket(family, socket.SOCK_STREAM)
                    s.setblocking(False)
                    err = s.connect_ex((ip, port))
                except OSError:
                    err = -1
                if err == 0:
                    winner = s
                    break
                if err in _IN_PROGRESS:
                    sel.register(s, selectors.EVENT_WRITE)
                    pending.append(s)
                    next_start = now + delay
                else:
                    if s is not None:
                        s.close()
                    next_start = now   # immediate failure: the next address starts right away
                continue
            if not pending:
                break   # nothing in flight and nothing left to try
            wait = deadline - now
            if idx < len(order):
                wait = min(wait, max(0.0, next_start - now))
            for key, _mask in sel.select(max(0.0, wait)):
                s = key.fileobj
                sel.unregister(s)
                pending.remove(s)
                try:
                    err = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                except OSError:
                    err = -1
                if err == 0 and winner is None:
                    winner = s
                else:
                    s.close()
                    if winner is None:
                        next_start = time.monotonic()
    finally:
        for s in pending:
            try:
                sel.unregister(s)
            except (KeyError, ValueError, OSError):
                pass
            s.close()
        sel.close()
    if winner is None:
        return None
    try:
        winner.setblocking(True)   # also clears the timeout; the tunnel sets its own
        winner.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        winner.close()
        return None
    return winner


def read_first_record(client, pending, budget=SPLIT_BUDGET):
    """Reads (bounded by a monotonic deadline) until `pending` holds one complete TLS handshake record carrying a
    ClientHello. Returns (all bytes read, reason): reason "" when the record is complete, otherwise why splitting is
    not applied. Every byte read is returned exactly once, in order; the socket timeout is restored."""
    buf = pending
    deadline = time.monotonic() + budget
    old = client.gettimeout()
    try:
        while True:
            if len(buf) >= 5:
                if buf[0] != 0x16 or buf[1] != 0x03:
                    return buf, "not_tls"
                length = (buf[3] << 8) | buf[4]
                if length < 2 or length > 16384:
                    return buf, "bad_record"
                if len(buf) >= 5 + length:
                    return buf, ("" if buf[5] == 0x01 else "not_client_hello")
            left = deadline - time.monotonic()
            if left <= 0:
                return buf, "timeout"
            client.settimeout(left)
            try:
                chunk = client.recv(16389)
            except socket.timeout:
                return buf, "timeout"
            except OSError:
                return buf, "read_error"
            if not chunk:
                return buf, "eof"
            buf += chunk
    finally:
        try:
            client.settimeout(old)
        except OSError:
            pass


def split_record(buf, host):
    """Re-frames the complete first record at the start of `buf` into two records. Returns (first, second, rest)."""
    length = (buf[3] << 8) | buf[4]
    payload, rest = buf[5:5 + length], buf[5 + length:]
    split = 1
    name = host.encode("ascii", "ignore") if host else b""
    pos = payload.find(name) if name else -1
    if pos > 0:
        split = pos + max(1, len(name) // 2)
    split = max(1, min(split, length - 1))
    first = bytes([0x16, buf[1], buf[2]]) + split.to_bytes(2, "big") + payload[:split]
    second = bytes([0x16, buf[1], buf[2]]) + (length - split).to_bytes(2, "big") + payload[split:]
    return first, second, rest


def hello_allows_retry(record):
    """True only when `record` is exactly one TLS record holding exactly one complete ClientHello handshake message
    that parses fully (bounded) and does not offer early_data (0x002a). Anything else: False."""
    try:
        if len(record) < 9 or record[0] != 0x16 or record[1] != 0x03:
            return False
        length = (record[3] << 8) | record[4]
        if length < 4 or length > 16384 or len(record) != 5 + length:
            return False
        body = record[5:]
        if body[0] != 0x01 or int.from_bytes(body[1:4], "big") != len(body) - 4:
            return False
        msg = body[4:]
        pos = 2 + 32                                  # legacy_version + random
        if len(msg) < pos + 1:
            return False
        pos += 1 + msg[pos]                           # session id
        if len(msg) < pos + 2:
            return False
        pos += 2 + int.from_bytes(msg[pos:pos + 2], "big")   # cipher suites
        if len(msg) < pos + 1:
            return False
        pos += 1 + msg[pos]                           # compression methods
        if pos == len(msg):
            return True                               # no extensions at all, so no early_data
        if len(msg) < pos + 2:
            return False
        ext_len = int.from_bytes(msg[pos:pos + 2], "big")
        pos += 2
        if pos + ext_len != len(msg):
            return False
        end = len(msg)
        while pos < end:
            if pos + 4 > end:
                return False
            etype = int.from_bytes(msg[pos:pos + 2], "big")
            elen = int.from_bytes(msg[pos + 2:pos + 4], "big")
            pos += 4
            if pos + elen > end:
                return False
            if etype == 0x002a:
                return False
            pos += elen
        return pos == end
    except (IndexError, ValueError):
        return False


def probe_silent_close(upstream, budget=RETRY_PROBE_BUDGET):
    """True only if the upstream shows EOF or a reset with no byte received. Uses MSG_PEEK so any data stays unread
    for the normal relay. Timeout, data or any other state: False."""
    old = upstream.gettimeout()
    try:
        upstream.settimeout(budget)
        try:
            data = upstream.recv(1, socket.MSG_PEEK)
        except socket.timeout:
            return False
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
            return True
        except OSError:
            return False
        return data == b""
    finally:
        try:
            upstream.settimeout(old)
        except OSError:
            pass


def client_quiet(client):
    """True only if the client socket has nothing queued: no bytes, no EOF, no error. Non-consuming, non-blocking."""
    try:
        r, _w, x = select.select([client], [], [client], 0)
    except (OSError, ValueError):
        return False
    return not r and not x


def reconnect_same_peer(family, peer, budget=RETRY_CONNECT_BUDGET):
    """New socket to the exact peer address the first (vetted) upstream was connected to; None on any failure."""
    new = None
    try:
        new = socket.socket(family, socket.SOCK_STREAM)
        new.settimeout(budget)
        new.connect(peer)
        new.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        new.settimeout(IDLE_TIMEOUT)
        return new
    except OSError:
        if new is not None:
            new.close()
        return None


SPLIT_FALLBACK_REASONS = {
    "not_tls": "TLS 연결이 아니어서 나눠 보내지 않고 그대로 전달했습니다.",
    "bad_record": "첫 TLS 레코드 형식이 예상과 달라 그대로 전달했습니다.",
    "not_client_hello": "첫 TLS 메시지가 ClientHello가 아니어서 그대로 전달했습니다.",
    "timeout": "첫 TLS 메시지가 제시간에 다 오지 않아 받은 그대로 전달했습니다.",
}


class ProxyServer:
    def __init__(self, emit, config):
        self.emit = emit
        self.username = str(config.get("username") or "")
        self.password = str(config.get("password") or "")
        self.split_tls = bool(config.get("splitTLS"))
        self.auto_allow_public = config.get("autoAllowPublic") is True
        self.auto_retry_tls = config.get("autoRetryTLS") is True
        self.policy = Policy()
        self.policy.update(config.get("domains") or (), config.get("hosts") or ())
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        self._recent = {}
        self._recent_lock = threading.Lock()
        self._user = self.username.encode("utf-8")
        self._password = self.password.encode("utf-8")
        self.sock = None
        self.stopping = threading.Event()

    # -- events ------------------------------------------------------------

    def _fresh(self, key):
        now = time.time()
        with self._recent_lock:
            if now - self._recent.get(key, 0) < 2.0:
                return False
            if len(self._recent) > 4096:
                self._recent.clear()
            self._recent[key] = now
            return True

    def blocked(self, host, port, code, reason, client=""):
        if self._fresh((host, code, client)):
            self.emit("blocked", {"host": str(host)[:253], "port": int(port or 0), "code": code, "reason": reason,
                                  "client": client})

    def split_fallback(self, host, code, client=""):
        if code in SPLIT_FALLBACK_REASONS and self._fresh(("split", host, code)):
            self.emit("splitFallback", {"host": str(host)[:253], "code": code,
                                        "reason": SPLIT_FALLBACK_REASONS[code], "client": client})

    # -- lifecycle ---------------------------------------------------------

    def start(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 0))
        s.listen(128)
        self.sock = s
        threading.Thread(target=self._accept_loop, daemon=True).start()
        return s.getsockname()[1]

    def stop(self):
        self.stopping.set()
        try:
            self.sock.close()
        except Exception:
            pass

    def _accept_loop(self):
        while not self.stopping.is_set():
            try:
                conn, addr = self.sock.accept()
            except OSError:
                if self.stopping.is_set():
                    return
                time.sleep(0.05)
                continue
            if addr[0] != "127.0.0.1":
                conn.close()
                continue
            if not self.slots.acquire(blocking=False):
                try:
                    conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                finally:
                    conn.close()
                continue
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    # -- per connection ----------------------------------------------------

    def _serve(self, conn):
        upstream = None
        try:
            conn.settimeout(30)
            buf = b""
            for _attempt in range(4):
                head, buf = self._read_head(conn, buf)
                if head is None:
                    return
                method, target, headers = self._parse_head(head)
                if method is None:
                    self._reply(conn, 400, "Bad Request", close=True)
                    return
                client = self._client(headers)
                if client is None:
                    self._reply(conn, 407, "Proxy Authentication Required",
                                extra="Proxy-Authenticate: Basic realm=\"HttpsDown\"\r\n")
                    continue
                if method != "CONNECT":
                    upstream = self._plain_http(conn, head, buf, method, target, client)
                    return
                host, port = self._split_target(target)
                ok, code, reason, addrs = self._check_destination(host, port, authenticated=True)
                if not ok:
                    self.blocked(host or str(target)[:80], port or 0, code, reason, client)
                    self._reply(conn, 403, "Forbidden", close=True, body=reason.encode("utf-8"))
                    return
                upstream = connect_staggered(addrs, port)
                if upstream is None:
                    self.blocked(host, port, "connect_failed", "목적지 서버에 연결하지 못했습니다 (15초 안에 응답한 주소 없음).",
                                 client)
                    self._reply(conn, 502, "Bad Gateway", close=True)
                    return
                conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                self._tunnel(conn, upstream, buf, host, client, split=self.split_tls and port != 80,
                             port=port)
                return
            self._reply(conn, 407, "Proxy Authentication Required", close=True,
                        extra="Proxy-Authenticate: Basic realm=\"HttpsDown\"\r\n")
        except Exception:
            pass
        finally:
            for s in (conn, upstream):
                if s is not None:
                    try:
                        s.close()
                    except Exception:
                        pass
            self.slots.release()

    @staticmethod
    def _read_head(conn, buf):
        while b"\r\n\r\n" not in buf:
            if len(buf) > MAX_HEADER:
                return None, b""
            try:
                chunk = conn.recv(4096)
            except OSError:
                return None, b""
            if not chunk:
                return None, b""
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        return head, rest

    @staticmethod
    def _parse_head(head):
        try:
            text = head.decode("latin-1")
        except Exception:
            return None, None, None
        lines = text.split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) != 3 or not parts[2].startswith("HTTP/1."):
            return None, None, None
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        return parts[0].upper(), parts[1], headers

    def _client(self, headers):
        """Client tag ("" for the plain session username) when the session credentials match, else None."""
        value = headers.get("proxy-authorization") or ""
        scheme, _, token = value.partition(" ")
        if scheme.lower() != "basic" or not self.username or not self.password:
            return None
        try:
            raw = base64.b64decode(token.strip().encode("latin-1", "replace"), validate=True)
        except (ValueError, binascii.Error):
            return None
        user, sep, password = raw.partition(b":")
        if not sep or not hmac.compare_digest(password, self._password):
            return None
        if hmac.compare_digest(user, self._user):
            return ""
        prefix = self._user + b"-"
        if user.startswith(prefix) and _TAG_RE.match(user[len(prefix):]):
            return user[len(prefix):].decode("ascii")
        return None

    @staticmethod
    def _reply(conn, code, text, close=False, extra="", body=b""):
        msg = f"HTTP/1.1 {code} {text}\r\n{extra}Content-Length: {len(body)}\r\n"
        if close:
            msg += "Connection: close\r\n"
        try:
            conn.sendall(msg.encode("latin-1") + b"\r\n" + body)
        except OSError:
            pass

    @staticmethod
    def _host_of_absolute(target):
        m = re.match(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://([^/:?#\[\]]+|\[[0-9a-fA-F:.]+\])", str(target or ""))
        return m.group(1).lower()[:253] if m else ""

    @staticmethod
    def _split_target(target):
        t = str(target or "")
        if t.startswith("["):
            end = t.find("]")
            if end < 0 or not t[end + 1:].startswith(":"):
                return "", 0
            host, port_s = t[1:end], t[end + 2:]
        else:
            host, _, port_s = t.rpartition(":")
        try:
            port = int(port_s)
        except ValueError:
            return host.lower(), 0
        return host.lower().rstrip("."), port

    def _check_destination(self, host, port, authenticated=False):
        if not host or not (0 < port < 65536):
            return False, "bad_target", "목적지 주소 형식이 올바르지 않습니다.", None
        if port not in ALLOWED_PORTS:
            return False, "port_denied", f"허용하지 않는 포트({port})입니다.", None
        literal = _ip_literal(host)
        if literal is None:
            if not valid_hostname(host) or host == "localhost" or host.endswith(_BLOCKED_SUFFIXES):
                return False, "bad_host", "로컬망 또는 올바르지 않은 호스트 이름입니다.", None
            if not (self.auto_allow_public and authenticated) and not self.policy.allows(host):
                return False, "not_allowed", "이 세션에서 아직 허용하지 않은 주소입니다. '허용 후 다시 시도'로 이 주소만 허용할 수 있습니다.", None
        else:
            if not (self.auto_allow_public and authenticated) and not self.policy.allows(host):
                return False, "not_allowed", "이 세션에서 아직 허용하지 않은 주소입니다. '허용 후 다시 시도'로 이 주소만 허용할 수 있습니다.", None
            if not _public(literal):
                return False, "private_address", "사설망·루프백·링크로컬 주소로는 연결하지 않습니다.", None
            family = socket.AF_INET6 if literal.version == 6 else socket.AF_INET
            return True, "", "", [(family, str(literal))]
        try:
            infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except OSError:
            return False, "dns_failed", "호스트 이름을 찾지 못했습니다.", None
        addrs = []
        for family, _t, _p, _c, sockaddr in infos:
            raw = str(sockaddr[0]).split("%", 1)[0]
            ip = _ip_literal(raw)
            if ip is None or not _public(ip):
                return False, "private_address", "이 호스트가 사설망·루프백·링크로컬 주소로 해석되어 연결하지 않습니다.", None
            if (family, raw) not in addrs:
                addrs.append((family, raw))
        if not addrs:
            return False, "dns_failed", "호스트 이름을 찾지 못했습니다.", None
        return True, "", "", addrs

    # -- plain http:// (absolute-form) -------------------------------------

    def _plain_reject(self, conn, host, port, code, reason, status=400, text="Bad Request", client=""):
        self.blocked(host or "?", port or 80, code, reason, client)
        self._reply(conn, status, text, close=True, body=reason.encode("utf-8"))

    def _plain_http(self, conn, head, buf, method, target, client):
        """Forwards one absolute-form http:// request as origin-form to its origin. Returns the upstream socket (the
        caller closes it) or None. Every refusal is a clear 4xx/5xx; nothing is forwarded before all checks pass."""
        if method not in PLAIN_METHODS:
            self._plain_reject(conn, self._host_of_absolute(target), 80, "plain_http",
                               "이 연결 도움 경로는 http:// GET/HEAD/POST 요청만 전달합니다.", 501, "Not Implemented", client)
            return None
        m = re.match(r"^http://([^/?#@]*)([/?][^#]*)?$", target, re.IGNORECASE)
        if not m or any(ord(c) <= 0x20 or ord(c) >= 0x7f for c in target):
            self._plain_reject(conn, "", 80, "bad_target", "http:// 주소 형식이 올바르지 않거나 계정 정보·조각이 들어 있습니다.",
                               client=client)
            return None
        authority, path = m.group(1), m.group(2) or "/"
        if path.startswith("?"):
            path = "/" + path
        host, port = self._split_authority(authority)
        if not host or port is None:
            self._plain_reject(conn, host, 80, "bad_target", "목적지 주소 형식이 올바르지 않습니다.", client=client)
            return None
        # Headers: strict line syntax, no folding, no bare CR/LF/NUL, exactly one Host that matches the target.
        try:
            lines = head.decode("latin-1").split("\r\n")[1:]
        except Exception:
            lines = None
        fwd, hosts, lengths, nominated = [], [], [], set()
        bad = lines is None
        for line in lines or ():
            k, sep, v = line.partition(":")
            if (not sep or not k or k != k.strip() or any(c in line for c in "\r\n\x00") or line[0] in " \t"
                    or not re.match(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", k)):
                bad = True
                break
            name, v = k.lower(), v.strip(" \t")
            if any((ord(c) < 0x20 and c != "\t") or ord(c) == 0x7f for c in v):
                bad = True
                break
            if name in ("transfer-encoding", "upgrade", "expect"):
                bad = True
                break
            if name == "connection":
                for tok in v.split(","):
                    tok = tok.strip(" \t").lower()
                    if not tok:
                        continue
                    # Nominating a header we synthesize ourselves (Host/Content-Length/framing) is contradictory.
                    if (not re.match(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", tok)
                            or tok in ("host", "content-length", "transfer-encoding")):
                        bad = True
                        break
                    nominated.add(tok)
                if bad:
                    break
            elif name == "host":
                hosts.append(v)
            elif name == "content-length":
                lengths.append(v)
            elif name not in _HOP_HEADERS:
                fwd.append((name, f"{k}: {v}"))
        fwd = [line for name, line in fwd if name not in nominated]
        length = 0
        if len(lengths) > 1 or (lengths and not re.match(r"^[0-9]{1,9}$", lengths[0])):
            bad = True
        elif lengths:
            length = int(lengths[0])
            if length > MAX_PLAIN_BODY:
                bad = True
        if bad or len(hosts) != 1:
            self._plain_reject(conn, host, port, "bad_request", "요청 헤더가 모호하거나 지원하지 않는 형식이라 전달하지 않았습니다.",
                               client=client)
            return None
        h_host, h_port = self._split_authority(hosts[0])
        if h_host != host or h_port != port:
            self._plain_reject(conn, host, port, "host_mismatch", "Host 헤더가 요청 주소와 달라 전달하지 않았습니다.", client=client)
            return None
        if len(buf) > length:
            self._plain_reject(conn, host, port, "bad_request", "연속(파이프라인) 요청은 전달하지 않습니다.", client=client)
            return None
        ok, code, reason, addrs = self._check_destination(host, port, authenticated=True)
        if not ok:
            self.blocked(host, port, code, reason, client)
            self._reply(conn, 403, "Forbidden", close=True, body=reason.encode("utf-8"))
            return None
        upstream = connect_staggered(addrs, port)
        if upstream is None:
            self.blocked(host, port, "connect_failed", "목적지 서버에 연결하지 못했습니다 (15초 안에 응답한 주소 없음).", client)
            self._reply(conn, 502, "Bad Gateway", close=True)
            return None
        try:
            upstream.settimeout(PLAIN_IO_TIMEOUT)
            conn.settimeout(PLAIN_IO_TIMEOUT)
            shown = authority if ("[" in authority or port != 80) else host
            out = [f"{method} {path} HTTP/1.1", f"Host: {shown}"] + fwd
            if lengths:
                out.append(f"Content-Length: {length}")
            out.append("Connection: close")
            upstream.sendall(("\r\n".join(out) + "\r\n\r\n").encode("latin-1") + buf)
            left = length - len(buf)
            while left > 0:
                chunk = conn.recv(min(65536, left))
                if not chunk:
                    return upstream
                upstream.sendall(chunk)
                left -= len(chunk)
            # Response head: forwarded with Connection: close so the browser never reuses this connection.
            data = b""
            while b"\r\n\r\n" not in data:
                if len(data) > MAX_HEADER:
                    self._reply(conn, 502, "Bad Gateway", close=True)
                    return upstream
                chunk = upstream.recv(65536)
                if not chunk:
                    if data:
                        self._reply(conn, 502, "Bad Gateway", close=True)
                    return upstream
                data += chunk
            rhead, body = data.split(b"\r\n\r\n", 1)
            if len(rhead) + 4 > MAX_HEADER:
                self._reply(conn, 502, "Bad Gateway", close=True)
                return upstream
            rlines = rhead.split(b"\r\n")
            keep = [rlines[0]] + [l for l in rlines[1:]
                                  if l.split(b":", 1)[0].strip().lower() not in (b"connection", b"proxy-connection", b"keep-alive")]
            keep.append(b"Connection: close")
            conn.sendall(b"\r\n".join(keep) + b"\r\n\r\n" + body)
            while True:
                chunk = upstream.recv(65536)
                if not chunk:
                    break
                conn.sendall(chunk)
        except OSError:
            pass
        return upstream

    @staticmethod
    def _split_authority(a):
        """(host, port) of `host[:port]` / `[v6][:port]` with the http default port 80; port None when invalid."""
        a = str(a or "").lower()
        if a.startswith("["):
            end = a.find("]")
            if end < 0:
                return "", None
            host, rest = a[1:end], a[end + 1:]
        else:
            host, sep, rest = a.partition(":")
            rest = sep + rest
        if rest == "":
            return host.rstrip("."), 80
        if not re.match(r"^:[0-9]{1,5}$", rest):
            return host, None
        return host.rstrip("."), int(rest[1:])

    # -- tunnel ------------------------------------------------------------

    def _tunnel(self, client, upstream, pending, host, tag="", split=None, port=0):
        owned = []   # the retry socket, if one is made; closed here on every exit path
        try:
            self._tunnel_inner(client, upstream, pending, host, tag, split, port, owned)
        finally:
            for s in owned:
                try:
                    s.close()
                except OSError:
                    pass

    def _tunnel_inner(self, client, upstream, pending, host, tag, split, port, owned):
        client.settimeout(IDLE_TIMEOUT)
        upstream.settimeout(IDLE_TIMEOUT)
        retry_hello = None
        retry_peer = None
        send_failed = False
        if self.split_tls if split is None else split:
            pending, why = read_first_record(client, pending)
            if not why:
                original = pending
                first, second, pending = split_record(pending, host)
                if (self.auto_retry_tls and tag == RETRY_CLIENT and port == 443 and not pending
                        and hello_allows_retry(original)):
                    try:
                        retry_peer = (upstream.family, upstream.getpeername())
                        retry_hello = original
                    except OSError:
                        retry_hello = None
                try:
                    upstream.sendall(first)
                    upstream.sendall(second)
                except OSError as e:
                    if retry_hello is None or not isinstance(
                            e, (ConnectionResetError, ConnectionAbortedError, BrokenPipeError)):
                        raise
                    send_failed = True   # a reset while sending is judged by the same silent-close probe below
            else:
                self.split_fallback(host, why, tag)
        replacement = None
        if retry_hello is not None:
            # Nothing else has been read from the client and nothing is sent upstream before this decision.
            if client_quiet(client) and probe_silent_close(upstream):
                replacement = reconnect_same_peer(*retry_peer)
                if replacement is not None and not client_quiet(client):
                    replacement.close()
                    replacement = None
                if replacement is not None:
                    try:
                        replacement.sendall(retry_hello)
                    except OSError:
                        replacement.close()
                        replacement = None
                    else:
                        owned.append(replacement)
                        try:
                            upstream.close()
                        except OSError:
                            pass
                        upstream = replacement
            if send_failed and replacement is None:
                raise BrokenPipeError(errno.EPIPE, "upstream closed while sending the ClientHello")
        if pending:
            upstream.sendall(pending)

        def pump(src, dst):
            try:
                while True:
                    data = src.recv(65536)
                    if not data:
                        break
                    dst.sendall(data)
            except OSError:
                pass
            finally:
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        t = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        t.start()
        pump(client, upstream)
        t.join(IDLE_TIMEOUT)


def run_proxy(emit, emit_error):
    """Entry for `engine.py proxy`. Returns the process exit status."""
    line = sys.stdin.readline()
    try:
        config = json.loads(line) if line.strip() else {}
    except ValueError:
        config = {}
    if not config.get("username") or not config.get("password"):
        emit_error("proxy_config", "연결 도움 설정을 받지 못했습니다.")
        return 1
    server = ProxyServer(emit, config)
    try:
        port = server.start()
    except OSError:
        emit_error("proxy_bind", "연결 도움용 로컬 포트를 열지 못했습니다.")
        return 1
    emit("proxyReady", {"port": int(port), "splitTLS": server.split_tls, "autoAllowPublic": server.auto_allow_public})

    # Policy updates until the app closes the pipe.
    for raw in sys.stdin:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(msg, dict):
            continue
        op = msg.get("op")
        if op == "allow":
            server.policy.update(msg.get("domains") or (), msg.get("hosts") or ())
            # Acknowledge only after the update is in force; the app waits for this before connecting.
            if isinstance(msg.get("id"), int) and not isinstance(msg.get("id"), bool):
                emit("policyApplied", {"id": msg["id"]})
        elif op == "config":
            if isinstance(msg.get("autoRetryTLS"), bool):
                server.auto_retry_tls = msg["autoRetryTLS"]
        elif op == "stop":
            break
    server.stop()
    return 0
