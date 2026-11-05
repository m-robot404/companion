# Companion

A small native macOS menu-bar companion for AeroSpace. It adds a compact workspace indicator to the existing macOS menu bar; it does not replace the menu bar or create a separate bar.

## Interface

- Adjacent rounded-rectangle workspace compartments, sized for the native menu-bar height.
- Workspace letter plus real macOS application icons for windows in that workspace.
- Restrained active-workspace treatment using the macOS glass material.
- Click a compartment to switch to that AeroSpace workspace.
- Up to three app icons per compartment, followed by a count when more apps are present.

## Implementation

- Native Swift, SwiftUI, and AppKit; no third-party runtime dependencies.
- Uses an `NSStatusItem` custom view in the existing system menu bar.
- Reads workspace/window state from the AeroSpace CLI.
- Uses AeroSpace's `subscribe` event stream for focus, workspace, monitor, and newly detected window changes. The stream reconnects if AeroSpace restarts.
- Caches application icons with a bounded in-memory cache.
- No continuous polling loop.

## Requirements

- macOS 26 or later.
- AeroSpace installed and its CLI available at `~/.local/bin/aerospace`, `/opt/homebrew/bin/aerospace`, or `/usr/local/bin/aerospace`.

## Build

Run:

```sh
bash scripts/build-app.sh release
```

The app bundle is created at `build/Companion.app`.

GitHub Actions builds the app on an Apple Silicon macOS 26 runner and uploads a ZIP artifact when the build and bundle verification succeed.

## Current validation status

The repository contains the first implementation. The CI build and live behavior still need to pass validation before this should be treated as a release.
