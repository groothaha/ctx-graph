#!/bin/bash
# CtxGraph.app 빌드 → ~/Applications/CtxGraph.app
#   ./build.sh          배포판 구성: 앱에 든 스크립트를 ~/Library/Application Support/CtxGraph/bin 에 풀어 씀
#   DEV=1 ./build.sh    개발용: 이 저장소의 bin/ 을 바로 씀 (고치면 바로 반영 — 소스 폴더를 지우면 안 됨)
#   OUT=<경로>          다른 곳에 만들기 (시험용)
#   ./build.sh --check  빌드에 필요한 것만 확인 (macOS·개발자 도구·Swift·Python·Claude Code)
#   ./build.sh --prebuilt  빌드하지 않고 GitHub Releases 의 앱을 받아 설치 (cask 의 sha256 으로 확인)
#   빌드가 안 되면 차례로: 지난번에 된 설정 → 기본 → 설치된 Xcode(DEVELOPER_DIR) → 이전 SDK → (터미널이면) 미리 빌드된 앱 제안
# macOS 기본 bash 3.2 로 돈다 (연관 배열·${x,,} 같은 4.x 문법 쓰지 말 것)
# `sh build.sh`·`zsh build.sh` 로 실행해도 bash 로 다시 (PIPESTATUS·local 은 bash 문법)
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${OUT:-$HOME/Applications/CtxGraph.app}"   # OUT=... 로 다른 곳에 만들 수 있음 (시험용)
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac   # 상대 경로는 실행한 곳 기준 (아래에서 app/ 으로 cd 한다)
PREBUILT="brew install --cask groothaha/tap/ctxgraph"

