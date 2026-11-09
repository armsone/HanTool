"""
Final MP4 output for video downloads (engine.py) and live recording intervals (live.py).

Runs only after the source file already passed the selection, completeness and full-decode checks; it never changes
which format was downloaded. The verified source stays untouched in the work folder (never renamed, overwritten or
deleted); the MP4 is a new file written by an app-owned FFmpeg child in the engine's process group (app cancel =
SIGTERM to the group ends it too), reading only local files (`-protocol_whitelist file`).

  * already a real MP4 whose tracks are all MP4 codecs → kept as is
  * MP4 codecs in another container (mkv/webm/…) → remux with stream copy (no quality change)
  * a track whose codec MP4 cannot carry (VP9, VP8, Opus, Vorbis, unknown, …) → only that track is re-encoded:
    video → H.264 (libx264 CRF 18, 8-bit 4:2:0), audio → AAC 192 kbps. Announced in the progress text.

The result is accepted only when the new file matches the plan (MP4 container, same track counts, copied codecs
unchanged, converted tracks H.264/AAC, same dimensions, same duration within tolerance) and passes the engine's
usual structure/codec/full-decode verification.
"""

import copy
import json
import os
import re
import subprocess
import threading
import time

COPY_VIDEO = {"h264", "hevc", "av1"}
COPY_AUDIO = {"aac", "mp3", "ac3", "eac3", "alac", "flac"}
VIDEO_CRF, AUDIO_BITRATE = "18", "192k"
STALL_SECONDS = 300
_LABELS = {"h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "aac": "AAC", "opus": "Opus",
           "vorbis": "Vorbis", "mp3": "MP3", "ac3": "AC-3", "eac3": "E-AC-3", "flac": "FLAC", "alac": "ALAC"}


def _hms(seconds):
    s = int(max(0, seconds or 0))
    return f"{s // 3600:d}:{(s % 3600) // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def _label(stream):
    return _LABELS.get(stream.get("family")) or (str(stream.get("codec") or "알 수 없는 코덱")[:20])


def _fail(kind, reason):
    return {"ok": False, "kind": kind, "reason": reason}


def probe(api, path):
    """Local-only ffprobe. Returns {"format", "brand", "duration", "video", "audio"} or None."""
    try:
        p = api._run([api._tool("ffprobe"), "-v", "error", "-protocol_whitelist", "file", "-show_entries",
                      "format=format_name,duration:format_tags=major_brand:"
                      "stream=codec_type,codec_name,width,height:stream_disposition=attached_pic",
                      "-of", "json", "file:" + path], 60)
        if p.returncode != 0:
            return None
        data = json.loads(p.stdout)
    except Exception:
        return None
    fmt = data.get("format") or {}
    try:
        dur = float(fmt.get("duration")) if fmt.get("duration") not in (None, "N/A") else None
    except ValueError:
        dur = None
    out = {"format": set(str(fmt.get("format_name") or "").split(",")),
           "brand": str((fmt.get("tags") or {}).get("major_brand") or "").strip().lower(),
           "duration": dur, "video": [], "audio": []}
    for s in data.get("streams") or []:
        kind = s.get("codec_type")
        if kind == "video" and (s.get("disposition") or {}).get("attached_pic"):
            continue
        if kind in ("video", "audio"):
            out[kind].append({"codec": s.get("codec_name"), "family": api.codec_family(s.get("codec_name")),
                              "width": s.get("width"), "height": s.get("height")})
    return out


def _even(n):
    return int(n) // 2 * 2 if n else n


def _plan_mismatch(src, out, plan):
    if "mp4" not in out["format"]:
        return "결과 파일이 MP4 컨테이너가 아닙니다."
    if len(out["video"]) != len(plan["video"]) or len(out["audio"]) != len(plan["audio"]):
        return "MP4 결과의 영상/오디오 트랙 구성이 원본과 다릅니다."
    for s, o, act in zip(src["video"], out["video"], plan["video"]):
        if o["family"] != (s["family"] if act == "copy" else "h264"):
            return "MP4 결과의 영상 코덱이 변환 계획과 다릅니다."
        if s.get("width") and s.get("height"):
            sw, sh = int(s["width"]), int(s["height"])
            ow, oh = int(o.get("width") or 0), int(o.get("height") or 0)
            ok = (ow, oh) == (sw, sh) if act == "copy" else (ow, oh) in ((_even(sw), _even(sh)), (_even(sh), _even(sw)))
            if not ok:
                return f"MP4 결과의 해상도({ow}x{oh})가 원본({sw}x{sh})과 다릅니다."
    for s, o, act in zip(src["audio"], out["audio"], plan["audio"]):
        if o["family"] != (s["family"] if act == "copy" else "aac"):
            return "MP4 결과의 오디오 코덱이 변환 계획과 다릅니다."
    if src["duration"] and out["duration"] is not None:
        if abs(out["duration"] - src["duration"]) > max(2.0, src["duration"] * 0.02):
            return "MP4 결과의 재생 길이가 원본과 다릅니다."
    elif src["duration"]:
        return "MP4 결과의 재생 길이를 확인할 수 없습니다."
    return None


