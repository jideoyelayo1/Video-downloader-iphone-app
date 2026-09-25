# VideoDownloaderApp

An iOS 17+ SwiftUI app with a `WKWebView` browser, media discovery, background direct-file downloads, HLS offline downloads, and an offline AVKit library.

## Open and run

Open `VideoDownloaderApp.xcodeproj` in Xcode, select an iOS 17+ simulator or a connected iPhone, set a signing team, and run the `VideoDownloaderApp` scheme. The first browser tab starts at the supplied My***REMOVED*** URL; both supplied URLs are available from the Starter sites bookmark menu.

The app only offers HTTP(S) media URLs exposed to the page. It deliberately ignores `blob:` and `data:` URLs and does not bypass DRM, authentication controls, paywalls, or anti-bot challenges. A site can therefore load successfully while providing no downloadable candidate. Downloads intentionally do not copy browser authentication cookies into background requests; session-protected media may require a site-provided public URL.

## Architecture

- `MediaDiscovery` receives candidates from a document-start WebKit script injected into the main page and child frames. It observes media elements, dynamically inserted nodes, playback events, source mutations, navigation changes, and resource timing entries.
- `DownloadManager` persists queue metadata under Application Support, uses background `URLSession` for ordinary files, and `AVAssetDownloadURLSession` for HLS.
- The Library tab opens completed files with AVKit. Completed ordinary files can be exported with the system share sheet; HLS packages stay inside the app for playback.

## Current verification

The app and XCTest targets compile successfully against Xcode's `iphonesimulator26.5` SDK with code signing disabled. XCTest execution and UI smoke tests remain pending because no matching simulator runtime/destination is installed. The two live URLs have not passed the required download/offline acceptance test. My***REMOVED*** previously stopped at Cloudflare verification during inspection; ***REMOVED*** loaded an embedded `***REMOVED***` player, but the stream and download path remain unverified.

Navigation clears candidates and filters stale same-host document messages. Cross-origin embedded frames remain eligible because players commonly run on a different host, so a frame that continues emitting after a page transition can require a manual refresh.

Reproduce the SDK builds from the project directory with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project VideoDownloaderApp.xcodeproj \
  -target VideoDownloaderApp -sdk iphonesimulator -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project VideoDownloaderApp.xcodeproj \
  -target VideoDownloaderAppTests -sdk iphonesimulator -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

python3 portable_tests.py
```
