# ScaleKit Testing

ScaleKit has three kinds of evidence. Each is reported separately and never inferred from another.

| Kind | What it proves | Touches real displays? | Where results live |
|---|---|---|---|
| **Automated tests** (§1) | Logic is correct against fixtures and a fake display stack | **No** | §1.4 of this file |
| **Harness runs** (§2) | The real trial mechanism works on real hardware (`scalekit-diag trial`, `virtual`) | Yes | FEASIBILITY.md §6 (IDs D1, T1–T7) and §11 (V1–V4, probe code) |
| **Manual checklist** (§3) | What a person sees and does at the Mac: sharpness, apps, sleep, cables, reboot, app UI | Yes | §3 of this file |

## 1. Automated tests

### 1.1 Framework: Swift Testing, not XCTest

The development Mac has Command Line Tools only. XCTest ships with Xcode, and importing it fails with
`unable to resolve module dependency: 'XCTest'` (FEASIBILITY §1). Swift Testing is included in the toolchain, so the
suite uses it: `import Testing`, `@Suite`, `@Test`, `#expect`, `#require`, and parameterized tests with
`arguments:`. The test target is `ScaleKitCoreTests` (`Package.swift`). It tests `ScaleKitCore` only. There are no UI
tests (XCUITest also needs Xcode), so the app UI is covered by the manual checklist in §3. The experimental
`ScaleKitVirtual` and `ScaleKitVirtualBridge` targets are deliberately not test dependencies: they create real virtual
displays. Their pure inputs (`VirtualScalingPlan`, `VirtualScalingPreference`, `VirtualTrialLaunchPolicy`) live in
core and are tested there.

### 1.2 Running the tests

Run from the package root. The path contains a space, so quote it:

```sh
cd scalekit

swift test                                # build and run everything
swift test --filter RecommendationTests   # run one suite (regex over test identifiers)
swift test list                           # list test identifiers without running them

scripts/run-tests.sh                      # same as swift test, plus a pass/fail summary and failure list
scripts/run-tests.sh --filter ProfileMappingTests
```

`scripts/run-tests.sh` passes extra arguments through to `swift test`. It honours `SCALEKIT_SCRATCH_PATH` for the
build directory and exits with `swift test`'s status. Opening `Package.swift` in Xcode also works if Xcode is
installed later. Xcode 16 and newer run Swift Testing suites natively.

### 1.3 How the tests avoid real hardware

- **`FakeDisplayHardware`** (`Tests/ScaleKitCoreTests/Support/FakeDisplayHardware.swift`) implements the
  `DisplayHardware` protocol in memory. Tests can:
  - connect and disconnect displays;
  - change the mode "externally" (`setCurrentMode`);
  - make `applyMode` throw (`applyError`, optionally only for some scopes via `failingScopes`);
  - make the driver silently ignore requests (`ignoresApply`);
  - hide AppKit screens (`reportsScreens`, `hiddenScreens`);
  - supply IORegistry attributes;
  - observe every apply call (`applyCalls`, `onApply`) and every `restorePermanentConfiguration` call.
- **Fixtures** (`Tests/ScaleKitCoreTests/Support/Fixtures.swift`):
  - `Fixtures.asus`, `Fixtures.msi`: modelled on the two reference displays. The ASUS mode list follows FEASIBILITY
    §4. A few small 1× mode IDs are synthetic and marked so in the file.
  - `Fixtures.uhd`: a *synthetic* 27″ 4K panel whose scaled HiDPI modes carry the native flag. Whether real 4K
    panels set that flag is untested (COMPATIBILITY.md §3).
  - `Fixtures.noNativeFlag`, `Fixtures.noModes`: edge cases.
  - `Fixtures.fixedDate`, `EnvironmentInfo.testFixture`: fixed clock and environment values.
- **Pure logic can be called directly**, without the fake. Examples: `ModeValidator`, `ScalingProfileMapper`, `RecommendationEngine`,
  `RollbackPolicy`, `LaunchRecoveryPolicy`, `VerificationEvaluator`, `OutcomeAssessor`.
- **Persistence uses temporary directories** (`AppPaths(root:)` or explicit file URLs), never
  `~/Library/Application Support/ScaleKit`.
- **Rule:** no test may construct `LiveDisplayHardware` or call `ScaleKitServices.live()`.

### 1.4 Coverage by required area

The "Tests" and "Result" columns are filled from a real run of `scripts/run-tests.sh`, never estimated.

