#!/usr/bin/env python3
"""
Portable arm64 engine builder for HTT (standard PyInstaller onedir; no hand-written dylib bundling or rpath rewriting).

Run it with the prepared virtualenv's Python (it needs PyInstaller + yt-dlp[default] there); dev.py only imports
`verify_artifact` from here and needs the standard library alone.

  <venv>/bin/python scripts/build_portable_engine.py [--target-macos 15.4] [--ffmpeg P] [--ffprobe P] [--deno P]
      -> .build/portable-engine/EngineRuntime/{htd-engine,_internal/...} + portable-manifest.json + licenses/
  /usr/bin/python3 scripts/build_portable_engine.py --package-only --app dist/HTT.app --public-doc A B C D
      -> .build/handoff/HTT-handoff/ and HTT-handoff.zip (copies only; nothing is executed)

Only .build/portable-engine/{stage,EngineRuntime} and a fresh handoff folder are ever written or removed.
"""

import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ENGINE_DIR = os.path.join(ROOT, "Engine")
COLLECTOR_DIR = os.path.join(ROOT, "tools", "evidence-collector")
BUILD_DIR = os.path.join(ROOT, ".build")
OUT_DIR = os.path.join(BUILD_DIR, "portable-engine")
STAGE_DIR = os.path.join(OUT_DIR, "stage")
RUNTIME_DIR = os.path.join(OUT_DIR, "EngineRuntime")
ENGINE_NAME = "htd-engine"
MANIFEST_NAME = "portable-manifest.json"
TOOLS = ("ffmpeg", "ffprobe", "deno")
MIN_PYINSTALLER = (6, 21)

ENGINE_MODULES = ("engine", "fragments", "keys", "connection", "session", "live", "mp4", "speed", "discovery", "progressive")
SOURCE_FILES = tuple(
    [os.path.join("Engine", m + ".py") for m in ENGINE_MODULES]
    + [os.path.join("Engine", "portable_entry.py"), os.path.join("Engine", "keydecode.mjs"),
       os.path.join("tools", "evidence-collector", "collector.py")])

LICENSE_DISTRIBUTIONS = ("yt-dlp", "yt-dlp-ejs", "pycryptodomex", "pyinstaller", "pyinstaller-hooks-contrib", "brotli",
                         "brotlicffi", "certifi", "mutagen", "requests", "urllib3", "websockets", "idna",
                         "charset-normalizer")
SOURCE_URLS = {
    "yt-dlp": "https://github.com/yt-dlp/yt-dlp",
    "yt-dlp-ejs": "https://github.com/yt-dlp/ejs",
    "CPython": "https://github.com/python/cpython",
    "PyInstaller": "https://github.com/pyinstaller/pyinstaller",
    "FFmpeg": "https://ffmpeg.org/download.html",
    "Deno": "https://github.com/denoland/deno",
    "PyCryptodome": "https://github.com/Legrandin/pycryptodome",
}

PUBLIC_DOC_EXTENSIONS = (".html", ".json", ".csv", ".md", ".txt")


def fail(message):
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def source_hashes():
    out = {}
    for rel in SOURCE_FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            fail(f"source file missing: {rel}")
        out[rel.replace(os.sep, "/")] = sha256_file(path)
    return out


def version_tuple(text):
    parts = re.findall(r"\d+", str(text))
    return tuple(int(p) for p in parts[:3]) if parts else ()


def numeric_version(text):
    m = re.search(r"\d{1,4}(?:\.\d{1,4}){1,3}", str(text or ""))
    return m.group(0) if m else None


def run_text(cmd, timeout=60):
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True, errors="replace", timeout=timeout)
    return p.returncode, p.stdout


# ----------------------------------------------------------------------------
# Mach-O audit (standard otool/lipo): nothing may require a newer macOS than the explicit target
# ----------------------------------------------------------------------------

