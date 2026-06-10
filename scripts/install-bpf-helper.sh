#!/bin/sh
# Grants Network Monitor read access to BPF devices so it can sniff DNS
# responses and show the real hostnames apps request (instead of reverse-DNS
# guesses). Modeled on Wireshark's "ChmodBPF": creates a dedicated group,
# adds you to it, and installs a LaunchDaemon that relaxes /dev/bpf* perms to
# that group at boot. No password needed per launch afterward.
#
# Usage:  sudo scripts/install-bpf-helper.sh
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This must run as root. Re-run:  sudo $0" >&2
    exit 1
fi

# Target user: explicit $1 (passed by the in-app installer, which runs us as
# root via osascript), else the invoking sudo user.
USER_NAME="${1:-${SUDO_USER:-$(logname 2>/dev/null)}}"
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; then
    echo "Could not determine your user account. Pass it as the first argument or run via sudo." >&2
    exit 1
fi

GROUP="gregskril_networkmonitor_bpf"
LABEL="com.gregskril.networkmonitor.chmodbpf"
LEGACY_LABEL="com.greg.networkmonitor.chmodbpf"
SUPPORT_DIR="/Library/Application Support/NetworkMonitor"
SCRIPT_PATH="$SUPPORT_DIR/ChmodBPF.sh"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
LEGACY_PLIST_PATH="/Library/LaunchDaemons/$LEGACY_LABEL.plist"
GROUP_MARKER="$SUPPORT_DIR/created-$GROUP"

echo "• Ensuring group '$GROUP' exists and adding '$USER_NAME'…"
if ! dseditgroup -o read "$GROUP" >/dev/null 2>&1; then
    dseditgroup -o create -r "Network Monitor BPF access" "$GROUP"
    mkdir -p "$SUPPORT_DIR"
    touch "$GROUP_MARKER"
fi
dseditgroup -o edit -a "$USER_NAME" -t user "$GROUP"

echo "• Installing chmod script to $SCRIPT_PATH…"
mkdir -p "$SUPPORT_DIR"
cat > "$SCRIPT_PATH" <<EOS
#!/bin/sh
# Relax /dev/bpf* permissions to the Network Monitor BPF group.
GROUP="$GROUP"
dseditgroup -o read "$GROUP" >/dev/null 2>&1 || exit 0
for dev in /dev/bpf*; do
    [ -e "$dev" ] || continue
    chgrp "$GROUP" "$dev" 2>/dev/null || true
    chmod g+rw "$dev" 2>/dev/null || true
done
EOS
chmod 755 "$SCRIPT_PATH"
chown root:wheel "$SCRIPT_PATH"

echo "• Installing LaunchDaemon to $PLIST_PATH…"
if [ -e "$LEGACY_PLIST_PATH" ]; then
    launchctl unload "$LEGACY_PLIST_PATH" 2>/dev/null || true
    rm -f "$LEGACY_PLIST_PATH"
fi
cat > "$PLIST_PATH" <<EOS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$SCRIPT_PATH</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>WatchPaths</key>
	<array>
		<string>/dev</string>
	</array>
</dict>
</plist>
EOS
chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

echo "• Loading the daemon and relaxing existing devices now…"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
sh "$SCRIPT_PATH"

echo ""
echo "Done. If the app still shows 'DNS names off' after relaunching, log out and"
echo "back in once so '$USER_NAME' picks up the new '$GROUP' group membership."