def _expected_after(expected, plan):
    """Selection intent for the MP4: converted tracks are now H.264/AAC; everything else is unchanged."""
    exp = copy.deepcopy(expected or {})

    def target(actions, new):
        if all(a == "copy" for a in actions):
            return "keep"
        return new if all(a != "copy" for a in actions) else None

    vt, at = target(plan["video"], "h264"), target(plan["audio"], "aac")
    for comp in exp.get("components") or []:
        for key, t in (("vcodec", vt), ("acodec", at)):
            if comp.get(key) in (None, "", "none") or t == "keep":
                continue
            if t is None:
                comp.pop(key, None)   # mixed per-track decisions: checked per track by _plan_mismatch instead
            else:
                comp[key] = t
    return exp


def _free_name(directory, stem, suffix):
    for n in range(100):
        tag = "" if n == 0 else (" (MP4)" if n == 1 else f" (MP4 {n})")
        path = os.path.join(directory, f"{stem}{tag}{suffix}")
        if not os.path.lexists(path):
            return path
    return None


def _has_encoders(api, need_video, need_audio):
    try:
        p = api._run([api._tool("ffmpeg"), "-hide_banner", "-v", "error", "-encoders"], 20)
    except Exception:
        return False
    text = p.stdout or ""
    return ((not need_video or re.search(r"^\s*V\S*\s+libx264\s", text, re.M) is not None)
            and (not need_audio or re.search(r"^\s*A\S*\s+aac\s", text, re.M) is not None))


