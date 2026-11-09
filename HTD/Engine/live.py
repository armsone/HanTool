"""
HttpsDown live stream recording ("녹화") on top of yt-dlp extraction and FFmpeg's own HLS/DASH demuxers.

`engine.py record` → run_record(). No new stream parser: yt-dlp resolves the approved live format(s); an app-owned
FFmpeg child (same process group) copies the streams into a work-folder file (mp4 when every codec fits MP4, else an
mkv interim). After a graceful finish and the usual checks/verification, a video capture becomes the final real MP4
through mp4.finalize (remux, or H.264/AAC only for tracks MP4 cannot carry); the interim file is kept.

Stop semantics:
  * graceful finish ("녹화 마치고 저장"): the app sends SIGUSR1 to the engine leader only; we write "q" to FFmpeg's
    stdin so it flushes and writes the container trailer, then the captured portion is verified like any download
  * time limit: FFmpeg `-t` ends the output cleanly at the chosen duration
  * a non-zero FFmpeg exit is accepted only as the expected answer to that finish request: "q" was actually
    written to our own FFmpeg child, it exited by itself within the grace period with status 255 or while
    reporting only the interrupt, no fetch/skip error and no error-level log line was seen, media was captured,
    and the file then passes the usual local verification
  * cancel: the app SIGTERMs the whole group; nothing is reported as success
  * anything else (FFmpeg error, other non-zero exits, segment fetch errors, segments skipped because they expired
    from the live playlist, the stream stopping on its own without a server-side end marker) is NOT a completed
    recording.

The source address is only handed to the owned FFmpeg child (argv is unavoidable for FFmpeg inputs); it never
appears in events. Cookies/headers for the selected format stay in this process and that child.
"""

import os
import re
import subprocess
import threading
import time

SEGMENT_ERROR_MARKERS = (
    "failed to open segment", "failed to reload playlist", "http error", "server returned 4", "server returned 5",
    "error in the pull function", "connection reset", "connection refused", "i/o error", "input/output error",
    "operation timed out", "end of file while", "unable to open resource", "keepalive request failed",
    "error opening input", "invalid data found when processing input", "will reconnect",
    # segments that left the live window before they were fetched = a gap in the middle of the capture
    "expired from playlist", "segments ahead", "expired fragment",
)
# What FFmpeg prints while honouring our "q" finish request (only counted after "q" was actually written).
INTERRUPT_MARKERS = ("immediate exit requested", "exit requested", "[q] command received")
FATAL_LEVEL_TAGS = ("[error]", "[fatal]", "[panic]")
# FFmpeg's exit status when it stops on an interrupt request instead of reaching the end of input.
EXPECTED_FINISH_RC = (255,)
MP4_FAMILIES = {"h264", "hevc", "av1", "aac", "mp3", "ac3", "eac3", "alac", "flac"}
MAX_LIMIT = 12 * 3600


def _fmt_hms(seconds):
    s = int(max(0, seconds or 0))
    return f"{s // 3600:d}:{(s % 3600) // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def _convert_deadline(limit):
    """
    Seconds after engine start by which MP4 conversion must end. The app's hard bound for a recording run is
    (limit * 7 + 3000) + 900 s (AppModel → EngineBridge.startRecording); 1000 s stay reserved for the final MP4
    verification, so the engine reports its own clear outcome before the app would kill the group.
    """
    return limit * 7 + 2900


def _container(api, fmts):
    fams = []
    for f in fmts:
        for key in ("vcodec", "acodec"):
            v = f.get(key)
            if v in (None, ""):
                return "mkv"
            if v == "none":
                continue
            fam = api.codec_family(v)
            if not fam:
                return "mkv"
            fams.append(fam)
    return "mp4" if fams and all(f in MP4_FAMILIES for f in fams) else "mkv"


def _stream_ended(api, ydl, fmt):
    """Positive server-side end evidence only: HLS #EXT-X-ENDLIST or a DASH manifest that turned static."""
    proto = str(fmt.get("protocol") or "")
    url = fmt.get("manifest_url") if proto.startswith("http_dash") else fmt.get("url")
    if not url:
        return False
    try:
        with ydl.urlopen(url) as resp:
            body = resp.read(4 * 1024 * 1024).decode("utf-8", "replace")
    except Exception:
        return False
    if proto.startswith("m3u8"):
        return "#EXT-X-ENDLIST" in body
    if proto.startswith("http_dash"):
        return re.search(r"<MPD[^>]*\btype\s*=\s*[\"']static[\"']", body) is not None
    return False


