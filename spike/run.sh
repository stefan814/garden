#!/bin/bash
# Usage: run.sh <serial> <a|b> <step>   — runs one spike step and prints its GARDEN log lines.
adb() { "$HOME/Library/Android/sdk/platform-tools/adb" -s "$SERIAL" "$@"; }
SERIAL=$1; P=io.github.stefan814.gardenspike.$2; STEP=$3
adb logcat -c
adb shell am start -W -n $P/io.github.stefan814.gardenspike.Spike --es do $STEP >/dev/null
for i in $(seq 1 90); do adb logcat -d -s GARDEN:I | grep -q "== done $STEP" && break; sleep 1; done
adb logcat -d -s GARDEN:I -v raw | grep -v '^-'
