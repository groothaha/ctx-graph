#!/bin/bash
# CtxGraph.app 빌드 → ~/Applications/CtxGraph.app
#   ./build.sh          배포판 구성: 앱에 든 스크립트를 ~/Library/Application Support/CtxGraph/bin 에 풀어 씀
#   DEV=1 ./build.sh    개발용: 이 저장소의 bin/ 을 바로 씀 (고치면 바로 반영 — 소스 폴더를 지우면 안 됨)
#   OUT=<경로>          다른 곳에 만들기 (시험용)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${OUT:-$HOME/Applications/CtxGraph.app}"   # OUT=... 로 다른 곳에 만들 수 있음 (시험용)
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac   # 상대 경로는 실행한 곳 기준 (아래에서 app/ 으로 cd 한다)

cd "$ROOT/app"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
build() {   # swift build 출력은 $LOG 에 모으고, 상태 코드를 돌려준다
  swift build -c release >"$LOG" 2>&1
}
show_log() { grep -vE "PlatformPath|XCTest|show-sdk-platform-path" "$LOG" || true; }

echo "Building (swift build -c release)…"
set +e
build
status=$?
set -e
# Command Line Tools 만 깔린 Mac 에서 새 SDK 의 SwiftUI 가 @State 를 macro 로 쓰는데
# CLT 에 그 plugin(SwiftUIMacros)이 없으면 실패한다 → 설치된 이전 SDK 로 차례로 다시 시도.
# SDKROOT 를 직접 지정했으면 건드리지 않는다.
if [ "$status" -ne 0 ] && [ -z "${SDKROOT:-}" ] && grep -q "plugin for module 'SwiftUIMacros' not found" "$LOG"; then
  CUR_SDK="$(cd -P "$(xcrun --show-sdk-path)" && pwd)"
  SDK_DIR="$(dirname "$CUR_SDK")"
  echo "The default SDK ($(basename "$CUR_SDK")) needs the SwiftUIMacros plugin, which these developer tools lack. Retrying with an older SDK…"
  TRIED="$CUR_SDK"
  for sdk in $(ls -d "$SDK_DIR"/MacOSX[0-9]*.sdk 2>/dev/null | sed -E 's/.*MacOSX([0-9.]+)\.sdk$/\1 &/' | sort -t. -k1,1nr -k2,2nr | cut -d' ' -f2); do
    real="$(cd -P "$sdk" && pwd)"
    case " $TRIED " in *" $real "*) continue ;; esac
    TRIED="$TRIED $real"
    echo "  → $(basename "$real")"
    set +e
    SDKROOT="$real" build
    status=$?
    set -e
    [ "$status" -eq 0 ] && break
    grep -q "plugin for module 'SwiftUIMacros' not found" "$LOG" || break   # 다른 이유로 실패하면 멈춤
  done
fi
show_log
[ "$status" -eq 0 ] || { echo "Build failed (swift build exit $status) — nothing was installed. See docs/DEVELOPMENT.md#building"; exit 1; }
BIN="$ROOT/app/.build/release/CtxGraph"
[ -x "$BIN" ] || { echo "Build failed: $BIN is missing"; exit 1; }

ICNS="$ROOT/app/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
  TMP="$(mktemp -d)"
  swiftc -O "$ROOT/app/make_icon.swift" -o "$TMP/make_icon" -framework AppKit 2>&1 | grep -vE "PlatformPath" || true
  "$TMP/make_icon" "$TMP/icon.png"
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o "$ICNS"
  rm -rf "$TMP"
fi

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CtxGraph"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# 터미널 글꼴 D2Coding (SIL OFL 1.1 — 라이선스 파일도 같이)
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$ROOT/app/Fonts/"*.ttf "$ROOT/app/Fonts/D2Coding-LICENSE.md" "$APP/Contents/Resources/Fonts/"
# 라이선스 (CtxGraph MIT, SwiftTerm MIT, D2Coding OFL)
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/CtxGraph-LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/"
cp "$ROOT/app/Vendor/SwiftTerm/LICENSE" "$APP/Contents/Resources/Licenses/SwiftTerm-LICENSE.txt"
# 언어 (ko = 기본, en). 번역은 app/Localization/en.py → build_strings.py
python3 -B "$ROOT/app/Localization/build_strings.py" >/dev/null
cp -R "$ROOT/app/Localization/"*.lproj "$APP/Contents/Resources/"
# 백엔드 스크립트 (배포판은 첫 실행 때 ~/Library/Application Support/CtxGraph/bin 에 풀어 씀)
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT/bin/ctxgraph.py" "$ROOT/bin/ctxpty.py" "$ROOT/bin/ctxgraph" "$ROOT/bin/ctx-skill.md" "$ROOT/bin/ctx-skill.en.md" "$APP/Contents/Resources/bin/"
# DEV=1: 소스의 bin 을 바로 쓰게
if [ -n "${DEV:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :CtxGraphSourceBin string $ROOT/bin" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built: $APP"
