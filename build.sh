#!/bin/bash
# HanTool.app 빌드 스크립트
# 사용법: ./build.sh
#   SIGN_IDENTITY          : 서명 인증서 SHA1 (기본: 기존 Developer ID Application, 팀 T7B4EPLHPK)
#   SIGN_TIMESTAMP         : 1이면 보안 타임스탬프 포함(배포/공증용, 네트워크 필요)
#   BROWSER_RUNTIME_SOURCE : 브라우저 엔진 런타임(EngineRuntime) 경로 (기본: BrowserModule/.build/portable-engine/EngineRuntime)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="HanTool"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE_NAME="HanTool"
BUNDLE_ID="com.local.screentranslator"
SPARKLE_DIR="$ROOT_DIR/Vendor/Sparkle"
# 앱 본체 권한: Mail 선택 메시지 읽기용 Apple Events만(hardened runtime 유지, 라이브러리 검증 완화 없음)
ENTITLEMENTS="$ROOT_DIR/Resources/SMTranslator.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-56C14CF3A623A4C64AF71A3D63C248FEAB4D8DB8}"

# shellcheck source=update-config.env
source "$ROOT_DIR/update-config.env"

if [ ! -d "$SPARKLE_DIR/Sparkle.framework" ]; then
  echo "==> Sparkle 의존성 준비"
  "$ROOT_DIR/scripts/bootstrap-sparkle.sh"
fi

