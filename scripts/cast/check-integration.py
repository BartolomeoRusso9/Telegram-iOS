#!/usr/bin/env python3
"""Checks, without building, that the Google Cast integration survived a merge.

A merge can succeed textually and still drop a hook: upstream may rewrite the code around one
line. Each entry names a file and a string that must be in it. Exit status 1 means the build must
not be distributed. Runs on any OS: it only reads the tree.
"""
import os
import sys

REQUIRED = [
    ("MODULE.bazel", 'name = "google_cast_sdk"'),
    ("third-party/googlecast/GoogleCast.BUILD", 'name = "GoogleCast"'),
    ("submodules/TelegramCast/BUILD", '"@google_cast_sdk//:GoogleCast"'),
    ("submodules/GalleryUI/BUILD", '"//submodules/TelegramCast:TelegramCast"'),
    ("submodules/GalleryUI/Sources/Items/CastGalleryItemController.swift", "TelegramCastSwitchController"),
    ("submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift", "CastGalleryItemController"),
    ("submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift", "self.setupCastController("),
    ("submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift", "self.castController?.setIsVisible(isVisible)"),
    ("submodules/TelegramUniversalVideoContent/Sources/SystemVideoContent.swift", "public let url"),
    ("Telegram/BUILD", "@google_cast_sdk//:GoogleCastUIResources"),
    ("Telegram/BUILD", ":GoogleCastInfoPlist"),
    ("Telegram/BUILD", "_googlecast._tcp"),
    ("Telegram/BUILD", "NSLocalNetworkUsageDescription"),
    ("Telegram/BUILD", "TelegramCastReceiverApplicationID"),
]

FILES = [
    "cast-receiver/index.html",
    "scripts/cast/upstream-merge.sh",
    "scripts/cast/build-ipa.sh",
    "submodules/TelegramCast/Sources/TelegramCastLocalServer.swift",
    "submodules/TelegramCast/Sources/TelegramCastManager.swift",
    "submodules/TelegramCast/Sources/TelegramCastPlayer.swift",
    "submodules/TelegramCast/Sources/TelegramCastSwitchController.swift",
    "submodules/TelegramCast/Sources/TelegramCastMediaProvider.swift",
    "submodules/TelegramCast/Sources/TelegramCastButton.swift",
    "submodules/TelegramCast/Sources/TelegramCastUpdateChecker.swift",
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    failures = []
    for path in FILES:
        if not os.path.isfile(os.path.join(root, path)):
            failures.append("missing file: " + path)
    for path, needle in REQUIRED:
        full_path = os.path.join(root, path)
        if not os.path.isfile(full_path):
            failures.append("missing file: " + path)
            continue
        with open(full_path, encoding="utf-8") as file:
            if needle not in file.read():
                failures.append("{}: no longer contains {!r}".format(path, needle))
    for failure in sorted(set(failures)):
        print("FAIL " + failure)
    if failures:
        return 1
    print("Google Cast integration intact: {} checks".format(len(REQUIRED) + len(FILES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
