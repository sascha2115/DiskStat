# Changelog

Versions are tagged; the bundle's `CFBundleShortVersionString` is read from the
most recent tag at build time, so tagging is the only step needed to release.
`CFBundleVersion` is the commit count.

## 1.0.3 - 2026-09-30

### Added
- Each disk row now shows the device macOS knows the volume by, after the
  filesystem and partition scheme: `exFAT • GUID • disk4s2`. It comes from
  `DeviceIdentifier` in the `diskutil` plist the app was already fetching and
  discarding. Worth the line because that is the name macOS uses when it
  *refuses* to act — "The disk disk4s2 wasn't ejected properly because a file
  was in use" — and the name a `diskutil` error quotes, neither of which the
  volume name ("MEDIADISK") matches. Omitted entirely when `diskutil` has not
  answered, rather than showing a placeholder.
- `DiskutilInspector.parse(_:)` is split out of `meta(forMountPath:)`, and
  `DiskMenuRowView.metaLine(for:)` out of the row's initialiser, so the key
  handling and the line's text can be tested. Neither was reachable before: the
  first needed a subprocess, the second an `NSView`. 11 new tests, bringing the
  suite to 32.

## 1.0.2 - 2026-09-30

A finished clean is now reported where the user will actually see it, and two
real bugs found on a live exFAT card are fixed. The cleaner is unchanged in what
it removes and what it refuses to remove.

### Added
- `.apdisk`, the volume marker macOS leaves on a drive it has connected, is now
  cleaned alongside the other artefacts. Matched on the exact name only, so
  `apdisk.bak`-style lookalikes are left alone, and it is reported as its own
  type in the clean log.
- The outcome of a clean is now reported on a "Last clean" line in the menu, as
  `<n> removed · <m> failed`, calling out a cancelled run and a failed eject
  alongside it. Both counts are always shown, including a zero. This is the
  primary record of a clean: the system notification is not sent under
  `swift run`, for a bundle with no identifier, or when the user declines the
  authorisation prompt, so those cases previously reported nothing at all.
- A `Show Clean Log…` menu item opens `~/Library/Logs/DiskStat_clean.log`, which
  was written by every clean but unreachable from the UI. It is enabled only
  once a log exists, and it is the only record that names individual paths.
- A `Clear Clean Log` menu item deletes that log, with no confirmation dialog.
  The log is a record rather than data and the next clean writes a new one, so a
  deliberately worded menu click is intent enough.
- A clean that removed nothing, failed on some files, or could not eject now
  says so on the disk row. It previously reverted silently to the normal size
  reading, so the only sign of a problem was the notification.
- Deliberately not added: a progress window. A clean scans and deletes a typical
  media library in well under a second, so a dialog would be up and gone before
  it could be read. If one is ever wanted, it should appear only after a clean
  has been running for some seconds.

### Changed
- The volume scan no longer tries to open regular files as directories. It used
  to queue every entry for descent, `stat` it to check for a symlink, and then
  `opendir` it — so on a media library of hundreds of thousands of files, two
  syscalls per file were spent reaching entries that were about to be discarded.
  The scan now reads the type that `readdir` already returns, and a reported
  directory is still confirmed with `lstat`, so symlinks are still never
  followed. Behaviour is unchanged; only the syscall count drops.
- `Sources/diskstat/main.swift` is split into one type per file. `main.swift` is
  now imports plus the bootstrap; the largest file went from 1,599 lines to 504.
  No behaviour changed — the only edit to any moved code is dropping `private`
  from `SynchronizedBox`, which two files now use and which Swift scopes to a
  single file. A new "Source Layout" section in `AGENTS.md` documents it.
- `Tests/DiskStatTests` has 21 tests. The exFAT sidecar regression lives in
  its own `SidecarOfArtefactTests.swift` because it needs a real exFAT disk image
  to reproduce the bug at all; the rest are in `CleanerSafetyTests.swift`.
- The clean button's tooltip is now "Clean and Eject", down from "Remove macOS
  files, then eject". The old wording described the implementation rather than
  the action, and was long enough to be unwieldy on a menu row. The string was
  duplicated in two places, so it is now a single constant.

### Fixed
- A clean no longer reports a spurious failure for the AppleDouble sidecar of a
  file it has already removed. On exFAT and FAT, a `.DS_Store` that carries an
  extended attribute has a `._.DS_Store` beside it, and both matched the
  cleaner; removing the `.DS_Store` made the kernel delete the sidecar too, so
  removing the sidecar's own entry failed with "“._.DS_Store” couldn't be
  removed." The volume was clean and only the count was wrong, but the run
  reported failures and so sent the user looking for a problem that was not
  there. Found on a real exFAT card, and now covered by a regression test that
  builds a real exFAT disk image to reproduce it.
- The version now appears when the app is run as a bare executable (`swift run`)
  or as `.build/release/diskstat`, not only from the `.app` bundle. Those runs
  have no `Info.plist` to read, so they fell back to showing "dev".
  `scripts/set_version.sh` writes the tagged version into a generated
  `Sources/diskstat/Version.swift`, and a test pins that file to the latest tag
  so it cannot go stale unnoticed.
- A `.fseventsd` holding a `no_log` marker is no longer deleted outright. That
  marker is how a volume is told not to journal file system events, so removing
  the directory removed the marker too and macOS recreated the directory and
  started logging again on the next mount. The directory is now emptied and
  kept. A `.fseventsd` without the marker is still removed as before.
- The clean button's VoiceOver label no longer loses the volume name after the
  first clean. It announced "Clean MYSTICK" when the row was built, but
  `setBusy(_:)` replaced the image with a bare "Clean" and the name was silently
  dropped from then on.

### Documentation
- `what_is_cleaned.txt` is gone. The artefact list existed only in that file —
  `.apdisk`, `.TemporaryItems` and `.Spotlight-V100` were named nowhere else — so
  it was moved rather than dropped, and the README and `AGENTS.md` now name the
  one source of truth instead of pointing at a separate file.
- That document also claimed `.Spotlight-V100`, `.fseventsd` and
  `.TemporaryItems` were cleaned only at the top level of a volume. The cleaner
  matches on the entry name alone, so a nested one of any of them would be
  removed too. The README now says what the code does rather than asserting a
  restriction it never enforced.

## 1.0.1 - 2025-09-28

### Added
- The version is shown next to the title in the menu, read from the bundle so
  the number on screen is the one that was tagged.

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
