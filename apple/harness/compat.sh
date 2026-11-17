#!/bin/bash
# Cross-version test in the iOS Simulator: an app on an OLDER version (v1 was called Garden / GardenKit) and an app on
# this one share one copy, both ways. Apps pin versions independently, so the on-device layout must stay compatible.
# Builds the harness at <old ref> (in a temporary worktree) and at HEAD; runs against android/tests/server.py on :8765.
# Usage: apple/harness/compat.sh <simulator udid> [old ref, default v1.0.0]
set -u
DEV=${1:?simulator udid}; OLD=${2:-v1.0.0}
cd "$(dirname "$0")/../.."
ROOT=$PWD; SERVER=; P=io.github.stefan814.garden.harness; PASS=0
DATA=android/tests/testdata; LOG=$(mktemp); TMP=$(mktemp -d); WT=$TMP/old
[ -f $DATA/vad.onnx ] || { mkdir -p $DATA; cp android/harness/src/a/assets/models/silero-vad-v5/vad.onnx $DATA/ || { echo "run scripts/fetch-deps.sh first"; exit 1; }; }
git worktree add -q --detach "$WT" "$OLD" || exit 1
trap 'kill $SERVER 2>/dev/null; git -C "$ROOT" worktree remove --force "$WT"; rm -rf "$TMP"' EXIT

echo "### build: old ($OLD) and new (HEAD) harness apps"
build() {  # build <repo root> <derived data>
  (cd "$1/apple/harness" && xcodegen -q) || return 1
  local proj=$(ls -td "$1"/apple/harness/*.xcodeproj | head -1)  # the one xcodegen just wrote
  for t in HarnessA HarnessB; do
    xcodebuild -project "$proj" -scheme $t -destination 'generic/platform=iOS Simulator' -derivedDataPath "$2" build -quiet \
      >/dev/null 2>&1 || return 1
  done
}
build "$WT" "$TMP/dd-old" || { echo "old build failed"; exit 1; }
build "$ROOT" "$TMP/dd-new" || { echo "new build failed"; exit 1; }
OLDAPPS=$TMP/dd-old/Build/Products/Debug-iphonesimulator; NEWAPPS=$TMP/dd-new/Build/Products/Debug-iphonesimulator

python3 android/tests/server.py $DATA $LOG & SERVER=$!
sleep 1

step() {  # step <a|b> <do> <model>
  OUT=$(xcrun simctl launch --console-pty --terminate-running-process $DEV $P.$1 -do $2 -model $3 2>&1 | grep '^GARDEN')
}
expect() {
  if echo "$OUT" | grep -qE "$2"; then PASS=$((PASS+1)); echo "PASS  $1"
  else echo "FAIL  $1"; echo "      wanted /$2/ in:"; echo "$OUT" | sed 's/^/      | /'; exit 1; fi
}
served() { grep -c "^ok vad.onnx" $LOG; }
fresh() {  # fresh <A.app> <B.app>
  xcrun simctl uninstall $DEV $P.a 2>/dev/null; xcrun simctl uninstall $DEV $P.b 2>/dev/null
  xcrun simctl install $DEV "$1"; xcrun simctl install $DEV "$2"
  step a remove t-share; step b remove t-share   # clear anything an earlier run left in the group
}

echo "### old app downloads, new app uses it"
fresh "$OLDAPPS/HarnessA.app" "$NEWAPPS/HarnessB.app"
step a download t-share;  expect "1 old a downloads into the shared store" "STATE t-share = ready\(.*shared\)"
N=$(served)
step b state t-share;     expect "2 new b sees it" "STATE t-share = sharedAvailable"
step b adopt t-share;     expect "3 new b adopts it" "STATE t-share = ready\(.*shared\)"
step b open t-share;      expect "4 new b reads every byte" "OPEN vad.onnx bytes=643854"
OUT=$(served);            expect "5 no second download" "^$N$"
step a remove t-share;    expect "6 old a lets go, the copy stays" "STATE t-share = sharedAvailable"
step b remove t-share;    expect "7 last holder gone" "STATE t-share = missing"

echo "### new app downloads, old app uses it"
fresh "$NEWAPPS/HarnessA.app" "$OLDAPPS/HarnessB.app"
step a download t-share;  expect "8 new a downloads into the shared store" "STATE t-share = ready\(.*shared\)"
N=$(served)
step b adopt t-share;     expect "9 old b adopts it" "STATE t-share = ready\(.*shared\)"
step b open t-share;      expect "10 old b reads every byte" "OPEN vad.onnx bytes=643854"
OUT=$(served);            expect "11 no second download" "^$N$"
step a remove t-share; step b remove t-share
xcrun simctl uninstall $DEV $P.a; xcrun simctl uninstall $DEV $P.b
echo "ALL $PASS CHECKS PASSED (old $OLD <-> new $(git rev-parse --short HEAD))"