| Area | What must be covered | Code under test | Test file(s) | Tests | Result |
|---|---|---|---|---|---|
| Display mode validation | Errors that block a change (not offered, stale mode ID, not desktop-usable, no `valid` flag, `neverShow`, already active). Warnings (interlaced, refresh drop/unknown, aspect, not native, upscaled, small workspace). Dedup, sorting, native resolution | `ModeValidator`, `DisplayModeService` | `ModeValidationTests.swift` | Pending | Pending |
| Scaling target mapping | 100% Verified / 200% Available on the ASUS. 125–175% Unsupported with 21:9 alternatives only. Unclean modes never auto-selected. Verification record promotes to Verified. 4K fixture | `ScalingProfileMapper`, `ScalingProfileService` | `ProfileMappingTests.swift` | Pending | Pending |
| Profile recommendation | Weights 25/20/15/15/10/10/5 total 100. Exact breakdown. Upscaled modes never outrank clean native ones. Unverified < verified. Aspect-correct only. `meetsAllCriteria` rules | `RecommendationEngine` | `RecommendationTests.swift` | Pending | Pending |
| Refresh-rate comparison | Exact reference rate preferred, then the lowest higher rate, then the highest lower rate. 0.5 Hz tolerance (119.88 ≈ 120). Proportional scoring of drops. Reduction requires confirmation | `RefreshComparison`, `RefreshRate`, `ModeSignature`, `EvaluationContext.referenceRefresh` | `RefreshRateTests.swift`, `ProfileMappingTests.swift`, `RecommendationTests.swift`, `ModeValidationTests.swift` | Pending | Pending |
| Configuration backup | Capture and save before any change. Atomic JSON round trip. One record per display. History capped at 200. Verification records deduplicated | `ConfigurationBackupService`, `HistoryStore`, `VerificationStore`, `JSONFileStore`, `AppPaths` | `BackupTests.swift`, `RecoveryServiceTests.swift` (backup taken before any apply) | Pending | Pending |
| Rollback decisions | Every `TrialEvent` × `TrialPhase` (`RollbackPolicy`). Every `LaunchAssessment` case. Trial state machine with the fake: Keep → `.permanent`, Revert/timeout/sleep/quit → restore, abandon, supersede, journal states | `RollbackPolicy`, `LaunchRecoveryPolicy`, `RecoveryService` | `RollbackPolicyTests.swift`, `RecoveryServiceTests.swift` | Pending | Pending |
| Error handling | `applyMode` throws → previous mode restored, journal `reverted`. Verification `failed` → restored. Keep's permanent apply fails → automatic revert. Backup or journal write fails → nothing changed. Restore falls back to `restorePermanentConfiguration`. Display missing | `RecoveryService`, `DisplayConfigurationService`, `VerificationEvaluator`, `JSONFileStore` | `RecoveryServiceTests.swift`, `BackupTests.swift` (unwritable or corrupt files) | Pending | Pending |
| Unsupported configurations | No native-flagged mode (inferred native). No modes at all (Unknown / no recommendation). No AppKit screen (`partial` verification, Medium confidence). Wrong aspect ratio. Intermediate sizes on a ≈109 PPI panel | `ScalingProfileService`, `HiDPIDetection`, `OutcomeAssessor`, `RecommendationEngine`, `RecoveryService` | `ProfileMappingTests.swift`, `RecommendationTests.swift`, `ModeValidationTests.swift`, `RecoveryServiceTests.swift` (no readable current mode), <!-- RESULT: any further test file(s) for unsupported configurations --> | Pending | Pending |

Additional areas, not in the required list:

| Area | Code under test | Test file(s) | Tests | Result |
|---|---|---|---|---|
| HiDPI detection and status confidence | `HiDPIDetection`, `HiDPIDetectionService` | <!-- RESULT: test file name --> Pending | Pending | Pending |
| Apply verification levels | `VerificationEvaluator`, `DisplayConfigurationService.verify` | `RecoveryServiceTests.swift` (partial and failed paths, indirectly), <!-- RESULT: dedicated test file name, if any --> | Pending | Pending |
| Discovery, provenance and monitor identification | `DisplayDiscoveryService.makeInfo`, `match` | <!-- RESULT: test file name --> Pending | Pending | Pending |
| Diagnostics and report rendering | `OutcomeAssessor`, `DiagnosticMarkdown`, `DiagnosticsService.write` | <!-- RESULT: test file name --> Pending | Pending | Pending |
| Event decoding and injection | `DisplayChangeSet`, `DisplayEventMonitor.emit` | <!-- RESULT: test file name --> Pending | Pending | Pending |
| Experimental virtual scaling (pure parts): plan sizes for 105–195% on 21:9 and 16:9 panels, exact 2× backing, aspect, 100/200%/out-of-range/zero rejection, the 8192 px limit, sampling and GPU load, `modeInfo`, summary and trade-offs, Codable round trips, launch policy, `RecoveryService.Session` public init | `VirtualScalingPlan`, `VirtualScalingPreference`, `VirtualTrialLaunchPolicy`, `RecoveryService.Session` | `VirtualScalingTests.swift` | 30 tests in 4 suites | Pass (2026-10-10, `scripts/run-tests.sh`) |

Latest full run (2026-10-10, Command Line Tools, Swift 6.4, `scripts/run-tests.sh`): **231 tests in 31 suites
passed**, 0 failed. The per-area cells above that still read Pending have not been counted separately.