def _run_ffmpeg(api, args, duration, timeout, report, describe):
    """Owned child in our process group. Returns (rc, None) or (None, reason) on timeout/stall."""
    env = {k: v for k, v in os.environ.items() if k.lower() not in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")}
    try:
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError:
        return None, "MP4 변환용 FFmpeg를 실행하지 못했습니다."
    st = {"pos": 0.0, "size": 0, "moved": time.time()}

    def read_progress(stream):
        for raw in iter(stream.readline, b""):
            k, _, v = raw.decode("utf-8", "replace").strip().partition("=")
            try:
                if k == "out_time_us" and int(v) / 1_000_000.0 > st["pos"]:
                    st["pos"], st["moved"] = int(v) / 1_000_000.0, time.time()
                elif k == "total_size" and int(v) > st["size"]:
                    st["size"], st["moved"] = int(v), time.time()
            except ValueError:
                pass

    def drain(stream):
        for _ in iter(stream.readline, b""):
            pass

    threads = [threading.Thread(target=read_progress, args=(proc.stdout,), daemon=True),
               threading.Thread(target=drain, args=(proc.stderr,), daemon=True)]
    for t in threads:
        t.start()
    started, last = time.time(), 0.0
    reason = None
    while True:
        try:
            rc = proc.wait(timeout=0.5)
            break
        except subprocess.TimeoutExpired:
            pass
        now = time.time()
        if now - started > timeout:
            reason = f"MP4 변환이 제한 시간({_hms(timeout)})을 넘어 중단했습니다."
        elif now - st["moved"] > STALL_SECONDS:
            reason = f"MP4 변환이 {STALL_SECONDS // 60}분 동안 진행되지 않아 중단했습니다."
        if reason:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            break
        if now - last >= 1.0:
            last = now
            elapsed = now - started
            pct = min(99.0, st["pos"] / duration * 100.0) if duration else None
            msg = f"{describe} · 경과 {_hms(elapsed)}"
            if pct is not None:
                msg += f" · {pct:.0f}%"
                if pct >= 2.0:
                    msg += f" · 남은 시간 약 {_hms(elapsed * (100.0 - pct) / pct)}"
            report("converting", pct, msg)
    for t in threads:
        t.join(5)
    return (None, reason) if reason else (rc, None)


def finalize(api, src_path, expected, root, report, deadline=None):
    """
    Make the final MP4 for an already verified video file.
    Returns {"ok": True, "path", "verified" (None = source kept as is), "note"} or {"ok": False, "kind", "reason"}.
    """
    keep = " 원본 파일은 작업 폴더에 그대로 보존됩니다."
    src = probe(api, src_path)
    if src is None:
        return _fail("failed", "MP4로 만들기 위해 원본 구조를 읽지 못했습니다." + keep)
    if not src["video"]:
        return _fail("failed", "영상 트랙을 찾지 못해 MP4로 만들 수 없습니다." + keep)
    plan = {"video": ["copy" if s["family"] in COPY_VIDEO else "h264" for s in src["video"]],
            "audio": ["copy" if s["family"] in COPY_AUDIO else "aac" for s in src["audio"]]}
    codecs = "/".join(_label(s) for s in src["video"] + src["audio"])
    all_copy = all(a == "copy" for a in plan["video"] + plan["audio"])
    if all_copy and src_path.lower().endswith(".mp4") and "mp4" in src["format"] and src["brand"] != "qt":
        return {"ok": True, "path": src_path, "verified": None, "note": f"원본이 이미 MP4({codecs})라 변환 없이 저장"}

    reencode_v = [f"영상 {_label(s)}→H.264" for s, a in zip(src["video"], plan["video"]) if a != "copy"]
    reencode_a = [f"오디오 {_label(s)}→AAC" for s, a in zip(src["audio"], plan["audio"]) if a != "copy"]
    reencode = reencode_v + reencode_a
    if reencode and not _has_encoders(api, bool(reencode_v), bool(reencode_a)):
        return _fail("failed", "이 FFmpeg에 H.264(libx264)/AAC 인코더가 없어 MP4와 호환되지 않는 코덱을 변환할 수 없습니다." + keep)

    directory = os.path.dirname(src_path)
    stem = os.path.splitext(os.path.basename(src_path))[0]
    tmp = _free_name(directory, stem, ".mp4.part")
    if not tmp:
        return _fail("failed", "MP4 결과 파일 이름을 정하지 못했습니다." + keep)

    ffmpeg = api._tool("ffmpeg")
    args = [ffmpeg, "-nostdin", "-hide_banner", "-nostats", "-v", "error", "-xerror", "-n",
            "-protocol_whitelist", "file", "-i", "file:" + src_path, "-map", "0:V"]
    if src["audio"]:
        args += ["-map", "0:a"]
    for i, act in enumerate(plan["video"]):
        if act == "copy":
            args += [f"-c:v:{i}", "copy"]
        else:
            args += [f"-c:v:{i}", "libx264", f"-preset:v:{i}", "veryfast", f"-crf:v:{i}", VIDEO_CRF,
                     f"-pix_fmt:v:{i}", "yuv420p", f"-fps_mode:v:{i}", "vfr",
                     f"-filter:v:{i}", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
    for i, act in enumerate(plan["audio"]):
        args += [f"-c:a:{i}", "copy"] if act == "copy" else [f"-c:a:{i}", "aac", f"-b:a:{i}", AUDIO_BITRATE]
    args += ["-max_muxing_queue_size", "4096", "-f", "mp4", "-progress", "pipe:1", "file:" + tmp]

    size = os.path.getsize(src_path)
    dur = src["duration"] or 0.0
    if reencode:
        timeout = 900 + max(dur * 6, size / (256 * 1024))
        describe = ("MP4 변환 중: " + ", ".join(reencode) + " 재인코딩(원본 코덱은 MP4에 담을 수 없음, "
                    "영상 길이에 따라 오래 걸릴 수 있음)")
    else:
        timeout = 600 + size / (8 * 1024 * 1024)
        describe = "MP4로 옮겨 담는 중(스트림 복사, 화질 변화 없음)"
    if deadline is not None:
        timeout = min(timeout, deadline - time.time())
        if timeout < 60:
            return _fail("incomplete", "MP4 변환에 쓸 시간이 남지 않아 변환하지 못했습니다." + keep)
    report("converting", 0.0, describe + " · 시작")
    rc, why = _run_ffmpeg(api, args, dur, timeout, report, describe)
    if why:
        return _fail("incomplete", why + keep)
    if rc != 0:
        return _fail("failed", f"MP4 변환 중 FFmpeg 오류가 발생했습니다(종료 코드 {rc})." + keep)
    ok, why = api.owned_regular(tmp, root)
    if not ok:
        return _fail("failed", why)

    final = _free_name(directory, stem, ".mp4")
    try:
        if not final:
            raise OSError
        os.link(tmp, final)   # never replaces an existing name
        os.unlink(tmp)
    except OSError:
        return _fail("failed", "MP4 결과 파일을 최종 이름으로 옮기지 못했습니다." + keep)

    report("verifying", None, "MP4 결과 파일의 트랙 구성, 코덱, 해상도, 길이와 전체 디코딩을 검증하는 중...")
    out = probe(api, final)
    if out is None:
        return _fail("failed", "MP4 결과 파일 구조를 읽지 못했습니다." + keep)
    why = _plan_mismatch(src, out, plan)
    if why:
        return _fail("failed", why + keep)
    v = api.verify_media_file(final, _expected_after(expected, plan), root)
    if not v.get("ok"):
        return _fail(v.get("kind") or "failed", (v.get("reason") or "MP4 결과 검증에 실패했습니다.") + keep)
    if reencode:
        note = (f"MP4 변환: {', '.join(reencode)} 재인코딩(원본 코덱이 MP4와 호환되지 않음"
                + (f", H.264 CRF {VIDEO_CRF}" if reencode_v else "")
                + (f", AAC {AUDIO_BITRATE}bps" if reencode_a else "") + ")"
                + (", 나머지 트랙은 스트림 복사" if not all(a != "copy" for a in plan["video"] + plan["audio"]) else ""))
    else:
        note = f"MP4로 재포장({codecs} 스트림 복사, 화질·음질 변화 없음)"
    return {"ok": True, "path": final, "verified": v, "note": note}
