# VideoDownloaderApp

A personal iOS 17+ SwiftUI app: an in-app browser that finds the videos a page plays, downloads them in the background, and keeps them in an offline library.

- **Browse** — `WKWebView` browser with searchable bookmarks and browsing history, back/forward, and a **Found videos** sheet. Each candidate is checked before it can be downloaded and shows *Ready* (with size/duration and HLS quality choices), *Expired*, *Protected (DRM)*, *Live*, or *Unavailable*.
- **Downloads** — progress, estimated time remaining, space used and available, search, cancel, retry, and a Start Over choice when a direct file has resume data. Ordinary files use a background `URLSession`; HLS streams use `AVAssetDownloadURLSession`. Downloads continue while the app is suspended and are recovered after relaunch.
- **My Videos** — the opening screen shows Continue Watching, shows, larger thumbnails, search, folders, labels, sorting and filters, and offline playback. Videos are marked watched, and episodes of a show can play on one after another. Rename, delete, and export (share sheet / Save to Files) remain available for ordinary video files. HLS downloads play inside the app only.

It supports media a page exposes over HTTP(S): direct files and unprotected, finite HLS. It does not bypass DRM, anti-bot challenges, or `blob:`-only players.

## Install on your iPhone

1. Open `VideoDownloaderApp.xcodeproj` in Xcode 26 or later.
2. Select the **VideoDownloaderApp** target → *Signing & Capabilities* → choose your **Team** (a free personal Apple ID works). If Xcode says the bundle ID is taken, change `com.jideoyelayo.VideoDownloaderApp` to something unique.
3. Connect and unlock the iPhone, trust the Mac, and enable **Developer Mode** (*Settings → Privacy & Security*) if prompted.
4. Choose the iPhone as the run destination and press **Run**.
5. The first launch may be blocked until you trust the developer: *Settings → General → VPN & Device Management → your Apple ID → Trust*.

With a free account the app must be re-installed from Xcode every 7 days. When that week runs out, iOS refuses to open the app: *"Video Downloader" Is No Longer Available*. A copy that is already running (for example, one kept alive by Picture in Picture) carries on until it is closed, and the app switcher can still bring it back. My Videos warns two days before. To renew, sign in to Xcode under *Settings → Accounts* with the Apple ID used for signing, then run the app again. Re-installing keeps your videos.

### Renewing automatically

```sh
scripts/device-reinstall/setup.sh            # or: setup.sh --uninstall
```

This installs a background job on the Mac (a LaunchAgent).
- **What it does:** every 5 days it builds the latest `master` and installs it over the app on the iPhone. It works over Wi-Fi once the phone has been paired with Xcode, and your videos and library are kept.
- **When it runs:** it checks every 6 hours, so a sleeping Mac or an out-of-reach phone only delays it. It waits while the app is open on the phone, unless the build would otherwise stop opening within a day.
- **Notifications:** it tells you when it has installed an update, and when Xcode needs you to sign in.
- **Log:** `~/Library/Logs/VideoDownloaderReinstall.log`. To install straight away, run `~/Library/Application Support/VideoDownloaderReinstall/reinstall.sh --now`.

macOS doesn't let background jobs read `~/Documents`, so the job builds from its own copy of `master` in `~/Library/Application Support/VideoDownloaderReinstall`. A git hook (`.git/hooks/reference-transaction`) updates that copy whenever `master` moves.

## Using it

1. In **Browse**, tap the book icon for **Bookmarks** and **History**. Starter bookmarks open site homepages, including anime sites and ***REMOVED*** and ***REMOVED*** as ***REMOVED*** alternatives. You can save the current page, rename or delete bookmarks, reopen visited pages, and clear history. Start a video playing — many players only load their stream after Play.
2. Tap **Found videos** (the number beside its icon turns green once a video is ready to save). Videos are grouped into *Ready to Save*, *Checking*, and *Can't Be Saved* with the reason. Tap **Download** (for HLS choose a quality or *Best quality*); long-press a row to copy its link. If nothing appears, tap **Refresh** in the sheet.
3. Watch progress and storage in **Downloads**; search, organize into folders, play, rename, export, or delete in **My Videos**. The folder button creates folders; long-press a video to move it. Tap a Continue Watching card to resume immediately.

