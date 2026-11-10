#!/usr/bin/env python3
"""Standalone stdlib HTML evidence URL inventory collector.

Extracts public website links from a captured HTML file (or a single bounded
4 MiB / 15s HTTPS GET with public-DNS pinning), canonicalizes and deduplicates
URLs without executing JavaScript or probing outgoing destinations, and writes
neutral technical inventory artifacts (inventory.json, inventory.csv,
inventory.html).
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import html
import http.client
import ipaddress
import json
import os
import posixpath
import re
import signal
import socket
import ssl
import stat
import sys
import time
import urllib.parse
import zipfile
from html.parser import HTMLParser
from typing import Any, Dict, List, Optional, Set, Tuple

COLLECTOR_VERSION = "0.1.0"
DIAGNOSTICS_SCHEMA_VERSION = "1.0"
DIAGNOSTICS_MAX_FILE_BYTES = 102400  # 100 KiB strict ceiling
DIAGNOSTICS_MAX_RECORDS = 32
DIAGNOSTICS_REL_DIR = os.path.join("Library", "Logs", "HTDCollector")
DIAGNOSTICS_FILENAME = "diagnostics.json"

DIAGNOSTIC_RECORD_WHITELIST: Tuple[str, ...] = (
    "schema_version",
    "collector_version",
    "timestamp_utc",
    "mode",
    "stage",
    "result",
    "error_category",
    "http_status",
    "hostname",
    "python_version",
    "openssl_version",
)
DIAGNOSTIC_MODES: Set[str] = {"offline_capture", "live_fetch", "diagnostics"}
DIAGNOSTIC_STAGES: Set[str] = {
    "arguments",
    "capture_load",
    "fetch",
    "parse",
    "write",
    "export",
    "complete",
}
DIAGNOSTIC_RESULTS: Set[str] = {"success", "failure"}
DIAGNOSTIC_ERROR_CATEGORIES: Set[str] = {
    "input",
    "deadline",
    "dns",
    "tls",
    "http",
    "io",
    "unexpected",
}

MAX_CAPTURE_BYTES = 4194304  # 4 MiB strict ceiling
LEGACY_OFFLINE_CAPTURE_BYTES = 1048576  # 1 MiB original capture fallback limit
FETCH_WALL_TIMEOUT_SECONDS = 15

MESSENGER_DOMAINS: Tuple[str, ...] = (
    "t.me",
    "telegram.me",
    "telegram.org",
    "wa.me",
    "whatsapp.com",
    "line.me",
    "kakao.com",
    "open.kakao.com",
    "pf.kakao.com",
    "discord.gg",
    "discord.com",
    "signal.me",
)

IGNORED_TAGS: Set[str] = {
    "img",
    "script",
    "link",
    "style",
    "svg",
    "path",
    "circle",
    "source",
    "video",
    "audio",
    "iframe",
    "frame",
    "embed",
    "object",
    "canvas",
    "noscript",
    "meta",
    "base",
}

ASSET_EXTENSIONS: Tuple[str, ...] = (
    ".webp",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".svg",
    ".ico",
    ".bmp",
    ".avif",
    ".css",
    ".js",
    ".mjs",
    ".map",
    ".woff",
    ".woff2",
    ".ttf",
    ".eot",
    ".otf",
    ".mp4",
    ".webm",
    ".m3u8",
    ".ts",
    ".mp3",
    ".wav",
    ".ogg",
    ".pdf",
    ".zip",
    ".rar",
    ".7z",
)

ASSET_PATH_PREFIXES: Tuple[str, ...] = (
    "/uploads/",
    "/images/",
    "/css/",
    "/js/",
    "/assets/",
    "/static/",
    "/favicon",
    "/apple-touch-icon",
    "/manifest.php",
)

REDIRECT_PATH_MARKERS: Set[str] = {
    "/out",
    "/go",
    "/redirect",
    "/jump",
    "/exit",
    "/link",
    "/out.php",
    "/go.php",
    "/redirect.php",
}

REDIRECT_QUERY_KEYS: Set[str] = {
    "url",
    "u",
    "target",
    "dest",
    "destination",
    "redirect",
    "redirect_uri",
    " redirect_url",
    "to",
    "out",
    "goto",
}

# Conservative safeguard patterns: ONLY plain, explicit child sexual exploitation
# or explicit nonconsensual/coerced filming labels trigger quarantine.
# Generic adult terms (야동, 성인, AV, 오피, 19, 망가, 애니, etc.) do NOT match.
EXPLICIT_SAFEGUARD_PATTERNS: Tuple[Tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(
            r"(아동\s*(?:성착취|포르노|야동)|유아\s*(?:성착취|포르노|야동)|"
            r"미성년자\s*성착취|초등\s*야동|중딩\s*야동|"
            r"\b(?:csam|child\s*porn(?:ography)?|pedophil(?:e|ia)|cp\s*site)\b)",
            re.IGNORECASE,
        ),
        "explicit_cse_label_match",
    ),
    (
        re.compile(
            r"(불법\s*촬영|몰카\s*(?:야동|사이트|전문)|도촬\s*(?:야동|사이트|전문)|"
            r"리벤지\s*포르노|강간\s*(?:야동|영상)|성착취물|"
            r"\b(?:nonconsensual\s*filming|revenge\s*porn)\b)",
            re.IGNORECASE,
        ),
        "explicit_nonconsensual_filming_label_match",
    ),
)


class FetchDeadlineExceeded(Exception):
    """Raised when the wall-clock deadline for --fetch is exceeded."""


def sanitize_url_for_error(raw_url: str) -> str:
    """Return a safe representation of a URL without userinfo, query, or fragment."""
    if not raw_url:
        return "<empty>"
    cleaned = "".join(ch if 32 <= ord(ch) < 127 else "?" for ch in raw_url.strip())
    try:
        sp = urllib.parse.urlsplit(cleaned)
        host = sp.hostname or ""
        scheme = sp.scheme.lower() if sp.scheme else ""
        if scheme and host:
            return f"{scheme}://{host}{sp.path or '/'}"
    except Exception:
        pass
    return "<redacted-url>"


def has_control_chars(value: str) -> bool:
    """Return True if value contains ASCII control characters."""
    return any(ord(ch) < 32 or ord(ch) == 127 for ch in value)


def normalize_idna_host(hostname: str) -> Optional[str]:
    """Normalize hostname to lowercase ASCII IDNA and validate syntax."""
    if not hostname:
        return None
    raw_host = hostname.strip().rstrip(".")
    if not raw_host or has_control_chars(raw_host):
        return None
    # Handle IPv6 literal if bracketed or raw
    try:
        ip_obj = ipaddress.ip_address(raw_host)
        if not ip_obj.is_global:
            return None
        if ip_obj.version == 6:
            return f"[{ip_obj.compressed.lower()}]"
        return ip_obj.compressed
    except ValueError:
        pass

    try:
        ascii_host = raw_host.encode("idna").decode("ascii").lower()
    except UnicodeError:
        return None

    if not ascii_host or "." not in ascii_host:
        return None
    if ascii_host in {"localhost", "broadcasthost"}:
        return None
    if ascii_host.endswith((".local", ".localhost", ".internal", ".arpa", ".lan", ".home")):
        return None
    # Verify allowed DNS characters
    if not re.fullmatch(r"[a-z0-9.-]+", ascii_host):
        return None
    if ".." in ascii_host or ascii_host.startswith("-") or ascii_host.endswith("-"):
        return None
    return ascii_host


def is_messenger_host(host: str) -> bool:
    """Return True if host belongs to a known messenger service."""
    h = host.lower().strip("[]")
    for domain in MESSENGER_DOMAINS:
        if h == domain or h.endswith("." + domain):
            return True
    return False


def is_same_origin_host(host: str, source_host: str) -> bool:
    """Return True if host is the source host or its www/subdomain equivalent."""
    h = host.lower()
    sh = source_host.lower()
    if h.startswith("www."):
        h = h[4:]
    if sh.startswith("www."):
        sh = sh[4:]
    return h == sh or h.endswith("." + sh)


def is_asset_or_gallery_url(host: str, path: str, source_host: str) -> bool:
    """Return True if URL points to a static/media/screenshot asset."""
    lower_host = host.lower()
    lower_path = (path or "/").lower()
    if "fenhub.org" in lower_host and ("/uploads/" in lower_path or lower_path.endswith(ASSET_EXTENSIONS)):
        return True
    if lower_path.endswith(ASSET_EXTENSIONS):
        return True
    if is_same_origin_host(lower_host, source_host):
        for prefix in ASSET_PATH_PREFIXES:
            if lower_path.startswith(prefix):
                return True
    return False


def normalize_url_path(path: str) -> str:
    """Normalize URL path while preserving trailing slash semantics."""
    if not path:
        return "/"
    had_trailing = path.endswith("/")
    normed = posixpath.normpath(path)
    if not normed.startswith("/"):
        normed = "/" + normed
    if had_trailing and not normed.endswith("/"):
        normed += "/"
    # Collapse leading double slashes
    while normed.startswith("//"):
        normed = normed[1:]
    return normed


def canonicalize_and_sanitize_url(
    raw_attr_value: str,
    source_url: str,
    source_host: str,
) -> Optional[Dict[str, Any]]:
    """Validate, resolve, sanitize, and canonicalize an extracted attribute URL.

    Returns None if the URL is non-http(s), malformed, contains userinfo, uses a
    non-standard port, targets a non-public literal IP or local hostname, or is a
    media/static asset.
    """
    if raw_attr_value is None:
        return None
    stripped = raw_attr_value.strip()
    if not stripped or has_control_chars(stripped):
        return None

    lower_head = stripped[:20].lower()
    if lower_head.startswith(("#", "javascript:", "data:", "vbscript:", "mailto:", "tel:", "blob:", "about:")):
        return None

    # Resolve relative URL against original source_url (ignoring HTML <base>)
    try:
        resolved = urllib.parse.urljoin(source_url, stripped)
        sp = urllib.parse.urlsplit(resolved)
    except Exception:
        return None

    scheme = (sp.scheme or "").lower()
    if scheme not in ("http", "https"):
        return None

    # Reject userinfo in netloc
    if sp.username is not None or sp.password is not None or "@" in (sp.netloc or ""):
        return None

    try:
        port = sp.port
    except ValueError:
        return None

    # Enforce default ports only (80 for http, 443 for https)
    if scheme == "http" and port not in (None, 80):
        return None
    if scheme == "https" and port not in (None, 443):
        return None

    norm_host = normalize_idna_host(sp.hostname or "")
    if not norm_host:
        return None

    norm_path = normalize_url_path(sp.path or "/")

    if is_asset_or_gallery_url(norm_host, norm_path, source_host):
        return None

    # Extract query parameter names only; strip all query values and fragments
    query_keys: List[str] = []
    if sp.query:
        try:
            parsed_q = urllib.parse.parse_qsl(sp.query, keep_blank_values=True)
            for k, _ in parsed_q:
                clean_k = re.sub(r"[^A-Za-z0-9_.-]", "", k)[:64]
                if clean_k and clean_k not in query_keys:
                    query_keys.append(clean_k)
        except Exception:
            pass

    destination_origin = f"{scheme}://{norm_host}/"
    canonical_url = f"{scheme}://{norm_host}{norm_path}"

    # Sanitized original attribute URL: preserves whether it was relative or absolute,
    # strips fragment and strips all query values (leaving only key= with empty value).
    redacted_query_str = "&".join(f"{k}=" for k in query_keys)
    raw_sp = urllib.parse.urlsplit(stripped)
    if raw_sp.scheme and raw_sp.netloc:
        sanitized_attr_url = canonical_url
    else:
        sanitized_attr_url = norm_path
    if redacted_query_str:
        sanitized_attr_url = f"{sanitized_attr_url}?{redacted_query_str}"

    is_same_origin = is_same_origin_host(norm_host, source_host)
    is_redirect_wrapper = False
    if is_same_origin:
        if norm_path.lower() in REDIRECT_PATH_MARKERS or any(
            k.lower() in REDIRECT_QUERY_KEYS for k in query_keys
        ):
            is_redirect_wrapper = True

    return {
        "scheme": scheme,
        "host": norm_host,
        "path": norm_path,
        "canonical_url": canonical_url,
        "destination_origin": destination_origin,
        "sanitized_attr_url": sanitized_attr_url,
        "query_keys": query_keys,
        "is_same_origin": is_same_origin,
        "is_redirect_wrapper": is_redirect_wrapper,
    }


def check_safeguard_label(text: str) -> Optional[str]:
    """Return neutral quarantine reason if text explicitly labels CSE or nonconsensual filming."""
    if not text:
        return None
    compact = " ".join(text.split())
    for pattern, reason in EXPLICIT_SAFEGUARD_PATTERNS:
        if pattern.search(compact):
            return reason
    return None


class InventoryHTMLParser(HTMLParser):
    """Stdlib HTMLParser extracting only public data-site-url and a[href] attributes."""

    def __init__(self, source_url: str, source_host: str) -> None:
        super().__init__(convert_charrefs=True)
        self.source_url = source_url
        self.source_host = source_host

        self.raw_candidate_attrs_seen = 0
        self.excluded_or_invalid_attrs_count = 0

        # Track context for site_id, ad containers, and anchor text safeguard check
        self._li_site_id_stack: List[Optional[str]] = []
        self._ad_container_depth = 0
        self._active_anchor: Optional[Dict[str, Any]] = None
        self._anchor_text_parts: List[str] = []

        # Raw extracted records before deduplication
        self.records: List[Dict[str, Any]] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        tag_l = tag.lower()
        attr_map: Dict[str, str] = {}
        for k, v in attrs:
            if k:
                attr_map[k.lower()] = v if v is not None else ""

        # Track <li data-favorite-site-id="...">
        if tag_l == "li":
            site_id = attr_map.get("data-favorite-site-id") or attr_map.get("data-site-id")
            self._li_site_id_stack.append(site_id.strip() if site_id else None)

        # Track ad containers (<aside class="mini-ad-strip">, etc.)
        cls_tokens = set(attr_map.get("class", "").lower().split())
        is_ad_container = bool(
            cls_tokens.intersection({"mini-ad-strip", "mini-ad-track", "mini-ad-slot", "ad-strip", "ad-banner", "ad-slot"})
        )
        if tag_l == "aside" and is_ad_container:
            self._ad_container_depth += 1

        if tag_l in IGNORED_TAGS:
            return

        current_site_id = (
            attr_map.get("data-site-id")
            or attr_map.get("data-favorite-site-id")
            or (self._li_site_id_stack[-1] if self._li_site_id_stack else None)
        )
        if current_site_id:
            current_site_id = re.sub(r"[^A-Za-z0-9_-]", "", current_site_id)[:32] or None

        site_name_label = attr_map.get("data-site-name", "")

        # 1. Check data-site-url / site-url attributes
        for data_attr_name in ("data-site-url", "site-url"):
            if data_attr_name in attr_map:
                raw_val = attr_map[data_attr_name]
                self.raw_candidate_attrs_seen += 1
                raw_sha256 = hashlib.sha256(
                    raw_val.encode("utf-8", errors="surrogateescape")
                ).hexdigest()
                parsed = canonicalize_and_sanitize_url(raw_val, self.source_url, self.source_host)
                if parsed is None:
                    self.excluded_or_invalid_attrs_count += 1
                else:
                    safeguard_reason = check_safeguard_label(site_name_label)
                    self.records.append(
                        {
                            "source_tag": tag_l,
                            "source_attr": data_attr_name,
                            "raw_attr_sha256": raw_sha256,
                            "site_id": current_site_id,
                            "rel_tokens": [],
                            "ad_marker": False,
                            "safeguard_reason": safeguard_reason,
                            "parsed": parsed,
                        }
                    )

        # 2. Check <a href="...">
        if tag_l == "a" and "href" in attr_map:
            raw_href = attr_map["href"]
            self.raw_candidate_attrs_seen += 1
            raw_sha256 = hashlib.sha256(
                raw_href.encode("utf-8", errors="surrogateescape")
            ).hexdigest()
            parsed = canonicalize_and_sanitize_url(raw_href, self.source_url, self.source_host)
            if parsed is None:
                self.excluded_or_invalid_attrs_count += 1
                self._active_anchor = None
                self._anchor_text_parts = []
            else:
                rel_raw = attr_map.get("rel", "").lower().split()
                rel_tokens = sorted(set(rel_raw))
                has_ad_marker = (
                    "sponsored" in rel_tokens
                    or is_ad_container
                    or self._ad_container_depth > 0
                )
                initial_safeguard = check_safeguard_label(site_name_label)
                rec = {
                    "source_tag": "a",
                    "source_attr": "href",
                    "raw_attr_sha256": raw_sha256,
                    "site_id": current_site_id,
                    "rel_tokens": rel_tokens,
                    "ad_marker": has_ad_marker,
                    "safeguard_reason": initial_safeguard,
                    "parsed": parsed,
                }
                self.records.append(rec)
                self._active_anchor = rec
                self._anchor_text_parts = []

    def handle_data(self, data: str) -> None:
        if self._active_anchor is not None and data:
            self._anchor_text_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        tag_l = tag.lower()
        if tag_l == "a" and self._active_anchor is not None:
            anchor_text = " ".join(self._anchor_text_parts)
            reason = check_safeguard_label(anchor_text)
            if reason and not self._active_anchor.get("safeguard_reason"):
                self._active_anchor["safeguard_reason"] = reason
            self._active_anchor = None
            self._anchor_text_parts = []
        elif tag_l == "li" and self._li_site_id_stack:
            self._li_site_id_stack.pop()
        elif tag_l in ("aside", "div", "section") and self._ad_container_depth > 0:
            # Conservatively decrement only on aside or when depth > 0
            if tag_l == "aside":
                self._ad_container_depth = 0


def build_inventory_from_records(
    parser: InventoryHTMLParser,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]], Dict[str, Any]]:
    """Deduplicate extracted records by canonical_url and classify into neutral categories."""
    grouped: Dict[str, Dict[str, Any]] = {}
    order: List[str] = []

    for rec in parser.records:
        parsed = rec["parsed"]
        c_url = parsed["canonical_url"]
        if c_url not in grouped:
            order.append(c_url)
            grouped[c_url] = {
                "canonical_url": c_url,
                "destination_origin": parsed["destination_origin"],
                "scheme": parsed["scheme"],
                "host": parsed["host"],
                "is_same_origin": parsed["is_same_origin"],
                "is_redirect_wrapper": parsed["is_redirect_wrapper"],
                "from_data_site_url": False,
                "from_a_href": False,
                "site_ids": [],
                "redacted_query_keys": [],
                "has_ad_technical_marker": False,
                "occurrence_count": 0,
                "safeguard_reasons": [],
                "provenance": [],
                "_prov_seen": set(),
            }

        item = grouped[c_url]
        item["occurrence_count"] += 1
        if parsed["is_redirect_wrapper"]:
            item["is_redirect_wrapper"] = True
        for qk in parsed["query_keys"]:
            if qk not in item["redacted_query_keys"]:
                item["redacted_query_keys"].append(qk)

        if rec["source_attr"] in ("data-site-url", "site-url"):
            item["from_data_site_url"] = True
        if rec["source_tag"] == "a" and rec["source_attr"] == "href":
            item["from_a_href"] = True

        if rec["site_id"] and rec["site_id"] not in item["site_ids"]:
            item["site_ids"].append(rec["site_id"])

        if rec["ad_marker"]:
            item["has_ad_technical_marker"] = True

        if rec["safeguard_reason"] and rec["safeguard_reason"] not in item["safeguard_reasons"]:
            item["safeguard_reasons"].append(rec["safeguard_reason"])

        prov_key = (
            rec["source_tag"],
            rec["source_attr"],
            parsed["sanitized_attr_url"],
            rec["raw_attr_sha256"],
            rec["site_id"] or "",
            ",".join(rec["rel_tokens"]),
            rec["ad_marker"],
        )
        if prov_key not in item["_prov_seen"]:
            item["_prov_seen"].add(prov_key)
            item["provenance"].append(
                {
                    "source_tag": rec["source_tag"],
                    "source_attr": rec["source_attr"],
                    "sanitized_attr_url": parsed["sanitized_attr_url"],
                    "raw_attr_sha256": rec["raw_attr_sha256"],
                    "site_id": rec["site_id"],
                    "rel": " ".join(rec["rel_tokens"]) if rec["rel_tokens"] else None,
                    "ad_marker": rec["ad_marker"],
                }
            )

    entries: List[Dict[str, Any]] = []
    quarantined: List[Dict[str, Any]] = []
    category_counts: Dict[str, int] = {
        "registered_site": 0,
        "source_internal": 0,
        "messenger": 0,
        "advertisement": 0,
        "other": 0,
    }
    primary_data_site_count = 0
    a_href_only_count = 0

    for c_url in order:
        item = grouped[c_url]
        del item["_prov_seen"]

        # Classification rule:
        # 1. same-origin -> source_internal
        # 2. messenger domain -> messenger
        # 3. data-site-url -> registered_site
        # 4. technical ad marker (rel=sponsored / ad container) -> advertisement
        # 5. otherwise -> other
        if item["is_same_origin"]:
            category = "source_internal"
        elif is_messenger_host(item["host"]):
            category = "messenger"
        elif item["from_data_site_url"]:
            category = "registered_site"
        elif item["has_ad_technical_marker"]:
            category = "advertisement"
        else:
            category = "other"

        # Safeguard quarantine check
        if item["safeguard_reasons"]:
            c_sha = hashlib.sha256(c_url.encode("utf-8")).hexdigest()
            first_raw_sha = (
                item["provenance"][0]["raw_attr_sha256"] if item["provenance"] else c_sha
            )
            quarantined.append(
                {
                    "canonical_url_sha256": c_sha,
                    "first_raw_attr_sha256": first_raw_sha,
                    "category": category,
                    "site_ids": item["site_ids"],
                    "occurrence_count": item["occurrence_count"],
                    "safeguard_status": "quarantined_blocked",
                    "quarantine_reason": item["safeguard_reasons"][0],
                    "clickable": False,
                    "runnable": False,
                }
            )
            continue

        category_counts[category] = category_counts.get(category, 0) + 1
        if item["from_data_site_url"]:
            primary_data_site_count += 1
        else:
            a_href_only_count += 1

        entries.append(
            {
                "canonical_url": item["canonical_url"],
                "destination_origin": item["destination_origin"],
                "scheme": item["scheme"],
                "host": item["host"],
                "category": category,
                "from_data_site_url": item["from_data_site_url"],
                "from_a_href": item["from_a_href"],
                "site_ids": item["site_ids"],
                "occurrence_count": item["occurrence_count"],
                "has_ad_technical_marker": item["has_ad_technical_marker"],
                "is_redirect_wrapper": item["is_redirect_wrapper"],
                "redacted_query_keys": item["redacted_query_keys"],
                "destination_status": "untested",
                "dns_status": "untested",
                "download_support_status": "untested",
                "safeguard_status": "pending_review",
                "provenance": item["provenance"],
            }
        )

    counts = {
        "total_canonical_urls": len(entries),
        "primary_data_site_url_entries": primary_data_site_count,
        "a_href_only_entries": a_href_only_count,
        "by_category": category_counts,
        "quarantined_blocked_count": len(quarantined),
        "raw_candidate_attrs_seen": parser.raw_candidate_attrs_seen,
        "excluded_or_invalid_attrs_count": parser.excluded_or_invalid_attrs_count,
    }
    return entries, quarantined, counts


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    """HTTPSConnection that connects to a pre-resolved global IP while verifying original TLS hostname."""

    def __init__(
        self,
        original_host: str,
        pinned_ip: str,
        port: int,
        timeout: float,
        ssl_context: ssl.SSLContext,
    ) -> None:
        super().__init__(host=original_host, port=port, timeout=timeout, context=ssl_context)
        self._original_host = original_host
        self._pinned_ip = pinned_ip

    def connect(self) -> None:
        raw_sock = socket.create_connection((self._pinned_ip, self.port), self.timeout)
        if self._tunnel_host:
            raise RuntimeError("Proxy tunneling is prohibited")
        self.sock = self._context.wrap_socket(raw_sock, server_hostname=self._original_host)


def validate_and_resolve_fetch_target(fetch_url: str, timeout: float) -> Tuple[str, str, int, str, str]:
    """Validate fetch URL and resolve public DNS, rejecting any non-global IPs."""
    if not fetch_url or has_control_chars(fetch_url):
        raise ValueError("Rejected fetch URL: empty or contains control characters")

    sp = urllib.parse.urlsplit(fetch_url.strip())
    scheme = (sp.scheme or "").lower()
    if scheme not in ("http", "https"):
        raise ValueError("Rejected fetch URL: scheme must be http or https")
    if scheme != "https":
        raise ValueError("Rejected fetch URL: --fetch requires bounded HTTPS GET")

    if sp.username is not None or sp.password is not None or "@" in (sp.netloc or ""):
        raise ValueError("Rejected fetch URL: userinfo is prohibited")

    try:
        port = sp.port or 443
    except ValueError as exc:
        raise ValueError("Rejected fetch URL: invalid port") from exc

    if port not in (80, 443) or port != 443:
        raise ValueError("Rejected fetch URL: non-443 port is prohibited for HTTPS fetch")

    raw_host = sp.hostname or ""
    # Reject literal local/private IPs and normalize IDNA
    try:
        lit_ip = ipaddress.ip_address(raw_host.strip("[]"))
        if not lit_ip.is_global:
            raise ValueError("Rejected fetch URL: non-global literal IP")
    except ValueError as exc:
        if "non-global" in str(exc):
            raise

    ascii_host = normalize_idna_host(raw_host)
    if not ascii_host or ascii_host.startswith("["):
        raise ValueError("Rejected fetch URL: invalid or literal IP hostname")

    path = normalize_url_path(sp.path or "/")
    canonical_source_url = f"https://{ascii_host}{path}"

    # Resolve DNS and verify EVERY returned address is global
    addr_infos = socket.getaddrinfo(ascii_host, port, type=socket.SOCK_STREAM)
    if not addr_infos:
        raise RuntimeError("DNS resolution returned no addresses")

    verified_ips: List[str] = []
    for family, _, _, _, sockaddr in addr_infos:
        if family not in (socket.AF_INET, socket.AF_INET6):
            continue
        ip_str = sockaddr[0]
        # Strip IPv6 scope ID if present
        if "%" in ip_str:
            raise ValueError("Rejected fetch DNS result: scoped IPv6 address is non-global")
        ip_obj = ipaddress.ip_address(ip_str)
        if (
            not ip_obj.is_global
            or ip_obj.is_private
            or ip_obj.is_loopback
            or ip_obj.is_link_local
            or ip_obj.is_multicast
            or ip_obj.is_reserved
            or ip_obj.is_unspecified
        ):
            raise ValueError("Rejected fetch DNS result: non-global IP address resolved")
        if ip_obj.compressed not in verified_ips:
            verified_ips.append(ip_obj.compressed)

    if not verified_ips:
        raise ValueError("Rejected fetch DNS result: no global IP addresses available")

    return canonical_source_url, ascii_host, port, path, verified_ips[0]


def format_byte_limit_label(byte_limit: int) -> str:
    """Return a concise human-readable byte limit label (e.g. '4 MiB' or '1 MiB')."""
    if byte_limit > 0 and byte_limit % (1024 * 1024) == 0:
        return f"{byte_limit // (1024 * 1024)} MiB"
    return f"{byte_limit:,} bytes"


def perform_bounded_fetch(fetch_url: str) -> Tuple[bytes, Dict[str, Any]]:
    """Perform exactly one bounded HTTPS GET (<=4 MiB, <=15s wall clock, pinned public IP, no redirects)."""
    start_mono = time.monotonic()
    deadline = start_mono + FETCH_WALL_TIMEOUT_SECONDS
    collected_utc = dt.datetime.now(dt.timezone.utc).isoformat()

    def _alarm_handler(signum: int, frame: Any) -> None:
        raise FetchDeadlineExceeded("15-second wall-clock deadline exceeded")

    old_handler = None
    has_sigalrm = hasattr(signal, "SIGALRM")
    if has_sigalrm:
        old_handler = signal.signal(signal.SIGALRM, _alarm_handler)
        signal.setitimer(signal.ITIMER_REAL, float(FETCH_WALL_TIMEOUT_SECONDS))

    errors: List[str] = []
    buf = bytearray()
    truncated = False
    http_status: Optional[int] = None
    content_type = ""
    canonical_source_url = sanitize_url_for_error(fetch_url)

    try:
        remaining = max(0.5, deadline - time.monotonic())
        canonical_source_url, ascii_host, port, path, pinned_ip = validate_and_resolve_fetch_target(
            fetch_url, remaining
        )

        remaining = max(0.5, deadline - time.monotonic())
        ssl_ctx = ssl.create_default_context()
        ssl_ctx.check_hostname = True
        ssl_ctx.verify_mode = ssl.CERT_REQUIRED

        conn = PinnedHTTPSConnection(
            original_host=ascii_host,
            pinned_ip=pinned_ip,
            port=port,
            timeout=remaining,
            ssl_context=ssl_ctx,
        )
        try:
            conn.request(
                "GET",
                path,
                headers={
                    "Host": ascii_host,
                    "User-Agent": "HTD-EvidenceCollector/1.0",
                    "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
                    "Accept-Encoding": "identity",
                    "Connection": "close",
                },
            )
            resp = conn.getresponse()
            http_status = resp.status
            raw_ct = resp.getheader("Content-Type") or ""
            content_type = "".join(ch for ch in raw_ct if 32 <= ord(ch) < 127)[:128]

            if 300 <= http_status < 400:
                errors.append(f"redirect_status_{http_status}_not_followed_uncollected")
            elif http_status != 200:
                errors.append(f"non_200_http_status_{http_status}")
            elif "html" not in content_type.lower():
                errors.append("non_html_content_type_rejected")
            else:
                while True:
                    if time.monotonic() >= deadline:
                        truncated = True
                        errors.append("wall_deadline_reached_partial_buffer")
                        break
                    need = (MAX_CAPTURE_BYTES + 1) - len(buf)
                    if need <= 0:
                        truncated = True
                        errors.append(f"max_{MAX_CAPTURE_BYTES}_bytes_cap_reached_truncated")
                        break
                    chunk = resp.read(min(16384, need))
                    if not chunk:
                        break
                    buf.extend(chunk)
                    if len(buf) > MAX_CAPTURE_BYTES:
                        del buf[MAX_CAPTURE_BYTES:]
                        truncated = True
                        errors.append(f"max_{MAX_CAPTURE_BYTES}_bytes_cap_reached_truncated")
                        break
        finally:
            try:
                conn.close()
            except Exception:
                pass
    except FetchDeadlineExceeded:
        truncated = True
        errors.append("wall_deadline_15s_exceeded")
    except Exception as exc:
        err_type = type(exc).__name__
        errors.append(f"fetch_error_{err_type}")
    finally:
        if has_sigalrm:
            signal.setitimer(signal.ITIMER_REAL, 0.0)
            if old_handler is not None:
                signal.signal(signal.SIGALRM, old_handler)

    captured_bytes = bytes(buf[:MAX_CAPTURE_BYTES])
    digest = hashlib.sha256(captured_bytes).hexdigest()
    is_partial = bool(truncated or errors or http_status != 200)

    meta = {
        "source_url": canonical_source_url,
        "collected_at_utc": collected_utc,
        "mode": "live_fetch",
        "http_status": http_status,
        "content_type": content_type,
        "bytes_captured": len(captured_bytes),
        "max_bytes_limit": MAX_CAPTURE_BYTES,
        "bytes_hashed_scope": (
            f"captured_prefix_{len(captured_bytes)}_bytes"
            if is_partial
            else f"full_response_{len(captured_bytes)}_bytes"
        ),
        "captured_prefix_sha256": digest,
        "full_response_sha256": None if is_partial else digest,
        "curl_exit": None,
        "partial": is_partial,
        "truncated": truncated,
        "errors": errors,
    }
    return captured_bytes, meta


def load_and_verify_offline_capture(
    input_html_path: str,
    capture_json_path: str,
) -> Tuple[bytes, Dict[str, Any]]:
    """Load offline captured HTML and verify exact byte count and SHA256 against capture.json."""
    with open(capture_json_path, "r", encoding="utf-8") as f:
        cap = json.load(f)

    raw_byte_limit = cap.get("byte_limit")
    if raw_byte_limit is not None:
        try:
            recorded_limit = int(raw_byte_limit)
        except (TypeError, ValueError) as exc:
            raise ValueError("Offline capture byte_limit must be an integer") from exc
        if recorded_limit <= 0 or recorded_limit > MAX_CAPTURE_BYTES:
            raise ValueError(
                f"Offline capture byte_limit ({recorded_limit}) must be positive and <= {format_byte_limit_label(MAX_CAPTURE_BYTES)} ({MAX_CAPTURE_BYTES} bytes); aborting."
            )
    else:
        recorded_limit = LEGACY_OFFLINE_CAPTURE_BYTES

    with open(input_html_path, "rb") as f:
        raw_bytes = f.read(MAX_CAPTURE_BYTES + 1)

    if len(raw_bytes) > MAX_CAPTURE_BYTES:
        raise ValueError(
            f"Offline capture file exceeds {format_byte_limit_label(MAX_CAPTURE_BYTES)} ceiling ({MAX_CAPTURE_BYTES} bytes); aborting."
        )
    if len(raw_bytes) > recorded_limit:
        raise ValueError(
            f"Offline capture file exceeds recorded {format_byte_limit_label(recorded_limit)} limit ({recorded_limit} bytes); aborting."
        )

    actual_sha256 = hashlib.sha256(raw_bytes).hexdigest()
    expected_sha256 = str(cap.get("sha256", "")).strip().lower()
    expected_bytes = int(cap.get("bytes", -1))

    if not expected_sha256 or actual_sha256 != expected_sha256:
        raise ValueError(
            f"Offline capture SHA256 mismatch: expected {expected_sha256}, got {actual_sha256}; aborting."
        )
    if expected_bytes != len(raw_bytes):
        raise ValueError(
            f"Offline capture byte length mismatch: expected {expected_bytes}, got {len(raw_bytes)}; aborting."
        )

    source_url = str(cap.get("source_url", "")).strip()
    sp = urllib.parse.urlsplit(source_url)
    if (sp.scheme or "").lower() not in ("http", "https") or not sp.hostname:
        raise ValueError("Invalid source_url in capture metadata")

    resp_meta_str = str(cap.get("response_metadata", "")).strip()
    http_status: Optional[int] = None
    content_type = resp_meta_str
    parts = resp_meta_str.split(None, 1)
    if parts and parts[0].isdigit():
        http_status = int(parts[0])
        content_type = parts[1] if len(parts) > 1 else ""

    curl_exit = cap.get("curl_exit")
    truncated = bool(
        curl_exit == 56
        or (curl_exit is not None and curl_exit != 0)
        or len(raw_bytes) >= recorded_limit
    )
    errors: List[str] = []
    if curl_exit == 56 and len(raw_bytes) == recorded_limit:
        errors.append(f"curl_exit_56_truncated_at_{recorded_limit}_bytes")
    elif curl_exit not in (None, 0):
        errors.append(f"curl_exit_{curl_exit}_incomplete_transfer")
    elif len(raw_bytes) >= recorded_limit:
        errors.append(f"byte_limit_reached_at_{recorded_limit}_bytes")

    meta = {
        "source_url": source_url,
        "collected_at_utc": str(cap.get("collected_at_utc", "")),
        "mode": "offline_capture",
        "http_status": http_status,
        "content_type": content_type,
        "bytes_captured": len(raw_bytes),
        "max_bytes_limit": recorded_limit,
        "bytes_hashed_scope": (
            f"captured_prefix_{len(raw_bytes)}_bytes"
            if truncated
            else f"full_response_{len(raw_bytes)}_bytes"
        ),
        "captured_prefix_sha256": actual_sha256,
        "full_response_sha256": None if truncated else actual_sha256,
        "curl_exit": curl_exit,
        "partial": truncated,
        "truncated": truncated,
        "errors": errors,
    }
    return raw_bytes, meta


def write_outputs(
    output_dir: str,
    capture_meta: Dict[str, Any],
    entries: List[Dict[str, Any]],
    quarantined: List[Dict[str, Any]],
    counts: Dict[str, Any],
) -> None:
    """Write inventory.json, inventory.csv, and inventory.html to output_dir."""
    os.makedirs(output_dir, exist_ok=True)
    is_partial = bool(capture_meta.get("partial"))
    rec_limit = int(capture_meta.get("max_bytes_limit") or MAX_CAPTURE_BYTES)
    rec_limit_label = format_byte_limit_label(rec_limit)
    bytes_cap = int(capture_meta.get("bytes_captured") or 0)
    curl_exit_val = capture_meta.get("curl_exit")
    curl_note = f", curl exit {curl_exit_val}" if curl_exit_val is not None else ""
    disclaimer = (
        f"TRUNCATED / PARTIAL CAPTURE: Source HTML stopped at {bytes_cap:,} bytes ({rec_limit_label} limit{curl_note}). "
        "This inventory represents only the captured prefix and is NOT a complete list of links on the source page."
        if is_partial
        else f"Complete response within {rec_limit_label} ({rec_limit:,} bytes) limit; outgoing destinations remain untested."
    )

    # 1. Write inventory.json
    json_payload = {
        "schema_version": "1.0",
        "partial": is_partial,
        "truncated": bool(capture_meta.get("truncated")),
        "completeness_disclaimer": disclaimer,
        "capture_metadata": capture_meta,
        "counts": counts,
        "entries": entries,
        "quarantined": quarantined,
    }
    json_path = os.path.join(output_dir, "inventory.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(json_payload, f, ensure_ascii=False, indent=2)
        f.write("\n")

    # 2. Write inventory.csv
    csv_path = os.path.join(output_dir, "inventory.csv")
    fieldnames = [
        "canonical_url",
        "destination_origin",
        "host",
        "category",
        "from_data_site_url",
        "from_a_href",
        "site_ids",
        "occurrence_count",
        "source_tags",
        "source_attrs",
        "sanitized_attr_url_sample",
        "first_raw_attr_sha256",
        "redacted_query_keys",
        "has_ad_technical_marker",
        "is_redirect_wrapper",
        "destination_status",
        "dns_status",
        "download_support_status",
        "safeguard_status",
        "capture_partial",
        "bytes_hashed_scope",
        "captured_prefix_sha256",
        "full_response_sha256",
    ]
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for item in entries:
            provs = item.get("provenance", [])
            tags = sorted({p["source_tag"] for p in provs})
            attrs = sorted({p["source_attr"] for p in provs})
            sample_sanitized = provs[0]["sanitized_attr_url"] if provs else ""
            first_sha = provs[0]["raw_attr_sha256"] if provs else ""
            writer.writerow(
                {
                    "canonical_url": item["canonical_url"],
                    "destination_origin": item["destination_origin"],
                    "host": item["host"],
                    "category": item["category"],
                    "from_data_site_url": str(item["from_data_site_url"]).lower(),
                    "from_a_href": str(item["from_a_href"]).lower(),
                    "site_ids": ";".join(item["site_ids"]),
                    "occurrence_count": item["occurrence_count"],
                    "source_tags": ";".join(tags),
                    "source_attrs": ";".join(attrs),
                    "sanitized_attr_url_sample": sample_sanitized,
                    "first_raw_attr_sha256": first_sha,
                    "redacted_query_keys": ";".join(item["redacted_query_keys"]),
                    "has_ad_technical_marker": str(item["has_ad_technical_marker"]).lower(),
                    "is_redirect_wrapper": str(item["is_redirect_wrapper"]).lower(),
                    "destination_status": item["destination_status"],
                    "dns_status": item["dns_status"],
                    "download_support_status": item["download_support_status"],
                    "safeguard_status": item["safeguard_status"],
                    "capture_partial": str(is_partial).lower(),
                    "bytes_hashed_scope": capture_meta["bytes_hashed_scope"],
                    "captured_prefix_sha256": capture_meta["captured_prefix_sha256"],
                    "full_response_sha256": capture_meta["full_response_sha256"] or "",
                }
            )

    # 3. Write inventory.html
    html_path = os.path.join(output_dir, "inventory.html")
    render_inventory_html(html_path, capture_meta, disclaimer, entries, quarantined, counts)


def render_inventory_html(
    html_path: str,
    capture_meta: Dict[str, Any],
    disclaimer: str,
    entries: List[Dict[str, Any]],
    quarantined: List[Dict[str, Any]],
    counts: Dict[str, Any],
) -> None:
    """Render minimal static HTML inventory without JS, images, or external assets."""
    esc = html.escape
    is_partial = bool(capture_meta.get("partial"))
    rec_limit = int(capture_meta.get("max_bytes_limit") or MAX_CAPTURE_BYTES)
    rec_limit_label = format_byte_limit_label(rec_limit)
    curl_exit_val = capture_meta.get("curl_exit")
    curl_badge_note = f", curl_exit={curl_exit_val}" if curl_exit_val is not None else ""
    badge_text = (
        f"TRUNCATED / PARTIAL CAPTURE ({rec_limit_label} CAP{curl_badge_note})"
        if is_partial
        else f"COMPLETE CAPTURE ({rec_limit_label} CAP)"
    )
    badge_class = "badge-partial" if is_partial else "badge-ok"
    page_title = (
        "Evidence URL Inventory (Partial Capture)"
        if is_partial
        else "Evidence URL Inventory (Complete Capture)"
    )
    full_resp_sha_display = str(
        capture_meta.get("full_response_sha256")
        or f"null (response truncated at {rec_limit_label})"
    )

    by_cat = counts.get("by_category", {})
    rows_html: List[str] = []
    for idx, item in enumerate(entries, start=1):
        provs = item.get("provenance", [])
        tags_attrs = sorted({f"{p['source_tag']}[{p['source_attr']}]" for p in provs})
        first_sha = provs[0]["raw_attr_sha256"][:16] if provs else ""
        site_ids_str = ", ".join(item["site_ids"]) if item["site_ids"] else "-"
        q_keys_str = ", ".join(item["redacted_query_keys"]) if item["redacted_query_keys"] else "-"
        primary_src = "data-site-url" if item["from_data_site_url"] else "a[href]"
        flags: List[str] = []
        if item["has_ad_technical_marker"]:
            flags.append("ad_marker")
        if item["is_redirect_wrapper"]:
            flags.append("redirect_wrapper")
        flags_str = ", ".join(flags) if flags else "-"

        c_url = item["canonical_url"]
        dest_origin = item["destination_origin"]
        sp_c = urllib.parse.urlsplit(c_url)
        norm_c_host = normalize_idna_host(sp_c.hostname or "")
        parsed_c_origin = (
            f"{(sp_c.scheme or '').lower()}://{norm_c_host}/"
            if (sp_c.scheme or "").lower() in ("http", "https") and norm_c_host
            else ""
        )
        disp_canonical = esc(c_url)
        if parsed_c_origin == dest_origin:
            href_canonical = esc(c_url, quote=True)
            link_cell_html = f'<a href="{href_canonical}" rel="noopener noreferrer">{disp_canonical}</a>'
        else:
            link_cell_html = f"<code>{disp_canonical}</code>"

        rows_html.append(
            "<tr>"
            f"<td>{idx}</td>"
            f"<td>{link_cell_html}</td>"
            f"<td><code>{esc(dest_origin)}</code></td>"
            f"<td><code>{esc(item['category'])}</code></td>"
            f"<td><code>{esc(primary_src)}</code></td>"
            f"<td><code>{esc(site_ids_str)}</code></td>"
            f"<td><code>{esc(', '.join(tags_attrs))}</code> (n={item['occurrence_count']}, sha256={esc(first_sha)}...)</td>"
            f"<td><code>{esc(q_keys_str)}</code> / <code>{esc(flags_str)}</code></td>"
            f"<td><code>dest={esc(item['destination_status'])} dns={esc(item['dns_status'])} dl={esc(item['download_support_status'])}</code></td>"
            f"<td><code>{esc(item['safeguard_status'])}</code></td>"
            "</tr>"
        )

    quarantine_rows_html: List[str] = []
    for q_idx, q_item in enumerate(quarantined, start=1):
        q_site_ids = ", ".join(q_item.get("site_ids", [])) or "-"
        quarantine_rows_html.append(
            "<tr>"
            f"<td>{q_idx}</td>"
            f"<td><code>{esc(q_item['canonical_url_sha256'])}</code></td>"
            f"<td><code>{esc(q_item['first_raw_attr_sha256'])}</code></td>"
            f"<td><code>{esc(q_site_ids)}</code></td>"
            f"<td><code>{esc(q_item['quarantine_reason'])}</code></td>"
            f"<td><code>blocked_non_clickable</code></td>"
            "</tr>"
        )

    if not quarantine_rows_html:
        quarantine_section = (
            "<p>No URLs matched explicit child sexual exploitation or nonconsensual filming label quarantine rules "
            "(all extracted URLs remain unverified / pending review; outgoing destinations were not fetched).</p>"
        )
    else:
        quarantine_section = (
            "<table><thead><tr>"
            "<th>#</th><th>Target URL SHA256 (Target Redacted)</th><th>First Raw Attr SHA256</th>"
            "<th>Site ID(s)</th><th>Neutral Reason</th><th>Action Status</th>"
            "</tr></thead><tbody>"
            + "\n".join(quarantine_rows_html)
            + "</tbody></table>"
        )

    doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline';">
<meta name="referrer" content="no-referrer">
<title>{esc(page_title)}</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 20px; color: #111; background: #fff; line-height: 1.45; }}
  h1, h2 {{ margin-top: 1.2em; margin-bottom: 0.4em; }}
  .banner {{ border: 2px solid #b91c1c; background: #fef2f2; padding: 12px 16px; margin-bottom: 16px; border-radius: 4px; }}
  .badge-partial {{ display: inline-block; background: #b91c1c; color: #fff; font-weight: 700; padding: 3px 8px; border-radius: 3px; font-size: 0.9em; }}
  .badge-ok {{ display: inline-block; background: #15803d; color: #fff; font-weight: 700; padding: 3px 8px; border-radius: 3px; font-size: 0.9em; }}
  table {{ border-collapse: collapse; width: 100%; margin-bottom: 20px; font-size: 0.86rem; }}
  th, td {{ border: 1px solid #d1d5db; padding: 6px 8px; text-align: left; vertical-align: top; word-break: break-all; }}
  th {{ background: #f3f4f6; font-weight: 600; }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.84rem; }}
  .meta-grid {{ width: auto; min-width: 60%; }}
</style>
</head>
<body>
<h1>Public Link Evidence Inventory</h1>
<div class="banner">
  <div><span class="{badge_class}">{esc(badge_text)}</span></div>
  <p><strong>Limitation Notice:</strong> {esc(disclaimer)}</p>
  <p>Outgoing links below set <code>href</code> to the sanitized <code>canonical_url</code> (path retained, query values and fragments stripped) only after confirming its parsed origin equals <code>destination_origin</code>. No outgoing DNS lookups, HTTP requests, or media inspections have been performed.</p>
</div>

<h2>1. Capture &amp; Integrity Metadata</h2>
<table class="meta-grid">
  <tbody>
    <tr><th>Source URL</th><td><code>{esc(str(capture_meta.get("source_url", "")))}</code></td></tr>
    <tr><th>Collected At (UTC)</th><td><code>{esc(str(capture_meta.get("collected_at_utc", "")))}</code></td></tr>
    <tr><th>Collection Mode</th><td><code>{esc(str(capture_meta.get("mode", "")))}</code></td></tr>
    <tr><th>HTTP Status / Content-Type</th><td><code>{esc(str(capture_meta.get("http_status", "")))}</code> / <code>{esc(str(capture_meta.get("content_type", "")))}</code></td></tr>
    <tr><th>Captured Bytes / Limit</th><td><code>{esc(str(capture_meta.get("bytes_captured", "")))}</code> / <code>{esc(str(capture_meta.get("max_bytes_limit", "")))}</code></td></tr>
    <tr><th>Bytes Hashed Scope</th><td><code>{esc(str(capture_meta.get("bytes_hashed_scope", "")))}</code></td></tr>
    <tr><th>Captured Prefix SHA256</th><td><code>{esc(str(capture_meta.get("captured_prefix_sha256", "")))}</code></td></tr>
    <tr><th>Full Response SHA256</th><td><code>{esc(full_resp_sha_display)}</code></td></tr>
    <tr><th>Capture Partial / Truncated</th><td><code>partial={esc(str(capture_meta.get("partial")).lower())}</code>, <code>truncated={esc(str(capture_meta.get("truncated")).lower())}</code>, <code>curl_exit={esc(str(capture_meta.get("curl_exit")))}</code></td></tr>
    <tr><th>Capture Error / Truncation Codes</th><td><code>{esc(", ".join(capture_meta.get("errors", [])) or "none")}</code></td></tr>
  </tbody>
</table>

<h2>2. Inventory Summary Counts</h2>
<table class="meta-grid">
  <tbody>
    <tr><th>Total Canonical URLs (Deduplicated, Non-Quarantined)</th><td><code>{counts["total_canonical_urls"]}</code></td></tr>
    <tr><th>Primary Website Inventory (<code>data-site-url</code>)</th><td><code>{counts["primary_data_site_url_entries"]}</code></td></tr>
    <tr><th>Anchor-Only Provenance (<code>a[href]</code> only)</th><td><code>{counts["a_href_only_entries"]}</code></td></tr>
    <tr><th>Category: <code>registered_site</code></th><td><code>{by_cat.get("registered_site", 0)}</code></td></tr>
    <tr><th>Category: <code>source_internal</code></th><td><code>{by_cat.get("source_internal", 0)}</code></td></tr>
    <tr><th>Category: <code>messenger</code></th><td><code>{by_cat.get("messenger", 0)}</code></td></tr>
    <tr><th>Category: <code>advertisement</code></th><td><code>{by_cat.get("advertisement", 0)}</code></td></tr>
    <tr><th>Category: <code>other</code></th><td><code>{by_cat.get("other", 0)}</code></td></tr>
    <tr><th>Quarantined / Blocked Count</th><td><code>{counts["quarantined_blocked_count"]}</code></td></tr>
    <tr><th>Raw Candidate Attributes Inspected / Excluded</th><td><code>{counts["raw_candidate_attrs_seen"]}</code> inspected / <code>{counts["excluded_or_invalid_attrs_count"]}</code> excluded (assets/fragments/non-http)</td></tr>
  </tbody>
</table>

<h2>3. Canonical URL Inventory (Outgoing Status: Untested)</h2>
<table>
  <thead>
    <tr>
      <th>#</th>
      <th>Canonical URL (href = Sanitized Canonical URL)</th>
      <th>Destination Origin</th>
      <th>Category</th>
      <th>Primary Source</th>
      <th>Site ID(s)</th>
      <th>Provenance Summary</th>
      <th>Redacted Query Keys / Flags</th>
      <th>Verification Status</th>
      <th>Safeguard Status</th>
    </tr>
  </thead>
  <tbody>
    {"".join(rows_html)}
  </tbody>
</table>

<h2>4. Safeguard Quarantine Section (Non-Clickable / Non-Runnable)</h2>
{quarantine_section}
</body>
</html>
"""
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(doc)


