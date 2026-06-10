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

GROUP="gregskril_networkmonitor_bpf"
LABEL="com.gregskril.networkmonitor.chmodbpf"
LEGACY_LABEL="com.greg.networkmonitor.chmodbpf"
SUPPORT_DIR="/Library/Application Support/NetworkMonitor"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
LEGACY_PLIST_PATH="/Library/LaunchDaemons/$LEGACY_LABEL.plist"
SCRIPT_PATH="$SUPPORT_DIR/ChmodBPF.sh"
GROUP_MARKER="$SUPPORT_DIR/created-$GROUP"

echo "• Unloading and removing the LaunchDaemon…"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"
launchctl unload "$LEGACY_PLIST_PATH" 2>/dev/null || true
rm -f "$LEGACY_PLIST_PATH"
rm -f "$SCRIPT_PATH"

echo "• Restoring root-only permissions on /dev/bpf*…"
for dev in /dev/bpf*; do
    [ -e "$dev" ] || continue
    chown root:wheel "$dev" 2>/dev/null || true
    chmod 600 "$dev" 2>/dev/null || true
done

if [ -e "$GROUP_MARKER" ]; then
    echo "• Removing the $GROUP group created by this installer…"
    dseditgroup -o delete "$GROUP" 2>/dev/null || true
    rm -f "$GROUP_MARKER"
else
    echo "• Leaving existing $GROUP group in place."
fi
rmdir "$SUPPORT_DIR" 2>/dev/null || true

echo "Done. Network Monitor will fall back to reverse DNS for hostnames."
