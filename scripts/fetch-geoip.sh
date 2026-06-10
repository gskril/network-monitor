#!/bin/sh
# Downloads the free DB-IP "IP to City Lite" database so the app can show an
# estimated city/country and map pin for each remote IP. The data is offline:
# nothing about your connections ever leaves your Mac.
#
# DB-IP Lite is free under CC-BY 4.0 (https://db-ip.com). Run monthly to refresh.
#
# Usage:  scripts/fetch-geoip.sh
set -e

DEST_DIR="$HOME/Library/Application Support/NetworkMonitor"
DEST="$DEST_DIR/GeoLite-City.mmdb"
mkdir -p "$DEST_DIR"

fetch() {
    month="$1"
    url="https://download.db-ip.com/free/dbip-city-lite-$month.mmdb.gz"
    echo "• Trying $url"
    curl -fSL "$url" -o "$DEST.gz"
}

# This month, falling back to last month if the new file isn't published yet.
this_month=$(date +%Y-%m)
last_month=$(date -v-1m +%Y-%m 2>/dev/null || date -d 'last month' +%Y-%m)

if ! fetch "$this_month"; then
    echo "• Falling back to $last_month"
    fetch "$last_month"
fi

gunzip -f "$DEST.gz"
echo "Installed $DEST ($(du -h "$DEST" | cut -f1)). Relaunch the app to enable the map."