def get_public_python_version() -> str:
    """Return bounded major.minor.micro Python version string."""
    vi = sys.version_info
    return f"{int(vi[0])}.{int(vi[1])}.{int(vi[2])}"


def get_public_openssl_version() -> str:
    """Return bounded public OpenSSL version token without build paths."""
    raw = getattr(ssl, "OPENSSL_VERSION", "") or ""
    cleaned = "".join(ch for ch in str(raw) if 32 <= ord(ch) < 127).strip()
    parts = cleaned.split()
    if len(parts) >= 2 and parts[0].lower() in ("openssl", "libressl", "boringssl"):
        token = f"{parts[0]} {parts[1]}"
    elif parts:
        token = parts[0]
    else:
        token = "unknown"
    return re.sub(r"[^A-Za-z0-9._ -]", "", token)[:48] or "unknown"


def extract_safe_diagnostic_hostname(raw_url: Optional[str]) -> Optional[str]:
    """Extract syntactically valid normalized IDNA hostname only, or None.

    Never copies full URL, path, query, fragment, or userinfo.
    """
    if not raw_url or not isinstance(raw_url, str):
        return None
    stripped = raw_url.strip()
    if not stripped or has_control_chars(stripped):
        return None
    try:
        sp = urllib.parse.urlsplit(stripped)
    except Exception:
        return None
    if sp.username is not None or sp.password is not None or "@" in (sp.netloc or ""):
        return None
    raw_host = sp.hostname
    if not raw_host:
        return None
    norm = normalize_idna_host(raw_host)
    if not norm or norm.startswith("["):
        return None
    try:
        ipaddress.ip_address(norm)
        return None
    except ValueError:
        pass
    if len(norm) > 253 or "/" in norm or ":" in norm or "?" in norm or "#" in norm:
        return None
    return norm