Browser videos stay in the website's inline player when it supports inline playback, preserving site-provided subtitle overlays such as the English captions on ***REMOVED***'s ***REMOVED*** player. Leaving Browse or opening a saved video pauses the page's audio and video so it doesn't keep playing or streaming in the background. Saved videos open in Apple's standard full-screen player, with one set of controls that fades during playback: close (✕), title, AirPlay, Picture in Picture where the iPhone supports it, skip and scrubbing, playback speed, and subtitles. Leaving the app while a saved video plays starts Picture in Picture on supported iPhones. Subtitle tracks inside the video are under **More Controls (…) → Subtitles**. Your last choice, including **Off**, applies to the next video; captions start on (full subtitles, not just forced ones) until you choose. Some players load subtitles as separate files rather than inside the stream (***REMOVED***'s player offers about nine languages this way). When Found videos lists *subtitle languages*, those files are saved with the download and drawn over the video; a **Subtitles** button beside the player's controls switches language or turns them off. Without a saved choice, your iPhone's language is picked first. Picture in Picture shows only the video, not these site subtitles. If a saved file is missing, an alert says so. HLS downloads request the caption languages advertised by the stream, but captions supplied only by a website's separate player are not part of the downloaded video. Playback uses the video audio session so the iPhone's Ring/Silent setting does not mute saved videos; closing the player releases it so other audio can resume. For HLS, choose the **master playlist** when it appears: a single quality playlist can leave out separate audio and caption renditions. Once a master is checked, Found videos hides its quality, audio-only and subtitle playlists. Older downloads with missing tracks may need to be downloaded again.

### Organising My Videos

- **Watched.** A video counts as watched when it plays to the end, or when you close it in its last 10% (usually the credits). Use **Mark as Watched / Unwatched** in its menu, or swipe right on it. Watched videos get a green tick and leave Continue Watching.
- **Labels.** Add labels from a video's menu (**Labels → New Label…**). Each download is also labelled with the site it came from, such as ****REMOVED**** or ****REMOVED****. Videos you saved earlier get theirs once. Under **Folders → Manage Labels** you can rename and recolour labels, turn off site labels, and give a label sites of its own. For example, give *Anime* ***REMOVED***.to and ***REMOVED***.to, and downloads from either get it; **Add to N saved videos** labels the ones you already have. Titles hide a trailing site name (" · ***REMOVED***") because the label shows it, so long series titles end with their episode number.
- **Sort & Filter.** The toolbar's filter button sorts by newest or oldest download, title (episode numbers in order), recently watched, or size. It can show only unwatched, in-progress or watched videos, or videos with chosen labels. Active filters appear as chips under the search field; tap one to remove it.
- **Shows.** When several videos look like episodes of one series ("Ep. 9", "Episode 5", "S29E2"), My Videos offers to make a show. **Create Show** lets you check its name and episodes, which start in episode order. You can also use **Add to Show** in a video's menu. In a show, drag episodes into the order you want to watch them (**Edit**), or use **Order by Episode Number**. **Play** starts the first episode you haven't watched. With **Autoplay Next Episode** on, the next episode starts when one ends: after a 5-second *Up Next* countdown in full screen, with **Play Now** and **Cancel**, or straight away in Picture in Picture. Newer downloads of the series are offered to the show. Deleting a show or a label keeps its videos.

Library thumbnails are generated from saved video frames, one video at a time. For HLS streams without an I-frame-only track, the app briefly plays the saved stream muted to capture a frame; the resulting JPEG is cached for later visits. A video whose frame can't be captured isn't retried until the next launch.

If a link shows *Expired*, replay the video in Browse (sites issue short-lived stream URLs) and download again.
If Found videos says **Ready · keep app open**, the stream needs the player’s Referer header. The app relays its HLS playlists, segments, and subtitle URLs through a local connection while downloading. Keep the app in the foreground until it completes; retry from the playing page if the stream URL expires.
**Found videos** excludes individual `.m4s` and `.ts` stream fragments and audio-only files such as theme previews. Those files are not complete videos. If the page plays but no full HLS playlist appears, try another server on the page; a DASH-only or protected player cannot be saved by the current downloader. Found videos says so when a stream is DASH (for example ***REMOVED***) or when the site's player scrambles its playlist so only its own script can read it (for example the ***REMOVED*** player on ***REMOVED***).
If an HLS download reports HTTP 500, its video server failed during the transfer. Use **Open Page** to replay the episode and obtain a fresh stream link. iOS does not expose resume data for failed HLS asset downloads, so Retry starts that stream again.
HTTP 429 means the video server is limiting requests. Wait before trying again, or open the page to obtain another source. Repeating an immediate retry usually cannot fix a server limit.

## Architecture

