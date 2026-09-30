Changelog structure is clean now. Here's my honest assessment.

## First, a correction I owe you

While reviewing, I caught that **I had corrupted the changelog myself** in the previous turn. I'd changed the `1.0.0` entry from "10 tests" to "15" — rewriting a historical record. I verified against git that v1.0.0 genuinely shipped 10 tests, so the original was right. Reverted, and I moved the count into `Unreleased`. I'd also produced two duplicate `### Fixed` headings. Both fixed; heading structure verified.

Worth saying plainly: I introduced that error while confidently editing, which is a good argument for the review-happy process we've been using on the destructive code.

## Where the code genuinely is strong

This is not a typical "AI wrote a macOS app" codebase, and I want to be specific about why:

- **Concurrency is compiler-enforced**, not conventional. `-strict-concurrency=complete` in `Package.swift`, with a comment explaining *why* and noting the `unsafeFlags` trade-off honestly. A full clean rebuild produces **zero warnings**.
- **Safety invariants are double-guarded and documented**, including the two places where I could only verify one guard mechanically — recorded in `AGENTS.md` rather than glossed over.
- **Comments explain *why*, not *what*.** The timer comment explains that `NSEventTrackingRunLoopMode` was the actual bug, the `DispatchQueue.main.async` hop explains it's for a property of the line rather than the callback, `openStorageSettings` explains why the fallback chain was deleted. These are the comments of someone who got burned and wrote down why.
- **The log/notification design is genuinely thoughtful** — the menu row showing the result may not be on screen, hence the system notification.

## Real weaknesses, ranked

**1. No CI — the biggest gap.** `AGENTS.md` says it outright: *"manual — nothing runs it in CI."* For a project whose central risk is a cleaner that deletes user files, a test suite that only runs when someone remembers is a standing risk. This is the single highest-value thing you could add. A 20-line GitHub Actions workflow running `swift build` and `swift test` would close it.

**2. One 1,599-line file.** Ten top-level types, from an app delegate to a filesystem walker to a pie-chart renderer. It's *readable* — well-spaced, consistently commented — but it's the main structural debt. Splitting the cleaner into its own file is the natural first cut, since it's the part with the most subtle invariants and the least UI coupling.

**3. UI is verified only by hand.** `AGENTS.md` is candid that the eject/clean/cancel buttons and row layout "can only be verified by hand." Acceptable, and documented — but it means the row state machine (busy → cancel → result, surviving menu rebuilds) is the least-tested logic in the app.

**4. Test coverage is narrower than the risk profile suggests.** 15 tests, all on `DiskCleaner`. `DiskUsageProvider`, `DiskMetaCache`, and `DiskutilInspector` are untested — including the `diskutil` plist parsing, which is the kind of thing that breaks on a new macOS. Lower risk than the cleaner, but not zero.

**5. `archive/main.00.swift` is gitignored.** An untracked reference implementation is a working copy, not a reference. If it matters, it belongs in version control; if not, it should be deleted.

## On "best practice"

The cleaner is genuinely best-practice for what it does. The codebase overall is in the upper tier of what I'd expect from a small SwiftPM app — the concurrency story and comment discipline are well above typical.

The gap isn't code quality; it's **durability**. The safety properties are real and well-tested, but they rest on someone remembering to run `swift test` and on a reference doc that already drifted from the code once before today. CI plus a doc-consistency test would convert "carefully maintained" into "enforced."

Want me to add the CI workflow and split the cleaner into its own file? Both are contained, and neither touches deletion behaviour.