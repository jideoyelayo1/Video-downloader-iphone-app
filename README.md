# Video Downloader

An iOS app with a built-in browser that finds the video a web page plays, downloads it and plays it offline. It is a general HLS and MP4 downloader for video you are entitled to save.

## What it does

- **Browse:** a web browser with bookmarks and history. It spots the videos a page's player loads and lists them under **Found videos**. Each one is checked first and marked *Ready* (with its size and HLS qualities), *Expired*, *Protected (DRM)*, *Live* or *Unavailable*.
- **Downloads:** video files download in the background and can resume. HLS streams download through AVFoundation. Downloads carry on while the app is suspended and are picked up again after a relaunch.
- **My Videos:** an offline library with shows, labels, folders, watched state, Continue Watching, search, sorting and filters. Videos play in Apple's full-screen player, with Picture in Picture, AirPlay, Chromecast, subtitles, intro skipping, a sleep timer and autoplay of the next episode.
- **Series:** on sites whose episode pages are numbered, it can download the next episodes and check a followed show for new ones.

### Where it downloads from

It works with any website you open whose player loads an unprotected video over HTTP(S): a direct file such as an MP4, or a finite HLS stream. It can't save DRM-protected video, DASH streams, live streams, players that only expose `blob:` addresses, or pages behind an anti-bot check it can't pass. It ships with no bookmarks or site list: you choose the sites.

## Requirements

- Xcode 26 or later
- iOS 17.0 or later
- An Apple ID to sign the app. A free account works, but its builds stop opening after 7 days.
- A real device for HLS downloads: the simulator can't download HLS for offline use

The only dependency, Google's Cast SDK, is fetched by Swift Package Manager when the project opens.

## Setup

1. Clone the repository and open `VideoDownloaderApp.xcodeproj`.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` to your Apple team ID. The copy is ignored by git, so your team ID stays out of the repository.
3. If Xcode says the bundle identifier `com.jideoyelayo.VideoDownloader` is taken, change it to one of your own.
4. Choose an iPhone or a simulator and press **Run**. On a device, turn on Developer Mode and trust your certificate under *Settings → General → VPN & Device Management*.

No API keys or other secrets are needed. Signing is the only configuration.

### Free Apple ID builds

A free account's build stops opening after 7 days, and My Videos warns two days before. Running the app from Xcode again renews it and keeps the library. `scripts/device-reinstall/setup.sh` can do this for you: it installs a LaunchAgent on the Mac that rebuilds `master` and reinstalls it on the iPhone over Wi-Fi every 5 days. It copies your `Config/Local.xcconfig` for the job, so run it again if you change that file. `setup.sh --uninstall` removes it, and the log is in `~/Library/Logs/VideoDownloaderReinstall.log`.

## Project structure

```text
VideoDownloaderApp/          the app
  Models/                    SwiftData models: videos, shows, labels, bookmarks
  Services/                  discovery, validation, downloads, playback and library logic
  Views/, WebView/           SwiftUI screens and the WKWebView browser
VideoDownloaderAppTests/     unit and integration tests, with a local media server and fixtures
VideoDownloaderAppUITests/   end-to-end UI tests against the same server
scripts/device-reinstall/    automatic reinstall for free-account builds
portable_tests.py            discovery checks that run without Xcode (Swift and Node)
docs/architecture.md         how discovery, downloads and playback fit together
```

## Testing

```sh
# Unit and integration tests (any iPhone simulator)
xcodebuild test -project VideoDownloaderApp.xcodeproj -scheme VideoDownloaderApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:VideoDownloaderAppTests

# UI tests: about 30 minutes, and the display must stay awake
caffeinate -dimsu xcodebuild test -project VideoDownloaderApp.xcodeproj -scheme VideoDownloaderApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:VideoDownloaderAppUITests

# Discovery checks without Xcode (needs swiftc and Node)
python3 portable_tests.py
```

- Don't pass `CODE_SIGNING_ALLOWED=NO` when you run the tests: background downloads fail in an unsigned app. The simulator's default local signing is enough.
- The integration and UI tests use `LocalMediaServer`, a localhost server in `VideoDownloaderAppTests/Support/` with MP4 and HLS fixtures, so they need no network.
- HLS downloads, background transfers and offline playback have to be checked on a device.
- GitHub Actions (`.github/workflows/swift.yml`) runs the portable checks and the unit tests on every push and pull request to `master`, except documentation-only changes.

## Licence

No licence has been chosen yet, so the author keeps all rights.

## Terms of service

Downloading video may be against a site's terms of service and may infringe copyright. Whether you may save a particular video depends on the site, the video and where you live. Checking that is your responsibility. This project hosts no content.
