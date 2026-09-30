# DiskStat AGENTS.md

## 0. Source Layout
`Sources/diskstat/` is one type per file. `main.swift` is imports plus the
bootstrap and nothing else:

| File | Holds |
|---|---|
| `DiskUsage.swift` | the `DiskUsage` value type |
| `DiskUsageProvider.swift` | volume discovery |
| `DiskMetaCache.swift` | thread-safe metadata cache |
| `DiskutilInspector.swift` | `diskutil` invocation and parsing |
| `DiskCleaner.swift` | `MacArtifact` and `DiskCleaner` |
| `DiskMenuRowView.swift` | one menu row |
| `DiskMenuController.swift` | app delegate, menu, clean orchestration |
| `Support.swift` | `DiskStatError`, `SynchronizedBox`, `DiskMeta` |
| `Version.swift` | generated, do not hand-edit |

`SynchronizedBox` is deliberately **not** `private`: two files use it, and
`private` at top level is file-scoped. Every other `private` in the codebase is
internal to its own type and travels with it when moved.

## 1. Build Agent
- **Purpose**: Compiles Swift code into executables
- **Scripts**: `scripts/build_app.sh` (for app bundle)
- **Commands**: `swift build -c release`
- **Output**: `Dist/DiskStat.app`

## 2. Login Item Agent
- **Purpose**: Installs app as macOS login item
- **Script**: `scripts/install_login_item.sh`
- **Action**: Creates LaunchAgent for startup

## 3. Uninstallation Agent
- **Purpose**: Removes login item and app traces
- **Script**: `scripts/uninstall_login_item.sh`
- **Action**: Cleans up LaunchAgent and the `~/Applications` copy, after
  checking the bundle id so it can never remove an unrelated app

## 4. Disk Monitoring Agent
- **Core Functionality**: Implements disk usage tracking
- **Source**: `Sources/diskstat/DiskUsageProvider.swift` (`DiskUsageProvider`)
- **Techniques**:
  - Uses `FileManager.mountedVolumeURLs()` for volume detection
  - Hides hidden volumes via `.skipHiddenVolumes`, drops non-local ones
  - Never offers eject or clean for the volume macOS is running from
  - Refreshes every 10s via timer

## 5. Cleanup Agent
- **Purpose**: Removes macOS artefacts from a removable volume, then ejects it
- **Source**: `DiskCleaner` / `MacArtifact` in `Sources/diskstat/DiskCleaner.swift`
- **Reference**: the "What a clean removes" table in `README.md` is the exact
  scope and the single source of truth. Adding or removing an artefact means
  changing that table in the same commit as the code
- **Never touches**: `.Trashes` (the user's deleted files), the startup
  volume, or any volume other than the one selected
- **User-placed markers are left alone**: `.VolumeIcon.icns`,
  `.metadata_never_index` and `.fseventsd/no_log`. Only the third needs code —
  a `.fseventsd` holding a `no_log` is emptied rather than deleted, or macOS
  recreates it and restarts journalling. The first two survive for free,
  because nothing matches their names, but they are pinned by tests so a future
  `._*`-style prefix rule cannot quietly start eating them
- **Symlinks are never followed**: a link is never removed and never
  descended into, so a clean cannot reach outside the selected volume.
  Re-enforced inside `DiskCleaner.clean()`, not only at the UI layer. Two
  independent guards cover this — the `d_type` `readdir` reports, and an
  `lstat` on anything it calls a directory — so either one alone is enough.
  The test suite can only exercise the first: APFS reports `DT_LNK`, so
  deleting the `lstat` backstop still passes on this machine
- **Scope is name-only**: `MacArtifact` matches the entry name wherever it
  appears, so nothing is restricted to the top level of the volume. If that is
  ever changed, the README table and this section both have to change with it
- **Operations**:
  - Scans the whole volume first, then deletes, so a long run stays cancellable
  - Uses POSIX `readdir`; `FileManager` hides the `._*` files it must remove
  - Skips non-directories on the `d_type` already returned by `readdir`, so a
    large library does not pay two syscalls per media file
  - Runs on a background queue; the clean button becomes a cancel button
  - Keeps working across a menu rebuild, and throttles progress to 4/sec
  - Logs every removed path to `~/Library/Logs/DiskStat_clean.log`,
    grouped by artefact type ahead of the path list
  - Ejects on success; a cancelled run leaves the volume mounted
  - Posts a system notification with the counts, because the menu row showing
    the result is not on screen if the menu was closed during the run. Plain
    ejects do not notify. Needs a real bundle id, so `.app` only, never
    `swift run`

## 6. Test Agent
- **Target**: `Tests/DiskStatTests/CleanerSafetyTests.swift`
- **Command**: `swift test` (manual — nothing runs it in CI, and a
  destructive-safety change without a test is an incomplete change)
- **Covers**: what the cleaner refuses to do. A test that cannot fail when
  its guarantee is removed is not a test — verify by breaking the guard
  and watching it go red before trusting it
- **Known gap**: the eject/clean/cancel buttons and the row layout can
  only be verified by hand, with a real DMG or media drive attached