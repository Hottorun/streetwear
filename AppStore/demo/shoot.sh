#!/bin/zsh
# Shoots the raw App Store screens from the fictional demo catalogue.
#
#   AppStore/demo/shoot.sh <simulator-udid>
#
# Needs a built app in /tmp/streetw-dd (see CLAUDE.md) and a booted 6.9" simulator.
# Every brand and garment on screen comes from `DemoCatalog` — nothing touches a real
# storefront, which is the point: App Review flags screenshots showing real brands.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEV=${1:?simulator udid}
HERE=${0:A:h}
APP=/tmp/streetw-dd/Build/Products/Debug-iphonesimulator/streetw.app
BUNDLE=com.kern.functional.streetw
PORT=8765
OUT="$HERE/raw"
mkdir -p "$OUT"

# The photographs, served to the simulator (which shares the host's loopback).
if ! curl -sf "http://127.0.0.1:$PORT/velmar-loafer.jpg" -o /dev/null; then
  python3 -m http.server $PORT --bind 127.0.0.1 --directory "$HERE/catalog" >/dev/null 2>&1 &
  SERVER=$!
  trap 'kill $SERVER 2>/dev/null' EXIT
  sleep 1
fi

COMMON=(-standalone YES -didOfferStarterPack YES -demoCatalog "http://127.0.0.1:$PORT"
        -seedSizes "M,L,10")

xcrun simctl status_bar "$DEV" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3

# A clean store every run, so the set is reproducible.
xcrun simctl uninstall "$DEV" $BUNDLE 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"

# Priming launch: seeds the catalogue and the size profile, which only applies next launch.
xcrun simctl launch "$DEV" $BUNDLE $COMMON >/dev/null
sleep 12
xcrun simctl terminate "$DEV" $BUNDLE || true

shot() {  # name, settle seconds, extra launch args...
  local name=$1 settle=$2; shift 2
  xcrun simctl terminate "$DEV" $BUNDLE 2>/dev/null || true
  xcrun simctl launch "$DEV" $BUNDLE $COMMON "$@" >/dev/null
  sleep $settle
  xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null
  echo "shot $name"
}

shot feed     10 -startTab feed -feedLastVisitHours 5
shot product  10 -startTab feed -demoOpen "restock:shopify:910001"
shot discover 14 -startTab discover
shot saved    40 -startTab saved
shot style    12 -startTab style
shot calendar 10 -startTab feed -feedFilter upcoming
shot fit      14 -startTab style -demoSheet fit

xcrun simctl terminate "$DEV" $BUNDLE || true
