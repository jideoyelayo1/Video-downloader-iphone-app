#!/bin/zsh
# Rebuilds the local `master` and installs it over the app on the iPhone, keeping its library.
# Run by launchd (see setup.sh); installs every INTERVAL_DAYS or before the build expires. `--now` forces it.
set -u

SUPPORT="$HOME/Library/Application Support/VideoDownloaderReinstall"
source "$SUPPORT/config"   # DEVICE, BRANCH, INTERVAL_DAYS
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
STATE="$SUPPORT/state"
WORK="$SUPPORT/work"
APP="$WORK/build/DerivedData/Build/Products/Debug-iphoneos/VideoDownloaderApp.app"
BUNDLE_ID=com.jideoyelayo.VideoDownloader
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

# Reads devicectl's JSON (Xcode 27's table shows a different ID); also sets DEVICE_UDID for signing.
DEVICE_UDID=""
device_reachable() {
    local json=$(mktemp) i=0 id udid tunnel
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || { rm -f "$json"; return 1 }
    while id=$(plutil -extract "result.devices.$i.identifier" raw -o - "$json" 2>/dev/null); do
        udid=$(plutil -extract "result.devices.$i.hardwareProperties.udid" raw -o - "$json" 2>/dev/null)
        if [[ $id == $DEVICE || $udid == $DEVICE ]]; then
            DEVICE_UDID=$udid
            tunnel=$(plutil -extract "result.devices.$i.connectionProperties.tunnelState" raw -o - "$json" 2>/dev/null)
            rm -f "$json"
            [[ -n $tunnel && $tunnel != unavailable ]]
            return
        fi
        (( i++ ))
    done
    rm -f "$json"
    return 1
}

if ! device_reachable; then
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
if [[ -f $SUPPORT/Local.xcconfig ]]; then cp "$SUPPORT/Local.xcconfig" "$WORK/Config/Local.xcconfig"; fi
building=$(git -C "$WORK" rev-parse --short HEAD)
log "Building $building ($BRANCH)…"

# Xcode reuses a cached profile until it expires, so move aside one ending within 5 days.
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
for cached in "$PROFILES"/*.mobileprovision(N); do
    decoded=$(mktemp)
    security cms -D -i "$cached" > "$decoded" 2>/dev/null
    app_id=$(plutil -extract Entitlements.application-identifier raw -o - "$decoded" 2>/dev/null)
    ends=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$(plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null)" +%s 2>/dev/null || print 0)
    rm -f "$decoded"
    if [[ $app_id == *.$BUNDLE_ID ]] && (( ends > 0 && ends - now < 5 * 86400 )); then
        mkdir -p "$SUPPORT/old-profiles" && mv "$cached" "$SUPPORT/old-profiles/" &&
            log "Moved aside the signing profile that ends $(date -r $ends '+%a %e %b at %H:%M'), for a fresh one."
    fi
done

# A free account only issues a profile for a build aimed at a specific iPhone.
destination='generic/platform=iOS'
[[ -n $DEVICE_UDID ]] && destination="platform=iOS,id=$DEVICE_UDID"
if ! xcodebuild -project "$WORK/VideoDownloaderApp.xcodeproj" -scheme VideoDownloaderApp -configuration Debug \
       -destination "$destination" -destination-timeout 300 -derivedDataPath "$WORK/build/DerivedData" \
       -allowProvisioningUpdates build > "$SUPPORT/last-build.log" 2>&1; then
    if grep -q "No Accounts" "$SUPPORT/last-build.log"; then
        fail "Can't re-sign the app: sign in to Xcode under Settings → Accounts."
    fi
    if grep -q "Timed out waiting for all destinations" "$SUPPORT/last-build.log"; then
        log "Xcode couldn't connect to the iPhone (it may be locked or asleep); trying again later."
        exit 0
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
