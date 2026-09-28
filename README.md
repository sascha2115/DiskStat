# DiskStat (menu bar disk usage)

Tiny macOS menu bar app that shows disk usage as a pie icon.

## What it does

- Shows the boot volume's usage in the menu bar as a pie chart icon, with the
  percentage in the tooltip.
- On click, opens a dropdown with all connected local disks:
  - disk name
  - used / total size
  - used percentage
  - filesystem and partition scheme
- Per-disk buttons for removable volumes:
  - **eject** — unmount and eject the volume
  - **clean** — remove macOS artefacts (`.DS_Store`, `._*`, `@eaDir`, Spotlight
    index and friends) and then eject, so the drive is clean when it reaches
    Kodi or Windows. Never touches `.Trashes`; see `what_is_cleaned.txt`.
- Includes `Refresh Now`, `Open Storage Settings…` and `Quit DiskStat` actions.

## Run

```bash
swift run
```

The app appears in the macOS menu bar while the process is running.

## Build

```bash
swift build -c release
```

Binary path:

```text
.build/release/diskstat
```

## Build `.app` (no Dock icon)

Creates a proper app bundle with `LSUIElement=true` so DiskStat runs as a menu bar app without a Dock icon.

```bash
./scripts/build_app.sh
```

Output:

```text
Dist/DiskStat.app
```

## Run At Login

1. Copy the app bundle somewhere stable (recommended):

```bash
mkdir -p ~/Applications
cp -R Dist/DiskStat.app ~/Applications/
```

2. Install a login item (LaunchAgent):

```bash
./scripts/install_login_item.sh ~/Applications/DiskStat.app
```

3. Remove it again later (optional):

```bash
./scripts/uninstall_login_item.sh
```

This unloads the LaunchAgent and deletes `~/Applications/DiskStat.app`.

## Notes

- Uses local mounted volumes from `FileManager.mountedVolumeURLs(...)` with
  `.skipHiddenVolumes`, and drops anything reporting as non-local.
- Eject and clean are never offered for the volume macOS is running from.
- Refreshes menu bar usage every 10 seconds; the menu is only rebuilt when it
  is opened, so the app stays idle.
- Filesystem details come from `diskutil`, which runs on a background queue
  with a 5 second timeout and is cached.
