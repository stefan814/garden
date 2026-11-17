#!/bin/bash
# Cross-version test: an app on an OLDER Garden and an app on this one share one copy on the same phone, both ways.
# Apps pin Garden versions independently (Earshot and Skald each pin their own), so the on-device format must stay
# compatible across every version. Builds the harness at <old ref> (in a temporary worktree) and at HEAD.
# Usage: tests/compat.sh <adb serial> [old ref, default 608f565: the last Garden with a bundled model list]
set -u
SERIAL=${1:?serial}; OLD=${2:-608f565}
cd "$(dirname "$0")/.."
ROOT=$(git rev-parse --show-toplevel); P=io.github.stefan814.garden.harness; PASS=0
ADB="$HOME/Library/Android/sdk/platform-tools/adb -s $SERIAL"
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
WT=$(mktemp -d)/garden-old
git -C "$ROOT" worktree add -q --detach "$WT" "$OLD" || exit 1
trap 'git -C "$ROOT" worktree remove --force "$WT"' EXIT
# Test models and the sherpa AAR aren't in git: share this checkout's.
mkdir -p "$WT/android/harness/src/a" "$WT/android/harness/libs"
cp -R harness/src/a/assets "$WT/android/harness/src/a/"; cp harness/libs/*.aar "$WT/android/harness/libs/"; cp local.properties "$WT/android/"
echo "### build: old ($OLD) and new (HEAD) harness apps"
(cd "$WT/android" && ./gradlew -q :harness:assembleADebug :harness:assembleBDebug) || { echo "old build failed"; exit 1; }
./gradlew -q :harness:assembleADebug :harness:assembleBDebug || { echo "new build failed"; exit 1; }
OLDAPK="$WT/android/harness/build/outputs/apk"; NEWAPK=harness/build/outputs/apk

step() {  # step <a|b> <do> <model>
  $ADB logcat -c
  $ADB shell am start -W -n $P.$1/$P.Harness --es do $2 --es model $3 >/dev/null
  for _ in $(seq 1 240); do $ADB logcat -d -s GARDEN:I | grep -q "== done" && break; sleep 1; done
  OUT=$($ADB logcat -d -s GARDEN:I -v raw | grep -v '^-')
}
expect() {
  if echo "$OUT" | grep -qE "$2"; then PASS=$((PASS+1)); echo "PASS  $1"
  else echo "FAIL  $1"; echo "      wanted /$2/ in:"; echo "$OUT" | sed 's/^/      | /'; exit 1; fi
}
fresh() { $ADB uninstall $P.a >/dev/null 2>&1; $ADB uninstall $P.b >/dev/null 2>&1; $ADB install -t "$1" >/dev/null; $ADB install -t "$2" >/dev/null; }
M=parakeet-tdt-110m-en-int8; TEXT="text='The goblin king"

echo "### old app shares, new app uses it"
fresh "$OLDAPK/a/debug/harness-a-debug.apk" "$NEWAPK/b/debug/harness-b-debug.apk"
step a contribute $M;  expect "1 old a contributes Parakeet" "= Ready\(SHARED\)"
step b state $M;       expect "2 new b sees it" "= SharedAvailable"
step b adopt $M;       expect "3 new b adopts, no network" "= Ready\(SHARED\)"
step b load $M;        expect "4 new b transcribes from it" "LOADED .* $TEXT"
step a remove $M;      expect "5 old a lets go" "= SharedAvailable"
step b load $M;        expect "6 new b unaffected" "LOADED .* $TEXT"
step b remove $M
echo "### new app shares, old app uses it"
fresh "$NEWAPK/a/debug/harness-a-debug.apk" "$OLDAPK/b/debug/harness-b-debug.apk"
step a contribute $M;  expect "7 new a contributes Parakeet" "= Ready\(SHARED\)"
step b state $M;       expect "8 old b sees it" "= SharedAvailable"
step b adopt $M;       expect "9 old b adopts, no network" "= Ready\(SHARED\)"
step b load $M;        expect "10 old b transcribes from it" "LOADED .* $TEXT"
OUT=$($ADB shell dumpsys blob_store | grep -c "tag:garden/v1/$M/encoder.int8.onnx"); expect "11 one copy on the phone" "^1$"
step b remove $M; step a remove $M
$ADB uninstall $P.a >/dev/null; $ADB uninstall $P.b >/dev/null
echo "ALL $PASS CHECKS PASSED (old $OLD <-> new $(git rev-parse --short HEAD))"
