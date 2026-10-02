#!/bin/zsh
# Rebuilds Video Downloader from the latest local `master` and installs it over the app on the
# iPhone, so a free developer account's 7-day signing never runs out. Installing over the app
# keeps its videos and library.
#
# launchd runs this every few hours (see setup.sh). It only installs once INTERVAL_DAYS have
# passed since the last install, or when the installed build is about to stop opening, and it
# waits while the app is open on the phone so a video isn't interrupted. `--now` installs at once.
#
# It runs from ~/Library/Application Support because macOS doesn't let background jobs read
# ~/Documents; a git hook in the project keeps a copy of `master` there (setup.sh installs it).
set -u

SUPPORT="$HOME/Library/Application Support/VideoDownloaderReinstall"
source "$SUPPORT/config"   # DEVICE, BRANCH, INTERVAL_DAYS
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
STATE="$SUPPORT/state"
WORK="$SUPPORT/work"
APP="$WORK/build/DerivedData/Build/Products/Debug-iphoneos/VideoDownloaderApp.app"
force=${1:-}

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" }
notify() { osascript -e "display notification \"$1\" with title \"Video Downloader\"" >/dev/null 2>&1 }

last_install=0 expires=0 commit="" last_alert=0
[[ -f $STATE ]] && source "$STATE"
save_state() { print -r -- "last_install=$last_install expires=$expires commit=$commit last_alert=$last_alert" > "$STATE" }

# Problems the viewer has to fix are shown at most twice a day.
fail() {
    log "FAILED: $1"
    if (( $(date +%s) - last_alert > 43200 )); then
        notify "$1"
        last_alert=$(date +%s)
        save_state
    fi
    exit 1
}

now=$(date +%s)
if [[ $force != --now ]] && (( now - last_install < INTERVAL_DAYS * 86400 && expires - now > 2 * 86400 )); then
    exit 0
fi

if ! xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -Eq "available|connected"; then
    log "The iPhone isn't reachable (it needs to be on the same Wi-Fi as this Mac); trying again later."
    exit 0
fi

# Installing closes the app, so wait while it's open unless the build stops opening within a day.
if [[ $force != --now ]] && (( expires - now > 86400 )) &&
   xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null | grep -q "VideoDownloaderApp.app/"; then
    log "Video Downloader is open on the iPhone; trying again later."
    exit 0
fi

if [[ ! -d $WORK/.git ]]; then
    git clone -q "$SUPPORT/repo.git" "$WORK" || fail "Couldn't copy the project for the automatic update."
fi
git -C "$WORK" fetch -q origin "$BRANCH" && git -C "$WORK" checkout -q --detach -f FETCH_HEAD && git -C "$WORK" clean -fdq -e build ||
    fail "Couldn't update the project copy for the automatic update."
building=$(git -C "$WORK" rev-parse --short HEAD)
log "Building $building ($BRANCH)…"

if ! xcodebuild -project "$WORK/VideoDownloaderApp.xcodeproj" -scheme VideoDownloaderApp -configuration Debug \
       -destination 'generic/platform=iOS' -derivedDataPath "$WORK/build/DerivedData" -allowProvisioningUpdates build \
       > "$SUPPORT/last-build.log" 2>&1; then
    if grep -q "No Accounts" "$SUPPORT/last-build.log"; then
        fail "Can't re-sign the app: sign in to Xcode under Settings → Accounts."
    fi
    fail "The automatic update failed to build. See $SUPPORT/last-build.log."
fi

profile=$(mktemp)
security cms -D -i "$APP/embedded.mobileprovision" > "$profile" 2>/dev/null
new_expiry=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$(plutil -extract ExpirationDate raw -o - "$profile" 2>/dev/null)" +%s 2>/dev/null || print 0)
rm -f "$profile"
if (( new_expiry - now < 5 * 86400 )); then
    fail "Xcode signed the update with an old profile. Check Xcode → Settings → Accounts, then build once from Xcode."
fi

if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$SUPPORT/last-build.log" 2>&1; then
    fail "Couldn't install the update on the iPhone; trying again later. Unlocking the phone can help."
fi

last_install=$now expires=$new_expiry commit=$building
save_state
until=$(date -r "$new_expiry" '+%a %e %b at %H:%M')
log "Installed $building. It opens until $until."
notify "Updated on your iPhone. It opens until $until."
