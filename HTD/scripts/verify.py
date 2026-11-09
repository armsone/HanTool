#!/usr/bin/env python3
"""
Minimal reproduction harness for the HttpsDown 0.1.0 final verification (not a general test runner).

  /usr/bin/python3 scripts/verify.py --core     run every verification group once
  /usr/bin/python3 scripts/verify.py --failed   re-run only groups that contain failed cases in docs/verification.json
  /usr/bin/python3 scripts/verify.py serve      (for a human/TM) start the loopback fixture server for manual UI inspection

Everything is isolated under validation/ (fixtures, fake yt-dlp extractor plugin, app state, destination folder).
HOME, credentials, the real Application Support folder and ~/Downloads are never touched. The loopback server binds
127.0.0.1 only and every process started here is cleaned up before exit.
"""

import argparse
import collections
import datetime
import hashlib
import importlib.util
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VAL = os.path.join(ROOT, "validation")
FIX = os.path.join(VAL, "fixtures")
XDG = os.path.join(VAL, "xdg")
EVID = os.path.join(VAL, "evidence")
DOCS = os.path.join(ROOT, "docs")
REPORT_JSON = os.path.join(DOCS, "verification.json")
REPORT_MD = os.path.join(DOCS, "verification.md")
ENGINE = os.path.join(ROOT, "Engine", "engine.py")
PY = "/opt/homebrew/Cellar/yt-dlp/2026.10.21/libexec/bin/python"
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
FFPROBE = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"
SMOKE_URL = "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4"

OWN_PIDS = set()
CASES = []          # list of dict(id, group, title, status, detail)


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def case(cid, group, title, ok, detail, skipped=False):
    status = "skipped" if skipped else ("pass" if ok else "fail")
    CASES.append({"id": cid, "group": group, "title": title, "status": status, "detail": str(detail)[:1500]})
    log("[%s] %s: %s" % (status.upper(), cid, str(detail)[:200]))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------------------------------------------------
# Fixture media (generated with the installed FFmpeg)
# ---------------------------------------------------------------------------------------------------------------------

