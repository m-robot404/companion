# Companion

A small native macOS menu-bar companion for AeroSpace. It adds a compact workspace indicator to the existing macOS menu bar; it does not replace the menu bar or create a separate bar.

## Interface

- Adjacent rounded-rectangle workspace compartments, sized for the native menu-bar height.
- Workspace letter plus real macOS application icons for windows in that workspace.
- Restrained active-workspace treatment using the macOS glass material.
- Click a compartment to switch to that AeroSpace workspace.
- Up to three app icons per compartment, followed by a count when more apps are present.
- A compact menu-bar controls item opens Preferences, About, and Quit.

## Implementation

- Native Swift and AppKit only; no SwiftUI, Electron, WebView, or third-party runtime dependencies.
- Draws the compact strip in a lightweight AppKit view hosted inside the supported `NSStatusItem` button.
- Reads workspace/window state from the AeroSpace CLI.
- Uses AeroSpace's `subscribe` event stream for focus, workspace, monitor, and newly detected window changes. The stream reconnects if AeroSpace restarts.
- Caches application icons with a bounded in-memory cache.
- Preferences persist strip size, glass/solid/transparent background, accent color, occupied-only filtering, app-icon visibility, and workspace-label visibility.
- Includes a generated native macOS app icon in the app bundle.
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

The event-driven implementation has passed the macOS 26 Apple Silicon CI build, app-bundle validation, and code-signature verification. Runtime behavior and memory use still need measurement on a real Mac before calling it a fully validated release.
