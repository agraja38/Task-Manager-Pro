# PulseTask Manager

PulseTask Manager is a native-style macOS Task Manager built with SwiftUI and AppKit. It brings the familiar Windows Task Manager workflow to macOS with a cleaner sidebar layout, real-time charts, safe process controls, and a built-in updater.

[Direct Download](https://github.com/agraja38/pulse-task-manager-macos/releases/download/v1.0.0/PulseTaskManager-1.0.0.zip)

## Highlights

- Processes view with name, PID, CPU, memory, estimated energy impact, status, and user
- Safe `Quit`, `Terminate`, and `Force Quit` actions with warnings for critical macOS processes
- Performance dashboard with live CPU, memory, disk, network, GPU fallback, battery, and thermal-state cards
- Startup Apps view with login items and best-effort startup impact estimates
- Details view with executable path, bundle ID, child processes, launch time, and recent CPU/memory history
- Search, sort, filter, process tree view, dark mode, beginner/advanced modes, and resource-heavy highlighting
- Menu bar live monitor showing CPU and memory activity
- CSV and JSON snapshot export
- Built-in update flow with download/install progress UI
- Universal build support for Apple Silicon and Intel

## macOS Notes

- PulseTask Manager uses public APIs first and falls back to safe alternatives when macOS restricts direct low-level telemetry.
- GPU usage and exact temperature readings are limited on macOS without private APIs or elevated tools.
- Startup item inspection may ask for Automation permission because login items are queried through `System Events`.
- Some process terminations may still be denied by macOS if the current user does not own the target process or the process is protected.

## Build

```bash
cd "/Users/agrajawijayawardane/Library/Mobile Documents/com~apple~CloudDocs/Codex/PulseTaskManager"
chmod +x build.sh
./build.sh
open "PulseTask Manager.app"
```

The build script produces:

- `PulseTask Manager.app`
- `dist/PulseTaskManager-1.0.0.zip`
- `dist/PulseTaskManager-1.0.0.dmg`

## Updating

PulseTask Manager checks a GitHub-hosted `docs/update.json` feed. The in-app updater downloads the latest archive, shows progress during download and install handoff, then opens the installer for replacement.

When publishing a new version:

1. Build a new release archive.
2. Upload the archive to a GitHub release.
3. Update `docs/update.json` with the new version and asset URL.

## Project Structure

- `Sources/` contains the app, views, models, and service modules
- `AppBundle/Contents/Info.plist` defines the app bundle metadata
- `build.sh` creates a universal binary, app bundle, zip, dmg, and update feed
- `docs/update.json` is the updater manifest
