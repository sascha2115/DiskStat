I've reviewed `Sources/diskstat/main.swift` (610 lines), all three shell scripts, and the docs — plus diffed against the archived `archive/main.00.swift` to see what changed. Here's what I found, ordered by severity.

---

# Code Review: DiskStat

## 🔴 High severity

### 1. Pipe deadlock + main-thread blocking in `diskutilInfoPlist` — `main.swift:223-250`

This is the most serious issue. Two independent deadlock paths plus main-thread blocking:

```swift
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = Pipe()      // (a) never read at all
try process.run()
process.waitUntilExit()             // (b) blocks main thread
let data = pipe.fileHandleForReading.readDataToEndOfFile()  // (c) read AFTER wait
```

- **(a)** `standardError` is a `Pipe` that is **never drained**. If `diskutil` writes >64 KB to stderr it blocks in `write()` forever. `diskutil` chatters on stderr when probing hardware.
- **(c)** Classic pipe-buffer deadlock: `waitUntilExit()` blocks before stdout is read. If `diskutil info -plist` emits >64 KB (plausible on a busy APFS container), the child blocks writing and we block waiting → **permanent, unrecoverable hang of the whole app including the menu bar**.
- **(b)** No timeout. A stalled USB device can block `diskutil` for many seconds; the main thread (and thus the UI) is frozen the whole time.

**Reachability is worse than it looks:** `rebuildMenu()` → `allMountedDisks()` → `diskMeta()` per volume, and `resolvePartitionMap` (`main.swift:176-194`) walks volume → `APFSPhysicalStore` → `ParentWholeDisk` → `Content`, spawning **up to 3-4 `diskutil` processes per volume, per cache expiry, on the main thread**.

**Fix:** read the pipes *before* `waitUntilExit()`, or better — move this off the main thread behind a `DispatchQueue` and make the cache access safe.

### 2. `rebuildMenu()` runs every 10 s even when the menu is closed — `main.swift:440-443`

```swift
refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
    self?.updateStatusItem()
    self?.rebuildMenu()          // ← pure waste when menu is closed
}
```

`menuNeedsUpdate` (`main.swift:450`) rebuilds again on open. So every 10 seconds, 24/7, the app: tears down and rebuilds the entire menu, allocates N `DiskMenuRowView`s, calls `NSWorkspace.shared.icon(forFile:)` N times, and (on cache expiry) spawns `diskutil` subprocesses — **for a menu nobody is looking at**.

**Cheapest big win in the codebase:** delete the `rebuildMenu()` call from the timer. `menuNeedsUpdate` already guarantees fresh data on every open.

### 3. The menu is mutated while the user is interacting with it — `main.swift:566`, `588-599`

`refreshNow()` calls `rebuildMenu()` **while the menu is open** — the user clicks the item, and the handler destroys the very menu mid-event. `ejectDisk()` does the same via `DispatchQueue.main.asyncAfter(1.0)`.

This is a genuine reentrancy hazard, and it is only *partially* masked: `Timer.scheduledTimer` registers in `.default` mode while menu tracking runs in `NSEventTrackingRunLoopMode`, so the timer usually can't fire mid-menu — but **`DispatchQueue.main` blocks *are* drained in common modes**, so the eject path can really do it. Modifying a tracking `NSMenu` is undefined AppKit behaviour (highlight loss, dead clicks, occasional crash).

**Fix:** `menu.close()` first, or defer the rebuild to `menuDidClose` / the next `menuNeedsUpdate`.

### 4. The entire "Cleanup Agent" is documented but **does not exist in the code**

`AGENTS.md` §5 and `what_is_cleaned.txt` describe a feature that isn't there. Confirmed by comparing against `archive/main.00.swift`:

| Archived version had | Current version |
|---|---|
| `struct CleanupResult` | ❌ gone |
| `cleanTapped` / `cleanDisk` | ❌ gone |
| `performMacMetadataCleanup` (recursive `.DS_Store` / `._*` + root artifacts) | ❌ gone |
| `appendCleanupLog` → `~/Library/Logs/DiskStat_clean.log` | ❌ gone |
| `requestNotificationAuthorization` / `postCleanupNotification` | ❌ gone |
| "Clean and Eject Disk" button per row | ❌ gone |

`grep -rniE 'DS_Store|Spotlight-V100|Trashes|removeItem' Sources/` returns exactly one hit — `menu.removeItem(...)`, an AppKit call.

And since you just moved the reference implementation to a **gitignored** `archive/`, the "Cleanup Agent" now has **no source of truth in version control at all**.

---

## 🟡 Medium severity

### 5. Duplicated & inconsistent resource-key sets — `main.swift:36-46, 53-62, 106-114`

