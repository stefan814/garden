#!/bin/bash
# End-to-end test of GardenKit's shared store across apps, in the iOS Simulator.
# Builds the harness as apps A and B (same App Group) and C (no App Group), then runs steps against
# android/tests/server.py on :8765 (the Simulator reaches the Mac at 127.0.0.1).
# Usage: apple/harness/e2e.sh <simulator udid>
set -u
DEV=${1:?simulator udid}
cd "$(dirname "$0")/../.."
ROOT=$PWD; DD=${TMPDIR:-/tmp}/garden-harness-dd; P=io.github.stefan814.garden.harness
DATA=android/tests/testdata; LOG=$(mktemp); PASS=0
[ -f $DATA/vad.onnx ] && [ -f $DATA/embed.onnx ] || { mkdir -p $DATA; cp android/harness/src/a/assets/models/silero-vad-v5/vad.onnx android/harness/src/a/assets/models/titanet-small-en/embed.onnx $DATA/ || { echo "run scripts/fetch-deps.sh first"; exit 1; }; }

echo "### build"
(cd apple/harness && xcodegen -q) || exit 1
for t in HarnessA HarnessB HarnessC; do
  xcodebuild -project apple/harness/GardenHarness.xcodeproj -scheme $t -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath $DD build -quiet >/dev/null 2>&1 || { echo "build $t failed"; exit 1; }
done
APPS=$DD/Build/Products/Debug-iphonesimulator

python3 android/tests/server.py $DATA $LOG & SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

step() {  # step <a|b|c> <do> <model> [extra args...]
  local app=$1 do=$2 model=$3; shift 3
  OUT=$(xcrun simctl launch --console-pty --terminate-running-process $DEV $P.$app -do $do -model $model "$@" 2>&1 | grep '^GARDEN')
}
expect() {  # expect <description> <regex>
  if echo "$OUT" | grep -qE "$2"; then PASS=$((PASS+1)); echo "PASS  $1"
  else echo "FAIL  $1"; echo "      wanted /$2/ in:"; echo "$OUT" | sed 's/^/      | /'; exit 1; fi
}
served() { grep -c "^$1 $2" $LOG; }
install() { xcrun simctl install $DEV $APPS/Harness$1.app; }
uninstall() { xcrun simctl uninstall $DEV $P.$1 2>/dev/null; }

echo "### setup: fresh installs"
for a in a b c; do uninstall $a; done
install A; install B; install C

echo "### the real catalog is bundled"
step a realcatalog x;                     expect "1 real catalog parses, Parakeet missing" "REAL parakeet-tdt-110m-en-int8,.* state=missing"

echo "### one download, two apps"
step b state t-share;                     expect "2 b sees nothing yet" "STATE t-share = missing\(bytes: 643854, partial: 0\)"
step a download t-share;                  expect "3 a downloads into the shared store" "STATE t-share = ready\(GardenKit.Tier.shared\)"
OUT=$(served ok vad.onnx);                expect "4 one request to the server" "^1$"
step b state t-share;                     expect "5 b sees a's copy" "STATE t-share = sharedAvailable"
step b adopt t-share;                     expect "6 b adopts it" "STATE t-share = ready\(GardenKit.Tier.shared\)"
OUT=$(served ok vad.onnx);                expect "7 adopting used no network" "^1$"
step b open t-share;                      expect "8 b reads every byte" "OPEN vad.onnx bytes=643854 tier=shared"
step b state t-share;                     expect "9 both apps hold it" "HOLDERS a,b"
step c state t-share;                     expect "10 an app outside the group gets no group container" "GROUP none"

echo "### letting go"
step a remove t-share;                    expect "11 a lets go; the copy stays for b" "STATE t-share = sharedAvailable"
step b open t-share;                      expect "12 b still reads it" "OPEN vad.onnx bytes=643854"
step b remove t-share;                    expect "13 last holder gone: file deleted" "STATE t-share = missing"
step a state t-share;                     expect "14 a sees it gone too" "STATE t-share = missing"

echo "### private copy, resume, corrupt"
step a download t-share -share 0;         expect "15 private download" "STATE t-share = ready\(GardenKit.Tier.private\)"
step b state t-share;                     expect "16 b can't see a's private copy" "STATE t-share = missing"
step a remove t-share
step a download t-resume;                 expect "17 cut download resumes" "STATE t-resume = ready\(GardenKit.Tier.shared\)"
OUT=$(grep "^cut embed.onnx" $LOG);       expect "18 second request used Range" "cut embed.onnx bytes=20128641-"
step a download t-corrupt;                expect "19 corrupt bytes refused" "ERROR .*SHA-256"
step a state t-corrupt;                   expect "20 nothing kept" "STATE t-corrupt = missing\(bytes: 643854, partial: 0\)"

echo "### uninstalls"
step a download t-share; step b adopt t-share
uninstall a
step b open t-share;                      expect "21 a uninstalled: b keeps reading" "OPEN vad.onnx bytes=643854"
install A
step a state t-share;                     expect "22 reinstalled a finds the copy (its old marker survived)" "STATE t-share = (ready|sharedAvailable)"
uninstall a; uninstall b; install A
step a state t-share;                     expect "23 every group app gone: iOS deleted the shared store" "STATE t-share = missing"

for a in a b c; do uninstall $a; done
echo "### $PASS checks passed"
