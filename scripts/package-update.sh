#!/bin/bash
# 업데이트 배포 산출물(DMG + 서명된 appcast.xml)을 만든다. 게시(업로드)는 하지 않는다.
# 사용법: scripts/package-update.sh
#   SPARKLE_KEYCHAIN_ACCOUNT : 로그인 키체인의 EdDSA 서명 키 계정명
#                              (기본: Resources/UpdateSigningAccount.txt 내용)
#   NOTARY_PROFILE           : 지정 시 notarytool 키체인 프로필로 공증 후 staple
# 개인키는 sign_update/generate_appcast가 키체인에서 직접 읽으며, 이 스크립트는 키를
# 내보내거나 출력하지 않는다.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../update-config.env
source "$ROOT_DIR/update-config.env"

ACCOUNT_FILE="$ROOT_DIR/Resources/UpdateSigningAccount.txt"
if [ -z "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ] && [ -f "$ACCOUNT_FILE" ]; then
  SPARKLE_KEYCHAIN_ACCOUNT="$(tr -d '[:space:]' < "$ACCOUNT_FILE")"
fi
if [ -z "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ]; then
  echo "오류: SPARKLE_KEYCHAIN_ACCOUNT(서명 키 키체인 계정)가 지정되지 않았습니다." >&2
  exit 1
fi
if [ ! -f "$ROOT_DIR/Resources/UpdatePublicKey.txt" ]; then
  echo "오류: Resources/UpdatePublicKey.txt가 없어 업데이트 검증 키 없이 배포할 수 없습니다." >&2
  exit 1
fi

APP="$ROOT_DIR/build/HanTool.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-56C14CF3A623A4C64AF71A3D63C248FEAB4D8DB8}"
BROWSER_RUNTIME_SOURCE="${BROWSER_RUNTIME_SOURCE:-$ROOT_DIR/BrowserModule/.build/portable-engine/EngineRuntime}"
BROWSER_EXPECTED_TEAM="${BROWSER_EXPECTED_TEAM:-T7B4EPLHPK}"
BUILD_STAMP="$ROOT_DIR/build/.package-update-build-stamp"

# build.sh 결과물 재사용 판정. 아래 입력이 하나라도 달라지거나 확인하지 못하면 재사용하지 않고 재빌드한다.
#  inputs : build.sh/설정/소스/리소스/확장/Sparkle/BrowserModule 전체 내용, 선택된 외부 런타임(경로·내용·서명),
#           빌드 환경변수, 툴체인(swiftc·SDK·python3·macOS), 서명 신원·타임스탬프 모드
#  app    : 앞서 만든 앱 번들 전체 내용(수정·삭제·교체 감지)
# 해시 계산은 python3 -I로 한다. 모드: inputs | app
bundle_hash() {
  BH_MODE="$1" BH_ROOT="$ROOT_DIR" BH_APP="$APP" BH_RUNTIME="$BROWSER_RUNTIME_SOURCE" \
  BH_IDENTITY="$SIGN_IDENTITY" BH_TEAM="$BROWSER_EXPECTED_TEAM" python3 -I - <<'PY'
import hashlib, os, subprocess, sys

root, app, runtime = os.environ["BH_ROOT"], os.environ["BH_APP"], os.environ["BH_RUNTIME"]
h = hashlib.sha256()

def put(*parts):
    for part in parts:
        data = part if isinstance(part, bytes) else str(part).encode("utf-8", "surrogateescape")
        h.update(len(data).to_bytes(8, "big")); h.update(data)

def file_digest(path):
    d = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            d.update(chunk)
    return d.digest()

def skip_dir(rel, name):
    # BrowserModule/.build(런타임 산출물, 선택 런타임은 별도 결속)와 파이썬 캐시만 제외
    if rel == "BrowserModule" and name == ".build":
        return True
    return name == "__pycache__" and rel.startswith("BrowserModule") and not rel.startswith("BrowserModule/Resources")

def bind_link(full, base, prune):
    # 링크는 대상이 같은 해시 트리 안에 실제로 존재할 때만 허용한다(대상 내용·권한은 트리 순회에서 결속됨).
    # 트리 밖·끊어진 링크·제외 디렉터리를 가리키는 링크는 내용을 보장할 수 없으므로 중단한다.
    real, top = os.path.realpath(full), os.path.realpath(base)
    if not os.path.exists(real) or not (real == top or real.startswith(top + os.sep)):
        raise SystemExit("unbound symlink: " + full)
    if prune:
        rr = os.path.relpath(real, os.path.realpath(root))
        if rr == "BrowserModule/.build" or rr.startswith("BrowserModule/.build/") or "__pycache__" in rr.split(os.sep):
            raise SystemExit("unbound symlink: " + full)
    put("link", os.readlink(full))

def hash_path(path, label, prune=False):
    put("path", label)
    if os.path.islink(path):
        raise SystemExit("top-level symlink: " + path)
    if os.path.isfile(path):
        put("file", os.stat(path).st_mode & 0o7777, file_digest(path)); return
    if not os.path.isdir(path):
        raise SystemExit("missing: " + path)
    put("dir", os.stat(path).st_mode & 0o7777)
    for cur, dirs, files in os.walk(path, followlinks=False):
        rel = os.path.relpath(cur, path if not prune else root)
        dirs[:] = sorted(d for d in dirs if not (prune and skip_dir(rel if rel != "." else "", d)))
        for name in dirs:
            full = os.path.join(cur, name)
            put("d", os.path.relpath(full, path), os.lstat(full).st_mode & 0o7777)
            if os.path.islink(full):
                bind_link(full, path, prune)
        for name in sorted(files):
            full = os.path.join(cur, name)
            r = os.path.relpath(full, path)
            st = os.lstat(full)
            if os.path.islink(full):
                put("l", r); bind_link(full, path, prune)
            else:
                put("f", r, st.st_mode & 0o7777, file_digest(full))

def run(*cmd):
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode != 0:
        raise SystemExit("failed: " + " ".join(cmd))
    return p.stdout

mode = os.environ["BH_MODE"]
if mode == "app":
    hash_path(app, "app")
else:
    for rel in ("build.sh", "update-config.env", "Info.plist", "scripts/bootstrap-sparkle.sh", "scripts/make-icon.sh"):
        hash_path(os.path.join(root, rel), rel)
    for rel in ("Sources", "CCMBModule", "BrowserModule", "BrowserExtension", "SafariExtension",
                "WakeHelper", "Resources", "Vendor/Sparkle"):
        hash_path(os.path.join(root, rel), rel, prune=True)
    # 선택된 외부 런타임: 실제 경로, 전체 내용, 서명 정보
    rt = os.path.realpath(runtime)
    put("runtime-path", rt)
    hash_path(rt, "runtime")
    engine = os.path.join(rt, "htd-engine")
    run("/usr/bin/codesign", "--verify", "--strict", engine)
    info = run("/usr/bin/codesign", "-dvvv", engine).decode("utf-8", "replace")
    put("runtime-sign", "\n".join(l for l in info.splitlines() if l.startswith(("TeamIdentifier=", "CDHash=", "Identifier=", "Authority="))))
    # 환경: 서명 신원, 타임스탬프 모드, 기대 팀, 빌드에 영향 줄 수 있는 변수
    put("env", os.environ["BH_IDENTITY"].upper(), "SIGN_TIMESTAMP=1", os.environ["BH_TEAM"])
    for key in sorted(os.environ):
        if key == "PATH" or key.startswith(("DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS", "MACOSX_DEPLOYMENT_TARGET", "SWIFT",
                                            "CPATH", "LIBRARY_PATH", "PYTHON", "CC", "CXX", "CLANG", "LD", "OBJC", "SOURCE_DATE_EPOCH")):
            put("var", key, os.environ[key])
    # 툴체인
    swiftc = run("/usr/bin/xcrun", "--find", "swiftc").decode().strip()
    put("swiftc", swiftc, file_digest(os.path.realpath(swiftc)), run("/usr/bin/xcrun", "swiftc", "--version"))
    put("sdk", run("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"), run("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"),
        run("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"), run("/usr/bin/xcode-select", "-p"))
    put("python", os.path.realpath(sys.executable), file_digest(os.path.realpath(sys.executable)), sys.version)
    put("system", run("/usr/bin/uname", "-m"), run("/usr/bin/sw_vers"))
print(h.hexdigest())
PY
}

# 기존 앱이 방금 같은 입력으로 SIGN_TIMESTAMP=1 빌드된 것과 동일한지 확인한다(0=재사용 가능).
can_reuse_build() {
  [ "${FORCE_REBUILD:-0}" != "1" ] || return 1
  [ -d "$APP" ] && [ -f "$BUILD_STAMP" ] || return 1
  [ "$(wc -l < "$BUILD_STAMP" | tr -d ' ')" = "2" ] || return 1
  local want_inputs want_app cur_inputs cur_app
  want_inputs="$(sed -n 1p "$BUILD_STAMP")"; want_app="$(sed -n 2p "$BUILD_STAMP")"
  cur_inputs="$(bundle_hash inputs 2>/dev/null)" || return 1
  [ -n "$cur_inputs" ] && [ "$cur_inputs" = "$want_inputs" ] || return 1
  cur_app="$(bundle_hash app 2>/dev/null)" || return 1
  [ -n "$cur_app" ] && [ "$cur_app" = "$want_app" ] || return 1
  # 서명: 앱이 지금도 유효하고, 지정 신원 인증서로, 보안 타임스탬프와 함께 서명돼 있어야 한다.
  local identities details certdir leaf
  identities="$(security find-identity -v -p codesigning)" || return 1
  grep -qi "$SIGN_IDENTITY" <<<"$identities" || return 1
  codesign --verify --deep --strict "$APP" 2>/dev/null || return 1
  details="$(codesign -dvv "$APP" 2>&1)" || return 1
  grep -q '^Timestamp=' <<<"$details" || return 1
  certdir="$(mktemp -d /private/tmp/hantool-reuse-cert.XXXXXX)"
  if ! codesign -d --extract-certificates="$certdir/c" "$APP" 2>/dev/null || [ ! -f "$certdir/c0" ]; then
    rm -rf "$certdir"; return 1
  fi
  leaf="$(shasum -a 1 "$certdir/c0" | awk '{print toupper($1)}')"
  rm -rf "$certdir"
  [ "$leaf" = "$(printf '%s' "$SIGN_IDENTITY" | tr '[:lower:]' '[:upper:]')" ] || return 1
  return 0
}

PRE_INPUTS="$(bundle_hash inputs 2>/dev/null || true)"
if [ -z "$PRE_INPUTS" ]; then
  echo "오류: 빌드 입력을 완전히 결속(해시)할 수 없어(외부·끊어진 심볼릭 링크 등) 공개 후보 패키징을 중단합니다." >&2
  exit 1
fi
if can_reuse_build; then
  echo "==> 입력·런타임·서명이 동일한 기존 빌드를 재사용합니다 (강제 재빌드: FORCE_REBUILD=1)"
else
  rm -f "$BUILD_STAMP"
  SIGN_TIMESTAMP=1 "$ROOT_DIR/build.sh"
  # 빌드 중 입력이 바뀌었거나 확인할 수 없으면 잘못된 결과물을 막기 위해 즉시 실패한다.
  POST_INPUTS="$(bundle_hash inputs 2>/dev/null || true)"
  if [ -z "$POST_INPUTS" ] || [ "$PRE_INPUTS" != "$POST_INPUTS" ]; then
    echo "오류: 빌드 중 입력이 바뀌었거나 확인할 수 없어 패키징을 중단합니다." >&2
    exit 1
  fi
  APP_HASH="$(bundle_hash app 2>/dev/null || true)"
  if [ -z "$APP_HASH" ]; then
    echo "오류: 빌드된 앱 번들을 해시할 수 없어 패키징을 중단합니다." >&2
    exit 1
  fi
  printf '%s\n%s\n' "$PRE_INPUTS" "$APP_HASH" > "$BUILD_STAMP.tmp" && mv "$BUILD_STAMP.tmp" "$BUILD_STAMP"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
RELEASE_DIR="$ROOT_DIR/build/release/v$VERSION"
DMG="$RELEASE_DIR/HanTool-$VERSION.dmg"
STAGING="$(mktemp -d /private/tmp/screentranslator-dmg.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo "==> DMG 생성"
ditto "$APP" "$STAGING/HanTool.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "HanTool $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> 공증 제출 (프로필: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "참고: NOTARY_PROFILE 미지정 — 공증 없이 생성했습니다. 게시 전 공증이 필요합니다." >&2
fi

echo "==> appcast 생성 및 EdDSA 서명 (키체인 계정: $SPARKLE_KEYCHAIN_ACCOUNT)"
"$ROOT_DIR/Vendor/Sparkle/bin/generate_appcast" \
  --account "$SPARKLE_KEYCHAIN_ACCOUNT" \
  --download-url-prefix "$SPARKLE_DOWNLOAD_URL_BASE/v$VERSION/" \
  -o "$RELEASE_DIR/appcast.xml" \
  "$RELEASE_DIR"

echo "==> 산출물 (게시하지 않음):"
ls -l "$RELEASE_DIR"
echo "피드 URL: $SPARKLE_FEED_URL"
echo "게시 시 DMG와 appcast.xml을 릴리스 v$VERSION 자산으로 올리고 해당 릴리스를 latest로 지정해야 합니다."