<!-- RESULT: summary line from scripts/run-tests.sh (Swift Testing "Test run with N tests in M suites passed/failed after X seconds"), date and toolchain -->
<!-- RESULT: any failing or skipped tests, with reasons -->

## 2. Hardware validation harness: `scalekit-diag`

`scalekit-diag` runs the same `ScaleKitServices` and `RecoveryService` code as the app. Its `trial` command applies a
real mode through the full trial sequence (ARCHITECTURE.md §4), so it doubles as the hardware test harness. Results of
harness runs are recorded in FEASIBILITY §6.

### 2.1 Which binary to run

Build with `swift build` and run `.build/debug/scalekit-diag`. `swift build -c release` gives
`.build/release/scalekit-diag`. The watchdog is found only next to the running executable, and SwiftPM puts
`ScaleKitGuard` in the same directory. `build/scalekit-diag` and `ScaleKit.app/Contents/Helpers/scalekit-diag`,
produced by `scripts/build-app.sh`, have **no `ScaleKitGuard` beside them**. Trials started from those copies run
without hang protection. Don't use them for `--simulate-hang`.

```sh
cd scalekit
swift build
DIAG="$PWD/.build/debug/scalekit-diag"
"$DIAG" --help
```

Files go to `~/Library/Application Support/ScaleKit` unless `SCALEKIT_SUPPORT_DIR` is set. If you set it, use the same
value for `journal` and `recover`. The app won't see harness files written elsewhere.

### 2.2 Read-only commands

These never change the display configuration.

| Command | Purpose |
|---|---|
| `displays` | Every display with provenance tags (`[M]` measured, `[I]` inferred, `[U]` unavailable), HiDPI status, active mode ID and flags, and the target-monitor match |
| `modes [--display ID] [--all]` | Desktop modes (or every reported mode with `--all`) with ID, looks-like, backing, scale, refresh, native flag and rendering path. Marks the active mode |
| `profiles [--display ID] [--refresh HZ] [--desired PERCENT]` | Profile evaluation (default reference refresh 120 Hz) and the recommendation for `--desired` (default 150%) |
| `report [--out DIR] [--no-profiler] [--refresh HZ] [--desired PERCENT]` | Full diagnostic report. Markdown to stdout, or `.md` + `.json` into `DIR` |
| `watch [--seconds N]` | Prints display events (connect, disconnect, mode, sleep, wake) for N seconds (default 30). Useful alongside the sleep and cable tests in §3 |
| `journal` | Prints the current trial journal: ID, state, PID, display, previous → target, note |
| `virtual --check [--display ID] [--refresh HZ]` | Experimental. Whether the private `CGVirtualDisplay` API is present, and the virtual-display plan (size, sampling, GPU load) for each standard size. Creates nothing |

Without `--display`, `modes` and `profiles` pick the ASUS if it is identified, otherwise the main display.
`displays` and `report` cover every display.

### 2.3 `trial`: apply a mode through the full safety sequence

```
scalekit-diag trial --display ID --mode MODE_ID [--seconds N] [--timeout N]
                    [--keep] [--accept-refresh-reduction]
                    [--simulate-hang] [--exit-without-revert]
```

| Flag | Meaning |
|---|---|
| `--display ID` | **Required.** CoreGraphics display ID from `displays` (3 = ASUS, 1 = MSI at research time; IDs can change). |
| `--mode MODE_ID` | **Required.** Mode ID from `modes --display ID`. Mode IDs can change after a reconnect, so look them up again before each session. |
| `--seconds N` | How long to hold the trial mode before reverting (or keeping). Default 5. |
| `--timeout N` | Confirmation countdown (`RecoveryService.confirmationTimeout`). Default `max(15, seconds + 10)`. If it is **shorter** than `--seconds`, the countdown expires first and the trial reverts automatically ("not confirmed in time"). This is how the timeout path is tested. |
| `--keep` | After the hold, press Keep: the mode is re-applied with `kCGConfigurePermanently` and **saved to your display preferences**. To undo, run another `--keep` trial back to the original mode ID, or use System Settings ▸ Displays. |
| `--accept-refresh-reduction` | Required when the target's refresh rate is lower than the current one. Without it the trial refuses to start and changes nothing. |
| `--simulate-hang` | After verification, blocks the main thread for 600 s. The watchdog should send `SIGTERM` at deadline + 8 s (the shell reports exit 143, or 137 if `SIGKILL` was needed). |
| `--exit-without-revert` | After the hold, exits with status 0 without reverting. macOS should restore the previous mode as the process ends. The watchdog records `revertedBySystem`. |

What `trial` prints, in order:

1. The before/after plan, with `✗` for validation errors and `!` for warnings.
2. The verification level and time.
3. The `NSScreen` scale and frame, and the `system_profiler` cross-check (limited to 6 s).
4. The journal state, deadline and **PID**. Use the PID for `kill -9` tests.
5. Events observed during the trial.
6. The outcome and the active mode afterwards.

