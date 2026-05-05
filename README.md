# Peek

A fast, minimal native macOS viewer for images and PDFs. Mouse-driven zoom and pan, the way design tools do it.

## Install

Download the latest DMG from [Releases](https://github.com/fbdegroot/Peek/releases/latest), open it, and drag `Peek.app` to `/Applications`. The app is signed with a Developer ID and notarized by Apple, and updates itself automatically through Sparkle.

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon
- Xcode 16+ to build from source

## Build

Open in Xcode:

```sh
open Peek.xcodeproj
```

…or build from the command line:

```sh
xcodebuild -project Peek.xcodeproj -scheme Peek -configuration Release build
```

The `.app` ends up at `~/Library/Developer/Xcode/DerivedData/Peek-*/Build/Products/Release/Peek.app`. Drag it to `/Applications` to install.

## Release

`Releases/release.sh` builds a Developer ID-signed, notarized, stapled, Sparkle-signed DMG and appends an entry to `Releases/appcast.xml`.

```sh
./Releases/release.sh           # release at the current MARKETING_VERSION
./Releases/release.sh 1.3       # bump to 1.3 (auto-increments build number)
```

One-time setup:

1. **Notarytool credentials** — `xcrun notarytool store-credentials AC_PASSWORD --apple-id <your-apple-id> --team-id 9U32932L68` (use an [app-specific password](https://appleid.apple.com)).
2. **Sparkle EdDSA key** — `Releases/sparkle-tools/generate_keys` (already done; private key lives in your Keychain). The matching public key is in `Peek/Info.plist` under `SUPublicEDKey`.
3. **Hosting** — DMG's go to GitHub Releases, `Releases/appcast.xml` is served from `raw.githubusercontent.com`. The release script handles `gh release create` and `git push` automatically; older Peek installs poll the feed daily and auto-update.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘ + scroll` | Zoom toward the cursor |
| Pinch (trackpad) | Zoom toward the cursor |
| Click + drag | Pan |
| Scroll | Pan vertically (horizontal with `⇧`) |
| `⌘O` | Open file |
| `⌘0` | Fit to window |
| `⌘1` | Actual size (100%) |
| `⌘+` / `⌘-` | Zoom in / out |
| `←` / `→` | Previous / next file in folder |
| `Space` | Next file |

You can also drop a file on the window or on the dock icon.

## Supported file types

PNG, JPEG, HEIC/HEIF, WebP, GIF, TIFF, BMP, SVG, PDF.

## Project layout

```
Peek/
  PeekApp.swift          # @main App + AppDelegate
  AppModel.swift         # Observable model: current file, playlist, zoom commands
  ContentView.swift      # Top-level view, drop target, empty state
  Viewer.swift           # Switches between image / PDF viewers
  ImageViewer.swift      # Custom NSView with CALayer-based rendering
  PDFViewer.swift        # PDFView subclass with cmd+scroll = zoom-at-cursor
  FilePlaylist.swift     # Folder scan for arrow-key navigation
  Info.plist             # Document type declarations
  Assets.xcassets/
```

The two non-negotiable interactions — `⌘ + scroll` zoom-toward-cursor, and click-drag pan — are implemented directly on `NSView` (and on a `PDFView` subclass for PDFs) rather than via SwiftUI gestures, because SwiftUI's gesture system can't deliver the precision needed for the zoom-at-cursor math.
