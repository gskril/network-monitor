#!/bin/sh
# Removes the BPF helper installed by install-bpf-helper.sh and restores
# default (root-only) /dev/bpf* permissions on next boot.
#
# Usage:  sudo scripts/uninstall-bpf-helper.sh
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This must run as root. Re-run:  sudo $0" >&2
    exit 1
fi

LABEL="com.greg.networkmonitor.chmodbpf"
SUPPORT_DIR="/Library/Application Support/NetworkMonitor"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"

echo "• Unloading and removing the LaunchDaemon…"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"
rm -f "$SUPPORT_DIR/ChmodBPF.sh"
rmdir "$SUPPORT_DIR" 2>/dev/null || true

echo "• Restoring root-only permissions on /dev/bpf*…"
for dev in /dev/bpf*; do
    [ -e "$dev" ] || continue
    chown root:wheel "$dev" 2>/dev/null || true
    chmod 600 "$dev" 2>/dev/null || true
done

echo "• Removing the access_bpf group (membership too)…"
dseditgroup -o delete access_bpf 2>/dev/null || true

echo "Done. Network Monitor will fall back to reverse DNS for hostnames."