Exit status:

| Status | Meaning |
|---|---|
| 0 | Completed (including `--exit-without-revert`) |
| 1 | Error: display or mode not found, validation failed, or the trial didn't start |
| 2 | Usage error |
| 3 | `--simulate-hang` returned, meaning the watchdog didn't act |

Limitations of the harness:

- Display events (sleep, disconnect, external mode changes) are **printed but not fed to `RecoveryService`**. Sleep
  and disconnect rollback rules can only be exercised from the app.
- `trial` always runs the `system_profiler` cross-check. The app does not use it in the apply path.

### 2.4 `recover`

`scalekit-diag recover` runs `RecoveryService.recoverAfterLaunch` (`LaunchRecoveryPolicy`) on the current journal,
exactly as the app does at launch. It **can change the display**: if an unconfirmed trial mode is still active, it
restores the previous mode with `kCGConfigurePermanently`. It prints the assessment (`previousModeActive`,
`trialModeStillActive`, `displayMissing`, `otherModeActive`) or "Nothing to recover".

### 2.5 Recipes

FEASIBILITY §6 records the test IDs, displays and mode IDs but not the exact command lines. The commands below are
equivalents, reconstructed from what each test exercises. Check with `"$DIAG" modes --display <ID>` that the mode IDs
are still the right ones before each run. After every
run, check `"$DIAG" journal` and `"$DIAG" displays`, and
`tail ~/Library/Application\ Support/ScaleKit/guard.log`.

| Purpose | Command | Recorded result |
|---|---|---|
| Revert (MSI, 100 → 60 Hz) | `"$DIAG" trial --display 1 --mode 65 --accept-refresh-reduction` | FEASIBILITY §6 T1: Pass |
| Exit without revert | The T1 command plus `--exit-without-revert` | T2: Pass |
| Crash | The T1 command plus `--seconds 60`, then `kill -9 <PID>` from a second terminal | T3: Pass |
| Hang / watchdog | The T1 command plus `--simulate-hang` | T4: Pass |
| Keep | The T1 command plus `--keep`, then a second `--keep` trial back to mode 63 (100 Hz) | T5: Pass |
| 200% HiDPI on the ASUS | `"$DIAG" trial --display 3 --mode 80` | T6: Pass, verified |
| 168% alternative on the ASUS | `"$DIAG" trial --display 3 --mode 110` | T7: Pass, behaves as predicted |
| Countdown timeout | `"$DIAG" trial --display 3 --mode 80 --seconds 30 --timeout 10` | Pending (HW-23) |
| Refresh-reduction gate | A lower-refresh mode **without** `--accept-refresh-reduction` | Pending (HW-27) |
| Rejected configuration | `--mode 119` while 119 is active, or a mode ID that doesn't exist | Pending (HW-22) |

### 2.6 `virtual`: experimental virtual-display scaling

```
scalekit-diag virtual --check [--display ID] [--refresh HZ]
scalekit-diag virtual --percent P [--display ID] [--seconds N] [--timeout N] [--refresh HZ]
                      [--simulate-hang] [--exit-without-revert]
```

`--percent` **changes the display.** It uses a private API (FEASIBILITY §11) and runs the same `VirtualScalingService`
as the app: journal (`virtual-trial.json`), watchdog, app-only mirroring, verification. It then holds for `--seconds`
(default 10) and turns the scaling off, unless the countdown (`--timeout`, default 30) runs out first. It never saves
a preference.

| Flag | Meaning |
|---|---|
| `--percent P` | 105–195. 100 and 200 are refused (use `trial` with a native mode). |
| `--display ID` | Defaults to the ASUS if identified, otherwise the main display. ScaleKit's own virtual displays are skipped. |
| `--refresh HZ` | Refresh rate for the virtual mode. Default: the monitor's current rate. |
| `--simulate-hang` | Blocks the main thread for 600 s after verification. The watchdog should end the process at deadline + 8 s, and macOS should then remove the virtual display. |
| `--exit-without-revert` | Exits after the hold without turning the scaling off. macOS should remove the virtual display as the process ends. |