The same 9-key array is written out **three times**, and:

> `disk(atPath:)` (`106-114`) is **missing `.volumeIsLocalKey`** which `allMountedDisks()` has.

Consequence: `disk(atPath:)` — the path used for the **menu bar status item** — never applies the `volumeIsLocal` filter that the menu path applies. Two different filtering rules for the same data.

Also, the second `url.resourceValues(forKeys:)` at `53-62` is **redundant**: `mountedVolumeURLs(includingResourceValuesForKeys:)` already prefetched exactly those keys.

**Fix:** one `private static let volumeKeys: Set<URLResourceKey>` used in both places.

### 6. Avoidable force-unwraps — `main.swift:158-159`

```swift
let fsValue = (fs?.isEmpty == false) ? fs! : "Unknown"
let mapValue = (partitionMap?.isEmpty == false) ? partitionMap! : "Unknown"
```

Logically safe (if `?.isEmpty == false` then non-nil), but the compiler can't prove it and it's a crash-shaped pattern. Idiomatic form: `if let fs, !fs.isEmpty`. And since both tuple members are non-optional `String`, the `mapValue` unwrap is avoidable entirely.

### 7. `primaryDisk()` fallback can display a random USB stick as "the system disk" — `main.swift:96-102`

```swift
return allMountedDisks().first   // sorted by NAME, no internal/boot preference
```

If `/` can't be read, the status bar silently shows whichever volume sorts first alphabetically — an external drive. Better: prefer the first **non-external** disk, or the volume containing `$HOME`.

### 8. `diskutil` cache is keyed wrong and caches failures — `main.swift:31, 136-145`

- **Keyed by mount path, never invalidated on unmount/remount** → a *different* physical device mounted at the same path shows stale filesystem/partition info for up to 5 minutes.
- **`"Unknown"` gets cached too** (`main.swift:142`: `?? ("Unknown", "Unknown")`) → a single transient `diskutil` failure poisons the label for 5 full minutes.
- **Never evicted** — grows for every path ever seen.
- The dictionary is **unsynchronized mutable state**. Safe *only* because everything currently runs on the main thread. It's a landmine the moment you apply the async fix for issue #1.

---

## 🟢 Low severity / polish

### 9. `UUID` identity is meaningless — `main.swift:4`
`let id = UUID()` regenerates on every refresh, and `Identifiable` is **never used** (rows are `NSView`s in an `NSMenu`, not a SwiftUI list). `var id: String { mountURL.path }` is the natural stable key.

### 10. Row view height is hardcoded and can clip — `main.swift:296`
Frame is `340×104`, but the stack is pinned to all four edges (`385-393`) so its intrinsic height can exceed `104 - 16 = 88pt` with larger system fonts, long volume names, or localization. `NSMenu` sizes items from the view frame, so content gets **clipped rather than the row growing**. Needs `fittingSize` / `preferredFrameSize` or a self-sizing view.

Related: `main.swift:305` mutates `.size` on the image returned by `NSWorkspace.shared.icon(forFile:)` — safer to `copy()` it first.

### 11. `openStorageSettings()` fallback logic is unreliable — `main.swift:571-586`
`NSWorkspace.shared.open(_:)` returns whether the request was **accepted**, not whether the right pane opened. With 4 candidate URLs (2 of them legacy/dead schemes), the loop will typically return `true` on the first and exit even if System Settings lands on the wrong screen. Entries 1 and 2 are also near-duplicates.

### 12. Pie image rebuilt 6×/minute — `main.swift:518`
`updateStatusItem()` allocates and rasterizes a new 20×20 `NSImage` via `lockFocus()` on **every tick**, even when the rounded percentage is unchanged. Cache and rebuild only on change. (`NSImage(size:flipped:drawingHandler:)` is the modern alternative to the legacy `lockFocus` path.)

### 13. `resolveFreeBytes` two-pass heuristic is subtle — `main.swift:252-284`
```swift
if let positive = candidates.compactMap({ $0 }).first(where: { $0 > 0 }) { return positive }
if let zero = candidates.compactMap({ $0 }).first(where: { $0 == 0 }) { return zero }
```
The `> 0` pass discards a legitimate `0` from a *higher-priority* key in favour of a positive value from a *lower-priority* one, so the result depends on the filter rather than the documented priority order. `compactMap` is also computed twice. Works, but it needs a comment and tests, or one explicitly documented key per filesystem family.

### 14. No guard against ejecting the boot volume — `main.swift:329`
`showEjectButton = disk.isExternal || disk.isEjectable` never excludes `disk.path == "/"`. On a Mac booted from external media, the button would offer to unmount the running system.