# 안내 문구는 터미널 언어가 한국어면 한국어로
KO=0; case "${LC_ALL:-${LANG:-}}" in ko*) KO=1 ;; esac
say()  { if [ "$KO" = 1 ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
ok()   { say "  ✓ $1" "  ✓ $2"; }
bad()  { say "  ✗ $1" "  ✗ $2"; FAILED=1; }
note() { say "  ! $1" "  ! $2"; }

version_ge() {   # "주.부" 비교: $1 >= $2
  local a1=${1%%.*} a2=${1#*.} b1=${2%%.*} b2=${2#*.}
  a2=${a2%%.*}; b2=${b2%%.*}
  [ "$a1" -gt "$b1" ] || { [ "$a1" -eq "$b1" ] && [ "$a2" -ge "$b2" ]; }
}

# 개발자 도구가 없을 때: 터미널에서 직접 실행했으면 Apple 설치 창을 띄울지 묻는다
offer_clt_install() {
  if [ -t 0 ] && [ -z "${CI:-}" ]; then
    printf '%s' "$(say "    Install the Command Line Tools now? [Y/n] " "    지금 개발자 도구(Command Line Tools)를 설치할까요? [Y/n] ")"
    local ans; read -r ans || ans=n
    case "$ans" in
      [nN]*) say "    Install later with: xcode-select --install" "    나중에 설치: xcode-select --install" ;;
      *) xcode-select --install >/dev/null 2>&1 || true
         say "    Apple's installer window opened. Run ./build.sh again when it finishes." "    Apple 설치 창이 열렸어요. 설치가 끝나면 ./build.sh 를 다시 실행하세요." ;;
    esac
  else
    say "    Install them with: xcode-select --install" "    설치: xcode-select --install"
  fi
}

preflight() {
  FAILED=0
  say "Checking what the build needs…" "빌드에 필요한 것 확인 중…"

  local mac; mac=$(sw_vers -productVersion 2>/dev/null || echo 0)
  if [ "${mac%%.*}" -ge 14 ] 2>/dev/null; then ok "macOS $mac" "macOS $mac"
  else bad "macOS $mac — CtxGraph needs macOS 14 Sonoma or later" "macOS $mac — CtxGraph 는 macOS 14 Sonoma 이상이 필요해요"; fi

  local dev
  if dev=$(xcode-select -p 2>/dev/null) && [ -d "$dev" ]; then
    ok "Developer tools: $dev" "개발자 도구: $dev"
  else
    bad "Xcode Command Line Tools are not installed" "Xcode Command Line Tools(개발자 도구)가 없어요"
    offer_clt_install
    return 1   # 이게 없으면 swift·python3 는 확인할 수 없다 (/usr/bin/python3 는 설치 창만 띄움)
  fi

  local out sv
  if out=$(swift --version 2>&1); then
    sv=$(printf '%s\n' "$out" | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
    if version_ge "${sv:-0.0}" 5.9; then ok "Swift $sv" "Swift $sv"
    else
      bad "Swift ${sv:-?} is too old — needs 5.9 or later (Xcode 15+)" "Swift ${sv:-?} 는 너무 오래됐어요 — 5.9 이상(Xcode 15 이상)이 필요해요"
      say "    Update the Command Line Tools: System Settings → General → Software Update" "    시스템 설정 → 일반 → 소프트웨어 업데이트에서 Command Line Tools 를 업데이트하세요"
    fi
  else
    case "$out" in
      *[Ll]icense*)
        bad "Xcode's license hasn't been accepted" "Xcode 라이선스에 아직 동의하지 않았어요"
        say "    Run: sudo xcodebuild -license accept" "    실행: sudo xcodebuild -license accept"
        say "    (or build with the Command Line Tools: sudo xcode-select -s /Library/Developer/CommandLineTools)" "    (또는 개발자 도구로 빌드: sudo xcode-select -s /Library/Developer/CommandLineTools)" ;;
      *)
        bad "swift doesn't run: $(printf '%s\n' "$out" | head -1)" "swift 가 실행되지 않아요: $(printf '%s\n' "$out" | head -1)"
        offer_clt_install ;;
    esac
  fi

  # Python: 빌드는 번역 파일을 다시 만들 때만 쓰지만, 앱은 훅을 돌릴 때 꼭 필요하다
  local py pv
  py=$(command -v python3 || true)
  if [ -n "$py" ] && pv=$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null); then
    if version_ge "$pv" 3.9; then ok "Python $pv ($py)" "Python $pv ($py)"
    else note "Python $pv is older than 3.9 — the app's hooks need 3.9+" "Python $pv 는 3.9 보다 오래됐어요 — 앱의 훅은 3.9 이상이 필요해요"; fi
  else
    note "python3 not found — the app needs Python 3.9+ to run its hooks" "python3 이 없어요 — 앱의 훅을 돌리려면 Python 3.9 이상이 필요해요"
  fi

  if command -v claude >/dev/null 2>&1; then ok "Claude Code: $(command -v claude)" "Claude Code: $(command -v claude)"
  else note "Claude Code isn't in PATH — install it before using the app: https://claude.com/claude-code" "PATH 에 Claude Code 가 없어요 — 앱을 쓰기 전에 설치하세요: https://claude.com/claude-code"; fi

  local free; free=$(df -Pk "$ROOT" | awk 'NR==2 {print int($4/1024)}')
  if [ "${free:-0}" -lt 1024 ]; then note "Only $free MB free — the build needs about 1 GB" "남은 공간이 $free MB 뿐이에요 — 빌드에 1 GB 쯤 필요해요"; fi

  return "$FAILED"
}

