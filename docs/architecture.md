# Architecture

A SwiftUI app with four tabs: My Videos, Browse, Downloads and Settings. SwiftData stores the library. The rest is WebKit, Foundation and AVFoundation, plus Google's Cast SDK. All paths below are under `VideoDownloaderApp/`.

## From page to saved video

1. **Discover.** `Services/MediaDiscovery.swift` injects a script into every frame of the browser's `WKWebView`. The script reports media elements, DOM changes, resource timing, `fetch`/XHR responses, subtitle files and poster images. `Services/MediaDiscoveryCore.swift` drops stream segments, duplicates and stale messages.
2. **Validate.** `Services/CandidateValidator.swift` checks each candidate before it can be downloaded. Files get a 4 KB range request. HLS gets manifest, variant, DRM, live and first-segment checks (`Services/HLSManifest.swift`). The result is *Ready*, *Expired*, *Protected (DRM)*, *Live* or *Unavailable*.
3. **Request context.** `Services/BrowserSession.swift` and `Services/RequestContext.swift` give each media request the browser's cookies, scoped by RFC 6265 domain, path and secure rules. They also add the browser's User-Agent and an origin-only Referer.
4. **Download.** `Services/DownloadManager.swift` uses a background `URLSession` for files and `AVAssetDownloadURLSession` for HLS (`Services/HLSMediaSelections.swift` picks the audio and caption renditions). Streams that need the player's Referer go through `Services/HLSRefererProxy.swift`, a localhost relay, so the app has to stay in the foreground for those. Live progress is kept in `Services/DownloadProgressStore.swift`, so progress ticks don't redraw the whole app.
5. **Play.** `Services/PlaybackCoordinator.swift` drives AVKit's full-screen player and handles Picture in Picture, site subtitles, intro and credits marks (`Services/IntroSkip.swift`), the sleep timer, the screen lock and autoplay. Site subtitles live in `Services/SubtitleStore.swift`, `Services/SubtitleParser.swift` and `Views/SubtitleOverlayView.swift`. For Picture in Picture and AirPlay, `Services/SubtitleRemuxer.swift` and `Services/SubtitleEmbedder.swift` write them into direct downloads. `Services/CastController.swift` and `Services/CastMediaServer.swift` play saved files on a Chromecast from a local HTTP server.

## Library

| Area | Files |
| --- | --- |
| Models | `Models/DownloadItem.swift` defines `DownloadItem`, `DownloadFolder`, `VideoLabel`, `Show`, `Bookmark` and `BrowsingHistoryEntry`, opened together through `LibrarySchema`. New fields are optional, so existing stores migrate automatically; `SchemaMigrationTests` opens a store saved by an older build. |
| Shows and series | `Services/Shows.swift`, `Services/ShowStore.swift`, `Services/EpisodeURL.swift` (the next episode's address), `Services/SeasonDownloader.swift` (a hidden browser that finds each episode's video), `Services/NewEpisodeChecker.swift` (background refresh and notifications) |
| Organising | `Services/LibraryQuery.swift`, `Services/LabelStore.swift`, `Services/SiteNames.swift`, `Services/WatchProgress.swift` (the watched rule) |
| Storage | `Services/StorageCleanup.swift`, `Services/LibraryStats.swift`, `Services/LibraryBackup.swift`, `Services/ThumbnailCache.swift`, `Services/VideoThumbnailService.swift` |
| Bookmarks | `Services/BrowserCollectionsStore.swift`; the starter sites are in `Bookmark` in `Models/DownloadItem.swift` |

Direct downloads are saved in Application Support. HLS packages stay where AVFoundation puts them.

## Project settings

- `Info.plist` allows plain-HTTP loads, because the user chooses the sites. It also declares Google Cast's Bonjour services and the local-network prompt.
- The new-episode background task's identifier is in `Info.plist` (`BGTaskSchedulerPermittedIdentifiers`) and in `NewEpisodeChecker.backgroundTaskID`. The two must match.
- `Services/BuildExpiry.swift` reads the embedded provisioning profile so that My Videos can warn before a free-account build expires.
- The only package is Google's Cast SDK (`GoogleCastDynamic`), resolved by Swift Package Manager (`Package.resolved` is committed).

## Diagnostics

**Settings → Error Log** shows the last 1,000 download, validation, playback and caption events, kept across launches (`Services/DiagnosticsLog.swift`). Logged URLs leave out credentials, query values and fragments. The log is at `Documents/diagnostics.log` in the app container.

## Launch arguments

| Argument | Effect |
| --- | --- |
| `-StartURL <url>` | Opens the address in Browse |
| `-NoInitialLoad` | Starts with a blank browser |
| `-UITestInMemory` | Uses an in-memory store and separate, reset preferences |
| `-KeepSiteSubtitleOverlay` | Keeps site subtitles drawn by the app (used by UI tests) |
| `-DiagnosticsAutoplay` | Debug builds: autoplays muted video in every frame |
| `-VerboseBrowserDiagnostics` | Debug builds: logs each browser request |
| `-BuildExpiresInHours <n>` | Debug builds: shows the expiry warning as if the build expired in *n* hours |
| `-UpNextSeconds <n>` | Debug builds: lengthens the end card's countdown |
