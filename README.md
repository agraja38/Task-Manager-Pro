# Task Manager Pro

Task Manager Pro is a native-style macOS Task Manager built with SwiftUI and AppKit. It brings the familiar Windows Task Manager workflow to macOS with a clean top navigation layout, real-time charts, safe process controls, and a built-in updater.

License: MIT. See [LICENSE](LICENSE).

[Download for Apple Silicon Macs](https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.38/TaskManagerPro-1.0.38-apple-silicon.dmg)

[Download for Intel Macs](https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.38/TaskManagerPro-1.0.38-intel.dmg)

## Highlights

- Processes view with app icons, app names, live CPU/memory, and quick actions
- Processes header badges for CPU, memory, GPU, and network at a glance
- Safe `Quit`, `Terminate`, and `Force Quit` actions with warnings for critical macOS processes
- Performance dashboard with live CPU, memory, disk, network, GPU fallback, battery, and thermal-state cards
- Right-click the CPU widget to switch between overall CPU activity and a per-core grid of mini CPU graphs
- Normal mode keeps the dashboard focused on CPU, memory, disk, and network, while advanced telemetry mode shows the extra GPU and Battery & System widgets
- Search, sort, filter, dark mode, and resource-heavy highlighting
- Menu bar live monitor with Off, Compact, and Two-Line display modes
- Settings for Dock icon visibility and app appearance
- Built-in update flow that downloads the latest DMG, installs it in the background, and reopens the app
- Separate Apple Silicon and Intel drag-and-drop DMG builds

## macOS Notes

- Task Manager Pro uses public APIs first and falls back to safe alternatives when macOS restricts direct low-level telemetry.
- GPU usage and exact temperature readings are limited on macOS without private APIs or elevated tools.
- Some process terminations may still be denied by macOS if the current user does not own the target process or the process is protected.

## Advanced Telemetry Helper

For normal users, the Performance tab stays focused on CPU, memory, disk, and network. In advanced mode, Task Manager Pro also uses Activity Monitor-style GPU utilization from the macOS graphics registry when it is available, and it can be paired with an optional privileged helper for deeper telemetry.

To achieve that helper flow:

1. Sign the main app and the helper target with the same Developer ID team.
2. Install the helper with admin approval using a privileged XPC helper flow such as `SMAppService` or `SMJobBless`.
3. Have the helper collect protected readings from tools like `powermetrics`, `ioreg`, or SMC/IOKit interfaces.
4. Send the readings back to Task Manager Pro over XPC and keep the public-API fallback for users who do not install the helper.

## Updating

Task Manager Pro checks a GitHub-hosted `docs/update.json` feed. The in-app updater downloads the latest signed disk image, replaces the installed app in the background, and reopens Task Manager Pro automatically.

When publishing a new version:

1. Build new DMG images.
2. Upload the DMG files to a GitHub release.
3. Update `docs/update.json` with the new version and asset URL.

## Project Structure

- `Sources/` contains the app, views, models, and service modules
- `AppBundle/Contents/Info.plist` defines the app bundle metadata
- `build.sh` creates architecture-specific app bundles, drag-and-drop DMGs, and the update feed
- `docs/update.json` is the updater manifest
