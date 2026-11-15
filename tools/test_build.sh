#!/bin/bash
# build.sh 의 대체 경로 시험: 가짜 swift 로 'SwiftUIMacros 플러그인 없음' 을 흉내 내고, build.sh 가
# 설치된 Xcode → 이전 SDK → 미리 빌드된 앱 순서로 제대로 넘어가는지 본다. 실제 빌드도 한다 (캐시가 있으면 빠름).
#   tools/test_build.sh            전부
#   SKIP_SDK=1 tools/test_build.sh 이전 SDK 시험 빼기 (캐시를 비우고 다시 빌드해서 몇 분 걸림)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_SWIFT="$(command -v swift)"
WORK="$(mktemp -d -t ctxgraph-buildtest)"
trap 'rm -rf "$WORK"; rm -f "$ROOT/app/.build/.choice"' EXIT
mkdir -p "$WORK/bin"
# FAKE: macro_unless_dev | macro_unless_sdk | macro_always — --version 은 늘 진짜로
cat > "$WORK/bin/swift" <<EOF
#!/bin/bash
[ "\${1:-}" = "--version" ] && exec "$REAL_SWIFT" "\$@"
case "\${FAKE:-}" in
  macro_unless_dev) [ -n "\${DEVELOPER_DIR:-}" ] && exec "$REAL_SWIFT" "\$@" ;;
  macro_unless_sdk) [ -n "\${SDKROOT:-}" ] && exec "$REAL_SWIFT" "\$@" ;;
esac
echo "error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found" >&2
exit 1
EOF
chmod +x "$WORK/bin/swift"

pass=0; fail=0
check() {   # $1 이름, $2 기대 종료 코드, $3 출력에 있어야 할 글 (grep -E), $4 .choice 에 있어야 할 글 (없으면 빈칸)
  local code=$5 out=$6
  if [ "$code" = "$2" ] && grep -qE "$3" <<<"$out" && { [ -z "$4" ] || grep -qF "$4" "$ROOT/app/.build/.choice" 2>/dev/null; }; then
    echo "ok   $1"; pass=$((pass+1))
  else
    echo "FAIL $1 (exit $code, wanted $2)"; printf '%s\n' "$out" | tail -15 | sed 's/^/     /'; fail=$((fail+1))
  fi
}
run() { (cd "$ROOT" && PATH="$WORK/bin:$PATH" LANG=en_US.UTF-8 OUT="$WORK/out/CtxGraph.app" "$@" ./build.sh </dev/null 2>&1); }

DEV_DIR="$(xcode-select -p)"
rm -f "$ROOT/app/.build/.choice"

out=$(run env FAKE=macro_unless_dev CTXGRAPH_XCODES="$DEV_DIR"); code=$?
check "no plugin → uses the installed Xcode" 0 "→ $DEV_DIR" "$DEV_DIR|" "$code" "$out"
out=$(run env FAKE=macro_unless_dev CTXGRAPH_XCODES="$DEV_DIR"); code=$?
check "next build reuses it at once" 0 "worked last time" "$DEV_DIR|" "$code" "$out"
if grep -q "Trying other setups" <<<"$out"; then echo "FAIL     …but it tried again"; fail=$((fail+1)); fi
rm -f "$ROOT/app/.build/.choice"

out=$(run env FAKE=macro_unless_dev CTXGRAPH_XCODES="$DEV_DIR" SDKROOT="$(xcrun --show-sdk-path)"); code=$?
check "SDKROOT set by the user is left alone" 1 "Build failed" "" "$code" "$out"

out=$(run env FAKE=macro_always CTXGRAPH_XCODES=""); code=$?
check "nothing works → clear message, points to --prebuilt" 1 "No installed Xcode or SDK" "" "$code" "$out"

SDKS=$(ls -d "$(dirname "$(cd -P "$(xcrun --show-sdk-path)" && pwd)")"/MacOSX[0-9]*.sdk 2>/dev/null | while read -r s; do (cd -P "$s" && pwd); done | sort -u | wc -l | tr -d ' ')
if [ -z "${SKIP_SDK:-}" ] && [ "$SDKS" -ge 2 ]; then
  out=$(run env FAKE=macro_unless_sdk CTXGRAPH_XCODES=""); code=$?
  check "no Xcode → falls back to an older SDK" 0 "→ MacOSX[0-9.]+\.sdk" "|/" "$code" "$out"
  rm -f "$ROOT/app/.build/.choice"
else
  echo "skip older-SDK fallback ($SDKS SDK(s) installed${SKIP_SDK:+, SKIP_SDK set})"
fi

# 미리 빌드된 앱: 진짜 릴리스를 받아 체크섬 확인, 그리고 틀린 파일은 거절
out=$(cd "$ROOT" && LANG=en_US.UTF-8 OUT="$WORK/pre/CtxGraph.app" ./build.sh --prebuilt 2>&1); code=$?
check "--prebuilt installs the verified release" 0 "checksum verified" "" "$code" "$out"
[ -x "$WORK/pre/CtxGraph.app/Contents/MacOS/CtxGraph" ] || { echo "FAIL     …but the app isn't there"; fail=$((fail+1)); }
ver=$(sed -n 's/^ *version "\([^"]*\)".*/\1/p' "$ROOT/packaging/homebrew/ctxgraph.rb")
mkdir -p "$WORK/fake-rel/v$ver" && echo "not the app" > "$WORK/fake-rel/v$ver/CtxGraph-$ver.zip"
out=$(cd "$ROOT" && LANG=en_US.UTF-8 OUT="$WORK/bad/CtxGraph.app" CTXGRAPH_RELEASES="file://$WORK/fake-rel" ./build.sh --prebuilt 2>&1); code=$?
check "--prebuilt refuses a file with the wrong checksum" 1 "Checksum mismatch" "" "$code" "$out"
[ ! -e "$WORK/bad/CtxGraph.app" ] || { echo "FAIL     …but it installed it"; fail=$((fail+1)); }

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
