#!/bin/bash
# Nimmt die App-Vorschau für den App Store im Simulator auf – je Sprache ein
# Bildschirmvideo, während der UI-Test „testPreview" die App bedient.
# Die Simulator-Kamera spielt dabei die Faltung aus FF_SIM_FRAMES ab.
#
#   scripts/record_preview.sh              # de en fr
#   scripts/record_preview.sh en           # nur eine Sprache
#
# Ergebnis: ~/Desktop/framefold-spot/preview-raw/<sprache>.mp4 (+ Zeitmarken)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then LANGS=("$@"); else LANGS=(de en fr); fi
DEVICE="iPhone 17 Pro Max"
SPOT="$HOME/Desktop/framefold-spot"
OUT="$SPOT/preview-raw"
FRAMES=/tmp/ff-simframes            # Simulator-Apps dürfen nicht auf den Schreibtisch
mkdir -p "$OUT"
rm -rf "$FRAMES" && cp -R "$SPOT/simframes" "$FRAMES"

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
d = json.load(sys.stdin)['devices']
c = [x for v in d.values() for x in v if x['name'] == '$DEVICE']
c.sort(key=lambda x: x['state'] != 'Booted')
print(c[0]['udid'] if c else '')")
[ -z "$UDID" ] && { echo "Kein Simulator „$DEVICE“ gefunden."; exit 1; }
echo "Simulator: $DEVICE ($UDID)"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""

echo "Baue …"
xcodebuild build-for-testing -scheme FrameFold -destination "id=$UDID" \
  -derivedDataPath build/preview -quiet

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

for L in "${LANGS[@]}"; do
  echo "── $L ──"
  rm -f "$OUT/$L.mp4" "$OUT/$L-start.txt" "$OUT/$L-record.log" "$OUT/$L-xcodebuild.log"
  # Startzeit genau dann, wenn simctl wirklich aufnimmt
  echo "Simulator-Zustand: $(xcrun simctl list devices | grep "$UDID" | sed 's/.*(\(.*\)).*/\1/')"
  ( xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/$L.mp4" 2>&1 | while read -r line; do
      echo "$line" >> "$OUT/$L-record.log"
      case "$line" in *"Recording started"*) now > "$OUT/$L-start.txt";; esac
    done ) &
  sleep 3
  [ -s "$OUT/$L-start.txt" ] || now > "$OUT/$L-start.txt"   # Meldung kam nicht durch: ungefähr reicht
  # Kein Parallel-Testen: sonst läuft der Test auf einem Klon und die Aufnahme zeigt den Homescreen
  TEST_RUNNER_FF_LANG=$L TEST_RUNNER_FF_SHOT_DIR="$OUT" TEST_RUNNER_FF_SIM_FRAMES="$FRAMES" \
    xcodebuild test-without-building -scheme FrameFold -destination "id=$UDID" \
    -derivedDataPath build/preview -parallel-testing-enabled NO \
    -only-testing:FrameFoldUITests/FrameFoldUITests/testPreview \
    > "$OUT/$L-xcodebuild.log" 2>&1 || echo "(Test meldet Fehler – Protokoll: $OUT/$L-xcodebuild.log)"
  sleep 1
  pkill -INT -f "simctl io $UDID recordVideo" || true
  wait
  ls -la "$OUT/$L.mp4" 2>/dev/null || echo "!! keine Aufnahme – siehe $OUT/$L-record.log"
done

xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
echo "Fertig. Aufnahmen in $OUT"
