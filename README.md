# Companion

A compact native macOS menu-bar companion for AeroSpace. It adds a small workspace island to the existing macOS menu bar; it does not replace the menu bar or create a separate full-width bar.

## Interface

- Adjacent rounded-rectangle workspace compartments sized for the native menu-bar height.
- Workspace labels and grouped macOS application icons.
- Click a workspace compartment to switch workspaces.
- Click a single app icon to focus that exact AeroSpace window. Click a grouped icon to choose a specific window from a menu.
- Repeated windows from the same app are grouped with a count badge.
- Hover an app icon for a lightweight window preview. A captured thumbnail is shown only when Screen Recording permission is already available; otherwise the preview falls back to the app icon and window title. Companion does not request Screen Recording permission automatically.
- A right-click on the strip opens controls for size, workspace spacing, app-icon spacing, background, background opacity, inactive-icon opacity, accent, occupied-only filtering, labels, icons, system stats, About, and Quit.
- System Stats opens on demand and samples system CPU, memory, and Companion's physical footprint; it does not run a background polling loop.
- The status item uses AppKit's native menu-bar placement and saves its position. macOS handles the built-in notch exclusion and available status-item area; Companion does not create an overlay window or move itself across the notch.

## Implementation

- Native Swift and AppKit; no SwiftUI, Electron, WebView, or third-party runtime dependencies.
- AeroSpace CLI snapshot reads workspace/window IDs, app bundle IDs, app names, and window titles.
- AeroSpace's subscribe event stream drives updates and reconnects if AeroSpace restarts.
- App icons use a bounded NSCache.
- Window thumbnails are captured on hover only, only if Screen Recording permission is already granted, and are not retained in a persistent cache.
- System CPU and memory statistics are sampled only when the user opens the stats popover.
- No continuous polling loop.

## Requirements

- macOS 26 or later.
- AeroSpace installed and its CLI available at ~/.local/bin/aerospace, /opt/homebrew/bin/aerospace, or /usr/local/bin/aerospace.
- Screen Recording permission is optional; without it, hover previews show app icon and window title rather than a screenshot.

## Build

Run:

```sh
bash scripts/build-app.sh release
```

The app bundle is created at build/Companion.app.

GitHub Actions builds the app on an Apple Silicon macOS 26 runner and uploads a ZIP artifact when the build and bundle verification succeed.

## Validation

CI verifies compilation, app-bundle structure, the generated app icon, and code signature. Runtime behavior, window-thumbnail permissions, and resource use still require validation on a real Mac.
