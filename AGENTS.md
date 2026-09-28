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
- **Purpose**: Manages disk cleanup tasks
- **Reference**: `what_is_cleaned.txt`
- **Operations**:
  - Deletes `.DS_Store`, `._*`, and system temp folders
  - Supports both root and recursive cleaning