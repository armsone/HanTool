"""
HttpsDown app-owned login session → yt-dlp cookie jar (in memory only).

The app sends, inside the stdin request, only cookies of the app's own WKWebView session that belong to the site the
user explicitly bound to the job (the job address or the login page it came from):
  {"site": "example.com", "userAgent": str, "cookies": [{name, value, domain, hostOnly, path, secure, expires,
                                                        httpOnly}]}
Every cookie is re-checked here. Nothing is written to disk, nothing becomes a global Cookie/Authorization header,
and cookie values never appear in events or errors.

Scope rules carried into http.cookiejar:
  * host-only cookies → domain_specified=False + DomainStrictNonDomain policy: sent to that exact host only
  * domain cookies     → leading-dot domain, sent to the domain and its subdomains (RFC 6265 domain match)
  * path, Secure (https only) and expiry are enforced by DefaultCookiePolicy on every request yt-dlp makes
"""

import http.cookiejar
import re
import time
from urllib.parse import urlsplit

_TOKEN_RE = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,256}$")
_BAD_VALUE = re.compile(r"[\x00-\x1f\x7f;]")
MAX_COOKIES = 300


def _within(host, site):
    return host == site or host.endswith("." + site)


def bound_ok(url, site):
    host = (urlsplit(url).hostname or "").lower().rstrip(".")
    site = str(site or "").lower().strip(".")
    return bool(host and site and "." in site and _within(host, site))


def build_cookies(session, url):
    """Returns (cookies, rejected_count) or raises ValueError with a safe Korean message."""
    site = str(session.get("site") or "").lower().strip(".")
    if not bound_ok(url, site):
        raise ValueError("로그인 세션이 이 주소의 사이트와 맞지 않아 사용하지 않았습니다.")
    now = time.time()
    out, rejected = [], 0
    for raw in (session.get("cookies") or [])[:MAX_COOKIES]:
        try:
            name = str(raw.get("name") or "")
            value = str(raw.get("value") or "")
            domain = str(raw.get("domain") or "").lower()
            host_only = bool(raw.get("hostOnly"))
            path = str(raw.get("path") or "/")
            secure = bool(raw.get("secure"))
            expires = raw.get("expires")
            expires = int(float(expires)) if expires not in (None, "") else None
        except (TypeError, ValueError):
            rejected += 1
            continue
        bare = domain.lstrip(".")
        if (not _TOKEN_RE.match(name) or _BAD_VALUE.search(value) or len(value) > 8192 or not bare
                or not _within(bare, site) or not path.startswith("/") or _BAD_VALUE.search(path)
                or (expires is not None and expires <= now)):
            rejected += 1
            continue
        if host_only:
            cookie_domain, specified, initial_dot = bare, False, False
        else:
            cookie_domain, specified, initial_dot = "." + bare, True, True
        rest = {"HttpOnly": None} if raw.get("httpOnly") else {}
        out.append(http.cookiejar.Cookie(
            version=0, name=name, value=value, port=None, port_specified=False,
            domain=cookie_domain, domain_specified=specified, domain_initial_dot=initial_dot,
            path=path, path_specified=True, secure=secure, expires=expires, discard=expires is None,
            comment=None, comment_url=None, rest=rest, rfc2109=False))
    return out, rejected


def install(ydl, session, url):
    """Loads the scoped cookies into this YoutubeDL instance's in-memory jar. Returns (accepted, rejected)."""
    cookies, rejected = build_cookies(session, url)
    jar = ydl.cookiejar
    jar.set_policy(http.cookiejar.DefaultCookiePolicy(
        strict_ns_domain=http.cookiejar.DefaultCookiePolicy.DomainStrictNonDomain))
    for c in cookies:
        jar.set_cookie(c)
    return len(cookies), rejected
