# VideoDownloaderApp

A personal iOS 17+ SwiftUI app: an in-app browser that finds the videos a page plays, downloads them in the background, and keeps them in an offline library.

- **Browse** — `WKWebView` browser with bookmarks, back/forward, and a **Found videos** sheet. Each candidate is checked before it can be downloaded and shows *Ready* (with size/duration and HLS quality choices), *Expired*, *Protected (DRM)*, *Live*, or *Unavailable*.
- **Downloads** — progress, estimated time remaining, space used and available, search, cancel, retry, and a Start Over choice when a direct file has resume data. Ordinary files use a background `URLSession`; HLS streams use `AVAssetDownloadURLSession`. Downloads continue while the app is suspended and are recovered after relaunch.
- **Library** — thumbnails, search, folders, offline playback with a Resume or Start from Beginning choice, rename, delete, and export (share sheet / Save to Files) for ordinary video files. HLS downloads play inside the app only.

It supports media a page exposes over HTTP(S): direct files and unprotected, finite HLS. It does not bypass DRM, anti-bot challenges, or `blob:`-only players.

## Install on your iPhone

1. Open `VideoDownloaderApp.xcodeproj` in Xcode 26 or later.
2. Select the **VideoDownloaderApp** target → *Signing & Capabilities* → choose your **Team** (a free personal Apple ID works). If Xcode says the bundle ID is taken, change `com.jideoyelayo.VideoDownloaderApp` to something unique.
3. Connect and unlock the iPhone, trust the Mac, and enable **Developer Mode** (*Settings → Privacy & Security*) if prompted.
4. Choose the iPhone as the run destination and press **Run**.
5. The first launch may be blocked until you trust the developer: *Settings → General → VPN & Device Management → your Apple ID → Trust*.

With a free account the app must be re-installed from Xcode every 7 days.

## Using it

1. In **Browse**, open a page (the bookmark menu has the two starter sites) and start the video playing — many players only load their stream after Play.
2. Tap **Found videos**. Wait for *Ready*, then tap **Download** (for HLS choose a quality or *Best quality*). If nothing appears, tap **Refresh** in the sheet.
3. Watch progress and storage in **Downloads**; search, organize into folders, play, rename, export, or delete in **Library**. The folder button creates folders; long-press a video to move it. When you reopen a partly watched video, choose Resume or Start from Beginning.

Browser videos open in iPhone's native full-screen player. In Library, tap **Full Screen** while a saved video is playing. The native player offers Picture in Picture on supported devices: tap its PiP control or leave the app while the video is playing. The player provides a captions control when the video contains subtitle tracks. HLS downloads include the caption languages advertised by the stream; videos without separate caption tracks cannot gain captions automatically. Library playback uses the video audio session so the iPhone's Ring/Silent setting does not mute saved videos. For HLS, choose the **master playlist** when it appears: a single quality playlist can leave out separate audio and caption renditions. If an older download is silent, delete it and download from the master playlist again.

Library thumbnails are generated from saved video frames. For HLS streams without an I-frame-only track, the app briefly plays the saved stream muted to capture a frame; the resulting JPEG is cached for later visits.

If a link shows *Expired*, replay the video in Browse (sites issue short-lived stream URLs) and download again.
If Found videos says **Ready · keep app open**, the stream needs the player’s Referer header. The app relays its HLS playlists, segments, and subtitle URLs through a local connection while downloading. Keep the app in the foreground until it completes; retry from the playing page if the stream URL expires.
**Found videos** excludes individual `.m4s` and `.ts` stream fragments. Those files are not complete videos. If the page plays but no full HLS playlist appears, try another server on the page; a DASH-only or protected player cannot be saved by the current downloader.
If an HLS download reports HTTP 500, its video server failed during the transfer. Use **Open Page** to replay the episode and obtain a fresh stream link. iOS does not expose resume data for failed HLS asset downloads, so Retry starts that stream again.

## Architecture

| Area | Files |
| --- | --- |
| Discovery | `Services/MediaDiscovery.swift` (document-start script in every frame: media elements, DOM mutations, resource timing, `fetch`/XHR response types, SPA navigation), `Services/MediaDiscoveryCore.swift` (payload rules, segment filtering, stale-message detection) |
| Validation | `Services/CandidateValidator.swift` (4 KB range probe for files; manifest, variant, DRM/live, and first-segment checks for HLS), `Services/HLSManifest.swift` |
| Request context | `Services/BrowserSession.swift`, `Services/RequestContext.swift` — browser cookies are scoped under RFC 6265 domain/path/secure rules for each request (including HLS child hosts), with the browser User-Agent and an origin-only Referer for cross-origin media. Direct downloads inject only cookies eligible for the starting URL into the URL loading system's cookie store. Strict cross-host behavior for background-session redirects remains unverified. |
| Downloads | `Services/DownloadManager.swift`, `Services/HLSMediaSelections.swift` (audio and captions), `Services/HLSRefererProxy.swift` (Referer-required streams), `Services/DownloadError.swift`, `Services/DownloadResponseValidation.swift`, `Services/Filenames.swift` |
| Storage | SwiftData models in `Models/DownloadItem.swift` (`DownloadItem`, `Bookmark`); files in Application Support; HLS packages stay where AVFoundation puts them. Old `downloads.json` queues are imported once. |
| UI | `Views/`, `WebView/BrowserView.swift` |

Debug builds add a **Diagnostics** screen (bookmark menu) listing every media request each frame made, with a *Share log* button, for checking new sites. The same log is written to `Documents/diagnostics.log` in the app container.

`Info.plist` allows plain-HTTP loads because this is a general browser whose sites and media hosts are chosen by the user.

## Tests

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select points at CommandLineTools
xcodebuild -project VideoDownloaderApp.xcodeproj -scheme VideoDownloaderApp \
  -destination 'platform=iOS Simulator,id=2443A476-79AB-495A-B941-FA92ED3ECBDB' \
  -derivedDataPath /Volumes/T7/VideoDownloaderApp-validation/artifacts/DerivedData-iPhone15ProMax test
python3 portable_tests.py   # Foundation-only checks + the discovery script under Node
```

- Unit tests cover discovery rules, cookie scoping, HLS parsing, error mapping, filenames, and persistence.
- Integration tests run the real download and validation code against `LocalMediaServer`, a localhost HTTP server in `VideoDownloaderAppTests/Support/` with MP4/HLS fixtures and routes for cookies, Referer, redirects, expiry, dropped connections, and slow transfers.
- UI tests (`VideoDownloaderAppUITests/`) drive browse → detect → download → library → play → export → rename → delete against the same server.

Don't pass `CODE_SIGNING_ALLOWED=NO` when running tests: background `URLSession` downloads fail with `NSURLErrorUnknown` in an unsigned app. The simulator's default "Sign to Run Locally" is enough.

The simulator can't download HLS for offline use (an Apple limitation), so HLS downloads, background transfers with the app suspended, and airplane-mode playback have to be checked on a physical iPhone. See `TEST_REPORT.md`.

Launch arguments used by tests and diagnostics: `-StartURL <url>`, `-NoInitialLoad`, `-UITestInMemory` (in-memory store), and `-DiagnosticsAutoplay` (Debug only; muted autoplay in every frame).
