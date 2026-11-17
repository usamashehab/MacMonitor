# MacMonitor

A tiny, free macOS menu bar app that shows your Mac's vitals at a glance.

The menu bar shows CPU usage and CPU temperature. One click opens a panel with:

- **Processor** usage
- **GPU** usage
- **Memory** used / total (same figure as Activity Monitor's "Memory Used")
- **Swap** used / total
- **Temperatures**: CPU, GPU, SSD, battery
- **Network** download / upload speed
- **Open at Login** switch

It refreshes every 2 seconds, uses no network, needs no permissions, and is under 500 KB.

## Install

### Option 1: download the app

1. Download `MacMonitor.zip` from the [latest release](https://github.com/usamashehab/MacMonitor/releases/latest).
2. Unzip it and drag `MacMonitor.app` into your **Applications** folder.
3. Open it. macOS will block it the first time because the app isn't signed with a paid Apple Developer ID. To allow it, do **one** of the following:
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to MacMonitor. Then open the app again.
   - Or run this in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/MacMonitor.app
     ```
4. A CPU-chip icon appears in the menu bar. Click it to open the panel. Click it again, click anywhere else, or press Esc to close it.

MacMonitor turns on **Open at Login** the first time it runs. You can switch it off in the panel.

### Option 2: build from source

Requirements: macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/usamashehab/MacMonitor.git
cd MacMonitor
./build.sh
cp -R MacMonitor.app /Applications/
open /Applications/MacMonitor.app
```

`./build.sh --zip` also creates `dist/MacMonitor.zip` for a release.

## Uninstall

1. Click the menu bar icon and turn off **Open at Login**, then click **Quit**.
2. Delete `/Applications/MacMonitor.app`.

## Compatibility

| | Status |
|---|---|
| Apple Silicon (M1–M4 and later) | Tested on M1 Max, macOS 27 |
| Intel Macs | Universal binary is built but **untested**; temperatures will likely show "—" |
| macOS | 13 Ventura or later |

## How it works

| Metric | Source |
|---|---|
| CPU | `host_statistics` (`HOST_CPU_LOAD_INFO`), measured between refreshes |
| Memory | `host_statistics64` (`HOST_VM_INFO64`): app + wired + compressed pages |
| Swap | `sysctl vm.swapusage` |
| GPU | IOKit `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %` |
| Temperature | IOHIDEventSystem temperature sensors (`PMU tdie*` for CPU, `PMU TP*g` for GPU, `NAND` for SSD, `gas gauge battery`) |
| Network | `sysctl NET_RT_IFLIST2` 64-bit counters on physical interfaces (VPN tunnels excluded to avoid double counting) |

The temperature sensors are read through an **undocumented** macOS API. It works today, but a future macOS update could change sensor names or remove access. If that happens, temperatures show "—" and everything else keeps working.

## Project layout

```
Sources/App.swift      menu bar item, dropdown panel, open-at-login
Sources/Stats.swift    CPU, memory, swap, network, temperature grouping
Sources/sensors.c      temperature sensors and GPU usage (C / IOKit)
Sources/sensors.h      C header bridged into Swift
build.sh               builds the universal app bundle
```

## License

[MIT](LICENSE)