def is_macho(path):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return False
    if len(head) < 8:
        return False
    if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        return True
    if head[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        return int.from_bytes(head[4:8], "big") <= 8   # a Java class file shares the magic but has a large count
    return False


def macho_files(root):
    found = []
    for dirpath, _dirs, files in os.walk(root, followlinks=False):
        for name in files:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path) and is_macho(path):
                found.append(path)
    return sorted(found)


def macho_minos(path):
    """Highest macOS minimum version declared by a Mach-O file (all slices), as a tuple, or None."""
    code, out = run_text(["/usr/bin/otool", "-l", path])
    if code != 0:
        fail(f"otool -l failed for a Mach-O file ({os.path.basename(path)})")
    cmd, best = None, None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("cmd "):
            cmd = s.split()[1]
        elif (cmd == "LC_BUILD_VERSION" and s.startswith("minos ")) or \
                (cmd == "LC_VERSION_MIN_MACOSX" and s.startswith("version ")):
            v = version_tuple(s.split()[1])
            best = v if best is None or v > best else best
    return best


def has_arm64(path):
    code, out = run_text(["/usr/bin/lipo", "-archs", path])
    return code == 0 and "arm64" in out.split()


def audit_macho(paths, target, label):
    """Returns (files audited, highest minos tuple). Exits when one needs a newer macOS or lacks arm64."""
    highest = ()
    problems = []
    for path in paths:
        if not has_arm64(path):
            problems.append(f"no arm64 slice: {os.path.basename(path)}")
            continue
        v = macho_minos(path)
        if v and v > target:
            problems.append(f"minos {'.'.join(map(str, v))} > target {'.'.join(map(str, target))}: {os.path.basename(path)}")
        if v and v > highest:
            highest = v
    if problems:
        fail(f"{label} Mach-O audit failed:\n  " + "\n  ".join(problems[:20]))
    print(f"{label} Mach-O audit: {len(paths)} files, highest minos {'.'.join(map(str, highest)) or 'n/a'}")
    return len(paths), highest


# ----------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------

def resolve_tool(name, explicit):
    path = explicit or shutil.which(name)
    if not path:
        fail(f"tool not found: {name} (pass --{name} PATH)")
    path = os.path.realpath(path)
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        fail(f"tool is not an executable file: {name}")
    return path


def require_modules():
    for mod in ("PyInstaller", "yt_dlp", "yt_dlp_ejs", "Cryptodome"):
        if importlib.util.find_spec(mod) is None:
            fail(f"python module missing in this interpreter: {mod} (use the prepared portable-engine venv)")
    import PyInstaller
    if version_tuple(PyInstaller.__version__)[:2] < MIN_PYINSTALLER:
        fail(f"PyInstaller {PyInstaller.__version__} is older than {'.'.join(map(str, MIN_PYINSTALLER))}")
    from yt_dlp.version import __version__ as ytdlp_version
    return PyInstaller.__version__, ytdlp_version


def tool_info(path, name):
    flag = "--version" if name == "deno" else "-version"
    code, out = run_text([path, flag])
    return out if code == 0 else ""


def first_line(text):
    lines = (text or "").strip().splitlines()
    return lines[0] if lines else ""


def own_tree(path):
    real = os.path.realpath(path)
    if not real.startswith(os.path.realpath(OUT_DIR) + os.sep):
        fail("refusing to touch a path outside the portable-engine build folder")
    return real


