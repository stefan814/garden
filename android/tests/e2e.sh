#!/bin/bash
# End-to-end test of the Model Library on a device/emulator, using the harness installed as two apps (a, b).
# Usage: tests/e2e.sh <adb serial>      (emulator only for the download tests: they use the host server at 10.0.2.2)
# Starts tests/server.py on :8765 itself. Exits non-zero on the first failed check.
set -u
SERIAL=${1:?serial}
cd "$(dirname "$0")/.."
ADB="$HOME/Library/Android/sdk/platform-tools/adb -s $SERIAL"
P=io.github.stefan814.garden.harness
DATA=tests/testdata; LOG=$(mktemp); PASS=0
mkdir -p $DATA
cp harness/src/a/assets/models/silero-vad-v5/vad.onnx harness/src/a/assets/models/titanet-small-en/embed.onnx $DATA/
python3 tests/make-testdata.py $DATA >/dev/null
python3 tests/server.py $DATA $LOG & SERVER=$!
# Emulators reach the host at 10.0.2.2; a real phone reaches it through adb reverse at 127.0.0.1.
if [[ $SERIAL == emulator-* ]]; then HOST=10.0.2.2; else HOST=127.0.0.1; $ADB reverse tcp:8765 tcp:8765 >/dev/null; fi
trap 'kill $SERVER 2>/dev/null; [[ $SERIAL == emulator-* ]] || $ADB reverse --remove tcp:8765 >/dev/null 2>&1' EXIT
sleep 1

step() {  # step <a|b> <do> <model> [am extras...]  -> prints the GARDEN lines
  local app=$1 do=$2 model=$3; shift 3
  $ADB logcat -c
  $ADB shell am start -W -n $P.$app/$P.Harness --es do $do --es model $model "$@" >/dev/null
  for _ in $(seq 1 240); do $ADB logcat -d -s GARDEN:I | grep -q "== done" && break; sleep 1; done
  [ "$do" = svcload ] && for _ in $(seq 1 60); do $ADB logcat -d -s GARDEN:I | grep -q "== done" && break; sleep 1; done
  OUT=$($ADB logcat -d -s GARDEN:I -v raw | grep -v '^-')
}
expect() {  # expect <description> <regex>
  if echo "$OUT" | grep -qE "$2"; then PASS=$((PASS+1)); echo "PASS  $1"
  else echo "FAIL  $1"; echo "      wanted /$2/ in:"; echo "$OUT" | sed 's/^/      | /'; exit 1; fi
}
served() { grep -c "^$1 $2" $LOG; }   # served <mode> <name> -> request count

echo "### setup: fresh installs, no shared model files"
$ADB uninstall $P.a >/dev/null 2>&1; $ADB uninstall $P.b >/dev/null 2>&1
$ADB install -t harness/build/outputs/apk/a/debug/harness-a-debug.apk >/dev/null
$ADB install -t harness/build/outputs/apk/b/debug/harness-b-debug.apk >/dev/null
OUT=$($ADB shell dumpsys blob_store | grep -c "label:Garden " || true); expect "no Garden blobs before the run" "^0$"

echo "### real catalog, across two apps"
step b state parakeet-tdt-110m-en-int8;            expect "1 b sees nothing yet" "STATE parakeet-tdt-110m-en-int8 = Missing\(partial=no\)"
step a contribute parakeet-tdt-110m-en-int8;       expect "2 a contributes Parakeet from its APK" "STATE .* = Ready\(SHARED\)"
step b state parakeet-tdt-110m-en-int8;            expect "3 b sees a shared copy" "= SharedAvailable"
step b load parakeet-tdt-110m-en-int8;             expect "4 b can't open before adopting (error, no crash)" "ERROR NotReady"
step b adopt parakeet-tdt-110m-en-int8;            expect "5 b adopts without network" "= Ready\(SHARED\)"
step b load parakeet-tdt-110m-en-int8;             expect "6 b transcribes from the shared copy" "LOADED .* in activity: text='The goblin king opened the door and asked the party for three pieces of gold.'"
step b svcload parakeet-tdt-110m-en-int8;          expect "7 same from a Service context" "LOADED .* in service: text='The goblin king"
step b loadclose parakeet-tdt-110m-en-int8;        expect "8 closing the OpenModel after building the engine is safe" "LOADED .* text='The goblin king"
$ADB uninstall $P.a >/dev/null; $ADB install -t harness/build/outputs/apk/a/debug/harness-a-debug.apk >/dev/null
step a state parakeet-tdt-110m-en-int8;            expect "9 reinstalled a still finds it (b co-committed)" "= SharedAvailable"
step a adopt parakeet-tdt-110m-en-int8;            expect "10a a adopts" "= Ready\(SHARED\)"
step a remove parakeet-tdt-110m-en-int8;           expect "10b a removes its hold" "= SharedAvailable"
step b load parakeet-tdt-110m-en-int8;             expect "10c b unaffected" "LOADED .* text='The goblin king"
step b load silero-vad-v5;                         expect "11 a model nobody has: clean error" "ERROR NotReady.*isn't on this phone"

