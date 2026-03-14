# Task Manager Pro

Task Manager Pro is a native-style macOS Task Manager built with SwiftUI and AppKit. It brings the familiar Windows Task Manager workflow to macOS with a cleaner sidebar layout, real-time charts, safe process controls, and a built-in updater.

[Download for Apple Silicon Macs](https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.04/TaskManagerPro-1.0.04-apple-silicon.dmg)

[Download for Intel Macs](https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.04/TaskManagerPro-1.0.04-intel.dmg)

## Highlights

- Processes view with name, PID, CPU, memory, estimated energy impact, status, and user
- Safe `Quit`, `Terminate`, and `Force Quit` actions with warnings for critical macOS processes
- Performance dashboard with live CPU, memory, disk, network, GPU fallback, battery, and thermal-state cards
- Startup Apps view with login items and best-effort startup impact estimates
- Details view with executable path, bundle ID, child processes, launch time, and recent CPU/memory history
- Search, sort, filter, process tree view, dark mode, beginner/advanced modes, and resource-heavy highlighting
- Menu bar live monitor showing CPU and memory activity
- Built-in update flow with download/install progress UI
- Separate Apple Silicon and Intel drag-and-drop DMG builds

## macOS Notes

- Task Manager Pro uses public APIs first and falls back to safe alternatives when macOS restricts direct low-level telemetry.
- GPU usage and exact temperature readings are limited on macOS without private APIs or elevated tools.
- Startup item inspection may ask for Automation permission because login items are queried through `System Events`.
- Some process terminations may still be denied by macOS if the current user does not own the target process or the process is protected.

## Updating

Task Manager Pro checks a GitHub-hosted `docs/update.json` feed. The in-app updater downloads the latest signed disk image, shows progress during download, then opens the DMG so you can drag the app into Applications.

When publishing a new version:

1. Build new DMG images.
2. Upload the DMG files to a GitHub release.
3. Update `docs/update.json` with the new version and asset URL.

## Project Structure

- `Sources/` contains the app, views, models, and service modules
- `AppBundle/Contents/Info.plist` defines the app bundle metadata
- `build.sh` creates architecture-specific app bundles, drag-and-drop DMGs, and the update feed
- `docs/update.json` is the updater manifest
