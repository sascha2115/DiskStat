# DiskStat (menu bar disk usage)

Tiny macOS menu bar app that shows disk usage as a pie icon + percentage.

## What it does

- Shows the current system disk usage in the menu bar as:
  - a pie chart icon
  - a numeric percentage
- On click, opens a dropdown with all connected local disks:
  - disk name
  - used percentage
  - used / total / free size
- Includes `Refresh Now` and `Quit DiskStat` actions.

## Run

```bash
cd /Users/sascha/develop/diskstat
swift run
```

The app appears in the macOS menu bar while the process is running.

## Build

```bash
swift build -c release
```

Binary path:

```text
/Users/sascha/develop/diskstat/.build/release/diskstat
```

## Build `.app` (no Dock icon)

Creates a proper app bundle with `LSUIElement=true` so DiskStat runs as a menu bar app without a Dock icon.

```bash
cd /Users/sascha/develop/diskstat
./scripts/build_app.sh
```

Output:

```text
/Users/sascha/develop/diskstat/Dist/DiskStat.app
```

## Run At Login

1. Copy the app bundle somewhere stable (recommended):

```bash
mkdir -p ~/Applications
cp -R /Users/sascha/develop/diskstat/Dist/DiskStat.app ~/Applications/
```

2. Install a login item (LaunchAgent):

```bash
cd /Users/sascha/develop/diskstat
./scripts/install_login_item.sh ~/Applications/DiskStat.app
```

3. Remove login item later (optional):

```bash
cd /Users/sascha/develop/diskstat
./scripts/uninstall_login_item.sh
```

## Notes

- Uses local mounted volumes from `FileManager.mountedVolumeURLs(...)`.
- Excludes hidden and non-local volumes.
- Refreshes menu bar usage every 10 seconds.