### 15. Timer run-loop mode — `main.swift:440`
Registered in `.default`, so it **silently stops firing while any menu is tracking**. Mostly harmless (arguably desirable), but it means "refreshes every 10 s" isn't strictly true. `RunLoop.main.add(_:forMode: .common)` if you want strictness.

### 16. Swift 6 forward-compat — `Package.swift:1`
`swift-tools-version: 5.9` → strict concurrency off. The mutable `diskutilCache`, the `Timer` closures, and the `NSStatusItem!` IUO would all need `@MainActor` under the Swift 6 language mode. Cheap to add now.

---

## 📄 Script issues

**`uninstall_login_item.sh`** — `AGENTS.md` §3 claims it *"Cleans up LaunchAgent **and local copies**"*, but the script only does `rm -f "$PLIST_PATH"`. `~/Applications/DiskStat.app` is left behind. Doc/impl mismatch.

**`install_login_item.sh`**
- `main:16-36` — `$APP_PATH` is interpolated **raw into the plist XML heredoc**. A path containing `&` or `<` produces an invalid plist. Escape it or use a plist writer.
- Uses `/usr/bin/open` as the program, so the agent exits immediately and launchd has no handle on the real process. Fine for `RunAtLoad`, but if you ever want to manage the process, point `ProgramArguments` at `Contents/MacOS/DiskStat` directly.

**`build_app.sh`**
- `VERSION`/`BUILD_NUMBER` hardcoded (`:6-7`), not derived from git.
- `codesign --force --deep --sign -` — Apple discourages `--deep`; sign nested code explicitly. Harmless for local ad-hoc use.

---

## 📚 Documentation inconsistencies

| Document | Claim | Reality |
|---|---|---|
| `README.md:7-9` | menu bar shows "a pie chart icon **and a numeric percentage**" | ❌ Percentage is **never rendered**. `button.title = ""` at `main.swift:432, 456, 463` — in all three places. The `monospacedDigitSystemFont` at `:431` is configured for a title that never gets set. **Present in the archived version too** (`:325, 350, 357`) → long-standing, not a regression. |
| `README.md:19,34,42,49,58,64` | `/Users/sascha/develop/diskstat` | ❌ Project lives in `/Users/sascha/Projects/DiskStat` |
| `README.md:12` | shows "used / total / **free** size" | ❌ Only "Used: X of Y" is displayed; free is never shown |
| `README.md:14` | "Includes `Refresh Now` and `Quit DiskStat`" | ⚠️ Omits `Open Storage Settings…` (`main.swift:509`) |
| `AGENTS.md:7` | Output: `/dist/DiskStat.app` | ⚠️ Wrong case — actual is `Dist/DiskStat.app` |
| `AGENTS.md:25` | "Excludes hidden volumes (`.Spotlight-V100`, `.Trashes`)" | ❌ Those names appear nowhere in the code. It actually uses `options: [.skipHiddenVolumes]` |
| `AGENTS.md:27-32` | Cleanup Agent | ❌ See issue #4 — feature doesn't exist |

---

## ✅ What the code gets right

Worth stating explicitly, since these are the easy things to get wrong:

- **No shell injection** — `diskutil` is invoked via `Process` with an argument array, never a shell string.
- **Permissive optional handling** — `volumeIsLocal != false` and `volumeIsInternal == false` correctly treat "unknown" as "include" rather than silently dropping volumes.
- **Numeric safety** — `usedBytes` clamps at 0 and `usedFraction` clamps to `0...1`, so no negative/NaN geometry in the pie chart.
- **No retain cycles** — `[weak self]` is used consistently in every closure, including the eject callback.
- **Clean build** — zero warnings from `swift build -c release`.
- **Scripts** — `set -euo pipefail` throughout, exec bits preserved in git, ad-hoc signing means Gatekeeper won't block local runs.

---

## Suggested priority

1. **Fix the pipe deadlock + move `diskutil` off the main thread** (#1) — the only issue that can hard-hang the app.
2. **Remove `rebuildMenu()` from the timer** (#2) — one-line change, removes ~99% of the wasted work.
3. **Decide on the Cleanup feature** (#4) — either restore it from `archive/main.00.swift` or delete `AGENTS.md` §5 and `what_is_cleaned.txt`. Right now the docs describe a ghost.
4. Guard menu rebuilds while tracking (#3), then the medium-severity cleanups (#5-#8).
5. Docs last — they're cheap and mostly mechanical once the code is settled.

Want me to implement any of these? I'd suggest starting with #1 and #2, since they're high-impact and low-risk. Just say which ones, and whether you want them as separate commits.