def ff(args):
    p = subprocess.run([FFMPEG, "-y", "-nostdin", "-v", "error"] + args, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg failed: %s :: %s" % (" ".join(args)[:200], p.stderr[:300]))


def make_media():
    shutil.rmtree(FIX, ignore_errors=True)
    os.makedirs(FIX)
    P = lambda n: os.path.join(FIX, n)
    src = ["-f", "lavfi", "-i", "testsrc=size=64x48:rate=10:duration=1"]
    aud = ["-f", "lavfi", "-i", "sine=frequency=440:duration=1"]
    ff(src + aud + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", "-shortest", P("ok.mp4")])
    ff(["-f", "lavfi", "-i", "testsrc=size=64x48:rate=5:duration=0.2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an",
        "-movflags", "+faststart", P("short.mp4")])
    ff(src + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", "-movflags", "+faststart", P("comp_v.mp4")])
    ff(aud + ["-c:a", "aac", P("comp_a.m4a")])
    ff(src + ["-c:v", "mpeg4", "-an", P("wrongmeta.mp4")])
    ff(src + ["-frames:v", "1", P("real.gif")])
    shutil.copy(P("real.gif"), P("fake_gif.mp4"))
    with open(P("fake_html.mp4"), "w") as f:
        f.write("<!DOCTYPE html><html><body>Access denied</body></html>")
    with open(P("fake_json.mp4"), "w") as f:
        f.write('{"error": "forbidden", "message": "not allowed"}')
    data = open(P("ok.mp4"), "rb").read()
    open(P("trunc.mp4"), "wb").write(data[: int(len(data) * 0.6)])
    ff(["-f", "lavfi", "-i", "color=c=red:size=32x32:duration=1", "-frames:v", "1", P("cover.png")])
    # mjpeg inside a real video container (must not be rejected by codec name alone); optional fixtures never abort the run
    try:
        ff(src + ["-c:v", "mjpeg", "-pix_fmt", "yuvj420p", "-an", P("mjpeg.mov")])
    except RuntimeError as e:
        log("optional fixture mjpeg.mov unavailable: %s" % e)
    # audio with attached cover art only (no real video track)
    try:
        ff(["-i", P("cover.png"), "-i", P("comp_a.m4a"), "-map", "1:a", "-map", "0:v", "-c:a", "copy", "-c:v", "mjpeg",
            "-disposition:v", "attached_pic", P("cover_audio.m4a")])
    except RuntimeError as e:
        log("optional fixture cover_audio.m4a unavailable: %s" % e)
    # HLS (VOD with end marker)
    hls = os.path.join(FIX, "hls")
    os.makedirs(hls)
    ff(["-f", "lavfi", "-i", "testsrc=size=64x48:rate=10:duration=4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "10",
        "-keyint_min", "10", "-sc_threshold", "0", "-an", "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod",
        "-hls_segment_filename", os.path.join(hls, "seg%d.ts"), os.path.join(hls, "index.m3u8")])
    pl = open(os.path.join(hls, "index.m3u8")).read()
    with open(os.path.join(hls, "live.m3u8"), "w") as f:
        f.write("\n".join(l for l in pl.splitlines() if not l.startswith("#EXT-X-ENDLIST") and "PLAYLIST-TYPE" not in l) + "\n")


PLUGIN_SRC = '''
from yt_dlp.extractor.common import InfoExtractor
from urllib.parse import urlsplit


class HdFixtureIE(InfoExtractor):
    IE_NAME = "hdfixture"
    _VALID_URL = r"https?://127\\.0\\.0\\.1:\\d+/page/(?P<id>[\\w-]+)"

    def _real_extract(self, url):
        vid = self._match_id(url)
        p = urlsplit(url)
        info = self._download_json("%s://%s/info/%s.json" % (p.scheme, p.netloc, vid), vid)
        info.setdefault("id", vid)
        return info
'''


def write_plugin():
    shutil.rmtree(XDG, ignore_errors=True)
    d = os.path.join(XDG, "yt-dlp", "plugins", "hdfixture", "yt_dlp_plugins", "extractor")
    os.makedirs(d)
    with open(os.path.join(d, "hdfixture.py"), "w") as f:
        f.write(PLUGIN_SRC)


# ---------------------------------------------------------------------------------------------------------------------
# Loopback fixture server
# ---------------------------------------------------------------------------------------------------------------------

class Fx:
    base = ""
    lock = threading.Lock()
    media_gets = collections.Counter()
    info_calls = collections.Counter()
    sub_gets = collections.Counter()
    hls_gets = collections.Counter()
    slow_aborted = 0
    files = {}


MEDIA_MODES = {
    "ok.mp4": "normal", "short.mp4": "normal", "comp_v.mp4": "normal", "comp_a.m4a": "normal",
    "fake.mp4": "normal", "fake_html.mp4": "normal", "fake_json.mp4": "normal", "trunc.mp4": "normal",
    "trunc_early.mp4": "early_close", "chunked.mp4": "chunked", "wrongmeta.mp4": "normal",
    "sel.mp4": "normal", "selc_v.mp4": "normal", "selc_a.m4a": "normal", "secret.mp4": "403", "slow.mp4": "slow",
}
MEDIA_SOURCE = {
    "ok.mp4": "ok.mp4", "short.mp4": "short.mp4", "comp_v.mp4": "comp_v.mp4", "comp_a.m4a": "comp_a.m4a",
    "fake.mp4": "fake_gif.mp4", "fake_html.mp4": "fake_html.mp4", "fake_json.mp4": "fake_json.mp4",
    "trunc.mp4": "trunc.mp4", "trunc_early.mp4": "ok.mp4", "chunked.mp4": "ok.mp4", "wrongmeta.mp4": "wrongmeta.mp4",
    "sel.mp4": "ok.mp4", "selc_v.mp4": "comp_v.mp4", "selc_a.m4a": "comp_a.m4a", "secret.mp4": "ok.mp4", "slow.mp4": "ok.mp4",
}


def fmt(fid, url, ext="mp4", vc="avc1.42c01e", ac="mp4a.40.2", h=48, w=64, tbr=None, proto="http"):
    d = {"format_id": fid, "url": url, "ext": ext, "vcodec": vc, "acodec": ac, "protocol": proto}
    if h:
        d["height"] = h
    if w:
        d["width"] = w
    if tbr:
        d["tbr"] = tbr
    return d


def info_for(case_name, n):
    b = Fx.base
    m = lambda name: "%s/media/%s" % (b, name)
    info = {"id": case_name, "title": case_name.replace("_", " ").title(), "formats": []}
    f = info["formats"]
    if case_name == "ok":
        info["title"] = "Ok Video"
        f.append(fmt("18", m("ok.mp4")))
    elif case_name == "short_silent":
        info["title"] = "Silent Short"
        f.append(fmt("v1", m("short.mp4"), ac="none"))
    elif case_name == "composite":
        info["title"] = "Composite Clip"
        f += [fmt("v1", m("comp_v.mp4"), ac="none"),
              fmt("a1", m("comp_a.m4a"), ext="m4a", vc="none", h=None, w=None, tbr=128),
              fmt("a2", m("comp_a.m4a"), ext="m4a", vc="none", h=None, w=None, tbr=64)]
    elif case_name == "fake_gif":
        f.append(fmt("18", m("fake.mp4")))
    elif case_name == "fake_html":
        f.append(fmt("18", m("fake_html.mp4")))
    elif case_name == "fake_json":
        f.append(fmt("18", m("fake_json.mp4")))
    elif case_name == "trunc_complete":
        f.append(fmt("18", m("trunc.mp4")))
    elif case_name == "trunc_early":
        f.append(fmt("18", m("trunc_early.mp4")))
    elif case_name == "chunked_ok":
        f.append(fmt("18", m("chunked.mp4")))
    elif case_name == "wrongmeta":
        f.append(fmt("22", m("wrongmeta.mp4"), vc="avc1.64001f", h=720, w=1280))
    elif case_name == "sel_height":
        f.append(fmt("18", m("sel.mp4"), h=48 if n <= 1 else 72))
    elif case_name == "sel_vcodec":
        f.append(fmt("18", m("sel.mp4"), vc="avc1.42c01e" if n <= 1 else "vp09.00.10.08"))
    elif case_name == "sel_acodec":
        f.append(fmt("18", m("sel.mp4"), ac="mp4a.40.2" if n <= 1 else "opus"))
    elif case_name == "sel_identity":
        f.append(fmt("18", m("sel.mp4")))
        if n > 1:
            info["id"] = "imposter"
    elif case_name == "sel_missing":
        f.append(fmt("18" if n <= 1 else "19", m("sel.mp4")))
    elif case_name == "sel_component_missing":
        f.append(fmt("v1", m("selc_v.mp4"), ac="none"))
        if n <= 1:
            f.append(fmt("a1", m("selc_a.m4a"), ext="m4a", vc="none", h=None, w=None, tbr=128))
    elif case_name in ("hls_vod", "hls_live", "hls_missing"):
        playlist = "live.m3u8" if case_name == "hls_live" else "index.m3u8"
        f.append(fmt("hls1", "%s/hls/%s/%s" % (b, case_name, playlist), ac="none", proto="m3u8_native"))
    elif case_name in ("subs_ok", "subs_fail"):
        info["title"] = case_name.replace("_", " ").title()
        f.append(fmt("18", m("ok.mp4")))
        ko = "ko_fail.vtt" if case_name == "subs_fail" else "ko.vtt"
        info["subtitles"] = {"ko": [{"url": "%s/sub/%s" % (b, ko), "ext": "vtt", "name": "한국어"}]}
        info["automatic_captions"] = {"en": [{"url": "%s/sub/en_auto.vtt" % b, "ext": "vtt", "name": "English"}]}
    elif case_name == "secret":
        f.append(fmt("18", m("secret.mp4") + "?X-Amz-Signature=SIGSECRET123456&token=TOKSECRET654321"))
    elif case_name == "slow":
        info["title"] = "Slow Download"
        f.append(fmt("18", m("slow.mp4")))
    else:
        return None
    return info


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_HEAD(self):
        self.route(True)

    def do_GET(self):
        self.route(False)

    def send_bytes(self, data, ctype="application/octet-stream", status=200, head=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if not head:
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
        self.close_connection = True

    def route(self, head):
        path = urlsplit(self.path).path
        try:
            if path == "/_stats":
                with Fx.lock:
                    body = {"media_gets": dict(Fx.media_gets), "info_calls": dict(Fx.info_calls), "sub_gets": dict(Fx.sub_gets),
                            "hls_gets": dict(Fx.hls_gets), "slow_aborted": Fx.slow_aborted}
                return self.send_bytes(json.dumps(body).encode(), "application/json", head=head)
            if path.startswith("/info/") and path.endswith(".json"):
                name = path[len("/info/"):-len(".json")]
                with Fx.lock:
                    Fx.info_calls[name] += 1
                    n = Fx.info_calls[name]
                info = info_for(name, n)
                if info is None:
                    return self.send_bytes(b"{}", "application/json", 404, head)
                return self.send_bytes(json.dumps(info).encode(), "application/json", head=head)
            if path.startswith("/media/"):
                return self.media(path[len("/media/"):], head)
            if path.startswith("/hls/"):
                return self.hls(path[len("/hls/"):], head)
            if path.startswith("/sub/"):
                return self.sub(path[len("/sub/"):], head)
            self.send_bytes(b"not found", "text/plain", 404, head)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def media(self, name, head):
        mode = MEDIA_MODES.get(name)
        if mode is None:
            return self.send_bytes(b"missing", "text/plain", 404, head)
        if not head:
            with Fx.lock:
                Fx.media_gets[name] += 1
        data = Fx.files[MEDIA_SOURCE[name]]
        if mode == "403":
            return self.send_bytes(b"<html>Forbidden</html>", "text/html", 403, head)
        ctype = "video/mp4"
        if mode == "normal":
            return self.send_bytes(data, ctype, head=head)
        if mode == "early_close":
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if not head:
                self.wfile.write(data[: len(data) // 2])
                self.wfile.flush()
            self.close_connection = True
            return
        if mode == "chunked":
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            if not head:
                for i in range(0, len(data), 4096):
                    chunk = data[i:i + 4096]
                    self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            self.close_connection = True
            return
        if mode == "slow":
            total = 50_000_000
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(total))
            self.end_headers()
            if head:
                return
            sent = 0
            try:
                while sent < total:
                    self.wfile.write(b"\0" * 16384)
                    self.wfile.flush()
                    sent += 16384
                    time.sleep(0.04)
            except (BrokenPipeError, ConnectionResetError, OSError):
                with Fx.lock:
                    Fx.slow_aborted += 1
            self.close_connection = True

    def hls(self, rel, head):
        parts = rel.split("/")
        if len(parts) != 2:
            return self.send_bytes(b"", "text/plain", 404, head)
        variant, name = parts
        with Fx.lock:
            Fx.hls_gets["%s/%s" % (variant, name)] += 1
        d = os.path.join(FIX, "hls")
        if name.endswith(".m3u8"):
            real = os.path.join(d, name)
            return self.send_bytes(open(real, "rb").read(), "application/vnd.apple.mpegurl", head=head)
        if variant == "hls_missing" and name == "seg1.ts":
            return self.send_bytes(b"gone", "text/plain", 404, head)
        real = os.path.join(d, os.path.basename(name))
        if not os.path.isfile(real):
            return self.send_bytes(b"", "text/plain", 404, head)
        return self.send_bytes(open(real, "rb").read(), "video/mp2t", head=head)

    def sub(self, name, head):
        with Fx.lock:
            Fx.sub_gets[name] += 1
            n = Fx.sub_gets[name]
        if name == "ko_fail.vtt" and n <= 1:
            return self.send_bytes(b"nope", "text/plain", 404, head)
        body = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n%s\n" % ("안녕하세요" if name.startswith("ko") else "Hello")
        return self.send_bytes(body.encode("utf-8"), "text/vtt; charset=utf-8", head=head)


def start_server(port=0):
    for n in os.listdir(FIX):
        p = os.path.join(FIX, n)
        if os.path.isfile(p):
            Fx.files[n] = open(p, "rb").read()
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    Fx.base = "http://127.0.0.1:%d" % srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# ---------------------------------------------------------------------------------------------------------------------
# Engine-level checks (run engine.py exactly like the app bridge does: own session, JSON on stdin, events on stdout)
# ---------------------------------------------------------------------------------------------------------------------

def engine_env():
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + env.get("PATH", "")
    env["XDG_CONFIG_HOME"] = XDG
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def run_engine(cmd, req, job_id="j1", gen=1, timeout=180):
    p = subprocess.Popen([PY, ENGINE, cmd, "--job-id", job_id, "--generation", str(gen)], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=engine_env(), start_new_session=True)
    OWN_PIDS.add(p.pid)
    try:
        out, err = p.communicate(json.dumps(req).encode(), timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        out, err = p.communicate()
    events = []
    bad_lines = 0
    for line in out.decode("utf-8", "replace").splitlines():
        if not line.strip():
            continue
        try:
            events.append(json.loads(line))
        except ValueError:
            bad_lines += 1
    try:
        os.killpg(p.pid, 0)
        leftover = True
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        leftover = False
    return {"events": events, "exit": p.returncode, "stderr": err.decode("utf-8", "replace"), "bad_lines": bad_lines,
            "leftover_group": leftover}


def terminal(events):
    for e in events:
        if e["event"] in ("verified", "selectionChanged", "verificationIncomplete", "verificationFailed", "error", "extractCompleted"):
            return e
    return None


def build_spec(formats, ids, out_dir, extractor, media_id):
    comps = []
    for f in formats:
        if f["formatId"] in ids:
            c = {"formatId": f["formatId"]}
            for src, dst in (("height", "height"), ("width", "width"), ("vcodec", "vcodec"), ("acodec", "acodec"), ("protocolName", "protocol")):
                if f.get(src) is not None:
                    c[dst] = f[src]
            comps.append(c)
    has_video = any(c.get("vcodec") not in (None, "none") for c in comps)
    intent = "video" if has_video else ("audio" if all(c.get("vcodec") == "none" for c in comps) else "media")
    return {"mode": "full", "outputDir": out_dir, "formatId": "+".join(ids),
            "expected": {"components": comps, "intent": intent, "extractor": extractor, "mediaId": media_id}, "subtitles": []}


def load_engine_module():
    spec = importlib.util.spec_from_file_location("hd_engine", ENGINE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def group_engine():
    g = "engine"
    eng = load_engine_module()

    # --- redaction ---
    secrets = ["SIGSECRET123456", "TOKSECRET654321", "abcdef0123456789abcdef0123456789abcdef", "s3cr3tCookieValue", "Bearer-abc.def.ghi"]
    sample = ("ERROR: unable to download https://cdn.example.com/v/clip.mp4?X-Amz-Signature=SIGSECRET123456&token=TOKSECRET654321 "
              "Authorization: Bearer abc.def.ghi Cookie: sid=s3cr3tCookieValue; other=1 "
              "key=abcdef0123456789abcdef0123456789abcdef https://user:pass@host.example/path?q=1")
    red = eng.redact(sample, 1000)
    leaked = [s for s in secrets + ["pass@", "q=1", "X-Amz"] if s in red]
    case("engine.redaction", g, "Engine redacts URLs/headers/tokens from any text it emits", not leaked, "leaked=%s redacted=%r" % (leaked, red[:200]))

    # --- verification unit cases (fake media must be rejected, real/short/silent accepted) ---
    def v(name, intent="media", comps=None, copy_as=None):
        d = os.path.join(VAL, "unit")
        os.makedirs(d, exist_ok=True)
        dst = os.path.join(d, copy_as or name)
        shutil.copy(os.path.join(FIX, name), dst)
        return eng.verify_media_file(dst, {"intent": intent, "components": comps or []}, d)

    r = v("ok.mp4", "video", [{"vcodec": "avc1.42c01e", "acodec": "mp4a.40.2", "height": 48}])
    case("engine.verify_valid_mp4", g, "Valid h264/aac mp4 passes full decode", r.get("ok") and r.get("hasVideo") and r.get("hasAudio"), r)
    r = v("short.mp4", "video")
    case("engine.verify_short_silent_ok", g, "0.2 s silent video is accepted (no min duration/audio rule)", r.get("ok") and not r.get("hasAudio"), r)
    if os.path.exists(os.path.join(FIX, "mjpeg.mov")):
        r = v("mjpeg.mov", "video")
        case("engine.verify_mjpeg_in_video_container_ok", g, "mjpeg track inside a real video container is not rejected by codec name", r.get("ok"), r)
    else:
        case("engine.verify_mjpeg_in_video_container_ok", g, "mjpeg in a video container", False, "fixture could not be generated by this ffmpeg", skipped=True)
    r = v("fake_gif.mp4", "video")
    case("engine.verify_gif_renamed_mp4_rejected", g, "Real GIF bytes named .mp4 are rejected", (not r.get("ok")) and r.get("kind") == "failed" and "GIF" in r.get("reason", ""), r)
    r = v("real.gif", "video", copy_as="real_named.gif")
    case("engine.verify_gif_file_rejected", g, "A .gif file is not accepted as video", not r.get("ok"), r)
    r = v("fake_html.mp4", "video")
    case("engine.verify_html_renamed_mp4_rejected", g, "HTML named .mp4 is rejected", (not r.get("ok")) and "HTML" in r.get("reason", ""), r)
    r = v("fake_json.mp4", "video")
    case("engine.verify_json_renamed_mp4_rejected", g, "JSON named .mp4 is rejected", (not r.get("ok")) and "JSON" in r.get("reason", ""), r)
    r = v("cover.png", "video", copy_as="cover_png.mp4")
    case("engine.verify_png_renamed_mp4_rejected", g, "PNG named .mp4 is rejected", (not r.get("ok")) and "PNG" in r.get("reason", ""), r)
    r = v("trunc.mp4", "video")
    case("engine.verify_truncated_mp4_rejected", g, "Truncated faststart mp4 (ffprobe-readable) fails the full decode", (not r.get("ok")) and r.get("kind") == "failed", r)
    if os.path.exists(os.path.join(FIX, "cover_audio.m4a")):
        r = v("cover_audio.m4a", "video")
        case("engine.verify_cover_art_not_video", g, "Audio with attached cover art does not satisfy a video selection", not r.get("ok"), r)
        r2 = v("cover_audio.m4a", "audio")
        case("engine.verify_cover_art_audio_ok", g, "Same file satisfies an audio-only selection", r2.get("ok"), r2)
    else:
        case("engine.verify_cover_art_not_video", g, "attached_pic handling", False, "fixture could not be generated by this ffmpeg", skipped=True)
    r = v("ok.mp4", "video", [{"vcodec": "vp09.00.10.08"}])
    case("engine.verify_codec_intent_mismatch", g, "Selected vp9 but file is h264 -> rejected", (not r.get("ok")) and "코덱" in r.get("reason", ""), r)
    r = v("ok.mp4", "video", [{"vcodec": "avc1.42c01e", "height": 720}])
    case("engine.verify_height_intent_mismatch", g, "Selected 720p but file is 48p -> rejected", (not r.get("ok")) and "해상도" in r.get("reason", ""), r)
    empty = os.path.join(VAL, "unit", "empty.mp4")
    open(empty, "wb").close()
    r = eng.verify_media_file(empty, {"intent": "video"}, os.path.join(VAL, "unit"))
    case("engine.verify_zero_byte_rejected", g, "0-byte output rejected", not r.get("ok"), r)
    link = os.path.join(VAL, "unit", "link.mp4")
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(os.path.join(FIX, "ok.mp4"), link)
    r = eng.verify_media_file(link, {"intent": "video"}, os.path.join(VAL, "unit"))
    case("engine.verify_symlink_output_rejected", g, "Symlinked output rejected", not r.get("ok"), r)

    # --- completeness evidence: no false claims ---
    http_ok = {"a": {"format_id": "18", "protocol": "http", "finished": True, "total_bytes": 100, "final_downloaded": 100, "disk_size": 100}}
    c1 = eng.assess_completeness(http_ok, {}, ["18"])
    no_cl = {"a": {"format_id": "18", "protocol": "http", "finished": True, "final_downloaded": 100, "disk_size": 100}}
    c2 = eng.assess_completeness(no_cl, {}, ["18"])
    mism = {"a": {"format_id": "18", "protocol": "http", "finished": True, "total_bytes": 100, "final_downloaded": 100, "disk_size": 90}}
    c3 = eng.assess_completeness(mism, {}, ["18"])
    hls = {"a": {"format_id": "h", "protocol": "m3u8_native", "finished": True, "fragment_count": 4, "fragment_index": 4}}
    c4 = eng.assess_completeness(hls, {"h": {"endlist": True, "frags": 4}}, ["h"])
    c5 = eng.assess_completeness(hls, {"h": {"endlist": False, "frags": 4}}, ["h"])
    c6 = eng.assess_completeness(hls, {}, ["h"])
    part = {"a": {"format_id": "h", "protocol": "m3u8_native", "finished": True, "fragment_count": 4, "fragment_index": 3}}
    c7 = eng.assess_completeness(part, {"h": {"endlist": True, "frags": 4}}, ["h"])
    c8 = eng.assess_completeness({"a": {"format_id": "x", "protocol": "m3u8", "finished": True}}, {}, ["x"])
    c9 = eng.assess_completeness(http_ok, {}, ["18", "140"])
    ok = c1[0] and not c2[0] and not c3[0] and c4[0] and not c5[0] and not c6[0] and not c7[0] and not c8[0] and not c9[0]
    case("engine.completeness_rules", g, "Completeness accepted only with HTTP length match or closed-VOD complete fragments; unknown otherwise", ok,
         json.dumps([c1, c2, c3, c4, c5, c6, c7, c8, c9], ensure_ascii=False))

    # --- real engine runs against the fixture server ---
    r = run_engine("extract", {"url": "%s/page/ok" % Fx.base})
    ev = r["events"]
    fe = next((e for e in ev if e["event"] == "formatsExtracted"), None)
    first_ready = ev and ev[0]["event"] == "ready" and ev[0]["payload"]["pid"] == ev[0]["payload"]["pgid"]
    case("engine.extract_events_and_handshake", g, "Extract emits ready handshake first (pid==pgid), formats, extractor, id; exit 0; no stray output lines",
         bool(first_ready and fe and fe["payload"]["extractor"] == "HdFixture" and fe["payload"]["mediaId"] == "ok" and r["exit"] == 0
              and r["bad_lines"] == 0 and not r["leftover_group"]),
         "ready=%s extractor=%s exit=%s bad_lines=%s leftover=%s" % (first_ready, fe and fe["payload"]["extractor"], r["exit"], r["bad_lines"], r["leftover_group"]))

    # download with the real engine: events, manifest, evidence, no secrets on stderr
    out_dir = os.path.join(VAL, "engine_out_ok")
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir)
    spec = build_spec(fe["payload"]["formats"], ["18"], out_dir, "HdFixture", "ok")
    r = run_engine("download", {"url": "%s/page/ok" % Fx.base, "spec": spec})
    t = terminal(r["events"])
    prim = (t or {}).get("payload", {}).get("primary") or {}
    same = prim.get("path") and os.path.isfile(prim["path"]) and sha256(prim["path"]) == sha256(os.path.join(FIX, "ok.mp4"))
    case("engine.download_verified_manifest", g, "Valid video downloads, verifies, reports actual after_move path and HTTP length evidence",
         bool(t and t["event"] == "verified" and same and "HTTP" in prim.get("completeness", "") and r["exit"] == 0 and not r["leftover_group"]),
         "terminal=%s path=%s completeness=%s exit=%s" % (t and t["event"], prim.get("path"), prim.get("completeness"), r["exit"]))

    # signed URL failure: nothing sensitive in events or stderr
    out_dir = os.path.join(VAL, "engine_out_secret")
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir)
    ex = run_engine("extract", {"url": "%s/page/secret?sig=PAGESECRET1" % Fx.base})
    fe2 = next((e for e in ex["events"] if e["event"] == "formatsExtracted"), None)
    spec = build_spec(fe2["payload"]["formats"], ["18"], out_dir, "HdFixture", "secret") if fe2 else None
    r = run_engine("download", {"url": "%s/page/secret?sig=PAGESECRET1" % Fx.base, "spec": spec}) if spec else {"events": [], "stderr": "", "exit": -1}
    blob = json.dumps(r["events"], ensure_ascii=False) + r["stderr"] + json.dumps(ex["events"], ensure_ascii=False) + ex["stderr"]
    leaked = [s for s in ("SIGSECRET123456", "TOKSECRET654321", "PAGESECRET1", "X-Amz-Signature") if s in blob]
    t = terminal(r["events"])
    case("engine.secret_url_not_in_events_or_stderr", g, "403 on signed URL: error is generic; events and stderr carry no signature/token",
         bool(t and t["event"] == "error" and not leaked), "terminal=%s leaked=%s message=%s" % (t and t["event"], leaked, (t or {}).get("payload", {}).get("message")))

    # extraction failure on unreachable port is generic and redacted
    r = run_engine("extract", {"url": "http://127.0.0.1:9/page/zzz?token=ABCDEF0123456789ABCDEF0123456789"})
    t = terminal(r["events"])
    blob = json.dumps(r["events"], ensure_ascii=False) + r["stderr"]
    case("engine.extract_failure_generic", g, "Unreachable address yields a generic redacted error", bool(t and t["event"] == "error" and "ABCDEF0123456789" not in blob),
         "terminal=%s detail=%s" % (t and t["event"], (t or {}).get("payload", {}).get("detail")))


def group_smoke():
    g = "smoke"
    d = os.path.join(VAL, "smoke")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        req = urllib.request.Request(SMOKE_URL, method="HEAD")
        with urllib.request.urlopen(req, timeout=20) as resp:
            length = int(resp.headers.get("Content-Length") or 0)
    except Exception as e:
        case("smoke.https_cc0_flower", g, "Optional real HTTPS smoke (CC0 sample)", False, "network unavailable: %s" % type(e).__name__, skipped=True)
        return
    if not (0 < length <= 10 * 1024 * 1024):
        case("smoke.https_cc0_flower", g, "Optional real HTTPS smoke (CC0 sample)", False, "unexpected content-length %s; skipped" % length, skipped=True)
        return
    ex = run_engine("extract", {"url": SMOKE_URL}, timeout=120)
    fe = next((e for e in ex["events"] if e["event"] == "formatsExtracted"), None)
    if not fe:
        case("smoke.https_cc0_flower", g, "Optional real HTTPS smoke (CC0 sample)", False, "extract failed: %s" % json.dumps(terminal(ex["events"]), ensure_ascii=False)[:300])
        return
    f0 = fe["payload"]["formats"][-1]
    spec = build_spec(fe["payload"]["formats"], [f0["formatId"]], d, fe["payload"]["extractor"], fe["payload"]["mediaId"])
    r = run_engine("download", {"url": SMOKE_URL, "spec": spec}, timeout=180)
    t = terminal(r["events"])
    prim = (t or {}).get("payload", {}).get("primary") or {}
    ok = bool(t and t["event"] == "verified" and prim.get("path") and os.path.getsize(prim["path"]) == length)
    case("smoke.https_cc0_flower", g, "Optional real HTTPS smoke (CC0 sample, <=10 MB) downloads, verifies and proves length", ok,
         "terminal=%s size=%s contentLength=%s completeness=%s reason=%s" % (t and t["event"], prim.get("size"), length, prim.get("completeness"),
                                                                         (t or {}).get("payload", {}).get("reason") or (t or {}).get("payload", {}).get("message")))
    shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------------------------------------------------------------
# Swift probe (real EngineBridge / Publisher / AppModel)
# ---------------------------------------------------------------------------------------------------------------------

def compile_probe():
    out_dir = os.path.join(VAL, "probe_build")
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(os.path.join(out_dir, "modcache"))
    srcs = [os.path.join(ROOT, "Sources", "HttpsDown", n) for n in ("Models.swift", "Publisher.swift", "EngineBridge.swift", "AppModel.swift")]
    srcs.append(os.path.join(VAL, "probe", "main.swift"))
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    exe = os.path.join(out_dir, "hdprobe")
    cmd = ["/usr/bin/xcrun", "swiftc", "-target", "%s-apple-macosx14.0" % arch, "-swift-version", "5", "-Onone",
           "-module-cache-path", os.path.join(out_dir, "modcache"), "-o", exe] + srcs
    env = dict(os.environ, TMPDIR="/tmp", CLANG_MODULE_CACHE_PATH=os.path.join(out_dir, "modcache"))
    t0 = time.time()
    p = subprocess.run(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=900)
    log("swiftc probe exit=%s in %.0fs" % (p.returncode, time.time() - t0))
    return exe, p


def run_probe(exe, groups):
    out = os.path.join(VAL, "probe_result.json")
    if os.path.exists(out):
        os.remove(out)
    for d in ("pub", "app", "restart"):
        if d in groups or (d == "app" and "restart" in groups) or (d == "restart" and "app" in groups) or not groups:
            shutil.rmtree(os.path.join(VAL, d), ignore_errors=True)
    env = engine_env()
    env.update({"HDX_BASE": Fx.base, "HDX_ROOT": VAL, "HDX_OUT": out, "HDX_ONLY": ",".join(sorted(groups))})
    p = subprocess.Popen([exe], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    OWN_PIDS.add(p.pid)
    try:
        so, se = p.communicate(timeout=1500)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        so, se = p.communicate()
        se += b"\nPROBE TIMEOUT"
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    data = None
    if os.path.exists(out):
        data = json.load(open(out))
    return data, p.returncode, se.decode("utf-8", "replace")


def ffprobe_json(path):
    p = subprocess.run([FFPROBE, "-v", "error", "-protocol_whitelist", "file", "-show_entries", "format=format_name,duration:stream=codec_type,codec_name,width,height",
                        "-of", "json", "file:" + path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
    return json.loads(p.stdout) if p.returncode == 0 else None


def post_checks(extra):
    g = "postcheck"
    s = (extra or {}).get("summary") or {}
    pub = s.get("published") or {}
    if pub.get("ok") and os.path.isfile(pub["ok"]):
        case("post.ok_bytes_identical", g, "Published 'ok' file is byte-identical to the served fixture (no transformation)",
             sha256(pub["ok"]) == sha256(os.path.join(FIX, "ok.mp4")), pub["ok"])
    if pub.get("composite") and os.path.isfile(pub["composite"]):
        info = ffprobe_json(pub["composite"]) or {}
        kinds = sorted(set(x.get("codec_type") for x in info.get("streams", [])))
        case("post.composite_has_video_and_audio", g, "Published composite file has both video and audio streams (independent ffprobe)", kinds == ["audio", "video"], kinds)
    if pub.get("short_silent") and os.path.isfile(pub["short_silent"]):
        info = ffprobe_json(pub["short_silent"]) or {}
        kinds = sorted(set(x.get("codec_type") for x in info.get("streams", [])))
        case("post.short_silent_video_only", g, "Short silent output is a real video-only file", kinds == ["video"], kinds)
    if pub.get("hls_vod") and os.path.isfile(pub["hls_vod"]):
        info = ffprobe_json(pub["hls_vod"]) or {}
        dur = float((info.get("format") or {}).get("duration") or 0)
        case("post.hls_vod_full_duration", g, "Published HLS VOD covers all 4 segments (~4 s)", 3.5 <= dur <= 4.6, "duration=%.2f" % dur)
    dest = s.get("dest")
    if dest and os.path.isdir(dest):
        left = [n for n in os.listdir(dest) if n.startswith(".httpsdown") or n.endswith(".part")]
        bad = [n for n in os.listdir(dest) if n.lower().endswith((".gif", ".html"))]
        case("post.destination_clean", g, "No staging/.part leftovers or fake-media files in the destination", not left and not bad, "left=%s bad=%s files=%s" % (left, bad, sorted(os.listdir(dest))))
    for name in ("app", "restart"):
        store = os.path.join(VAL, name, "store", "jobs.json")
        if os.path.isfile(store):
            text = open(store, encoding="utf-8").read()
            leaked = [x for x in ("SIGSECRET123456", "TOKSECRET654321", "PAGESECRET1", "X-Amz-Signature", "Authorization") if x in text]
            case("post.job_store_secret_scan_%s" % name, g, "Independent grep of %s/store/jobs.json for secrets" % name, not leaked, "leaked=%s bytes=%d" % (leaked, len(text)))


GROUP_OF_PREFIX = {"proc.": "proc", "pub.": "pub", "health.": "health", "app.": "app", "restart.": "restart"}


def group_swift(groups):
    g = "swift"
    exe, p = compile_probe()
    if p.returncode != 0 or not os.path.exists(exe):
        case("swift.probe_compile", g, "Product Swift sources (Models/Publisher/EngineBridge/AppModel) compile with the probe", False,
             (p.stderr or p.stdout)[-1500:])
        return None
    warn = [l for l in p.stderr.splitlines() if "warning:" in l]
    case("swift.probe_compile", g, "Product Swift sources (Models/Publisher/EngineBridge/AppModel) compile with the probe", True, "ok; %d warnings" % len(warn))
    data, rc, stderr = run_probe(exe, groups)
    if not data:
        case("swift.probe_run", g, "Probe produced a result file", False, "exit=%s stderr tail=%s" % (rc, stderr[-1200:]))
        return None
    for c in data["checks"]:
        gid = c["id"].split(".")[0]
        case(c["id"], gid, c["id"], c["pass"], c["detail"])
    post_checks(data.get("extra"))
    return data


# ---------------------------------------------------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------------------------------------------------

LIMITATIONS = [
    "Real cross-volume / NAS publishing was NOT exercised: only a simulated EXDEV (injected rename failure) verified the staging-copy path; no second writable volume was used.",
    "HLS evidence covers native-HLS media playlists with #EXT-X-ENDLIST and complete fragment lists; DASH, ffmpeg-delegated HLS, live streams and chunked/unknown-length HTTP are reported as verificationIncomplete by design (never saved).",
    "Only the loopback fixture extractor and one optional public CC0 HTTPS sample were exercised; no real site extractors, no login/cookies, no signed-URL expiry behaviour.",
    "Connection help (loopback proxy) and the owned WebView login are intentionally not implemented and are shown as unavailable.",
    "Dev stack only: Homebrew Python/yt-dlp/FFmpeg/Deno (GPL-enabled FFmpeg); not a portable, signed or notarised release.",
    "Native SwiftUI window behaviour (layout, buttons, pickers) is not covered here; it is left to the separate UI inspection.",
    "PID reuse: the engine group is signalled only while its leader is unreaped or the group still exists (kernel does not reuse a pid while a group with that id exists); an unrelated process cannot be hit unless the group vanished and the id was recycled in the 25 ms polling window.",
]


def cleanup_traces():
    """Keep only evidence; remove every temporary fixture, isolated app state and build cache this harness created."""
    os.makedirs(EVID, exist_ok=True)
    for src, dst in (("probe_result.json", "probe_result-latest.json"), (os.path.join("app", "store", "jobs.json"), "jobs-after-app-flows.json"),
                     (os.path.join("restart", "store", "jobs.json"), "jobs-after-restart-flows.json")):
        p = os.path.join(VAL, src)
        if os.path.isfile(p):
            shutil.copy(p, os.path.join(EVID, dst))
    for d in ("unit", "engine_out_ok", "engine_out_secret", "smoke", "work", "pub", "app", "restart", "probe_build", "fixtures", "xdg"):
        shutil.rmtree(os.path.join(VAL, d), ignore_errors=True)
    try:
        os.remove(os.path.join(VAL, "probe_result.json"))
    except OSError:
        pass


def write_reports(mode, previous):
    os.makedirs(DOCS, exist_ok=True)
    py_ver = subprocess.run([PY, "-c", "import yt_dlp.version as v,sys;print(v.__version__, sys.version.split()[0])"], stdout=subprocess.PIPE, text=True).stdout.strip()
    ff_ver = subprocess.run([FFMPEG, "-version"], stdout=subprocess.PIPE, text=True).stdout.splitlines()[0]
    report = {
        "generated": now(), "mode": mode, "platform": platform.platform(), "yt_dlp_and_python": py_ver, "ffmpeg": ff_ver,
        "cases": CASES, "limitations": LIMITATIONS,
        "summary": {"pass": sum(1 for c in CASES if c["status"] == "pass"), "fail": sum(1 for c in CASES if c["status"] == "fail"),
                    "skipped": sum(1 for c in CASES if c["status"] == "skipped")},
    }
    if previous:
        report["previous_failures"] = previous.get("previous_failures", [])
        if previous.get("server_stats"):
            report["server_stats"] = previous["server_stats"]
        if previous.get("group_inputs"):
            report["group_inputs"] = previous["group_inputs"]
        if previous.get("build"):
            report["build"] = previous["build"]
    with open(REPORT_JSON, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    lines = ["# HttpsDown 0.1.0 검증 결과", "", "- 생성: %s (%s)" % (report["generated"], mode),
             "- 환경: %s · yt-dlp/Python %s · %s" % (report["platform"], py_ver, ff_ver),
             "- 결과: 통과 %d · 실패 %d · 건너뜀 %d" % (report["summary"]["pass"], report["summary"]["fail"], report["summary"]["skipped"]), "",
             "| 상태 | ID | 설명 / 증거 |", "| --- | --- | --- |"]
    for c in CASES:
        lines.append("| %s | `%s` | %s — %s |" % (c["status"], c["id"], c["title"].replace("|", "/"), c["detail"].replace("|", "/").replace("\n", " ")[:300]))
    if report.get("previous_failures"):
        lines += ["", "## 이전 실패 증거 (수정 전)", ""]
        for pf in report["previous_failures"]:
            lines.append("- `%s` (%s): %s" % (pf["id"], pf.get("recorded", ""), pf["detail"].replace("\n", " ")[:300]))
    lines += ["", "## 남은 한계", ""] + ["- " + l for l in LIMITATIONS]
    with open(REPORT_MD, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def load_previous():
    if os.path.isfile(REPORT_JSON):
        try:
            return json.load(open(REPORT_JSON, encoding="utf-8"))
        except ValueError:
            return None
    return None


def preserve_failures(prev):
    """Never overwrite failure evidence: archive it under validation/evidence and keep a summary in the new report."""
    if not prev:
        return []
    failed = [c for c in prev.get("cases", []) if c["status"] == "fail"]
    carried = list(prev.get("previous_failures", []))
    if failed:
        os.makedirs(EVID, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        with open(os.path.join(EVID, "failures-%s.json" % stamp), "w", encoding="utf-8") as f:
            json.dump(prev, f, ensure_ascii=False, indent=2)
        for c in failed:
            carried.append({"id": c["id"], "recorded": stamp, "detail": c["detail"]})
    return carried


def finish(servers):
    for s in servers:
        try:
            s.shutdown()
            s.server_close()
        except Exception:
            pass
    for pid in list(OWN_PIDS):
        try:
            os.killpg(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    cleanup_traces()


SWIFT_SRC = ["Sources/HttpsDown/" + n for n in ("Models.swift", "Publisher.swift", "EngineBridge.swift", "AppModel.swift")]
PROBE_SRC = "validation/probe/main.swift"
GROUP_INPUTS = {
    "engine": ["Engine/engine.py"],
    "proc": ["Sources/HttpsDown/EngineBridge.swift", PROBE_SRC],
    "pub": ["Sources/HttpsDown/Publisher.swift", "Sources/HttpsDown/Models.swift", PROBE_SRC],
    "health": ["Engine/engine.py", "Sources/HttpsDown/EngineBridge.swift", PROBE_SRC],
    "app": ["Engine/engine.py"] + SWIFT_SRC + [PROBE_SRC],
    "restart": ["Engine/engine.py"] + SWIFT_SRC + [PROBE_SRC],
}


def inputs_sha(group):
    return {rel: sha256(os.path.join(ROOT, rel)) for rel in GROUP_INPUTS[group]}


def do_run(mode):
    prev = load_previous()
    carried = preserve_failures(prev)
    base_cases = []
    groups_to_run = None
    if mode == "failed":
        if not prev:
            log("no previous docs/verification.json; run --core first")
            return 2
        failed_ids = [c["id"] for c in prev["cases"] if c["status"] == "fail"]
        stale = [g for g in GROUP_INPUTS if prev.get("group_inputs", {}).get(g) != inputs_sha(g)]
        if not failed_ids and not stale:
            log("no failed or stale cases recorded; nothing to re-run (leftover temporary fixtures removed)")
            cleanup_traces()
            return 0
        groups_to_run = set()
        for fid in failed_ids:
            for pref, grp in GROUP_OF_PREFIX.items():
                if fid.startswith(pref):
                    groups_to_run.add(grp)
            if fid.startswith(("engine.", "swift.", "post.", "smoke.")):
                groups_to_run.add(fid.split(".")[0])
        # Earlier passes only count for the exact sources they ran against: changed inputs invalidate the group.
        recorded = prev.get("group_inputs", {})
        for grp in GROUP_INPUTS:
            if recorded.get(grp) != inputs_sha(grp):
                groups_to_run.add(grp)
                log("inputs of group '%s' changed since its last run -> re-running" % grp)
        if "restart" in groups_to_run:
            groups_to_run.add("app")
        base_cases = [c for c in prev["cases"] if c["status"] != "fail"]
    os.makedirs(EVID, exist_ok=True)
    make_media()
    write_plugin()
    srv = start_server()
    log("fixture server %s" % Fx.base)
    CASES.extend(base_cases)
    try:
        run_all = groups_to_run is None
        ran = set()
        if run_all or "engine" in groups_to_run:
            group_engine()
            ran.add("engine")
        swift_groups = set() if run_all else {g for g in groups_to_run if g in ("proc", "pub", "health", "app", "restart")}
        if run_all or swift_groups or "swift" in groups_to_run or "post" in groups_to_run:
            if not run_all and not swift_groups:
                swift_groups = {"proc", "pub", "health", "app", "restart"}
            group_swift(set() if run_all else swift_groups)
            ran |= {"proc", "pub", "health", "app", "restart"} if run_all else swift_groups
            if "app" in ran:
                ran.add("restart")
        if run_all or "smoke" in groups_to_run:
            group_smoke()
        # a re-run replaces earlier results with the same id (failed ones were dropped from base_cases)
        seen = {}
        for c in CASES:
            seen[c["id"]] = c
        CASES[:] = list(seen.values())
        report_prev = dict(prev or {})
        report_prev["previous_failures"] = carried
        gi = dict((prev or {}).get("group_inputs", {}))
        for grp in ran:
            gi[grp] = inputs_sha(grp)
        report_prev["group_inputs"] = gi
        with Fx.lock:
            report_prev["server_stats"] = {"media_gets": dict(Fx.media_gets), "info_calls": dict(Fx.info_calls),
                                           "sub_gets": dict(Fx.sub_gets), "hls_gets": dict(Fx.hls_gets), "slow_aborted": Fx.slow_aborted}
        write_reports(mode, report_prev)
    finally:
        finish([srv])
    fails = [c for c in CASES if c["status"] == "fail"]
    log("RESULT: %d pass, %d fail, %d skipped" % (sum(1 for c in CASES if c["status"] == "pass"), len(fails), sum(1 for c in CASES if c["status"] == "skipped")))
    for c in fails:
        log("  FAIL %s :: %s" % (c["id"], c["detail"][:300]))
    return 0 if not fails else 1


def do_serve(port, minutes):
    make_media()
    write_plugin()
    srv = start_server(port)
    dest = os.path.join(VAL, "ui_session", "Downloads")
    support = os.path.join(VAL, "ui_session", "support")
    os.makedirs(dest, exist_ok=True)
    os.makedirs(support, exist_ok=True)
    app = os.path.join(ROOT, "dist", "HttpsDown.app", "Contents", "MacOS", "HttpsDown")
    print("Fixture server: %s (loopback only, stops in %d min or Ctrl-C)" % (Fx.base, minutes))
    print("Launch the app isolated (no real history/Downloads touched):")
    print("  HTTPSDOWN_APP_SUPPORT_DIR=%s HTTPSDOWN_DEFAULT_DESTINATION=%s XDG_CONFIG_HOME=%s %s" % (support, dest, XDG, app))
    print("Addresses to paste into the app:")
    for name in ("ok", "short_silent", "composite", "subs_ok", "subs_fail", "fake_gif", "fake_html", "trunc_complete", "chunked_ok",
                 "hls_vod", "hls_live", "sel_height", "slow", "secret"):
        print("  %s/page/%s" % (Fx.base, name))
    sys.stdout.flush()
    try:
        time.sleep(minutes * 60)
    except KeyboardInterrupt:
        pass
    srv.shutdown()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", nargs="?", choices=["serve"])
    ap.add_argument("--core", action="store_true")
    ap.add_argument("--failed", action="store_true")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--minutes", type=int, default=30)
    a = ap.parse_args()
    if a.mode == "serve":
        return do_serve(a.port, a.minutes)
    if a.core:
        return do_run("core")
    if a.failed:
        return do_run("failed")
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