def run_pyinstaller(tools, epoch):
    stage = own_tree(STAGE_DIR)
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    cmd = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--log-level", "WARN",
           "--onedir", "--name", ENGINE_NAME, "--target-arch", "arm64", "--contents-directory", "_internal",
           "--distpath", os.path.join(stage, "dist"), "--workpath", os.path.join(stage, "work"),
           "--specpath", os.path.join(stage, "spec"),
           "--paths", ENGINE_DIR, "--paths", COLLECTOR_DIR,
           "--collect-all", "yt_dlp", "--collect-all", "yt_dlp_ejs", "--collect-all", "Cryptodome",
           "--collect-all", "certifi"]
    for module in ENGINE_MODULES + ("collector",):
        cmd += ["--hidden-import", module]
    for name in TOOLS:
        cmd += ["--add-binary", f"{tools[name]}:tools"]
    cmd += ["--add-data", f"{os.path.join(ENGINE_DIR, 'keydecode.mjs')}:.",
            os.path.join(ENGINE_DIR, "portable_entry.py")]
    env = dict(os.environ, PYINSTALLER_CONFIG_DIR=os.path.join(stage, "config"), SOURCE_DATE_EPOCH=str(epoch))
    print("==> PyInstaller onedir arm64 (ad-hoc signing by PyInstaller only)")
    res = subprocess.run(cmd, cwd=stage, env=env)
    if res.returncode != 0:
        fail(f"PyInstaller failed with exit code {res.returncode}")
    built = os.path.join(stage, "dist", ENGINE_NAME)
    if not os.path.isfile(os.path.join(built, ENGINE_NAME)):
        fail("PyInstaller produced no executable")
    return built


def tree_stats(root):
    """File count and bytes of the runtime, excluding the manifest itself (build and verify count the same set)."""
    count, size = 0, 0
    for dirpath, _dirs, files in os.walk(root, followlinks=False):
        for name in files:
            if dirpath == root and name == MANIFEST_NAME:
                continue
            path = os.path.join(dirpath, name)
            count += 1
            if not os.path.islink(path):
                size += os.path.getsize(path)
    return count, size


def copy_licenses(dest):
    """Official license/notice files that ship inside the installed distributions (where available)."""
    pattern = re.compile(r"(?i)^(licen[cs]e|copying|notice)[^/]*$")
    copied = {}
    for dist_name in LICENSE_DISTRIBUTIONS:
        try:
            dist = importlib.metadata.distribution(dist_name)
        except importlib.metadata.PackageNotFoundError:
            continue
        for f in dist.files or []:
            base = os.path.basename(str(f))
            src = str(dist.locate_file(f))
            if not pattern.match(base) or not os.path.isfile(src) or os.path.getsize(src) > (1 << 20):
                continue
            target_dir = os.path.join(dest, dist_name)
            os.makedirs(target_dir, exist_ok=True)
            target = os.path.join(target_dir, base)
            n = 1
            while os.path.exists(target):
                n += 1
                target = os.path.join(target_dir, f"{n}-{base}")
            shutil.copyfile(src, target)
            copied.setdefault(dist_name, []).append(os.path.basename(target))
    return copied


def build(args):
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        fail("the portable engine is built on Apple Silicon macOS only")
    target = version_tuple(args.target_macos)
    if len(target) < 1 or target[0] < 11:
        fail("--target-macos must be an explicit macOS version such as 27.0")
    pyinstaller_version, ytdlp_version = require_modules()
    tools = {name: resolve_tool(name, getattr(args, name)) for name in TOOLS}

    ffmpeg_text = tool_info(tools["ffmpeg"], "ffmpeg")
    if "--enable-nonfree" in ffmpeg_text:
        fail("this FFmpeg is a nonfree build and must not be packaged")
    ffmpeg_flags = {"enableGpl": "--enable-gpl" in ffmpeg_text, "enableVersion3": "--enable-version3" in ffmpeg_text}

    audit_macho(list(tools.values()), target, "pre-build")

    before = source_hashes()
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH") or max(int(os.path.getmtime(os.path.join(ROOT, r))) for r in SOURCE_FILES))
    built = run_pyinstaller(tools, epoch)
    if source_hashes() != before:
        fail("engine sources changed while freezing; the artifact is stale. Run the build again.")

    audited, highest = audit_macho(macho_files(built), target, "post-build")

    runtime = own_tree(RUNTIME_DIR)
    if os.path.isdir(runtime):
        shutil.rmtree(runtime)
    os.makedirs(runtime)
    shutil.rmtree(runtime)
    shutil.copytree(built, runtime, symlinks=True)   # the PyInstaller dist folder itself becomes EngineRuntime
    licenses = copy_licenses(os.path.join(runtime, "licenses"))

    files, size = tree_stats(runtime)
    bundled_tools = os.path.join(runtime, "_internal", "tools")
    manifest = {
        "schema": 1,
        "product": ENGINE_NAME,
        "arch": "arm64",
        "targetMacOS": ".".join(map(str, target)),
        "machoMaxMinOS": ".".join(map(str, highest)) or None,
        "machoFilesAudited": audited,
        "versions": {
            "python": ".".join(map(str, sys.version_info[:3])),
            "yt-dlp": numeric_version(ytdlp_version),
            "pyinstaller": numeric_version(pyinstaller_version),
            "ffmpeg": numeric_version(first_line(ffmpeg_text)),
            "ffprobe": numeric_version(first_line(tool_info(tools["ffprobe"], "ffprobe"))),
            "deno": numeric_version(first_line(tool_info(tools["deno"], "deno"))),
        },
        "ffmpegBuild": ffmpeg_flags,
        "sources": before,
        "tools": {name: sha256_file(os.path.join(bundled_tools, name)) for name in TOOLS},
        "executableSha256": sha256_file(os.path.join(runtime, ENGINE_NAME)),
        "files": files,
        "bytes": size,
        "licenseFiles": licenses,
        "sourceUrls": SOURCE_URLS,
    }
    with open(os.path.join(runtime, MANIFEST_NAME), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"Portable engine ready: {runtime}")
    print("Next: /usr/bin/python3 scripts/dev.py build --portable")


