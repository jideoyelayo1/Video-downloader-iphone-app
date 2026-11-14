#!/bin/zsh
# Installs a LaunchAgent that keeps the app installed on an iPhone signed with a free (7-day) account.
# Usage: setup.sh [device]  (from `xcrun devicectl list devices`; default: first reachable iPhone)
#        setup.sh --uninstall
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SUPPORT="$HOME/Library/Application Support/VideoDownloaderReinstall"
LABEL=com.jideoyelayo.videodownloader.reinstall
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOOK="$REPO/.git/hooks/reference-transaction"
BRANCH=master
INTERVAL_DAYS=5
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ ${1:-} == --uninstall ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    if [[ -f $HOOK ]] && grep -q VideoDownloaderReinstall "$HOOK"; then rm -f "$HOOK"; fi
    rm -rf "$SUPPORT"
    print "Removed the automatic iPhone update."
    exit 0
fi

DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | grep -E "iPhone" | grep -E "available|connected" | head -1 |
                awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}/) { print $i; exit } }')}
if [[ -z $DEVICE ]]; then
    print "No reachable iPhone. Connect it (or put it on the same Wi-Fi), unlock it, and try again." >&2
    exit 1
fi

if [[ -f $HOOK ]] && ! grep -q VideoDownloaderReinstall "$HOOK"; then
    print "$HOOK already exists; add the push from this script to it by hand." >&2
    exit 1
fi

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Background jobs can't read ~/Documents, so the job builds from a bare copy a git hook keeps current.
[[ -d $SUPPORT/repo.git ]] || git init -q --bare "$SUPPORT/repo.git"
git -C "$REPO" push -q --force "$SUPPORT/repo.git" "$BRANCH:$BRANCH"
cat > "$HOOK" <<EOF
#!/bin/sh
# VideoDownloaderReinstall: keeps the automatic iPhone update's copy of $BRANCH current
# (scripts/device-reinstall/setup.sh; background jobs can't read ~/Documents).
[ "\$1" = committed ] || exit 0
grep -q " refs/heads/$BRANCH\\\$" || exit 0
git push -q --force "\$HOME/Library/Application Support/VideoDownloaderReinstall/repo.git" $BRANCH:$BRANCH >/dev/null 2>&1 &
EOF
chmod +x "$HOOK"

cp "$REPO/scripts/device-reinstall/reinstall.sh" "$SUPPORT/reinstall.sh"
chmod +x "$SUPPORT/reinstall.sh"
print -r -- "DEVICE=$DEVICE BRANCH=$BRANCH INTERVAL_DAYS=$INTERVAL_DAYS" > "$SUPPORT/config"

# Every 6 hours; reinstall.sh decides whether an install is due.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/zsh</string><string>$SUPPORT/reinstall.sh</string></array>
    <key>StartInterval</key><integer>21600</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/VideoDownloaderReinstall.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/VideoDownloaderReinstall.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

print "Installed: every $INTERVAL_DAYS days, $BRANCH is built and installed on $DEVICE."
print "Log: ~/Library/Logs/VideoDownloaderReinstall.log"
print "Install now: launchctl kickstart gui/$(id -u)/$LABEL  (or run $SUPPORT/reinstall.sh --now)"