# ── 미리 빌드된 앱: GitHub Releases 에서 받아 저장소의 Homebrew cask 에 적힌 sha256 으로 확인 ──
install_prebuilt() {
  local rb="$ROOT/packaging/homebrew/ctxgraph.rb" ver sha url tmp got
  ver=$(sed -n 's/^ *version "\([^"]*\)".*/\1/p' "$rb" | head -1)
  sha=$(sed -n 's/^ *sha256 "\([0-9a-f]*\)".*/\1/p' "$rb" | head -1)
  if [ -z "$ver" ] || [ -z "$sha" ]; then say "Can't read the release version from $rb" "$rb 에서 릴리스 버전을 읽지 못했어요"; return 1; fi
  url="${CTXGRAPH_RELEASES:-https://github.com/groothaha/ctx-graph/releases/download}/v$ver/CtxGraph-$ver.zip"
  tmp=$(mktemp -d -t ctxgraph-prebuilt)
  say "Downloading CtxGraph $ver: $url" "CtxGraph $ver 받는 중: $url"
  if ! curl -fL --retry 2 --progress-bar -o "$tmp/app.zip" "$url"; then
    rm -rf "$tmp"; say "Download failed." "내려받지 못했어요."; return 1
  fi
  got=$(shasum -a 256 "$tmp/app.zip" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    rm -rf "$tmp"; say "Checksum mismatch — not installing (expected $sha, got $got)" "체크섬이 달라 설치하지 않아요 (예상 $sha, 받은 것 $got)"; return 1
  fi
  if ! ditto -x -k "$tmp/app.zip" "$tmp/x" || [ ! -d "$tmp/x/CtxGraph.app" ]; then
    rm -rf "$tmp"; say "The download has no CtxGraph.app" "받은 파일에 CtxGraph.app 이 없어요"; return 1
  fi
  mkdir -p "$(dirname "$APP")"; rm -rf "$APP"; mv "$tmp/x/CtxGraph.app" "$APP"; rm -rf "$tmp"
  say "Installed the prebuilt CtxGraph $ver (checksum verified): $APP" "미리 빌드된 CtxGraph $ver 버전을 설치했어요 (체크섬 확인): $APP"
  say "  It is the $ver release, so changes made in this checkout after it aren't included." "  $ver 릴리스라서 그 뒤에 이 소스에 생긴 변경은 들어 있지 않아요."
}

# 빌드가 끝내 안 되면: 터미널에서 직접 실행했으면 미리 빌드된 앱을 설치할지 묻는다 (개발용 DEV=1 은 소스가 필요해서 제외)
offer_prebuilt() {
  [ -z "${DEV:-}" ] || return 1
  [ -t 0 ] && [ -z "${CI:-}" ] || return 1
  printf '%s' "$(say "Install the prebuilt app from GitHub Releases instead? [Y/n] " "대신 GitHub Releases 의 미리 빌드된 앱을 설치할까요? [Y/n] ")"
  local ans; read -r ans || ans=n
  case "$ans" in [nN]*) return 1 ;; esac
  install_prebuilt
}

case "${1:-}" in
  --check)
    if preflight; then say "Ready to build: ./build.sh" "빌드할 준비가 됐어요: ./build.sh"; exit 0; fi
    exit 1 ;;
  --prebuilt)
    [ -z "${DEV:-}" ] || { say "DEV=1 needs a build from source." "DEV=1 은 소스에서 빌드해야 해요."; exit 1; }
    install_prebuilt; exit $? ;;
  "") ;;
  *) say "Usage: ./build.sh [--check | --prebuilt]   (DEV=1, OUT=<path>)" "사용법: ./build.sh [--check | --prebuilt]   (DEV=1, OUT=<경로>)"; exit 2 ;;
esac
if ! preflight; then
  say "Fix the items marked ✗ and run ./build.sh again — or install the prebuilt app: ./build.sh --prebuilt" \
      "✗ 표시를 해결하고 ./build.sh 를 다시 실행하세요 — 미리 빌드된 앱을 설치해도 돼요: ./build.sh --prebuilt"
  exit 1
fi

cd "$ROOT/app"
mkdir -p "$ROOT/app/.build"
# 출력은 $LOG 에 모았다가 실패했을 때만 보여 준다 (다른 설정으로 다시 할 때 실패한 시도가 화면을 덮지 않게)
LOG="$(mktemp -t ctxgraph-build)"
trap 'rm -f "$LOG"' EXIT
STAMP="$ROOT/app/.build/.toolchain"   # 이 캐시를 만든 개발자 도구·SDK·Swift
CHOICE="$ROOT/app/.build/.choice"     # 기본 설정으로 안 됐을 때 된 조합 "DEVELOPER_DIR|SDKROOT" — 다음부터 바로 쓴다
MACRO_ERR="plugin for module 'SwiftUIMacros' not found"
show_log() { grep -vE "PlatformPath|XCTest|show-sdk-platform-path" "$LOG" || true; }
toolchain_id() { printf '%s|%s|%s' "${1:-$(xcode-select -p)}" "$2" "$(env ${1:+"DEVELOPER_DIR=$1"} swift --version 2>/dev/null | head -1)"; }