# ----------------------------------------------------------------------------
# Artifact verification (used by dev.py before it copies anything)
# ----------------------------------------------------------------------------

def verify_artifact(runtime=RUNTIME_DIR):
    """List of problems with the built runtime (empty = it matches the current sources and recorded hashes)."""
    problems = []
    manifest_path = os.path.join(runtime, MANIFEST_NAME)
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError):
        return [f"artifact manifest missing or unreadable: {MANIFEST_NAME}"]
    if manifest.get("schema") != 1 or manifest.get("arch") != "arm64":
        problems.append("manifest schema/arch mismatch")
    target = version_tuple(manifest.get("targetMacOS") or "")
    highest = version_tuple(manifest.get("machoMaxMinOS") or "")
    if not target or (highest and highest > target):
        problems.append("manifest minimum-macOS audit is missing or exceeds its target")
    try:
        current = source_hashes()
    except SystemExit:
        return problems + ["engine source file missing"]
    if manifest.get("sources") != current:
        problems.append("engine sources changed after the engine was frozen (stale artifact)")
    exe = os.path.join(runtime, ENGINE_NAME)
    if not os.path.isfile(exe) or sha256_file(exe) != manifest.get("executableSha256"):
        problems.append("engine executable missing or changed")
    for name in TOOLS:
        path = os.path.join(runtime, "_internal", "tools", name)
        if not os.path.isfile(path) or sha256_file(path) != (manifest.get("tools") or {}).get(name):
            problems.append(f"bundled tool missing or changed: {name}")
    files, size = tree_stats(runtime) if os.path.isdir(runtime) else (0, 0)
    if files != manifest.get("files") or size != manifest.get("bytes"):
        problems.append("runtime file count/size differs from the manifest")
    return problems


# ----------------------------------------------------------------------------
# Handoff packaging (copies only; no command is executed except ditto for the zip)
# ----------------------------------------------------------------------------

RECOLLECT_COMMAND = """#!/bin/bash
# 사이트 목록 다시 수집 (직접 실행할 때만 동작합니다)
DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$DIR/HTT.app/Contents/Resources/EngineRuntime/htd-engine"
OUT="$DIR/수집결과"
mkdir -p "$OUT"
echo "https://mango59.com/ 첫 화면을 한 번 받아 공개 주소 목록을 만듭니다."
"$BACKEND" collect-sites --fetch https://mango59.com/ --output-dir "$OUT"
echo ""
echo "결과 폴더: $OUT"
echo "참고: HTT 앱 자체의 문제는 앱의 '설정 > 진단 로그 내보내기' 버튼을 사용하세요."
read -n 1 -s -r -p "아무 키나 누르면 닫힙니다."
"""