def sanitize_http_status(value: Any) -> Optional[int]:
    """Return integer HTTP status in 100..599 or None."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int) and 100 <= value <= 599:
        return value
    return None


def sanitize_diagnostic_record(raw: Any) -> Optional[Dict[str, Any]]:
    """Validate and reconstruct a diagnostic record strictly from the field/enum whitelist."""
    if not isinstance(raw, dict):
        return None
    mode = raw.get("mode")
    stage = raw.get("stage")
    result = raw.get("result")
    if mode not in DIAGNOSTIC_MODES or stage not in DIAGNOSTIC_STAGES or result not in DIAGNOSTIC_RESULTS:
        return None

    err_cat = raw.get("error_category")
    if result == "success":
        err_cat = None
    elif err_cat not in DIAGNOSTIC_ERROR_CATEGORIES:
        return None

    http_status = sanitize_http_status(raw.get("http_status"))

    raw_host = raw.get("hostname")
    hostname: Optional[str] = None
    if isinstance(raw_host, str) and raw_host:
        cand = normalize_idna_host(raw_host)
        if cand and not cand.startswith("[") and len(cand) <= 253:
            try:
                ipaddress.ip_address(cand)
            except ValueError:
                hostname = cand

    ts_raw = raw.get("timestamp_utc")
    if isinstance(ts_raw, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:\+00:00|Z)", ts_raw):
        timestamp_utc = ts_raw[:40]
    else:
        return None

    schema_ver = raw.get("schema_version")
    if not isinstance(schema_ver, str) or not re.fullmatch(r"[0-9]+\.[0-9]+", schema_ver):
        schema_ver = DIAGNOSTICS_SCHEMA_VERSION

    coll_ver = raw.get("collector_version")
    if not isinstance(coll_ver, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", coll_ver):
        coll_ver = COLLECTOR_VERSION

    py_ver = raw.get("python_version")
    if not isinstance(py_ver, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", py_ver):
        py_ver = get_public_python_version()

    ossl_ver = raw.get("openssl_version")
    if not isinstance(ossl_ver, str) or not re.fullmatch(r"[A-Za-z0-9._ -]{1,48}", ossl_ver):
        ossl_ver = get_public_openssl_version()

    rec: Dict[str, Any] = {
        "schema_version": schema_ver,
        "collector_version": coll_ver,
        "timestamp_utc": timestamp_utc,
        "mode": mode,
        "stage": stage,
        "result": result,
        "error_category": err_cat,
        "http_status": http_status,
        "hostname": hostname,
        "python_version": py_ver,
        "openssl_version": ossl_ver,
    }
    return {k: rec[k] for k in DIAGNOSTIC_RECORD_WHITELIST}


def build_diagnostic_record(
    mode: str,
    stage: str,
    result: str,
    error_category: Optional[str] = None,
    http_status: Optional[int] = None,
    hostname: Optional[str] = None,
) -> Dict[str, Any]:
    """Build a strictly whitelisted diagnostic record."""
    safe_mode = mode if mode in DIAGNOSTIC_MODES else "diagnostics"
    safe_stage = stage if stage in DIAGNOSTIC_STAGES else "complete"
    safe_result = result if result in DIAGNOSTIC_RESULTS else "failure"
    if safe_result == "success":
        safe_err: Optional[str] = None
    else:
        safe_err = error_category if error_category in DIAGNOSTIC_ERROR_CATEGORIES else "unexpected"

    safe_host: Optional[str] = None
    if isinstance(hostname, str) and hostname:
        cand = normalize_idna_host(hostname)
        if cand and not cand.startswith("[") and len(cand) <= 253:
            try:
                ipaddress.ip_address(cand)
            except ValueError:
                safe_host = cand

    now_utc = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    raw_rec = {
        "schema_version": DIAGNOSTICS_SCHEMA_VERSION,
        "collector_version": COLLECTOR_VERSION,
        "timestamp_utc": now_utc,
        "mode": safe_mode,
        "stage": safe_stage,
        "result": safe_result,
        "error_category": safe_err,
        "http_status": sanitize_http_status(http_status),
        "hostname": safe_host,
        "python_version": get_public_python_version(),
        "openssl_version": get_public_openssl_version(),
    }
    return {k: raw_rec[k] for k in DIAGNOSTIC_RECORD_WHITELIST}


def classify_exception_category(exc: Exception, stage: str) -> str:
    """Map an exception to a controlled diagnostic error_category enum."""
    if isinstance(exc, FetchDeadlineExceeded):
        return "deadline"
    if isinstance(exc, ssl.SSLError):
        return "tls"
    if isinstance(exc, socket.gaierror):
        return "dns"
    if isinstance(exc, TimeoutError) or isinstance(exc, socket.timeout):
        return "deadline"
    if isinstance(exc, http.client.HTTPException):
        return "http"
    if isinstance(exc, (ValueError, json.JSONDecodeError, UnicodeError)):
        if stage == "fetch":
            msg = str(exc).lower()
            if "dns" in msg:
                return "dns"
        return "input"
    if isinstance(exc, OSError):
        return "io"
    return "unexpected"


def _resolve_diagnostics_paths(ensure_dir: bool) -> Tuple[str, str]:
    """Return verified (log_dir, log_file) under ~/Library/Logs/HTDCollector without following symlinks."""
    home = os.path.expanduser("~")
    if not home or home == "~" or not os.path.isabs(home):
        raise OSError("Invalid home directory")
    uid = os.getuid()

    lib_dir = os.path.join(home, "Library")
    logs_dir = os.path.join(lib_dir, "Logs")
    diag_dir = os.path.join(logs_dir, "HTDCollector")
    diag_file = os.path.join(diag_dir, DIAGNOSTICS_FILENAME)

    for parent in (home, lib_dir, logs_dir):
        if os.path.lexists(parent):
            st = os.lstat(parent)
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                raise OSError("Symlink or non-directory ancestor rejected")

    if os.path.lexists(diag_dir):
        st_dir = os.lstat(diag_dir)
        if stat.S_ISLNK(st_dir.st_mode) or not stat.S_ISDIR(st_dir.st_mode):
            raise OSError("Diagnostic log directory is a symlink or not a directory")
        if st_dir.st_uid != uid:
            raise OSError("Diagnostic log directory ownership mismatch")
        try:
            os.chmod(diag_dir, 0o700)
        except OSError:
            pass
    elif ensure_dir:
        for anc in (lib_dir, logs_dir):
            if not os.path.lexists(anc):
                os.mkdir(anc, 0o700)
            st_anc = os.lstat(anc)
            if stat.S_ISLNK(st_anc.st_mode) or not stat.S_ISDIR(st_anc.st_mode):
                raise OSError("Invalid ancestor directory")
        os.mkdir(diag_dir, 0o700)
        st_new = os.lstat(diag_dir)
        if stat.S_ISLNK(st_new.st_mode) or not stat.S_ISDIR(st_new.st_mode) or st_new.st_uid != uid:
            raise OSError("Created diagnostic directory verification failed")
        os.chmod(diag_dir, 0o700)

    if os.path.lexists(diag_file):
        st_file = os.lstat(diag_file)
        if stat.S_ISLNK(st_file.st_mode) or not stat.S_ISREG(st_file.st_mode):
            raise OSError("Diagnostic log file is a symlink or non-regular file")
        if st_file.st_uid != uid:
            raise OSError("Diagnostic log file ownership mismatch")

    return diag_dir, diag_file


def load_sanitized_diagnostic_records() -> List[Dict[str, Any]]:
    """Safely read existing diagnostics.json (<=100 KiB) and reconstruct valid records only."""
    try:
        _, diag_file = _resolve_diagnostics_paths(ensure_dir=False)
    except OSError:
        return []

    if not os.path.lexists(diag_file):
        return []

    uid = os.getuid()
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(diag_file, flags)
    except OSError:
        return []

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != uid:
            return []
        if st.st_size > DIAGNOSTICS_MAX_FILE_BYTES:
            return []
        chunks: List[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, 16384)
            if not chunk:
                break
            total += len(chunk)
            if total > DIAGNOSTICS_MAX_FILE_BYTES:
                return []
            chunks.append(chunk)
        raw_bytes = b"".join(chunks)
    except OSError:
        return []
    finally:
        try:
            os.close(fd)
        except OSError:
            pass

    if not raw_bytes:
        return []

    try:
        parsed = json.loads(raw_bytes.decode("utf-8"))
    except Exception:
        return []

    if not isinstance(parsed, dict):
        return []
    raw_records = parsed.get("records")
    if not isinstance(raw_records, list):
        return []

    reconstructed: List[Dict[str, Any]] = []
    for item in raw_records:
        clean = sanitize_diagnostic_record(item)
        if clean is not None:
            reconstructed.append(clean)

    if len(reconstructed) > DIAGNOSTICS_MAX_RECORDS:
        reconstructed = reconstructed[-DIAGNOSTICS_MAX_RECORDS:]
    return reconstructed


def serialize_diagnostics_payload(records: List[Dict[str, Any]]) -> bytes:
    """Serialize bounded diagnostic payload guaranteed to be <= 100 KiB and <= 32 records."""
    clean_list: List[Dict[str, Any]] = []
    for r in records:
        c = sanitize_diagnostic_record(r)
        if c is not None:
            clean_list.append(c)
    trimmed = clean_list[-DIAGNOSTICS_MAX_RECORDS:]

    while True:
        payload = {
            "schema_version": DIAGNOSTICS_SCHEMA_VERSION,
            "collector_version": COLLECTOR_VERSION,
            "records": trimmed,
        }
        data = (json.dumps(payload, ensure_ascii=True, indent=2) + "\n").encode("utf-8")
        if len(data) <= DIAGNOSTICS_MAX_FILE_BYTES or not trimmed:
            return data
        trimmed = trimmed[1:]


def persist_diagnostic_record(record: Dict[str, Any]) -> None:
    """Persist a diagnostic record atomically with 0700 dir / 0600 file permissions.

    Never raises or masks the caller's operation.
    """
    try:
        clean_new = sanitize_diagnostic_record(record)
        if clean_new is None:
            return
        existing = load_sanitized_diagnostic_records()
        combined = (existing + [clean_new])[-DIAGNOSTICS_MAX_RECORDS:]
        payload_bytes = serialize_diagnostics_payload(combined)
        if len(payload_bytes) > DIAGNOSTICS_MAX_FILE_BYTES:
            return

        diag_dir, diag_file = _resolve_diagnostics_paths(ensure_dir=True)
        uid = os.getuid()
        pid = os.getpid()
        temp_name = f".diagnostics.tmp.{pid}.{int(time.monotonic() * 1000000)}"
        temp_path = os.path.join(diag_dir, temp_name)

        if os.path.lexists(temp_path):
            return

        open_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(temp_path, open_flags, 0o600)
        try:
            os.fchmod(fd, 0o600)
            view = memoryview(payload_bytes)
            written = 0
            while written < len(payload_bytes):
                n = os.write(fd, view[written:])
                if n <= 0:
                    raise OSError("Short write")
                written += n
            os.fsync(fd)
        finally:
            os.close(fd)

        try:
            if os.path.lexists(diag_file):
                st_dst = os.lstat(diag_file)
                if stat.S_ISLNK(st_dst.st_mode) or not stat.S_ISREG(st_dst.st_mode) or st_dst.st_uid != uid:
                    raise OSError("Destination verification failed before replace")
            os.replace(temp_path, diag_file)
            st_final = os.lstat(diag_file)
            if not stat.S_ISREG(st_final.st_mode):
                raise OSError("Replaced file is not regular")
            os.chmod(diag_file, 0o600)
        except Exception:
            try:
                if os.path.lexists(temp_path):
                    os.unlink(temp_path)
            except OSError:
                pass
    except Exception:
        return


def export_diagnostics_zip(zip_path: str) -> None:
    """Export sanitized recent diagnostic records into a newly created 0600 ZIP archive.

    Refuses existing targets or symlinks and writes only a single sanitized diagnostics.json entry.
    """
    if not zip_path or not isinstance(zip_path, str) or has_control_chars(zip_path):
        raise ValueError("Invalid export path")

    norm_target = os.path.abspath(zip_path)
    parent_dir = os.path.dirname(norm_target) or "."
    if not os.path.lexists(parent_dir):
        raise OSError("Export parent directory does not exist")
    st_parent = os.lstat(parent_dir)
    if stat.S_ISLNK(st_parent.st_mode) or not stat.S_ISDIR(st_parent.st_mode):
        raise OSError("Export parent directory is a symlink or not a directory")

    if os.path.lexists(norm_target):
        raise FileExistsError("Export destination already exists")

    records = load_sanitized_diagnostic_records()
    # Include the current export success record in the persisted log and exported bundle
    export_rec = build_diagnostic_record(
        mode="diagnostics",
        stage="export",
        result="success",
        error_category=None,
        http_status=None,
        hostname=None,
    )
    updated_records = (records + [export_rec])[-DIAGNOSTICS_MAX_RECORDS:]
    payload_bytes = serialize_diagnostics_payload(updated_records)
    if len(payload_bytes) > DIAGNOSTICS_MAX_FILE_BYTES:
        raise ValueError("Serialized diagnostics exceed size ceiling")

    open_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(norm_target, open_flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as raw_file:
            fd = -1
            with zipfile.ZipFile(raw_file, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
                zinfo = zipfile.ZipInfo(filename=DIAGNOSTICS_FILENAME, date_time=(2026, 1, 1, 0, 0, 0))
                zinfo.compress_type = zipfile.ZIP_DEFLATED
                zinfo.external_attr = (0o100600 & 0xFFFF) << 16
                zf.writestr(zinfo, payload_bytes)
        os.chmod(norm_target, 0o600)
    except Exception:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            if os.path.lexists(norm_target):
                os.unlink(norm_target)
        except OSError:
            pass
        raise

    persist_diagnostic_record(export_rec)


def emit_neutral_error(stage: str, error_category: str) -> None:
    """Write a neutral, path-free, message-free error line to stderr."""
    safe_stage = stage if stage in DIAGNOSTIC_STAGES else "complete"
    safe_cat = error_category if error_category in DIAGNOSTIC_ERROR_CATEGORIES else "unexpected"
    sys.stderr.write(f"error: stage={safe_stage} error_category={safe_cat}\n")


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    max_label = format_byte_limit_label(MAX_CAPTURE_BYTES)
    ap = argparse.ArgumentParser(
        prog="collector.py",
        description=f"Standalone public URL inventory collector (offline capture or bounded {max_label} / {FETCH_WALL_TIMEOUT_SECONDS}s HTTPS fetch).",
    )
    ap.add_argument(
        "--input",
        dest="input_html",
        help="Path to captured source HTML file (offline mode).",
    )
    ap.add_argument(
        "--capture",
        dest="capture_json",
        help="Path to capture.json metadata file (offline mode).",
    )
    ap.add_argument(
        "--fetch",
        dest="fetch_url",
        help=f"Perform a single bounded HTTPS GET (<={max_label}, <={FETCH_WALL_TIMEOUT_SECONDS}s, public-DNS pinned, no redirects).",
    )
    ap.add_argument(
        "--output-dir",
        dest="output_dir",
        default=".",
        help="Directory to write inventory.json, inventory.csv, and inventory.html.",
    )
    ap.add_argument(
        "--export-diagnostics",
        dest="export_diagnostics",
        help="Export sanitized diagnostic records to a new ZIP file without fetching or parsing.",
    )
    return ap.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else 2
        if code == 0:
            return 0
        persist_diagnostic_record(
            build_diagnostic_record(
                mode="diagnostics",
                stage="arguments",
                result="failure",
                error_category="input",
            )
        )
        return 2
    except Exception:
        persist_diagnostic_record(
            build_diagnostic_record(
                mode="diagnostics",
                stage="arguments",
                result="failure",
                error_category="input",
            )
        )
        emit_neutral_error("arguments", "input")
        return 2

    if args.export_diagnostics is not None:
        if args.fetch_url or args.input_html or args.capture_json:
            persist_diagnostic_record(
                build_diagnostic_record(
                    mode="diagnostics",
                    stage="arguments",
                    result="failure",
                    error_category="input",
                )
            )
            emit_neutral_error("arguments", "input")
            return 2
        try:
            export_diagnostics_zip(args.export_diagnostics)
        except Exception as exc:
            err_cat = classify_exception_category(exc, "export")
            persist_diagnostic_record(
                build_diagnostic_record(
                    mode="diagnostics",
                    stage="export",
                    result="failure",
                    error_category=err_cat,
                )
            )
            emit_neutral_error("export", err_cat)
            return 1
        print(f"status=ok mode=diagnostics stage=export collector_version={COLLECTOR_VERSION}")
        return 0

    if args.fetch_url and (args.input_html or args.capture_json):
        persist_diagnostic_record(
            build_diagnostic_record(
                mode="live_fetch",
                stage="arguments",
                result="failure",
                error_category="input",
            )
        )
        sys.stderr.write("error: specify either (--input and --capture) OR --fetch, not both.\n")
        return 2
    if not args.fetch_url and (not args.input_html or not args.capture_json):
        persist_diagnostic_record(
            build_diagnostic_record(
                mode="offline_capture",
                stage="arguments",
                result="failure",
                error_category="input",
            )
        )
        sys.stderr.write("error: offline mode requires both --input and --capture.\n")
        return 2

    mode = "live_fetch" if args.fetch_url else "offline_capture"
    load_stage = "fetch" if args.fetch_url else "capture_load"
    initial_host = extract_safe_diagnostic_hostname(args.fetch_url) if args.fetch_url else None

    try:
        if args.fetch_url:
            raw_bytes, capture_meta = perform_bounded_fetch(args.fetch_url)
        else:
            raw_bytes, capture_meta = load_and_verify_offline_capture(
                args.input_html, args.capture_json
            )
    except Exception as exc:
        err_cat = classify_exception_category(exc, load_stage)
        persist_diagnostic_record(
            build_diagnostic_record(
                mode=mode,
                stage=load_stage,
                result="failure",
                error_category=err_cat,
                http_status=None,
                hostname=initial_host,
            )
        )
        emit_neutral_error(load_stage, err_cat)
        return 1

    source_url = capture_meta["source_url"]
    source_host = urllib.parse.urlsplit(source_url).hostname or ""
    diag_host = extract_safe_diagnostic_hostname(source_url) or initial_host
    diag_http_status = sanitize_http_status(capture_meta.get("http_status"))

    if mode == "live_fetch":
        fetch_errors = capture_meta.get("errors") or []
        if (
            fetch_errors
            or bool(capture_meta.get("partial"))
            or bool(capture_meta.get("truncated"))
            or capture_meta.get("http_status") != 200
        ):
            err_token = str(fetch_errors[0]) if fetch_errors else ""
            if err_token in (
                "wall_deadline_reached_partial_buffer",
                "wall_deadline_15s_exceeded",
                "fetch_error_TimeoutError",
                "fetch_error_timeout",
            ):
                fetch_err_cat = "deadline"
            elif err_token == "fetch_error_gaierror":
                fetch_err_cat = "dns"
            elif err_token in (
                "fetch_error_SSLError",
                "fetch_error_SSLCertVerificationError",
                "fetch_error_SSLZeroReturnError",
                "fetch_error_SSLWantReadError",
                "fetch_error_SSLWantWriteError",
                "fetch_error_SSLSyscallError",
                "fetch_error_SSLEOFError",
                "fetch_error_CertificateError",
            ):
                fetch_err_cat = "tls"
            elif (
                err_token.startswith(("redirect_status_", "non_200_http_status_"))
                or err_token
                in (
                    "non_html_content_type_rejected",
                    "fetch_error_HTTPException",
                    "fetch_error_NotConnected",
                    "fetch_error_InvalidURL",
                    "fetch_error_UnknownProtocol",
                    "fetch_error_UnknownTransferEncoding",
                    "fetch_error_UnimplementedFileMode",
                    "fetch_error_IncompleteRead",
                    "fetch_error_ImproperConnectionState",
                    "fetch_error_CannotSendRequest",
                    "fetch_error_CannotSendHeader",
                    "fetch_error_ResponseNotReady",
                    "fetch_error_BadStatusLine",
                    "fetch_error_LineTooLong",
                    "fetch_error_RemoteDisconnected",
                )
                or (not err_token and capture_meta.get("http_status") != 200)
            ):
                fetch_err_cat = "http"
            elif err_token in ("fetch_error_ValueError", "fetch_error_UnicodeError"):
                fetch_err_cat = "input"
            elif err_token in (
                "fetch_error_OSError",
                "fetch_error_ConnectionError",
                "fetch_error_ConnectionResetError",
                "fetch_error_ConnectionRefusedError",
                "fetch_error_ConnectionAbortedError",
                "fetch_error_BrokenPipeError",
                "fetch_error_NetworkUnreachable",
                "fetch_error_HostUnreachable",
            ):
                fetch_err_cat = "io"
            else:
                fetch_err_cat = "unexpected"
            persist_diagnostic_record(
                build_diagnostic_record(
                    mode="live_fetch",
                    stage="fetch",
                    result="failure",
                    error_category=fetch_err_cat,
                    http_status=diag_http_status,
                    hostname=diag_host,
                )
            )
            emit_neutral_error("fetch", fetch_err_cat)
            return 1

    try:
        # Only parse HTML if status is 200 (in --fetch mode redirects/errors yield empty inventory)
        if capture_meta.get("http_status") == 200 and raw_bytes:
            html_text = raw_bytes.decode("utf-8", errors="replace")
            parser = InventoryHTMLParser(source_url=source_url, source_host=source_host)
            parser.feed(html_text)
            parser.close()
            entries, quarantined, counts = build_inventory_from_records(parser)
        else:
            entries, quarantined = [], []
            counts = {
                "total_canonical_urls": 0,
                "primary_data_site_url_entries": 0,
                "a_href_only_entries": 0,
                "by_category": {
                    "registered_site": 0,
                    "source_internal": 0,
                    "messenger": 0,
                    "advertisement": 0,
                    "other": 0,
                },
                "quarantined_blocked_count": 0,
                "raw_candidate_attrs_seen": 0,
                "excluded_or_invalid_attrs_count": 0,
            }
    except Exception as exc:
        err_cat = classify_exception_category(exc, "parse")
        persist_diagnostic_record(
            build_diagnostic_record(
                mode=mode,
                stage="parse",
                result="failure",
                error_category=err_cat,
                http_status=diag_http_status,
                hostname=diag_host,
            )
        )
        emit_neutral_error("parse", err_cat)
        return 1

    try:
        write_outputs(
            output_dir=args.output_dir,
            capture_meta=capture_meta,
            entries=entries,
            quarantined=quarantined,
            counts=counts,
        )
    except Exception as exc:
        err_cat = classify_exception_category(exc, "write")
        persist_diagnostic_record(
            build_diagnostic_record(
                mode=mode,
                stage="write",
                result="failure",
                error_category=err_cat,
                http_status=diag_http_status,
                hostname=diag_host,
            )
        )
        emit_neutral_error("write", err_cat)
        return 1

    persist_diagnostic_record(
        build_diagnostic_record(
            mode=mode,
            stage="complete",
            result="success",
            error_category=None,
            http_status=diag_http_status,
            hostname=diag_host,
        )
    )

    by_cat = counts["by_category"]
    print(
        f"status=ok mode={capture_meta['mode']} partial={str(capture_meta['partial']).lower()} "
        f"truncated={str(capture_meta['truncated']).lower()} bytes={capture_meta['bytes_captured']} "
        f"total_canonical_urls={counts['total_canonical_urls']} "
        f"data_site_url={counts['primary_data_site_url_entries']} "
        f"registered_site={by_cat['registered_site']} "
        f"source_internal={by_cat['source_internal']} "
        f"messenger={by_cat['messenger']} "
        f"advertisement={by_cat['advertisement']} "
        f"other={by_cat['other']} "
        f"quarantined={counts['quarantined_blocked_count']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