if [ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ] || [ "$ROOT_DIR/Resources/AppIcon-source.png" -nt "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  echo "==> 앱 아이콘 생성"
  "$ROOT_DIR/scripts/make-icon.sh"
fi

# 브라우저 엔진 런타임 사전 검증 (런타임 프리플라이트)
# 컴파일 및 스테이징 전 필수 확인: BrowserModule/.build/portable-engine/EngineRuntime 또는 BROWSER_RUNTIME_SOURCE
BROWSER_RUNTIME_SOURCE="${BROWSER_RUNTIME_SOURCE:-$ROOT_DIR/BrowserModule/.build/portable-engine/EngineRuntime}"
if [ ! -d "$BROWSER_RUNTIME_SOURCE" ]; then
  echo "오류: 브라우저 엔진 런타임을 찾을 수 없습니다: $BROWSER_RUNTIME_SOURCE" >&2
  exit 1
fi

BUILDER_SCRIPT="$ROOT_DIR/BrowserModule/scripts/build_portable_engine.py"
if [ ! -f "$BUILDER_SCRIPT" ]; then
  echo "오류: portable engine builder 스크립트가 없습니다: $BUILDER_SCRIPT" >&2
  exit 1
fi

echo "==> 브라우저 엔진 런타임 아티팩트 검증 (verify_artifact)"
python3 - "$BUILDER_SCRIPT" "$BROWSER_RUNTIME_SOURCE" <<'PY'
import sys, importlib.util
builder_path, runtime_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("build_portable_engine", builder_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
problems = mod.verify_artifact(runtime=runtime_path)
if problems:
    print(f"오류: EngineRuntime 아티팩트 검증 실패 ({runtime_path}):", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)
print(f"==> EngineRuntime 아티팩트 검증 성공 ({runtime_path})")
PY

HTD_ENGINE_BIN="$BROWSER_RUNTIME_SOURCE/htd-engine"
if [ ! -x "$HTD_ENGINE_BIN" ]; then
  echo "오류: EngineRuntime 실행 파일(htd-engine)이 없거나 실행 권한이 없습니다." >&2
  exit 1
fi
if ! lipo -archs "$HTD_ENGINE_BIN" | tr ' ' '\n' | grep -x "$(uname -m)" >/dev/null; then
  echo "오류: htd-engine 아키텍처가 현재 시스템($(uname -m))과 일치하지 않습니다." >&2
  exit 1
fi
if ! codesign --verify --strict "$HTD_ENGINE_BIN" 2>/dev/null; then
  echo "오류: htd-engine 코드 서명이 올바르지 않습니다." >&2
  exit 1
fi

BROWSER_EXPECTED_TEAM="${BROWSER_EXPECTED_TEAM:-T7B4EPLHPK}"
HTD_ENGINE_TEAM="$(codesign -dv "$HTD_ENGINE_BIN" 2>&1 | awk -F'=' '/^TeamIdentifier=/ {print $2}')"
if [ -z "$HTD_ENGINE_TEAM" ]; then
  echo "오류: htd-engine 코드 서명에서 TeamIdentifier를 확인할 수 없습니다." >&2
  exit 1
fi
if [ "$HTD_ENGINE_TEAM" != "$BROWSER_EXPECTED_TEAM" ]; then
  echo "오류: htd-engine TeamIdentifier 불일치 (기대값: $BROWSER_EXPECTED_TEAM, 실제값: $HTD_ENGINE_TEAM)" >&2
  exit 1
fi

echo "==> 빌드 디렉터리 정리"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
if [ "$(uname -m)" = "arm64" ]; then
  SWIFT_TARGET="arm64-apple-macos15.0"
else
  SWIFT_TARGET="x86_64-apple-macos15.0"
fi

SWIFT_SOURCES=(
  "$ROOT_DIR"/Sources/*.swift
  "$ROOT_DIR"/Sources/InputMate/*.swift
  "$ROOT_DIR"/Sources/InputMateCore/*.swift
  "$ROOT_DIR"/Sources/BTN/*.swift
  "$ROOT_DIR"/Sources/BTNCore/*.swift
  "$ROOT_DIR"/Sources/CleanUSB/*.swift
)

CCMB_MODULE_DIR="$BUILD_DIR/Modules"
mkdir -p "$CCMB_MODULE_DIR"
if compgen -G "$ROOT_DIR/CCMBModule/*.swift" > /dev/null; then
  echo "==> HTTCCMB 정적 모듈 컴파일 (target: $SWIFT_TARGET)"
  xcrun swiftc \
    -O \
    -swift-version 5 \
    -target "$SWIFT_TARGET" \
    -sdk "$SDK_PATH" \
    -module-name HTTCCMB \
    -emit-module \
    -emit-module-path "$CCMB_MODULE_DIR/HTTCCMB.swiftmodule" \
    -emit-library \
    -static \
    -o "$CCMB_MODULE_DIR/libHTTCCMB.a" \
    -F "$SPARKLE_DIR" \
    -framework Sparkle \
    -framework AppKit \
    -framework SwiftUI \
    -framework WebKit \
    -framework CloudKit \
    -framework ServiceManagement \
    -framework Network \
    -framework Security \
    "$ROOT_DIR"/CCMBModule/*.swift
fi

HTD_MODULE_DIR="$BUILD_DIR/Modules"
if ! compgen -G "$ROOT_DIR/BrowserModule/Sources/*.swift" > /dev/null; then
  echo "오류: BrowserModule/Sources 소스 파일을 찾을 수 없습니다." >&2
  exit 1
fi
HTD_SOURCES=("$ROOT_DIR"/BrowserModule/Sources/*.swift)

echo "==> HTTHTDCore 정적 모듈 컴파일 (target: $SWIFT_TARGET)"
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -module-name HTTHTDCore \
  -D HTT_HOST \
  -parse-as-library \
  -emit-module \
  -emit-module-path "$HTD_MODULE_DIR/HTTHTDCore.swiftmodule" \
  -emit-library \
  -static \
  -o "$HTD_MODULE_DIR/libHTTHTDCore.a" \
  -framework AppKit \
  -framework SwiftUI \
  -framework WebKit \
  -framework AVKit \
  -framework AVFoundation \
  -framework Security \
  -framework Network \
  -framework UniformTypeIdentifiers \
  "${HTD_SOURCES[@]}"

echo "==> Swift 소스 컴파일 (target: $SWIFT_TARGET)"
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -F "$SPARKLE_DIR" \
  -I "$CCMB_MODULE_DIR" \
  -L "$CCMB_MODULE_DIR" \
  -lHTTCCMB \
  -I "$HTD_MODULE_DIR" \
  -L "$HTD_MODULE_DIR" \
  -lHTTHTDCore \
  -framework Sparkle \
  -framework AppKit \
  -framework SwiftUI \
  -framework ScreenCaptureKit \
  -framework Vision \
  -framework Translation \
  -framework ServiceManagement \
  -framework Carbon \
  -framework WebKit \
  -framework CloudKit \
  -framework NaturalLanguage \
  -framework UniformTypeIdentifiers \
  -framework ApplicationServices \
  -framework SafariServices \
  -framework Network \
  -framework Security \
  -framework AVKit \
  -framework AVFoundation \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" \
  "${SWIFT_SOURCES[@]}"

# 브라우저 번역: Chrome·Whale 네이티브 메시징 도우미, 압축 해제용 확장, Safari 웹 확장(.appex)
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$ROOT_DIR/Info.plist")"
BROWSER_DIR="$ROOT_DIR/BrowserExtension"
HELPER_ID="com.local.screentranslator.browserhost"
SAFARI_APPEX="$APP_BUNDLE/Contents/PlugIns/SMTSafariExtension.appex"
SAFARI_ID="com.local.screentranslator.safari-extension"
SAFARI_ENTITLEMENTS="$ROOT_DIR/SafariExtension/SafariExtension.entitlements"

echo "==> 브라우저 도우미 컴파일 (SMTBrowserHost)"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -module-name SMTBrowserHost \
  -framework AppKit \
  -framework Security \
  -o "$APP_BUNDLE/Contents/Helpers/SMTBrowserHost" \
  "$BROWSER_DIR/NativeHost/main.swift" \
  "$ROOT_DIR/Sources/BrowserProtocol.swift"

echo "==> 브라우저 확장 파일 준비 (버전 $APP_VERSION)"
ICON_DIR="$BUILD_DIR/browser-icons"
rm -rf "$ICON_DIR"
mkdir -p "$ICON_DIR"
# 툴바용 그림은 A·가를 크게 하고 여백을 줄인 별도 원본을 쓴다. Dock 아이콘 원본은 유지한다.
BROWSER_ICON_SOURCE="$ICON_DIR/_source-cropped.png"
cp "$ROOT_DIR/Resources/BrowserToolbarIcon-source.png" "$BROWSER_ICON_SOURCE"
for size in 16 32 48 128; do
  sips -z "$size" "$size" "$BROWSER_ICON_SOURCE" --out "$ICON_DIR/icon$size.png" >/dev/null
done
rm -f "$BROWSER_ICON_SOURCE"
# stage_extension <대상 폴더> <manifest 원본>
stage_extension() {
  local dest="$1" manifest="$2"
  mkdir -p "$dest/icons" "$dest/fonts" "$dest/provider-logos"
  cp "$BROWSER_DIR/shared/fx.js" "$BROWSER_DIR/shared/background.js" "$BROWSER_DIR/shared/content.js" \
     "$BROWSER_DIR/shared/popup.html" "$BROWSER_DIR/shared/popup.js" "$BROWSER_DIR/shared/popup.css" \
     "$BROWSER_DIR/shared/autoshorts.js" "$dest/"
  # WKWebExtension은 외부 JS를 한국어 로케일에서 레거시 문자셋으로 읽어 한글이 깨지고 정규식이 오류를 낼 수 있다.
  # 복사본 JS의 비ASCII 문자만 \uXXXX(UTF-16)로 바꿔 인코딩과 무관하게 같은 의미로 읽히게 한다. 원본은 UTF-8 그대로다.
  python3 -I - "$dest/fx.js" "$dest/background.js" "$dest/content.js" "$dest/popup.js" <<'PY'
import sys
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    out = []
    for ch in text:
        cp = ord(ch)
        if cp < 128:
            out.append(ch)
        elif cp < 0x10000:
            out.append("\\u%04x" % cp)
        else:
            cp -= 0x10000
            out.append("\\u%04x\\u%04x" % (0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF)))
    open(path, "w", encoding="utf-8", newline="").write("".join(out))
PY
  cp "$ICON_DIR"/icon*.png "$dest/icons/"
  # 팝업의 구글·DeepL 버튼 공식 로고(번들 안 로컬 파일, 네트워크로 받지 않음).
  cp "$BROWSER_DIR/shared/provider-logos/google-translate.png" "$BROWSER_DIR/shared/provider-logos/deepl-blue.svg" \
     "$BROWSER_DIR/shared/provider-logos/deepl-white.svg" "$BROWSER_DIR/shared/provider-logos/deepl-symbol-"*.svg "$dest/provider-logos/"
  # 고딕/명조/손글씨 글꼴(패키지 번들, 온라인 Google Fonts 의존 안 함). 라이선스(OFL)도 함께 접근 가능하게 둔다.
  cp "$ROOT_DIR/Resources/Fonts"/*.ttf "$dest/fonts/"
  cp "$ROOT_DIR/Resources/Fonts"/*-OFL.txt "$ROOT_DIR/Resources/Fonts"/*-LICENSE.txt "$dest/fonts/"
  sed "s/__SMT_VERSION__/$APP_VERSION/" "$manifest" > "$dest/manifest.json"
  plutil -convert json -o /dev/null "$dest/manifest.json"
}
stage_extension "$APP_BUNDLE/Contents/Resources/BrowserExtension/Chromium" "$BROWSER_DIR/chromium/manifest.json"

echo "==> Safari 웹 확장(.appex) 컴파일"
mkdir -p "$SAFARI_APPEX/Contents/MacOS" "$SAFARI_APPEX/Contents/Resources"
xcrun swiftc \
  -O \
  -swift-version 5 \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -parse-as-library \
  -application-extension \
  -module-name SMTSafariExtension \
  -framework Foundation \
  -framework AppKit \
  -framework SafariServices \
  -framework Translation \
  -framework Vision \
  -framework NaturalLanguage \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$SAFARI_APPEX/Contents/MacOS/SMTSafariExtension" \
  "$ROOT_DIR/SafariExtension/SafariWebExtensionHandler.swift" \
  "$ROOT_DIR/Sources/BrowserEngineCore.swift" \
  "$ROOT_DIR/Sources/BrowserProtocol.swift" \
  "$ROOT_DIR/Sources/Models.swift" \
  "$ROOT_DIR/Sources/BundledFonts.swift" \
  "$ROOT_DIR/Sources/ImageTextRecognizer.swift" \
  "$ROOT_DIR/Sources/DocumentTextRecognizer.swift" \
  "$ROOT_DIR/Sources/AppleTranslationRefiner.swift" \
  "$ROOT_DIR/Sources/CurrencyAnnotation.swift"
cp "$ROOT_DIR/SafariExtension/Info.plist" "$SAFARI_APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$SAFARI_APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$SAFARI_APPEX/Contents/Info.plist"
plutil -lint "$SAFARI_APPEX/Contents/Info.plist" >/dev/null
stage_extension "$SAFARI_APPEX/Contents/Resources" "$BROWSER_DIR/safari/manifest.json"

echo "==> 리소스/Info.plist/프레임워크 복사"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
# 외부 AI(AIBI 0.5.3) 공통 런타임과 제공사 레지스트리 — 메일 번역기 원본과 같은 파일
# 원화 환산 공용 파서(메일 서식 보기의 격리된 WKWebView 스크립트가 읽는 번들 파일 — 브라우저 확장과 같은 fx.js)
cp "$BROWSER_DIR/shared/fx.js" "$APP_BUNDLE/Contents/Resources/fx.js"
cp "$ROOT_DIR/Resources/aibi-browser-runtime.js" "$ROOT_DIR/Resources/aibi-providers.json" "$APP_BUNDLE/Contents/Resources/"
# 화면 번역문 글꼴(고딕/명조/손글씨, 패키지 번들). 앱 실행 중 프로세스 범위로만 등록하며 시스템에 설치하지 않는다.
mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
cp "$ROOT_DIR/Resources/Fonts"/*.ttf "$ROOT_DIR/Resources/Fonts"/*-OFL.txt "$ROOT_DIR/Resources/Fonts"/*-LICENSE.txt "$APP_BUNDLE/Contents/Resources/Fonts/"
if [ -d "$ROOT_DIR/Resources/InterfaceIcons" ]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/InterfaceIcons"
  cp -R "$ROOT_DIR/Resources/InterfaceIcons/"* "$APP_BUNDLE/Contents/Resources/InterfaceIcons/"
fi
if [ -f "$ROOT_DIR/Resources/GeminiLogo.png" ]; then
  cp "$ROOT_DIR/Resources/GeminiLogo.png" "$APP_BUNDLE/Contents/Resources/GeminiLogo.png"
fi
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# 브라우저 엔진 런타임 및 에셋 복사
# 사전 검증된 EngineRuntime을 서명 상태 유지하며 루트 Resources로 복사
echo "==> 검증된 브라우저 엔진 런타임(EngineRuntime) 복사"
ditto "$BROWSER_RUNTIME_SOURCE" "$APP_BUNDLE/Contents/Resources/EngineRuntime"

# BrowserModule/Engine의 모든 *.py 및 *.mjs 복사 (폴백 및 진단용)
if [ -d "$ROOT_DIR/BrowserModule/Engine" ]; then
  echo "==> BrowserModule/Engine 스크립트 복사 (*.py, *.mjs)"
  for item in "$ROOT_DIR/BrowserModule/Engine"/*.py "$ROOT_DIR/BrowserModule/Engine"/*.mjs; do
    [ -e "$item" ] || continue
    cp "$item" "$APP_BUNDLE/Contents/Resources/"
  done
fi

# BrowserModule/Resources의 큐레이션된 브라우저 에셋 복사 (Root Info/icons/entitlements 덮어쓰기 금지)
if [ -d "$ROOT_DIR/BrowserModule/Resources" ]; then
  echo "==> BrowserModule/Resources 브라우저 에셋 복사"
  for f in "$ROOT_DIR/BrowserModule/Resources"/*; do
    [ -e "$f" ] || continue
    fname="$(basename "$f")"
    if [ "$fname" != "Info.plist" ] && [ "$fname" != "AppIcon.icns" ] && [ "$fname" != "SMTranslator.entitlements" ]; then
      cp -R "$f" "$APP_BUNDLE/Contents/Resources/"
    fi
  done
fi

PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :BarobogiBuildStamp $APP_BUILD" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :BarobogiBuildStamp string $APP_BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :HTDBuildStamp $APP_BUILD" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :HTDBuildStamp string $APP_BUILD" "$PLIST"
PUBLIC_KEY_FILE="$ROOT_DIR/Resources/UpdatePublicKey.txt"
if [ -f "$PUBLIC_KEY_FILE" ]; then
  PUBLIC_KEY="$(tr -d '[:space:]' < "$PUBLIC_KEY_FILE")"
  if [[ ! "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "오류: Resources/UpdatePublicKey.txt가 EdDSA 공개키(base64 44자) 형식이 아닙니다." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$PLIST"
  echo "==> SUPublicEDKey 포함 (공개키)"
else
  echo "경고: Resources/UpdatePublicKey.txt 없음 — 자동 업데이트가 비활성 상태로 빌드됩니다." >&2
fi
plutil -lint "$PLIST" >/dev/null

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime)
if [ "${SIGN_TIMESTAMP:-0}" = "1" ]; then
  SIGN_ARGS+=(--timestamp)
else
  SIGN_ARGS+=(--timestamp=none)
fi

echo "==> Sparkle 내부 구성요소 서명 (안쪽부터)"
FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FW"

echo "==> 브라우저 도우미·Safari 확장 서명"
# 도우미: 권한 없음(hardened runtime). 앱 엔진은 이 식별자 + 같은 팀 서명만 연결을 받는다.
codesign "${SIGN_ARGS[@]}" --identifier "$HELPER_ID" "$APP_BUNDLE/Contents/Helpers/SMTBrowserHost"
# Safari 확장: 앱 샌드박스만(앱 그룹·임시 예외 없음)
plutil -lint "$SAFARI_ENTITLEMENTS" >/dev/null
codesign "${SIGN_ARGS[@]}" --entitlements "$SAFARI_ENTITLEMENTS" --identifier "$SAFARI_ID" "$SAFARI_APPEX"

# 잠자기 깨어남 헬퍼 (SMAppService.loginItem)
WAKE_HELPER_DIR="$APP_BUNDLE/Contents/Library/LoginItems/HTTWakeHelper.app"
mkdir -p "$WAKE_HELPER_DIR/Contents/MacOS"
xcrun swiftc -target "$SWIFT_TARGET" -sdk "$SDK_PATH" -swift-version 5 -framework AppKit \
    "$ROOT_DIR/WakeHelper/main.swift" \
    -o "$WAKE_HELPER_DIR/Contents/MacOS/HTTWakeHelper"
cp "$ROOT_DIR/WakeHelper/Info.plist" "$WAKE_HELPER_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$WAKE_HELPER_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$WAKE_HELPER_DIR/Contents/Info.plist"
codesign "${SIGN_ARGS[@]}" --identifier "com.local.screentranslator.wake-helper" "$WAKE_HELPER_DIR"

echo "==> 앱 서명 (identity: $SIGN_IDENTITY, identifier: $BUNDLE_ID, entitlements: Apple Events)"
plutil -lint "$ENTITLEMENTS" >/dev/null
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"
echo "==> 빌드 완료: $APP_BUNDLE"
