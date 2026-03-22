# Task Manager Pro

Task Manager Pro is a polished macOS system monitor built for people who want a cleaner, more powerful alternative to jumping between Activity Monitor, network tools, and temperature utilities.

It gives you a modern Mac-native dashboard for processes, performance, thermals, and network activity, with a fast UI, safe app controls, menu bar monitoring, and built-in updating.

[Download for Apple Silicon Macs](https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.56/TaskManagerPro-1.0.56-apple-silicon.dmg)

[Download for Intel Macs](https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.56/TaskManagerPro-1.0.56-intel.dmg)

## Why Task Manager Pro

- See what is using your Mac at a glance
- Monitor CPU, RAM, disk, network, GPU, and thermals from one app
- Quit, terminate, or force quit apps quickly and safely
- Watch live resource usage with clear charts and a lightweight menu bar view
- Get a simple everyday view for normal users and deeper telemetry for power users

## What It Can Do

- Processes tab with live per-app CPU, GPU, and memory usage
- Quick actions for `Quit`, `Terminate`, and `Force Quit`
- Performance dashboard with real-time CPU, RAM, disk, and network charts
- Right-click CPU widget to switch between overall CPU activity and per-core mini graphs
- Advanced Network tab with interfaces, routing, DNS, and active connection details
- Advanced Thermals tab with CPU temp, GPU temp, palm-rest temp, live fan RPM, and readable sensor names
- Search, sorting, filtering, and resource-heavy app highlighting
- Menu bar monitor with `Off`, `Compact`, and `Two-Line` display modes
- Light mode, dark mode, or follow system appearance
- Optional Dock icon visibility
- Built-in background updater

## Built For

- Mac users who want a cleaner replacement for Activity Monitor
- Power users who want deeper diagnostics without juggling multiple tools
- Developers, creators, and professionals who want live visibility into system load

## Modes

### Basic Mode

Basic Mode keeps the app simple, clean, and focused on what most people want every day:

- Processes with live CPU and memory usage
- Safe app controls like `Quit`, `Terminate`, and `Force Quit`
- Performance charts for CPU, RAM, disk, and network
- A lighter dashboard that is easier to scan quickly
- Menu bar monitoring and appearance controls

### Advanced Mode

Advanced Mode is built for power users who want deeper insight into how their Mac is behaving:

- GPU visibility in more areas of the app
- Full Network monitoring with interfaces, DNS, routing, and active connections
- Full Thermals monitoring with CPU temp, GPU temp, palm-rest temp, fan RPM, and sensor readings
- Expanded telemetry for troubleshooting, diagnostics, and performance analysis

## Download

Task Manager Pro is available as drag-and-drop DMG installers:

- [Apple Silicon DMG](https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.56/TaskManagerPro-1.0.56-apple-silicon.dmg)
- [Intel DMG](https://github.com/agraja38/Task-Manager-Pro/releases/download/v1.0.56/TaskManagerPro-1.0.56-intel.dmg)

## For Developers

License: MIT. See [LICENSE](LICENSE).

- `Sources/` contains the app, views, models, and service modules
- `AppBundle/Contents/Info.plist` defines the app bundle metadata
- `build.sh` creates architecture-specific app bundles, DMGs, and the update feed
- `docs/update.json` is the updater manifest
