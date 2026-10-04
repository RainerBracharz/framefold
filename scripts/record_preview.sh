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
  rm -f "$OUT/$L.mp4"
  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/$L.mp4" 2>/dev/null &
  REC=$!
  sleep 2
  now > "$OUT/$L-start.txt"
  TEST_RUNNER_FF_LANG=$L TEST_RUNNER_FF_SHOT_DIR="$OUT" TEST_RUNNER_FF_SIM_FRAMES="$FRAMES" \
    xcodebuild test-without-building -scheme FrameFold -destination "id=$UDID" \
    -derivedDataPath build/preview -only-testing:FrameFoldUITests/FrameFoldUITests/testPreview \
    -quiet || echo "(Test meldet Fehler – Video wird trotzdem behalten, siehe $OUT/$L/log.txt)"
  sleep 1
  kill -INT $REC; wait $REC 2>/dev/null || true
  echo "→ $OUT/$L.mp4"
done

xcrun simctl status_bar "$UDID" clear
echo "Fertig. Aufnahmen in $OUT"
