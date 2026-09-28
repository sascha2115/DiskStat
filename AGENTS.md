# DiskStat AGENTS.md

## 1. Build Agent
- **Purpose**: Compiles Swift code into executables
- **Scripts**: `scripts/build_app.sh` (for app bundle)
- **Commands**: `swift build -c release`
- **Output**: `/dist/DiskStat.app`

## 2. Login Item Agent
- **Purpose**: Installs app as macOS login item
- **Script**: `scripts/install_login_item.sh`
- **Action**: Creates LaunchAgent for startup

## 3. Uninstallation Agent
- **Purpose**: Removes login item and app traces
- **Script**: `scripts/uninstall_login_item.sh`
- **Action**: Cleans up LaunchAgent and local copies

## 4. Disk Monitoring Agent
- **Core Functionality**: Implements disk usage tracking
- **Source**: `Sources/diskstat/main.swift`
- **Techniques**:
  - Uses `FileManager.mountedVolumeURLs()` for volume detection
  - Excludes hidden volumes (`.Spotlight-V100`, `.Trashes`)
  - Refreshes every 10s via timer

## 5. Cleanup Agent
- **Purpose**: Removes macOS artefacts from a removable volume, then ejects it
- **Source**: `DiskCleaner` / `MacArtifact` in `Sources/diskstat/main.swift`
- **Reference**: `what_is_cleaned.txt` for the exact scope
- **Never touches**: `.Trashes` (the user's deleted files), the startup
  volume, or any volume other than the one selected
- **Operations**:
  - Scans the whole volume first, then deletes, so a long run stays cancellable
  - Uses POSIX `readdir`; `FileManager` hides the `._*` files it must remove
  - Runs on a background queue; the clean button becomes a cancel button
  - Logs every removed path to `~/Library/Logs/DiskStat_clean.log`
  - Ejects on success; a cancelled run leaves the volume mounted