| Area | Files |
| --- | --- |
| Discovery | `Services/MediaDiscovery.swift` (document-start script in every frame: media elements, DOM mutations, resource timing, `fetch`/XHR response types, SPA navigation), `Services/MediaDiscoveryCore.swift` (payload rules, segment filtering, stale-message detection) |
| Validation | `Services/CandidateValidator.swift` (4 KB range probe for files; manifest, variant, DRM/live, and first-segment checks for HLS), `Services/HLSManifest.swift` |
| Request context | `Services/BrowserSession.swift`, `Services/RequestContext.swift` — browser cookies are scoped under RFC 6265 domain/path/secure rules for each request (including HLS child hosts), with the browser User-Agent and an origin-only Referer for cross-origin media. Direct downloads inject only cookies eligible for the starting URL into the URL loading system's cookie store. Strict cross-host behavior for background-session redirects remains unverified. |
| Downloads | `Services/DownloadManager.swift`, `Services/DownloadProgressStore.swift` (throttled live progress, observed only by progress views), `Services/HLSMediaSelections.swift` (audio and captions), `Services/HLSRefererProxy.swift` (Referer-required streams), `Services/DownloadError.swift`, `Services/DownloadResponseValidation.swift`, `Services/Filenames.swift` |
| Storage | SwiftData models in `Models/DownloadItem.swift` (`DownloadItem`, `DownloadFolder`, `VideoLabel`, `Show`, `Bookmark`, `BrowsingHistoryEntry`, opened together through `LibrarySchema`; new fields are optional so existing libraries migrate automatically); files in Application Support; HLS packages stay where AVFoundation puts them. Old `downloads.json` queues are imported once. The two episode-specific starter bookmarks are replaced once without changing personal bookmarks. |
| Playback and library | `Services/PlaybackCoordinator.swift`, `Services/CaptionPreference.swift` (remembered caption choice), `Models/SubtitleTrack.swift`, `Services/SubtitleStore.swift`, `Services/SubtitleParser.swift` and `Views/SubtitleOverlayView.swift` (site subtitle files saved with downloads and drawn over the video), `Services/ThumbnailCache.swift` and `Services/VideoThumbnailService.swift` (shared, serialized thumbnail extraction), `Services/WatchProgress.swift` (the watched rule), `Services/LibraryQuery.swift` (sorting and filters), `Services/LabelStore.swift` and `Services/SiteNames.swift` (labels, site labels and rules), `Services/Shows.swift` and `Services/ShowStore.swift` (show suggestions from titles, watch order, the next episode), `Services/BuildExpiry.swift` (the signing profile's expiry date) |
| UI | `Views/`, `WebView/BrowserView.swift` (the view model owns one `WKWebView` and observes its URL, title, back/forward and loading state, so client-side routing is followed even when it bypasses the page's `history.pushState`) |

**Downloads → Error log** opens the shareable diagnostics log in every build. It records download, validation, playback, caption, and PiP events across launches, keeping the latest 1,000 entries. URLs in the log omit credentials, query values, and fragments. Detailed browser requests can be recorded in Debug builds with `-VerboseBrowserDiagnostics`; this is off by default. Each request is logged once, as the page's resource timing reports it; taps and **Refresh** don't repeat earlier requests. The log is written to `Documents/diagnostics.log` in the app container on a background queue, and the share file is created only when you share it.

`Info.plist` allows plain-HTTP loads because this is a general browser whose sites and media hosts are chosen by the user.

## Tests

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select points at CommandLineTools
xcodebuild -project VideoDownloaderApp.xcodeproj -scheme VideoDownloaderApp \
  -destination 'platform=iOS Simulator,id=2443A476-79AB-495A-B941-FA92ED3ECBDB' \
  -derivedDataPath build/DerivedData -parallel-testing-enabled NO test
python3 portable_tests.py   # Foundation-only checks + the discovery script under Node
```

- Unit tests cover discovery rules, cookie scoping, HLS parsing, error mapping, filenames, persistence, and the library's watched rule, sorting and filters, labels, show suggestions (with real episode titles) and autoplay.
- Integration tests run the real download and validation code against `LocalMediaServer`, a localhost HTTP server in `VideoDownloaderAppTests/Support/` with MP4/HLS fixtures and routes for cookies, Referer, redirects, expiry, dropped connections, and slow transfers.
- UI tests (`VideoDownloaderAppUITests/`) drive browse → detect → download → library → play → export → rename → delete against the same server, plus watched, labels, Sort & Filter, a show made from its suggestion (drag to reorder) and the Up Next countdown.

Don't pass `CODE_SIGNING_ALLOWED=NO` when running tests: background `URLSession` downloads fail with `NSURLErrorUnknown` in an unsigned app. The simulator's default "Sign to Run Locally" is enough.

The simulator can't download HLS for offline use (an Apple limitation), so HLS downloads, background transfers with the app suspended, and airplane-mode playback have to be checked on a physical iPhone. See `TEST_REPORT.md`.

Launch arguments used by tests and diagnostics: `-StartURL <url>`, `-NoInitialLoad`, `-UITestInMemory` (in-memory store and separate, reset preferences), `-DiagnosticsAutoplay` (Debug only; muted autoplay in every frame), `-VerboseBrowserDiagnostics` (Debug only; detailed network events), and `-BuildExpiresInHours <n>` (Debug only; shows the expiry warning as if the build expired in *n* hours).