DIAGNOSTICS_COMMAND = """#!/bin/bash
# 수집기 진단 정보 저장 (직접 실행할 때만 동작합니다)
DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$DIR/HTT.app/Contents/Resources/EngineRuntime/htd-engine"
ZIP="$DIR/collector-diagnostics.zip"
"$BACKEND" collect-sites --export-diagnostics "$ZIP"
echo ""
echo "저장 위치: $ZIP"
echo "참고: 이 파일은 수집기용입니다. HTT 앱 자체의 문제는 앱의 '설정 > 진단 로그 내보내기' 버튼을 사용하세요."
read -n 1 -s -r -p "아무 키나 누르면 닫힙니다."
"""


def checked_public_doc(path):
    if os.path.islink(path) or not os.path.isfile(path):
        fail("public document must be a regular file (no symlink)")
    real = os.path.realpath(path)
    name = os.path.basename(real)
    if name.startswith(".") or ".capture" in real.split(os.sep) or not name.lower().endswith(PUBLIC_DOC_EXTENSIONS):
        fail(f"not an allowed public document: {name}")
    if os.path.getsize(real) > (50 << 20):
        fail(f"public document too large: {name}")
    return real


def package_only(args):
    app = os.path.abspath(args.app)
    runtime = os.path.join(app, "Contents", "Resources", "EngineRuntime")
    if not os.path.isfile(os.path.join(runtime, ENGINE_NAME)):
        fail("the app has no portable EngineRuntime (build with: scripts/dev.py build --portable)")
    docs = [checked_public_doc(p) for p in args.public_doc]
    if len({os.path.basename(d) for d in docs}) != 4:
        fail("the four public documents need distinct file names")
    handoff = os.path.abspath(args.handoff_dir)
    archive = handoff + ".zip"
    if os.path.lexists(handoff) or os.path.lexists(archive):
        fail("the handoff folder/zip already exists; pass a fresh --handoff-dir")
    os.makedirs(os.path.dirname(handoff), exist_ok=True)
    os.mkdir(handoff)
    shutil.copytree(app, os.path.join(handoff, "HTT.app"), symlinks=True)
    for doc in docs:
        shutil.copyfile(doc, os.path.join(handoff, os.path.basename(doc)))
    for src, name in ((os.path.join(runtime, MANIFEST_NAME), "build-manifest.json"),
                      (os.path.join(app, "Contents", "Resources", "THIRD-PARTY-NOTICES.txt"), "THIRD-PARTY-NOTICES.txt")):
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(handoff, name))
    for name, text in (("사이트 목록 다시 수집.command", RECOLLECT_COMMAND), ("수집기 진단 내보내기.command", DIAGNOSTICS_COMMAND)):
        path = os.path.join(handoff, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(path, 0o755)
    res = subprocess.run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl",
                          "--keepParent", handoff, archive])
    if res.returncode != 0:
        fail(f"ditto failed with exit code {res.returncode}")
    print(f"Handoff folder: {handoff}")
    print(f"Handoff zip: {archive}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--target-macos", default="15.4", help="explicit minimum macOS the artifact may require (default 15.4)")
    for name in TOOLS:
        p.add_argument(f"--{name}", help=f"exact path of {name} (default: found on PATH)")
    p.add_argument("--package-only", action="store_true", help="copy the built app + docs into a fresh handoff folder/zip")
    p.add_argument("--app", default=os.path.join(ROOT, "dist", "HTT.app"))
    p.add_argument("--public-doc", nargs=4, metavar=("DOC1", "DOC2", "DOC3", "DOC4"), help="the four public documents")
    p.add_argument("--handoff-dir", default=os.path.join(BUILD_DIR, "handoff", "HTT-handoff"))
    args = p.parse_args()
    if args.package_only:
        if not args.public_doc:
            fail("--package-only needs --public-doc with exactly four files")
        package_only(args)
    else:
        build(args)


if __name__ == "__main__":
    main()
