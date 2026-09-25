#!/usr/bin/env python3
"""Compile and run the Foundation-only media discovery core without Xcode."""

from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).parent
swiftc = shutil.which("swiftc")
if swiftc is None:
    raise SystemExit("swiftc is unavailable; install Command Line Tools to run the portable core tests")

with tempfile.TemporaryDirectory(prefix="video-downloader-tests-") as temp:
    output = Path(temp) / "media-discovery-tests"
    command = [swiftc, "-module-cache-path", str(Path(temp) / "module-cache"),
               str(root / "VideoDownloaderApp/Models/MediaCandidate.swift"),
               str(root / "VideoDownloaderApp/Services/MediaDiscoveryCore.swift"),
               str(root / "VideoDownloaderApp/Services/DownloadError.swift"),
               str(root / "VideoDownloaderApp/Services/DownloadResponseValidation.swift"),
               str(root / "portable_media_discovery.swift"), "-o", str(output)]
    subprocess.run(command, check=True)
    subprocess.run([str(output)], check=True)
subprocess.run(["node", str(root / "portable_media_discovery_js_test.js")], check=True)
