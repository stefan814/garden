#!/bin/bash
# Downloads every model in the real catalog from its real urls (GitHub / Hugging Face) into app b, loads each in its
# engine, then removes them and uninstalls. Usage: tests/real-downloads.sh <adb serial>
set -u
cd "$(dirname "$0")/.."
ADB() { "$HOME/Library/Android/sdk/platform-tools/adb" -s "$1" "${@:2}"; }
S=${1:?serial}; P=io.github.stefan814.garden.harness
ADB $S install -t harness/build/outputs/apk/b/debug/harness-b-debug.apk >/dev/null
run() {
  ADB $S logcat -c
  ADB $S shell am start -W -n $P.b/$P.Harness --es do $1 --es model $2 >/dev/null
  for _ in $(seq 1 400); do ADB $S logcat -d -s GARDEN:I | grep -q "== done" && break; sleep 1; done
  ADB $S logcat -d -s GARDEN:I -v raw | grep -vE '^-|^=='
}
for m in silero-vad-v5 titanet-small-en pyannote-seg-3.0 parakeet-tdt-110m-en-int8; do
  t0=$(date +%s); run download $m | grep -E "ERROR|STATE"; echo "  download took $(( $(date +%s) - t0 )) s"
  [ $m != pyannote-seg-3.0 ] && run load $m | grep -E "LOADED|ERROR"
done
for m in silero-vad-v5 titanet-small-en pyannote-seg-3.0 parakeet-tdt-110m-en-int8; do run remove $m | grep STATE; done
ADB $S uninstall $P.b >/dev/null
echo "garden blobs left: $(ADB $S shell dumpsys blob_store | grep -c 'label:Garden ')"
