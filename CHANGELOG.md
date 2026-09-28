# Changelog

Versions are tagged; the bundle's `CFBundleShortVersionString` is read from the
most recent tag at build time, so tagging is the only step needed to release.
`CFBundleVersion` is the commit count.

## 1.0.0 - 2025-09-28

First tagged release. Everything below landed after the initial commit.

### Added
- Volume cleanup for removable volumes: removes `.DS_Store`, `._*`, `@eaDir`,
  `.Spotlight-V100`, `.fseventsd` and `.TemporaryItems`, then ejects. Runs on a
  background queue, is cancellable, and writes every removed path to
  `~/Library/Logs/DiskStat_clean.log` grouped by artefact type.
- System notification reporting a finished clean. `.app` bundle only, since
  authorisation needs a bundle identifier.
- Volume mount/unmount notifications, so an ejected disk leaves the menu
  immediately instead of after a fixed delay.
- `Tests/DiskStatTests/CleanerSafetyTests.swift` - 10 tests covering what the
  cleaner refuses to do.
- `CHANGELOG.md`, and an uninstall script that checks the bundle id before
  removing anything.

### Fixed
- `diskutil` no longer runs on the main thread. It deadlocked, froze the menu,
  and had no timeout; metadata is now fetched on a background queue and cached.
- The menu is never rebuilt while AppKit is tracking it, which previously tore
  down the menu mid-interaction.
- Disk rows self-size instead of using a hardcoded height, and pin the volume
  icon instead of resizing a shared multi-representation image.
- The cleaner no longer follows symlinks. A link is never removed and never
  descended into, so a clean cannot reach outside the selected volume. The guard
  lives inside `DiskCleaner.clean()`, not only at the UI layer.
- Free space is read from `volumeAvailableCapacity` and matches Disk Utility;
  the previous "important usage" heuristic could report more free space than
  existed.
- `DiskUsage` has a stable identity instead of a fresh UUID per refresh.
- A clean in progress stays visible across a menu rebuild, and its progress is
  throttled to 4 updates/second.

### Changed
- `@MainActor` and `-strict-concurrency=complete`, so the compiler enforces the
  main-thread rule that was previously only a convention.
- Main-actor callbacks hop to the main queue instead of asserting via
  `MainActor.assumeIsolated`, which would have turned a later edit into a crash
  in shipped code.
- The app version is read from the most recent git tag rather than a constant in
  the build script.