attempt() {   # $1 = DEVELOPER_DIR, $2 = SDKROOT (빈 값 = 지금 설정 그대로), $3 = 캐시 비울 때 알릴지
  local id keep; id=$(toolchain_id "$1" "$2")
  # 다른 컴파일러·SDK 로 만든 캐시는 'module compiled with Swift …' 같은 오류를 내므로 비운다 (고른 조합은 남김)
  if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" != "$id" ]; then
    [ -n "${3:-}" ] && say "The Swift toolchain changed — clearing the old build cache" "Swift 가 바뀌어서 예전 빌드 캐시를 지워요"
    keep=$(cat "$CHOICE" 2>/dev/null || true)
    rm -rf "$ROOT/app/.build"; mkdir -p "$ROOT/app/.build"
    [ -z "$keep" ] || printf '%s' "$keep" > "$CHOICE"
  fi
  printf '%s' "$id" > "$STAMP"
  env ${1:+"DEVELOPER_DIR=$1"} ${2:+"SDKROOT=$2"} swift build -c release >"$LOG" 2>&1
}

find_xcodes() {   # 설치된 Xcode 의 Developer 폴더, 새 버전 먼저 (CTXGRAPH_XCODES 로 바꿔 시험)
  if [ -n "${CTXGRAPH_XCODES+x}" ]; then printf '%s\n' "$CTXGRAPH_XCODES" | sed '/^$/d'; return 0; fi
  { ls -d /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app 2>/dev/null || true
    mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true; } |
  while IFS= read -r x; do
    [ -d "$x/Contents/Developer" ] || continue
    v=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$x/Contents/Info.plist" 2>/dev/null) || continue
    printf '%s\t%s\n' "$v" "$(cd -P "$x" && pwd)/Contents/Developer"
  done | sort -t "$(printf '\t')" -k2,2 -u | sort -t. -k1,1nr -k2,2nr -k3,3nr | cut -f2
}

USE_DEV=""; USE_SDK=""
if [ -z "${DEVELOPER_DIR:-}${SDKROOT:-}" ] && [ -f "$CHOICE" ]; then
  IFS='|' read -r USE_DEV USE_SDK < "$CHOICE" || true
  if { [ -n "$USE_DEV" ] && [ ! -d "$USE_DEV" ]; } || { [ -n "$USE_SDK" ] && [ ! -d "$USE_SDK" ]; }; then
    USE_DEV=""; USE_SDK=""; rm -f "$CHOICE"
  else
    say "Using the setup that worked last time: ${USE_DEV:-$(xcode-select -p)}${USE_SDK:+ + $(basename "$USE_SDK")}" \
        "지난번에 된 설정으로 빌드해요: ${USE_DEV:-$(xcode-select -p)}${USE_SDK:+ + $(basename "$USE_SDK")}"
  fi
fi
say "Building (about a minute the first time)…" "빌드 중 (처음엔 1분쯤)…"
set +e; attempt "$USE_DEV" "$USE_SDK" announce; status=$?; set -e