def run_record(api, job_id, generation, request):
    emit = lambda ev, p: api.emit_event(job_id, generation, ev, p)  # noqa: E731
    engine_started = time.time()
    url = request.get("url") or ""
    spec = request.get("spec") or {}
    ctx = request.get("context") or {}
    output_dir = spec.get("outputDir") or ""
    if not url or not output_dir or not os.path.isdir(output_dir) or os.path.islink(output_dir):
        api.emit_error(job_id, generation, "bad_request", "유효한 작업 폴더 또는 주소가 지정되지 않았습니다.")
        return 1
    output_dir = os.path.realpath(output_dir)
    try:
        limit = int(spec.get("limitSeconds") or 1800)
    except (TypeError, ValueError):
        limit = 1800
    limit = max(10, min(limit, MAX_LIMIT))
    expected = spec.get("expected") or {}
    exp_components = {str(c.get("formatId")): c for c in (expected.get("components") or []) if c.get("formatId")}
    if not exp_components:
        api.emit_error(job_id, generation, "bad_request", "녹화할 형식이 지정되지 않았습니다.")
        return 1

    err = api.context_problem(url, ctx)
    if err:
        api.emit_error(job_id, generation, err[0], err[1])
        return 1

    try:
        import yt_dlp
    except ImportError:
        api.emit_error(job_id, generation, "engine_missing", "yt-dlp 모듈을 찾을 수 없습니다.")
        return 1

    emit("progress", {"phase": "extracting", "message": "실시간 방송 정보를 확인하는 중..."})
    logger = api.QuietLogger()
    opts = {
        "quiet": True, "no_warnings": True, "logger": logger, "noplaylist": True, "cachedir": False,
        "socket_timeout": 20, "retries": 0, "extractor_retries": 0, "skip_download": True,
        "format": spec.get("formatId") or "+".join(exp_components),
    }
    api.apply_context_opts(opts, ctx)
    try:
        ydl = yt_dlp.YoutubeDL(opts)
    except Exception as e:
        api.emit_error(job_id, generation, "engine_exception", "엔진을 준비하지 못했습니다.", type(e).__name__)
        return 1
    with ydl:
        try:
            api.apply_context_cookies(ydl, ctx, url)
        except ValueError as e:
            api.emit_error(job_id, generation, "session_mismatch", str(e))
            return 1
        try:
            info = ydl.extract_info(url, download=False)
        except Exception as e:
            text = (logger.last_error or str(e)).lower()
            if "requested format is not available" in text:
                emit("selectionChanged", {"reason": "선택한 방송 화질이 지금은 제공되지 않습니다. 다시 분석해 주세요."})
                return 0
            api.emit_error(job_id, generation, "extract_failed", "실시간 방송 정보를 가져오지 못했습니다.",
                           logger.last_error or str(e))
            return 1
        if not info:
            api.emit_error(job_id, generation, "extract_empty", "실시간 방송 정보를 가져오지 못했습니다.")
            return 1

        if expected.get("extractor") and str(info.get("extractor_key") or "").lower() != str(expected["extractor"]).lower():
            emit("selectionChanged", {"reason": "원본 사이트 정보(추출기)가 선택 시점과 다릅니다."})
            return 0
        if expected.get("mediaId") and str(info.get("id") or "") != str(expected["mediaId"]):
            emit("selectionChanged", {"reason": "원본 방송 식별자가 선택 시점과 다릅니다."})
            return 0
        if not info.get("is_live"):
            emit("selectionChanged", {"reason": "지금은 실시간 방송이 아닙니다(방송이 끝났거나 아직 시작하지 않음). 다시 분석해 주세요."})
            return 0

        fmts = list(info.get("requested_formats") or ([info] if info.get("format_id") else []))
        actual = {str(f.get("format_id")): f for f in fmts}
        if set(actual) != set(exp_components):
            emit("selectionChanged", {"reason": "서버가 제공한 방송 형식 구성이 선택한 구성과 다릅니다."})
            return 0
        for fid, exp in exp_components.items():
            act = actual[fid]
            for key, label in (("height", "해상도"), ("vcodec", "영상 코덱"), ("acodec", "오디오 코덱")):
                if exp.get(key) is not None and act.get(key) is not None and str(exp[key]) != str(act[key]):
                    emit("selectionChanged", {"reason": f"방송 {label}이(가) 선택 시점과 다릅니다."})
                    return 0
            if any(f.get("has_drm") for f in fmts):
                api.emit_error(job_id, generation, "drm", "DRM으로 보호된 방송이라 녹화할 수 없습니다.")
                return 1
            proto = str(act.get("protocol") or "")
            if not (proto.startswith("m3u8") or proto == "http_dash_segments"):
                api.emit_error(job_id, generation, "live_protocol",
                               "이 방송의 전송 방식은 녹화를 지원하지 않습니다 (HLS/DASH 실시간 방송만 지원).")
                return 1

        if api.STOP_EVENT.is_set():
            api.emit_error(job_id, generation, "record_empty", "녹화가 시작되기 전에 종료되어 저장할 구간이 없습니다.")
            return 1

        ffmpeg = api._tool("ffmpeg")
        if not os.path.isfile(ffmpeg):
            api.emit_error(job_id, generation, "engine_missing", "FFmpeg를 찾을 수 없습니다.")
            return 1

        ext = _container(api, fmts)
        from yt_dlp.utils import sanitize_filename
        stem = sanitize_filename(str(info.get("title") or "live"), restricted=False)[:100].strip() or "live"
        stem = f"{stem} (녹화 {time.strftime('%Y-%m-%d %H%M')})"
        out_path = os.path.join(output_dir, f"{stem}.{ext}")

        args = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "level+warning", "-n"]
        multi = len(fmts) > 1
        for f in fmts:
            furl = str(f.get("url") or "")
            if not re.match(r"^https?://", furl):
                api.emit_error(job_id, generation, "live_protocol", "방송 주소 형식을 녹화할 수 없습니다.")
                return 1
            if ctx.get("proxy") and furl.startswith("http://"):
                api.emit_error(job_id, generation, "assist_http_unsupported",
                               "연결 도움을 켠 상태에서는 암호화되지 않은 http:// 방송을 녹화할 수 없습니다.")
                return 1
            headers = dict(f.get("http_headers") or info.get("http_headers") or {})
            cookie = ydl.cookiejar.get_cookie_header(furl)
            if cookie:
                headers["Cookie"] = cookie
            headers = {k: v for k, v in headers.items() if "\r" not in f"{k}{v}" and "\n" not in f"{k}{v}"}
            if headers:
                args += ["-headers", "".join(f"{k}: {v}\r\n" for k, v in headers.items())]
            args += ["-protocol_whitelist", "http,https,tcp,tls,crypto,httpproxy,data", "-rw_timeout", "20000000"]
            if str(f.get("protocol")) == "http_dash_segments":
                args += ["-re"]
            args += ["-i", furl]
        if multi or any(str(f.get("protocol")) == "http_dash_segments" for f in fmts):
            for i, f in enumerate(fmts):
                args += ["-map", f"{i}:{int(f.get('manifest_stream_number') or 0)}"]
        args += ["-c", "copy", "-t", str(limit), "-f", "mp4" if ext == "mp4" else "matroska",
                 "-progress", "pipe:1", out_path]

        env = dict(os.environ)
        for k in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY", "all_proxy", "ALL_PROXY"):
            env.pop(k, None)
        if ctx.get("proxy"):
            env["http_proxy"] = ctx["proxy"]   # FFmpeg tls → httpproxy CONNECT with Basic credentials

        state = {"seconds": 0.0, "bytes": 0, "seg_errors": 0, "last_error": "", "ended": False,
                 "q_sent": False, "q_delivered": False, "interrupt_notes": 0, "fatal": 0}

        def read_progress(stream):
            last = 0.0
            for raw in iter(stream.readline, b""):
                line = raw.decode("utf-8", "replace").strip()
                k, _, v = line.partition("=")
                try:
                    if k == "out_time_us":
                        state["seconds"] = max(state["seconds"], int(v) / 1_000_000.0)
                    elif k == "total_size":
                        state["bytes"] = max(state["bytes"], int(v))
                except ValueError:
                    pass
                if k == "progress":
                    now = time.time()
                    if now - last >= 1.0 or v == "end":
                        last = now
                        emit("progress", {"phase": "recording", "recordedSeconds": round(state["seconds"], 1),
                                          "downloadedBytes": int(state["bytes"]), "limitSeconds": limit,
                                          "percent": round(min(100.0, state["seconds"] / limit * 100.0), 2),
                                          "message": f"녹화 중 {_fmt_hms(state['seconds'])} / 최대 {_fmt_hms(limit)}"})

        def read_errors(stream):
            for raw in iter(stream.readline, b""):
                low = raw.decode("utf-8", "replace").lower()
                if any(m in low for m in SEGMENT_ERROR_MARKERS):
                    state["seg_errors"] += 1
                    state["last_error"] = api.redact(low, 160)
                elif state["q_sent"] and any(m in low for m in INTERRUPT_MARKERS):
                    state["interrupt_notes"] += 1
                elif any(t in low for t in FATAL_LEVEL_TAGS):
                    state["fatal"] += 1
                    state["last_error"] = api.redact(low, 160)

        emit("progress", {"phase": "recording", "recordedSeconds": 0, "downloadedBytes": 0, "limitSeconds": limit,
                          "percent": 0.0, "message": "녹화를 시작합니다..."})
        try:
            proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        except OSError:
            api.emit_error(job_id, generation, "ffmpeg_start", "FFmpeg를 실행하지 못했습니다.")
            return 1
        t_out = threading.Thread(target=read_progress, args=(proc.stdout,), daemon=True)
        t_err = threading.Thread(target=read_errors, args=(proc.stderr,), daemon=True)
        t_out.start()
        t_err.start()

        started = time.time()
        stop_reason = None
        q_sent_at = None
        forced = False
        while True:
            try:
                rc = proc.wait(timeout=0.5)
                break
            except subprocess.TimeoutExpired:
                pass
            if q_sent_at is None and (api.STOP_EVENT.is_set() or time.time() - started > limit + 120):
                stop_reason = "user" if api.STOP_EVENT.is_set() else "limit"
                q_sent_at = time.time()
                emit("processing", {"message": "녹화를 마무리하고 파일을 정리하는 중..."})
                state["q_sent"] = True
                try:
                    proc.stdin.write(b"q")
                    proc.stdin.flush()
                    state["q_delivered"] = True
                    proc.stdin.close()
                except OSError:
                    pass
            elif q_sent_at is not None and time.time() - q_sent_at > 30:
                forced = True
                proc.terminate()
                try:
                    rc = proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    rc = proc.wait()
                break
        t_out.join(5)
        t_err.join(5)
        recorded = state["seconds"]

        if forced:
            emit("verificationFailed", {"reason": "녹화를 정상적으로 마무리하지 못해 파일이 온전하지 않을 수 있어 저장하지 않았습니다."})
            return 0
        # The one accepted non-zero outcome: FFmpeg's own answer to the finish request we delivered (see module doc).
        expected_finish = (rc > 0 and stop_reason in ("user", "limit") and state["q_delivered"]
                           and state["seg_errors"] == 0 and state["fatal"] == 0
                           and (rc in EXPECTED_FINISH_RC or state["interrupt_notes"] > 0))
        if rc != 0 and not expected_finish:
            api.emit_error(job_id, generation, "record_failed", "녹화 중 오류가 발생해 저장하지 않았습니다.",
                           state["last_error"] or f"FFmpeg 종료 코드 {rc}")
            return 1
        if not os.path.exists(out_path) or recorded <= 0:
            api.emit_error(job_id, generation, "record_empty", "녹화된 구간이 없습니다.")
            return 1

        if stop_reason is None:
            if recorded >= limit - 1.5:
                stop_reason = "limit"
            elif all(_stream_ended(api, ydl, f) for f in fmts):
                stop_reason = "ended"
            else:
                emit("verificationIncomplete", {
                    "reason": "방송 연결이 예기치 않게 끊겨 녹화가 끝까지 정상적으로 이루어졌는지 확인할 수 없어 저장하지 않았습니다. "
                              "받은 파일은 작업 폴더에 보존됩니다."})
                return 0
        if state["seg_errors"]:
            emit("verificationIncomplete", {
                "reason": f"녹화 중 방송 조각을 받지 못했거나 건너뛴 기록이 {state['seg_errors']}건 있어 중간이 빠졌을 수 있으므로 저장하지 않았습니다."})
            return 0

    emit("progress", {"phase": "verifying", "message": "녹화 파일의 구조와 전체 디코딩을 검증하는 중..."})
    v = api.verify_media_file(out_path, expected, output_dir)
    if not v.get("ok"):
        emit("verificationIncomplete" if v.get("kind") == "incomplete" else "verificationFailed", {"reason": v.get("reason")})
        return 0
    final_path, mp4_note = os.path.abspath(out_path), ""
    if v.get("hasVideo") and expected.get("intent") != "audio":
        # The verified capture (mp4 or the mkv interim container) becomes the final real MP4 (see mp4.py).
        import mp4
        r = mp4.finalize(api, final_path, expected, output_dir, api.conversion_reporter(job_id, generation),
                         deadline=engine_started + _convert_deadline(limit))
        if not r["ok"]:
            emit("verificationIncomplete" if r["kind"] == "incomplete" else "verificationFailed", {"reason": r["reason"]})
            return 0
        v, final_path, mp4_note = r["verified"] or v, r["path"], f" · {r['note']}"
    label = {"user": "사용자가 녹화를 마침", "limit": "정한 녹화 시간 도달", "ended": "방송이 종료됨"}[stop_reason]
    duration = v.get("duration") or recorded
    finish = f"FFmpeg 마무리 요청 처리(종료 코드 {rc})" if rc != 0 else "FFmpeg 정상 마무리"
    basis = (f"실시간 방송 녹화 구간 {_fmt_hms(duration)} ({label}) · {finish} · 조각 수신·건너뜀 오류 없음{mp4_note}. "
             "원본 방송 전체가 아니라 녹화한 구간입니다.")
    emit("verified", {
        "primary": dict(v, path=final_path, completeness=basis),
        "recording": {"seconds": float(duration), "endReason": stop_reason, "limitSeconds": limit},
        "subtitles": [], "subtitlesFailed": False, "subtitleError": None,
    })
    return 0