echo "### same bytes, any app's names for them"
T="--es catalog test --es host $HOST"
step b state t-alias $T;                           expect "22 b already holds Parakeet's vocabulary: under another name it's Ready" "STATE t-alias = Ready\(SHARED\)"
step a state t-alias $T;                           expect "22 a (which let go) finds it by its own name" "STATE t-alias = SharedAvailable"
step a adopt t-alias $T;                           expect "22 and adopts it" "STATE t-alias = Ready\(SHARED\)"
OUT=$($ADB shell dumpsys blob_store | grep -c "garden/v1/parakeet-tdt-110m-en-int8/tokens.txt");  expect "22 one copy on the phone" "^1$"
step a download t-v2a $T;                          expect "23 a downloads a file no older version knew" "STATE t-v2a = Ready\(SHARED\)"
BEFORE=$(served ok alias.bin)
step b state t-v2b $T;                             expect "23 b, calling it something else, sees it" "STATE t-v2b = SharedAvailable"
step b adopt t-v2b $T;                             expect "23 and adopts it" "STATE t-v2b = Ready\(SHARED\)"
OUT="$BEFORE $(served ok alias.bin)";              expect "23 ...without touching the network" "^([0-9]+) \1$"
OUT=$($ADB shell dumpsys blob_store | grep -c "garden/v2/0872da6e48ff149e3ce7379620ab956dd8751ac115a6489dac028181ac314524"); expect "23 one copy, named by its hash" "^1$"
step a remove t-v2a $T;                         expect "23 a lets go" "STATE t-v2a = SharedAvailable"
step b remove t-v2b $T;                            expect "23 b lets go" "STATE t-v2b = (SharedAvailable|Missing)"

echo "### split models and descriptor leaks"
step a contribute t-split --es catalog test --es host $HOST --es skip embed.onnx; expect "20 half shared, half missing" "STATE t-split = Missing\(partial=no\)"
step a contribute t-split --es catalog test --es host $HOST --ez share false;     expect "20 rest added privately: a split model is Ready" "STATE t-split = Ready\(SHARED\)"
step a load t-split --es catalog test --es host $HOST;                            expect "20 and it opens across both stores" "LOADED t-split .* dim=192"
step a fdloop t-split --es catalog test --es host $HOST;                          expect "21 30 open/load/close cycles" "FDS before="
N=$(echo "$OUT" | sed -nE 's/.*FDS before=([0-9]+) after=([0-9]+).*/\1 \2/p')
OUT=$(echo $N | awk '{ print ($2 - $1 <= 3) ? "flat" : "LEAK " $0 }'); expect "21 no descriptor leak ($N)" "^flat$"

step a remove t-split --es catalog test --es host $HOST;          expect "21 split model removed" "STATE t-split = Missing\(partial=no\)"

echo "### downloads (test catalog, host server)"
step a download t-resume $T;                       expect "12 dropped connection resumes" "= Ready\(SHARED\)"
OUT=$(grep "^cut resume.bin" $LOG);                 expect "12 second request asked for a Range" "^cut resume.bin bytes=[1-9][0-9]*-$"
step a download t-norange $T;                      expect "13 server ignoring Range restarts cleanly" "= Ready\(SHARED\)"
OUT=$(grep "^cutnorange" $LOG);                    expect "13 resume was attempted" "bytes=[1-9]"
step a load t-norange $T;                          expect "13 and the file works" "LOADED t-norange .* dim=192"
step a download t-corrupt $T;                      expect "14 bad bytes rejected by the system's SHA check" "ERROR Checksum"
expect "14 nothing half-kept" "STATE t-corrupt = Missing\(partial=no\)"
step a download t-mirror $T;                       expect "15 dead mirror skipped" "= Ready\(SHARED\)"
OUT=$(grep -E "^(dead|ok) mirror.bin" $LOG);       expect "15 tried dead first, then ok" "dead mirror.bin"
step a download t-privcorrupt $T --ez share false; expect "16 private bad bytes rejected" "ERROR Checksum"
expect "16 nothing half-kept (the split test's shared copy of the same file may still be there)" "STATE t-privcorrupt = (Missing\(partial=no\)|SharedAvailable)"
step a download t-private $T --ez share false;     expect "17 private download" "= Ready\(PRIVATE\)"
step a load t-private $T;                          expect "17 private copy loads" "LOADED t-private .* speechWindows="
step a state t-privcorrupt $T;                     expect "17 private copies are shared by hash inside one app" "= Ready\(PRIVATE\)"
step a download t-pause $T --ei attempts 1;        expect "18 a failed try leaves a paused download" "STATE t-pause = Missing\(partial=yes\)"
step a download t-pause $T;                        expect "18 next call resumes and finishes" "= Ready\(SHARED\)"
OUT=$(grep "^cut pause.bin" $LOG);                 expect "18 resumed with a Range" "bytes=[1-9]"
BEFORE=$(served cut resume.bin)
step b state t-resume $T;                          expect "19 b sees a's download" "= SharedAvailable"
step b download t-resume $T;                       expect "19 b 'download' adopts instead" "= Ready\(SHARED\)"
OUT="$BEFORE $(served cut resume.bin)";              expect "19 ...without touching the network" "^([0-9]+) \1$"

echo "### cleanup"
for m in parakeet-tdt-110m-en-int8; do step b remove $m; done
step a remove t-alias $T
for m in t-resume t-norange t-mirror t-pause; do step a remove $m $T; step b remove $m $T; done
step a remove t-private $T
$ADB uninstall $P.a >/dev/null; $ADB uninstall $P.b >/dev/null
echo "ALL $PASS CHECKS PASSED"
