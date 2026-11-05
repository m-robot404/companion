# Companion

A lightweight native macOS menu bar companion for AeroSpace.

Companion displays AeroSpace workspaces as compact rounded compartments in the existing macOS menu bar. Each compartment shows its workspace name and the real application icons for windows in that workspace.

## Goals

- Native AppKit menu bar item; does not replace the macOS menu bar.
- Compact, train-car-style workspace compartments.
- Real macOS application icons, cached between updates.
- Click a compartment to switch workspace.
- Event-driven updates from AeroSpace where supported, with a conservative fallback.
- Minimal idle CPU and memory use.
- No third-party runtime dependencies.

## Status

Initial project setup. Implementation and runtime validation are in progress.

## Requirements

- macOS 26 or later for the Liquid Glass appearance (the app should retain a restrained fallback appearance on older supported systems).
- AeroSpace installed and its CLI available at `~/.local/bin/aerospace` or on the login shell PATH.

## Build

Open `Companion.xcodeproj` in Xcode and build the `Companion` scheme.

A GitHub Actions workflow will build the app on an Apple Silicon macOS runner and publish a ZIP artifact.