It prints the plan and trade-offs, the verification (mirroring, the virtual display's mode, `NSScreen` scale and size,
the monitor's mode while mirrored), the deadline and PID, and afterwards the monitor's mode. Exit status 0 means the
monitor came back in its previous mode, 1 means it didn't or the scaling didn't start, 3 means `--simulate-hang`
returned. Sleep, wake and disconnect events **are** routed to the service, unlike `trial`.

Before every run note the monitor's mode (`displays`). If anything looks wrong, quit the process (Ctrl-C) or
`kill -9` it; macOS removes the virtual display when the process ends (FEASIBILITY §11, V4).

## 3. Manual hardware test checklist

> **Results recorded here are physical tests on the hardware listed; automated results are reported separately.**

How to record a test:

- **Result:** Pass, Fail or Partial, with a one-line note.
- **Date:** when the test was run.
- **Environment:** an ID from the table below.

Attach photos, `scalekit-diag report --out` output or log excerpts where a test asks for them. A row stays
**Pending** until a person has run it exactly as written. "App" means the ScaleKit app built with
`scripts/build-app.sh`. "CLI" means `.build/debug/scalekit-diag` (§2.1).

| Env ID | Mac | macOS | Displays and connection |
|---|---|---|---|
| E1 | Mac mini `Mac16,10`, Apple M4, 16 GB | 27.0 (`26A428`) | ASUS VG34WQML5A (CG display 3, main) via HDMI. MSI MP223 (CG display 1) via HDMI |

### 3.0 Harness results already recorded (FEASIBILITY §6)

These ran through the CLI on E1 on 2026-10-09. They are listed here so the checklist doesn't repeat them by accident.
The checklist rows they relate to stay Pending, because each row asks for something the harness run didn't cover (the
app, the ASUS rather than the MSI, or a person's observation).

| §6 ID | What was shown | Display | Related rows |
|---|---|---|---|
| D1 | Diagnostics identify the ASUS with high confidence. All values carry provenance | Both | HW-01, HW-05 |
| T1 | App-only trial → verify (≈ 1.2 s) → Revert | MSI | HW-02 |
| T2 | Exit without revert → macOS restored, `revertedBySystem` | MSI | HW-18 |
| T3 | `kill -9` during trial → macOS restored | MSI | HW-18, HW-19 |
| T4 | Hang → watchdog `SIGTERM` 8 s after the deadline → `revertedByGuard` | MSI | HW-20 |
| T5 | Keep → persisted after process exit | MSI | HW-24 |
| T5a | Unplanned stall, recovered by the watchdog. Root cause not confirmed | MSI | HW-20 |
| T6 | 1720 × 720 HiDPI @ 120 Hz verified (3440 × 1440 backing, scale 2.0). Revert restored 3440 × 1440 @ 120 Hz | ASUS | HW-02, HW-05 |
| T7 | 2048 × 858 @ 120 Hz: 1×, no native flag, output unavailable. Reverted cleanly | ASUS | HW-03 |

### 3.1 Display modes and output

| ID | Test | Steps | Expected | Result | Date | Environment |
|---|---|---|---|---|---|---|
| HW-01 | Baseline: 3440 × 1440 @ 120 Hz (100%) | 1. Set 3440 × 1440 @ 120 Hz in System Settings if needed.<br>2. `"$DIAG" displays` and `"$DIAG" profiles --display 3`.<br>3. Open the app's main window. | Mode ID 119, flags include `native`, 1×, 120 Hz `[M]`. Physical output 3440 × 1440 `[I]`. 100% shows **Verified (current)**. App shows the same values as the CLI | Pending | — | — |
| HW-02 | 200% HiDPI (1720 × 720 HiDPI @ 120 Hz) from the **app** | 1. In the app, start a trial of the 200% profile.<br>2. Read the before/after summary, then confirm.<br>3. During the countdown, check the desktop.<br>4. Press **Revert**. Repeat and let it reach **Keep**, then switch back to 100% the same way. | Summary shows 200%, rendered at 3440 × 1440, native output, HiDPI text, 120 Hz, 21:9, workspace warning. Verification `verified`. Revert restores 3440 × 1440 @ 120 Hz. History lists each step | Pending | — | — |
| HW-03 | Lower-resolution alternatives: 168% (2048 × 858) and 179% (1920 × 804) | 1. `"$DIAG" modes --display 3` to find the IDs.<br>2. `"$DIAG" trial --display 3 --mode <ID> --seconds 15` for each.<br>3. Optionally repeat from the app, where they appear only as alternatives. | Warnings: not native, upscaled (softer text), small workspace. 1×, no native flag, physical output `[U]`. Never selected automatically by a profile. Reverts cleanly | Pending | — | — |
| HW-04 | Native output preserved, confirmed on the **monitor OSD** | 1. At 100%, open the monitor's OSD Information page and photograph the input signal line.<br>2. Start a 200% trial (app or `trial --display 3 --mode 80 --seconds 60`) and photograph the OSD again.<br>3. Repeat with the 168% mode. | 100% and 200%: OSD reports 3440 × 1440 @ 120 Hz input. 168%: record what the OSD shows. ScaleKit reports it as unavailable, and this is the only way to learn it | Pending | — | — |
| HW-05 | HiDPI status: CoreGraphics and `NSScreen` agree | 1. At 100%: `"$DIAG" displays` → HiDPI line.<br>2. During a 200% trial: read the trial output (`NSScreen.backingScaleFactor`, frame) and the app's HiDPI indicator. | 100%: "Not HiDPI (1×)", confidence High. 200%: "HiDPI (2×)", confidence High. `backingScaleFactor` 2.0, frame 1720 × 720 | Pending | — | — |
| HW-06 | 16:9 mode on the 21:9 panel (for example 2560 × 1440, or 1920 × 1080 HiDPI) | 1. `"$DIAG" trial --display 3 --mode <16:9 ID> --seconds 15`.<br>2. Observe the panel. | Validator warns "16:9 mode on a 21:9 panel: expect black bars or stretching". Record whether the monitor pillarboxes or stretches. Reverts cleanly | Pending | — | — |

### 3.2 Visual quality and applications (200% HiDPI kept, then restored)

| ID | Test | Steps | Expected | Result | Date | Environment |
|---|---|---|---|---|---|---|
| HW-07 | Readability | 1. Keep 200%.<br>2. From normal seating distance, read body text in Finder, a browser, and the editor.<br>3. Compare with 100%. | Text and controls clearly larger. Record the subjective size relative to 100% and any element that remains too small | Pending | — | — |
| HW-08 | Text sharpness (side-by-side photos, close inspection) | 1. Open the same document at 100%, 200% HiDPI and 168% (trial is enough for 168%).<br>2. Photograph the same paragraph close up with the same camera settings.<br>3. Inspect glyph edges. | 200% HiDPI at least as crisp as 100% (2× glyphs on native pixels). 168% visibly softer (rescaled). Photos attached | Pending | — | — |
| HW-09 | Finder and menu bar | At 200%: menu bar, Control Center, Finder windows, sidebar, Desktop icons, Dock, Mission Control, screenshots (⇧⌘4). | All scale together (system-wide mode, not app zoom). No clipped menu bar items. Screenshots are 2× (3440 × 1440 px for a full-screen capture). Record any issue | Pending | — | — |
| HW-10 | Browser behaviour | At 200%: Safari and Chrome on text-heavy pages, video, a page zoomed with ⌘+. | Pages render with HiDPI text and images. Browser zoom still works on top. Video plays smoothly at 120 Hz. Record any layout that no longer fits 1720 pt width | Pending | — | — |
| HW-11 | VS Code behaviour | At 200%: VS Code editor, terminal, minimap, a split view. Check `window.zoomLevel` is 0. | Crisp text without changing VS Code zoom. Record whether the workspace (1720 × 720 pt) is usable for the user's layout | Pending | — | — |

### 3.3 Sleep, wake, connect and disconnect

| ID | Test | Steps | Expected | Result | Date | Environment |
|---|---|---|---|---|---|---|
| HW-12 | Sleep/wake **outside** a trial | 1. Run `"$DIAG" watch --seconds 120` in a terminal (or keep the app open).<br>2. Sleep the Mac (Apple menu ▸ Sleep), wait 30 s, wake. | Events logged (system will sleep, did wake, display reconfigure). Mode unchanged after wake. No journal or history entries created | Pending | — | — |
| HW-13 | Display-only sleep **during** a trial (app) | 1. Start a 200% trial in the app.<br>2. Within the countdown, put the displays to sleep only (hot corner or `pmset displaysleepnow`).<br>3. Wake after 30 s. | Core has no rollback rule for display sleep. Expected: the countdown keeps running and the trial reverts on timeout. Record what the app actually does | Pending | — | — |
| HW-14 | System sleep **during** a trial (app) | 1. Start a 200% trial in the app.<br>2. Within the countdown, Apple menu ▸ Sleep.<br>3. Wake. | `systemWillSleep` → Revert. After wake: 3440 × 1440 @ 120 Hz, journal `reverted`, history "Automatically reverted … went to sleep". Record whether the revert completed before sleep or after wake | Pending | — | — |
| HW-15 | Disconnect/reconnect **outside** a trial | 1. With the app open (or `watch`), unplug the ASUS HDMI cable.<br>2. Wait 10 s, reconnect. | Removal and addition events. The app updates its display list. After reconnect: same mode, same display UUID. The CG display ID may change (record it). No journal changes | Pending | — | — |
| HW-16 | Disconnect **during** a trial (app) | 1. Start a 200% trial in the app.<br>2. Unplug the ASUS during the countdown.<br>3. Reconnect after 10 s. Quit and relaunch the app if it doesn't reconcile on reconnect. | Trial **abandoned** (journal `abandoned`, history "Abandoned (display disconnected)"). On reconnect or relaunch, launch recovery restores or confirms 3440 × 1440 @ 120 Hz. Record the mode the monitor came back in | Pending | — | — |

### 3.4 Lifecycle, crash, hang and recovery

| ID | Test | Steps | Expected | Result | Date | Environment |
|---|---|---|---|---|---|---|
| HW-17 | Application restart (no pending trial) | 1. Quit the app normally with no trial running.<br>2. Relaunch. | No recovery message. Mode unchanged. `journal` state unchanged from the last resolved trial | Pending | — | — |
| HW-18 | Crash during a trial: **app** | 1. Start a 200% trial in the app.<br>2. `kill -9 $(pgrep -x ScaleKit)` during the countdown.<br>3. Relaunch the app. | 3440 × 1440 @ 120 Hz restored immediately by macOS. `guard.log` shows the parent exit. Journal `revertedBySystem`. On relaunch, no further action or a "was undone by macOS" message | Pending | — | — |
| HW-19 | Crash during a trial: **CLI on the ASUS** | `"$DIAG" trial --display 3 --mode 80 --seconds 60`, then `kill -9 <PID>` from another terminal. | As T3, but on the ASUS: 3440 × 1440 @ 120 Hz active right after exit 137. Journal `revertedBySystem` | Pending | — | — |
| HW-20 | Hang during a trial (watchdog) **on the ASUS** | `"$DIAG" trial --display 3 --mode 80 --simulate-hang` | About 23 s after verification (15 s countdown + 8 s grace), `guard.log` shows `SIGTERM`. Shell exit 143 (or 137). 3440 × 1440 @ 120 Hz active. Journal `revertedByGuard` | Pending | — | — |
| HW-21 | Launch recovery without the watchdog | 1. `"$DIAG" trial --display 3 --mode 80 --seconds 60`.<br>2. `kill -9` the guard (`pgrep -x ScaleKitGuard`), then the CLI.<br>3. `"$DIAG" journal`, then `"$DIAG" recover`. | After step 2 the journal is still `pending` and macOS has restored 100%. `recover` reports `previousModeActive`, journal → `revertedBySystem`, history "Recovered after restart" | Pending | — | — |
| HW-22 | Failed or rejected configuration | 1. `"$DIAG" trial --display 3 --mode 119` while 119 is active.<br>2. `"$DIAG" trial --display 3 --mode 99999`.<br>3. In the app, try to apply the profile that is already active. | 1: `✗ … is already active`, "Validation failed; nothing was changed", exit 1. 2: "does not offer mode", exit 1. 3: refused with a clear message. Display never changes, no journal written. (Apply-failure and verification-failure restore paths can't be provoked safely on hardware. They are covered by automated tests, §1.4.) | Pending | — | — |
| HW-23 | Countdown timeout → automatic revert | 1. App: start a 200% trial and press nothing.<br>2. CLI: `"$DIAG" trial --display 3 --mode 80 --seconds 30 --timeout 10`. | Reverts at the deadline: 3440 × 1440 @ 120 Hz, journal `reverted`, history "Automatically reverted", CLI prints "REVERTED — The change was not confirmed in time." | Pending | — | — |

### 3.5 Persistence after Keep

| ID | Test | Steps | Expected | Result | Date | Environment |
|---|---|---|---|---|---|---|
| HW-24 | Keep persists after **quit** | 1. In the app, apply 200% and press **Keep**.<br>2. Quit the app.<br>3. `"$DIAG" displays`. | 1720 × 720 HiDPI @ 120 Hz still active after quit. Journal `kept` | Pending | — | — |
| HW-25 | Keep persists after **logout** | Continue from HW-24: log out and back in. | 200% HiDPI @ 120 Hz active at login | Pending | — | — |
| HW-26 | Keep persists after **reboot** | Continue from HW-25: restart the Mac. Afterwards restore 100% with the app (trial + Keep). | 200% HiDPI @ 120 Hz active after reboot. The return to 100% also persists | Pending | — | — |

### 3.6 Safety behaviour and UI

| ID | Test | Steps | Expected | Result | Date | Environment |
|---|---|---|---|---|---|---|
| HW-27 | Refresh-reduction confirmation gate | 1. App: choose a mode below 120 Hz (for example 1720 × 720 HiDPI @ 60 Hz) and try to apply.<br>2. CLI: `"$DIAG" trial --display 3 --mode <60 Hz ID>` without `--accept-refresh-reduction`, then with it. | The app requires an explicit acknowledgement naming "120 Hz → 60 Hz" before anything changes. CLI without the flag: "Drops from 120 Hz to 60 Hz. Confirm the refresh-rate reduction to continue.", trial not started, display unchanged. With the flag: the trial runs | Pending | — | — |
| HW-28 | Countdown visible on **every** screen, even with the main window hidden | 1. Start a 200% trial from the app.<br>2. During the countdown, close the main window (⌘W) or hide the app (⌘H).<br>3. Repeat with a full-screen app in front.<br>4. Check both the ASUS and the MSI each time. | A countdown with Keep and Revert appears on every connected screen, above other windows, and stays readable at the new scale. Revert works from either screen | Pending | — | — |
| HW-29 | Mode changed elsewhere during a trial (app) | 1. Start a 200% trial in the app.<br>2. During the countdown, choose a different resolution in System Settings ▸ Displays. | Trial **superseded**. ScaleKit stops and doesn't touch the display. Journal `superseded`. The System Settings choice remains | Pending | — | — |

### 3.7 Experimental virtual-display scaling (125/150/175%)

None of these has been run with the shipped code. FEASIBILITY §11.2 lists the probe measurements V1–V4 that preceded
them. Before starting: `"$DIAG" displays` shows 3440 × 1440 @ 120 Hz on the ASUS, and `"$DIAG" virtual --check`
reports the API as available and lists 2752 × 1152, 2293 × 960 and 1966 × 823 pt plans.

| ID | Test | Steps | Expected | Result | Date | Environment |
|---|---|---|---|---|---|---|
| HW-30 | 125% applies | `"$DIAG" virtual --percent 125 --seconds 20` | Verification VERIFIED. Mirroring active. Virtual display 2752 × 1152 pt, 5504 × 2304 px, 120 Hz. Desktop visibly larger than 100%. Exit 0, ASUS back at 3440 × 1440 @ 120 Hz | Pending | — | — |
| HW-31 | 150% applies | As HW-30 with `--percent 150` | Virtual display 2293 × 960 pt, 4586 × 1920 px. Otherwise as HW-30. (Probes used 2294 × 960; record any problem with the odd width) | Pending | — | — |
| HW-32 | 175% applies | As HW-30 with `--percent 175` | Virtual display 1966 × 823 pt, 3932 × 1646 px. Otherwise as HW-30 | Pending | — | — |
| HW-33 | HiDPI really 2×, not the 1× mode | During each of HW-30–32: read "NSScreen scale / size" in the output; take a full-screen screenshot (⇧⌘3) and check its pixel size with `sips -g pixelWidth -g pixelHeight` | Scale 2.0, size equal to the planned points. Screenshot pixels equal the planned backing size. A 1× result (as in V3: 4588 × 1920 pt) is a **Fail** | Pending | — | — |
| HW-34 | Physical output stays 120 Hz | During HW-31: read "Monitor mode while mirrored"; run `system_profiler SPDisplaysDataType`; open the monitor OSD Information page | CLI and `system_profiler` show the VG34WQML5A at 120 Hz. OSD shows 3440 × 1440 @ 120 Hz input. Photograph the OSD | Pending | — | — |
| HW-35 | Text sharpness (visual) | Same paragraph in Finder, a browser and the editor at 100%, 200% HiDPI and 150% virtual. Photograph close up with the same camera settings | 150% virtual visibly sharper than the 168% 1× alternative (HW-08) and close to 200%. Record any shimmer, blur or colour fringing | Pending | — | — |
| HW-36 | Keep → re-applied at next launch (app) | 1. In the app, choose 150% and start the virtual trial. 2. Press **Keep**. 3. Quit and relaunch the app. | After Keep: `virtual-scaling.json` exists, `virtual-trial.json` state `kept`. On quit: ASUS returns to 3440 × 1440. On relaunch: 150% is re-applied without a new countdown. Record what the app shows | Pending | — | — |
| HW-37 | Quit, crash and `kill -9` remove it | 1. App with 150% active: quit normally. 2. Relaunch (re-applies), then `kill -9 $(pgrep -x ScaleKit)`. 3. CLI: `"$DIAG" virtual --percent 150 --seconds 60`, then `kill -9 <PID>`. 4. CLI: `--exit-without-revert`. | Each time the ASUS is back at 3440 × 1440 @ 120 Hz within a few seconds, with no virtual display left in System Settings ▸ Displays and windows still on screen. Journal of a pending trial ends `revertedBySystem` | Pending | — | — |
| HW-38 | Watchdog on hang | `"$DIAG" virtual --percent 150 --simulate-hang --timeout 15` | About 23 s after verification `guard.log` shows `SIGTERM`, the shell reports exit 143 (or 137), the ASUS is back at 3440 × 1440 @ 120 Hz, journal `revertedByGuard` | Pending | — | — |
| HW-39 | Disconnect during scaling | 1. App with 150% active (kept). 2. Unplug the ASUS HDMI cable, wait 10 s, reconnect. | Scaling turns off ("was disconnected"). No invisible virtual display holding windows. After reconnect the ASUS is at its saved mode. The preference is kept. Record whether the app re-applies it | Pending | — | — |
| HW-40 | Sleep/wake | 1. App with 150% kept: sleep the Mac 30 s, wake. 2. Start a 150% trial and sleep before confirming. | 1: still 150% after wake, mirroring re-established if macOS dropped it; record any window movement. 2: the trial is turned off before or at sleep; after wake the ASUS is at 3440 × 1440 | Pending | — | — |
| HW-41 | Second monitor unaffected; turn-off restores | 1. With 150% active on the ASUS, check the MSI's mode, position and windows (`"$DIAG" displays`). 2. Turn the scaling off in the app. | 1: MSI stays 1920 × 1080 @ 100 Hz at the same position, its windows stay put. 2: ASUS back at 3440 × 1440 @ 120 Hz, 1×, no mirroring, `virtual-scaling.json` deleted, history records the turn-off | Pending | — | — |

<!-- RESULT: overall summary of the manual checklist (counts of Pass / Fail / Partial / Pending) once rows are filled in -->
<!-- RESULT: links or filenames of attached photos (HW-04, HW-08) and diagnostic reports -->