# Command Line Tools 만 있는 Mac: 가장 새 SDK 의 SwiftUI 는 @State 를 매크로로 쓰는데, 그 플러그인(SwiftUIMacros)은
# Xcode 에만 있다 (PR #1: macOS 27.2 + CLT 27.2, Swift 6.4.2). 사용자가 DEVELOPER_DIR·SDKROOT 를 정했으면 건드리지 않는다.
if [ "$status" -ne 0 ] && grep -q "$MACRO_ERR" "$LOG" && [ -z "${DEVELOPER_DIR:-}${SDKROOT:-}" ]; then
  say "These developer tools don't have the SwiftUI macro plugin (SwiftUIMacros) that the newest SDK needs. Trying other setups…" \
      "이 개발자 도구엔 새 SDK 가 쓰는 SwiftUI 매크로 플러그인(SwiftUIMacros)이 없어요. 다른 설정으로 해 볼게요…"
  FAILED_DEV="$(cd -P "${USE_DEV:-$(xcode-select -p)}" && pwd)"
  # 1) 설치된 Xcode: 플러그인이 들어 있다. sudo xcode-select 없이 이 빌드에만 DEVELOPER_DIR 로 쓴다
  while IFS= read -r dev <&3; do
    [ -z "${CTXGRAPH_XCODES+x}" ] && [ "$(cd -P "$dev" 2>/dev/null && pwd)" = "$FAILED_DEV" ] && continue
    if ! env DEVELOPER_DIR="$dev" swift --version >/dev/null 2>&1; then
      note "Skipping $dev — its license isn't accepted yet (sudo xcodebuild -license accept)" "$dev 는 건너뛰어요 — 라이선스 동의가 안 됨 (sudo xcodebuild -license accept)"
      continue
    fi
    say "  → $dev" "  → $dev"
    set +e; attempt "$dev" ""; status=$?; set -e
    if [ "$status" -eq 0 ]; then printf '%s|' "$dev" > "$CHOICE"; break; fi
    grep -q "$MACRO_ERR" "$LOG" || break   # 다른 이유로 실패하면 거기서 멈춘다
  done 3< <(find_xcodes)
  # 2) Command Line Tools 에 같이 들어 있는 이전 SDK (새 것부터)
  if [ "$status" -ne 0 ] && grep -q "$MACRO_ERR" "$LOG"; then
    CUR_SDK="$(cd -P "$(xcrun --show-sdk-path)" && pwd)"
    TRIED=" $CUR_SDK "
    while IFS= read -r sdk <&3; do
      real="$(cd -P "$sdk" && pwd)"
      case "$TRIED" in *" $real "*) continue ;; esac   # 같은 SDK 를 가리키는 링크는 한 번만
      TRIED="$TRIED$real "
      say "  → $(basename "$real")" "  → $(basename "$real")"
      set +e; attempt "" "$real"; status=$?; set -e
      if [ "$status" -eq 0 ]; then printf '|%s' "$real" > "$CHOICE"; break; fi
      grep -q "$MACRO_ERR" "$LOG" || break
    done 3< <(ls -d "$(dirname "$CUR_SDK")"/MacOSX[0-9]*.sdk 2>/dev/null | sed -E 's/.*MacOSX([0-9.]+)\.sdk$/\1 &/' | sort -t. -k1,1nr -k2,2nr | cut -d' ' -f2-)
  fi
fi

if [ "$status" -ne 0 ]; then
  show_log | tail -60
  say "Build failed (swift build exit $status) — nothing was installed." "빌드 실패 (swift build exit $status) — 아무것도 설치하지 않았어요."
  if grep -q "$MACRO_ERR" "$LOG"; then
    say "  No installed Xcode or SDK has the SwiftUI macro plugin. Installing Xcode (App Store) fixes this for good." \
        "  설치된 Xcode·SDK 중 SwiftUI 매크로 플러그인이 있는 게 없어요. Xcode(App Store)를 설치하면 해결돼요."
  fi
  if offer_prebuilt; then exit 0; fi
  say "  Known problems and fixes: docs/DEVELOPMENT.md#building — or install the prebuilt app: ./build.sh --prebuilt" \
      "  알려진 문제와 해결: docs/DEVELOPMENT.md#building — 미리 빌드된 앱 설치: ./build.sh --prebuilt"
  exit 1
fi
grep -E "^Build complete" "$LOG" || true   # 성공하면 경고(대부분 SwiftTerm)는 감추고 끝 줄만
BIN="$ROOT/app/.build/release/CtxGraph"
[ -x "$BIN" ] || { say "Build failed: $BIN is missing" "빌드 실패: $BIN 이 없어요"; exit 1; }

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
python3 -B "$ROOT/app/Localization/build_strings.py" >/dev/null 2>&1 \
  || say "  ! Couldn't regenerate translations — using the ones in the repository" "  ! 번역 파일을 다시 만들지 못해 저장소에 있는 것을 써요"
cp -R "$ROOT/app/Localization/"*.lproj "$APP/Contents/Resources/"
# 백엔드 스크립트 (배포판은 첫 실행 때 ~/Library/Application Support/CtxGraph/bin 에 풀어 씀)
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT/bin/ctxgraph.py" "$ROOT/bin/ctxpty.py" "$ROOT/bin/ctxgraph" "$ROOT/bin/ctx-skill.md" "$ROOT/bin/ctx-skill.en.md" "$APP/Contents/Resources/bin/"
# DEV=1: 소스의 bin 을 바로 쓰게
if [ -n "${DEV:-}" ]; then
  plutil -insert CtxGraphSourceBin -string "$ROOT/bin" "$APP/Contents/Info.plist"   # 경로에 공백이 있어도 됨 (PlistBuddy 는 깨짐)
fi
codesign --force --sign - "$APP" >/dev/null 2>&1
say "Built: $APP" "완료: $APP"
