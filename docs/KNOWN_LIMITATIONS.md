# ScaleKit Known Limitations

This page lists what ScaleKit cannot do, what it infers rather than measures, and what has not been tested. Measured
facts and hardware results come from [FEASIBILITY.md](FEASIBILITY.md). Hardware tests are cited by their §6 IDs
(D1, T1–T7). Behaviour comes from the source code. Checks that need a person at the Mac are still pending
(TESTING.md §3). §12 collects what hardware validation has turned up so far. §13 covers the experimental
virtual-display scaling, the only feature that uses a private API.

## 1. No intermediate sharp scaling on the reference monitor

On the ASUS VG34WQML5A (3440 × 1440, ≈ 109 PPI), **125%, 150% and 175% with HiDPI-sharp text at native output can't be
achieved through public APIs.**

- Public CoreGraphics APIs can only select modes that macOS already generates. They can't create modes.
- macOS offers exactly one HiDPI mode with this panel's shape and native output: **1720 × 720 HiDPI** (backing
  3440 × 1440), which is 200%. It was applied and verified at 120 Hz on this hardware (T6).
- macOS offers no "scaled" HiDPI modes for this monitor (a backing store larger than the panel, downsampled, such as
  2752 × 1152 pt → 5504 × 2304 px for 125%). Apple generates those only for displays it classifies as high density,
  and this panel doesn't qualify (FEASIBILITY §5).
- The closest 21:9 sizes, 2048 × 858 (≈ 168%) and 1920 × 804 (≈ 179%), are 1× modes **without** the native flag. They
  are rendered at lower resolution and enlarged, so text is softer. ScaleKit lists them only as explicit, labelled
  alternatives and never selects them automatically.

The only ways to get those sizes sharply are the private or unsupported approaches in §9. ScaleKit offers one of them,
a virtual HiDPI display with mirroring, as an **opt-in experimental mode** that uses a private API and works only while
ScaleKit runs (§13). In the profile list those sizes stay **Unsupported**, because no clean native mode exists.

## 2. Physical output timing isn't exposed

No public API reports the signal timing on the cable.

- For native-flagged modes, ScaleKit reports physical output as ***inferred*** from `kDisplayModeNativeFlag`. The flag
  is the display driver's statement, not a measurement of the link. The hardware checklist asks the tester to confirm
  the input signal on the monitor's on-screen display (OSD).
- For modes without the native flag, physical output is ***unavailable***. macOS doesn't report whether the Mac's GPU
  or the monitor's scaler enlarges the image (FEASIBILITY §5).
- `system_profiler` doesn't fill the gap. For the 2048 × 858 mode it reported `pixels 2048 x 858`, which is the render
  size, not the HDMI timing (T7). For the 200% mode it reported the 3440 × 1440 backing size (T6).

## 3. The 200% workspace is small

1720 × 720 points is a quarter of the native desktop area, smaller than a 13″ MacBook Air (FEASIBILITY §7). Windows
and dialogs designed for larger screens may need resizing. `ModeValidator` warns about this before the change
("Workspace shrinks to 25% of the native desktop area").

## 4. Trial semantics

Trials are applied with `kCGConfigureForAppOnly`. The SDK documents that WindowServer reverts such a change when the
process that made it terminates.

| Situation while a trial is pending | What happens |
|---|---|
| ScaleKit quits normally | `applicationWillTerminate` → `RecoveryService.prepareForTermination()` records `revertedBySystem`. WindowServer reverts the mode as the process exits. The CLI equivalent (exit without reverting) passed on hardware (T2). |
| ScaleKit crashes or is force-quit | WindowServer reverts. The watchdog (or the next launch) records the outcome. `kill -9` during a CLI trial passed on hardware (T3). |
| Logout, restart or shutdown | ScaleKit is terminated with the session, so the app-only change ends with it. Recorded as above. |
| System sleep | `RollbackPolicy` maps `systemWillSleep` to a revert. Whether the revert finishes before the system sleeps hasn't been tested on hardware. |
| Display sleep only (`screensDidSleep`) | Core has no rollback event for this. Unless the front end maps it, the countdown keeps running and the trial times out and reverts while the screens are dark. |
| Target display disconnected | The trial is **abandoned** (nothing to restore). It is reconciled at the next launch or reconnect. |
| Mode changed by another app or System Settings | The trial is **superseded**. ScaleKit stops without touching the display. |

The **Keep** step writes the mode with `kCGConfigurePermanently`, which saves it to the user's display preferences.
`kCGConfigureForSession` is not used. A kept mode persisted after the process exited (T5, MSI display). Persistence
across logout and reboot is pending (TESTING.md).

## 5. Watchdog (`ScaleKitGuard`) limits

- **It can't help if WindowServer itself is wedged.** Both the app-only revert and
  `CGRestorePermanentDisplayConfiguration` are carried out by WindowServer.
- **It depends on the journal file.** The guard exits as soon as `trial.json` is missing, unreadable, or belongs to a
  different trial. A trial won't start if the journal can't be written, but if the file is deleted or corrupted during
  a trial, hang protection is lost.
- **It must sit next to the executable.** `ProcessGuardLauncher.locate()` only looks in the running executable's
  directory. That covers `.build/<config>/` and the app's `Contents/MacOS/`, but not `build/scalekit-diag` or
  `Contents/Helpers/scalekit-diag`. Without it, trials run with a logged notice and no hang protection.
- **It waits.** It acts only after deadline + grace (15 s + 8 s by default), so a hung app leaves the trial mode on
  screen for about 23 s plus up to 2 s for `SIGTERM` → `SIGKILL`. On hardware it sent `SIGTERM` 8 s after the
  deadline (T4). In the unplanned stall T5a it acted 33 s after the trial started (provisional deadline + grace).
- **It stops after 15 minutes.** A trial with a confirmation timeout longer than about 15 minutes (possible with
  `scalekit-diag trial --timeout`) outlives its watchdog.
- **It is an ordinary user process.** If the user or another tool kills it, the hang case falls back to the user
  force-quitting ScaleKit. The crash case is still covered by WindowServer.
- **It terminates ScaleKit abruptly** (`SIGTERM`, then `SIGKILL`). The app gets no chance to run its own cleanup, so
  the guard updates the journal itself.

## 6. Undocumented sources

| Source | Used for | Risk |
|---|---|---|
| IORegistry `IOMobileFramebuffer` → `DisplayAttributes` (`ProductAttributes`, `MaximumRefreshRate`, `MinimumRefreshRate`, `SupportsVariableRefreshRate`, `SupportsPQEOTF`) and `Transport` (`Upstream`, `Downstream`) | Connection type, EDID refresh range, VRR and HDR flags, registry product name | Keys can change or disappear in any macOS release. The `IOMobileFramebuffer` class is expected to be absent on Intel Macs (untested) |
| `system_profiler SPDisplaysDataType -json` (`spdisplays_ndrvs`, `_spdisplays_displayID`, `_spdisplays_pixels`, `_spdisplays_resolution`) | A secondary cross-check after applying a mode, and in reports | Output format is undocumented |

The experimental virtual-display scaling also uses a **private** API, `CGVirtualDisplay` (§13). It is not a data
source: it creates the virtual display and nothing else.

Everything from these sources is labelled ***inferred*** and is never the only evidence for a decision. Verification
uses CoreGraphics and AppKit only. The IORegistry also contains an EDID "native format" of 1920 × 1080 for this
monitor, which contradicts its mode list. ScaleKit ignores that key (FEASIBILITY §1). IORegistry serial numbers are
deliberately not read.

## 7. Engine and persistence behaviour

- **Higher refresh rates score the same as the reference rate.** A higher rate earns full refresh points. Equal scores
  are resolved in favour of the exact reference rate (ARCHITECTURE.md §3.4), so the recommendation keeps 120 Hz when
  120 Hz is offered. The score itself does not penalise extra refresh, so the score breakdown of a 250 Hz variant also
  shows 15/15.
- **Verification records are not invalidated.** A `VerificationRecord` is keyed only by display UUID and mode
  signature. It stores the macOS version and Mac model for reference, but a record made before a macOS update, or over
  a different cable, still marks the mode **Verified**.
- **Backups are one level deep.** `backups.json` holds only the mode before the *most recent* ScaleKit change for each
  display. It is not an archive of the original configuration. `history.json` keeps only the newest 200 entries.
- **Restoring falls back to saved preferences.** If the previous mode can no longer be found by signature or applied,
  ScaleKit calls `CGRestorePermanentDisplayConfiguration`. That restores the user's saved display preferences, which
  may differ from the pre-trial mode if that mode was itself temporary.
- **Identical monitors.** IORegistry attributes are matched to displays by vendor and product ID. With two identical
  monitors, both may show the first entry's inferred connection and refresh range. Pass `--display ID` explicitly to
  the CLI.
- **Display IDs and mode IDs aren't stable.** `CGDirectDisplayID` and mode IDs can change when a display reconnects.
  Stored records use the display UUID and mode signature instead. Re-run `scalekit-diag modes` before each manual
  trial.
- **`guard.log` is never rotated.** It grows by a few lines per trial.

## 8. Tooling and distribution

- **No Xcode project file.** ScaleKit is a Swift Package. To use Xcode, open `Package.swift` (File ▸ Open). From the
  command line:
  - `swift build` / `swift test` build and test the package;
  - `scripts/build-app.sh` assembles `build/ScaleKit.app`;
  - `swift run ScaleKit` runs the executable unbundled, without the `Info.plist`, icon or bundle identifier.
- **Swift Testing instead of XCTest.** XCTest ships only with Xcode, which isn't installed (FEASIBILITY §1), so the
  tests use Swift Testing (`import Testing`). There are no XCUITest UI tests. The SwiftUI app is validated with the
  manual checklist in TESTING.md.
- **Ad-hoc signing only.**
  - `scripts/build-app.sh` signs ad hoc (`codesign --sign -`, hardened runtime, no timestamp). This is enough on the
    Mac that built it.
  - A copy moved to another Mac (zip, AirDrop, download) is quarantined and blocked by Gatekeeper until the user
    allows it in **System Settings ▸ Privacy & Security**. Since macOS 15 the Control-click ▸ Open shortcut no longer
    bypasses this.
  - Warning-free distribution requires a Developer ID Application certificate and notarization (`notarytool`). Both
    need a paid Apple Developer Program membership. Neither has been done.

## 9. Experimental and excluded approaches

These are the only known routes to arbitrary HiDPI sizes on this monitor (FEASIBILITY §8). Only the first is
implemented, and only as an opt-in experiment.

| Approach | Status |
|---|---|
| Virtual HiDPI display (`CGVirtualDisplay`) + mirroring | **Experimental, opt-in** (§13, FEASIBILITY §11). Private API, absent from SDK headers, can break on any macOS update. Mirroring can drop HDR and VRR, adds a GPU composition pass, and the virtual display disappears when the process exits |
| Display override plist (`/Library/Displays/Contents/Resources/Overrides/…`, `scale-resolutions`) | Excluded. Needs administrator write access to `/Library`. Undocumented format. Behaviour on Apple silicon not verified |
| EDID or timing injection (private SkyLight / IOAVService calls) | Excluded. Private, risky, can blank the display |
| Global UI injection, forced window resizing, accessibility tricks | Excluded. Not real scaling. Out of scope |

`ScalingProfileMapper` never assigns `SupportStatus.experimental`: a size without a clean mode stays Unsupported, and
the virtual-display option is offered next to it rather than changing its status.

## 10. Not system scaling: app zoom guidance and the preview

- **App zoom guidance is per-app only.** `AppZoomGuide` lists text and zoom settings for VS Code, Safari, Chrome,
  Firefox, Terminal, iTerm2 and Finder, plus the macOS Text Size setting. Each tip enlarges content inside that app
  only, never the menu bar, Finder (except Finder's own view options) or other apps. The steps are static text, and
  menu paths can change when those apps update.
- **The scaling preview is illustrative.** It is drawn inside ScaleKit's own window (FEASIBILITY §9). It can't
  reproduce what the panel will actually show: physical size, HiDPI glyph rendering, or the softness of upscaled modes.
  Judge sharpness with a real trial, which reverts automatically.

## 11. Untested scenarios

Unless a result is recorded in FEASIBILITY §6 or in the TESTING.md checklist, the following have **not** been tested:

- Any macOS version other than 27.0 (the deployment target is 14.0).
- Intel Macs, and Apple silicon Macs other than the M4 Mac mini.
- Built-in displays, 4K/5K and other high-density external displays, other ultrawides.
- DisplayPort, USB-C/Thunderbolt, adapters, docks, KVM switches, DisplayLink, AirPlay, Sidecar.
- Mirrored displays, two identical monitors, and arrangement changes during a trial.
- HDR on vs off, and VRR behaviour after a mode change.
- Fast user switching and multiple logged-in users during a trial.
- Other display utilities (for example BetterDisplay or SwitchResX) running at the same time.
- Clamshell mode and FileVault or login-window display states.
- Sleep, wake, disconnect and reconnect during a trial started from the **CLI**. `scalekit-diag trial` prints these
  events but doesn't route them to `RecoveryService`, so only the app exercises those rollback rules.
- Most of the experimental virtual-display scaling (§13).
- Every scenario in the TESTING.md hardware checklist, until its Result column is filled in.

## 12. Discovered during hardware validation

From FEASIBILITY §6 (2026-10-09, Mac mini M4, macOS 27.0, `scalekit-diag` 0.1.0 debug build):

- **Unexplained stall (T5a).** One Keep run stopped responding after the trial started, before printing verification
  output. The watchdog terminated it and 100 Hz was active afterwards. The root cause was **not confirmed**, because
  the info-level logs weren't persisted. The most likely candidate was the `system_profiler` cross-check, which had no
  timeout. Since then:
  - the probe is limited to 6 s;
  - the app doesn't use the probe in the apply path;
  - the apply steps log at notice level, which is persisted.

  The stall did not recur in the 5 trials run after the fix, which is too few to rule it out.
- **Mechanism tests used the secondary display.** T1–T5 (revert, exit, `kill -9`, hang, Keep) changed only the MSI
  display's refresh rate (100 → 60 Hz). On the ASUS, apply → verify → revert was exercised for the 200% HiDPI mode
  (T6) and the 168% mode (T7). Crash, hang and Keep were not repeated on the ASUS.
- **Native output is still inferred.** The 200% mode carries the native flag and a 3440 × 1440 backing (T6). The HDMI
  signal timing has not been confirmed on the monitor's OSD.

Still to be recorded from the manual checklist:

<!-- RESULT: native input signal shown on the monitor OSD at 100% and at 200% HiDPI (TESTING.md HW-04) -->
<!-- RESULT: anything observed about revert timing during system sleep (TESTING.md HW-14) -->
<!-- RESULT: behaviour on cable disconnect / reconnect during a trial (TESTING.md HW-16) -->
<!-- RESULT: Keep persistence across logout and reboot (TESTING.md HW-25, HW-26) -->
<!-- RESULT: any other limitation, surprise or deviation found during manual testing (one bullet each, with the test ID) -->

## 13. Experimental virtual-display scaling

ScaleKit can produce 105–195% (in practice 125%, 150% and 175%) on monitors that have no clean native mode for those
sizes, by mirroring the monitor to a HiDPI virtual display (FEASIBILITY §11). Limits:

- **Private API.** The virtual display comes from CoreGraphics' private `CGVirtualDisplay` classes, used only in
  `Sources/ScaleKitVirtualBridge`. If a macOS update removes a class or selector, ScaleKit shows the feature as
  unavailable. If Apple changes the behaviour behind an unchanged selector, ScaleKit can't detect it in advance.
- **Only while ScaleKit runs.** The change is made with `kCGConfigureForAppOnly` and the virtual display belongs to
  ScaleKit's process. Quitting ScaleKit, a crash, or the watchdog ending a hung ScaleKit returns the monitor to its
  normal mode. **Keep** only saves a preference (`virtual-scaling.json`) that is re-applied when ScaleKit starts again;
  until then the monitor runs at its saved mode.
- **Mirroring side effects.** HDR, variable refresh rate, color profiles and screen recording of the physical monitor
  can behave differently. The virtual display is listed in System Settings ▸ Displays while it exists.
- **GPU work.** The desktop is rendered at 1.3–2.6× the native pixel count on the reference monitor, then scaled.
- **Sleep and reconfiguration.** After wake ScaleKit re-establishes mirroring if macOS dropped it. Whether macOS drops
  it, and whether windows move, is untested.
- **System sleep during a trial** turns the trial off, as with ordinary trials. A kept setting stays on.
- **Not saved per display mode.** The preference stores the display and the percentage. The plan is recomputed at
  launch from the monitor's native resolution and current refresh rate.
- **Backing-store limit.** Plans wider or taller than 8192 px are refused, so on a very large panel only sizes near
  200% are possible (for example 7680 × 4320 allows 188% and above).

What has and hasn't been measured (FEASIBILITY §11.2–11.3):

- **Measured (probe code, E1):** the private classes exist on macOS 27.0 (V1); a HiDPI virtual display at 2752 × 1152,
  2294 × 960 and 1966 × 822 pt offers 2× modes at 120 Hz (V2); mirroring the ASUS to it succeeds and
  `system_profiler` reports the ASUS at 120.00 Hz as a hardware mirror (V3); the monitor returns to 3440 × 1440 when
  the process exits (V4).
- **Known problem, fix untested:** in V3 macOS chose the virtual display's 1× mode, which made the UI smaller. The
  scaler now selects the HiDPI mode explicitly. This has not been run on hardware.
- **Unverified:** text sharpness, 120 Hz at the panel during HiDPI mirroring, the plan's exact 150% and 175% sizes
  (2293 × 960, 1966 × 823), the full app flow, Keep and re-apply at launch, `kill -9`, the watchdog, sleep/wake,
  disconnect, the second monitor, and turning it off. These are HW-30 to HW-41 in TESTING.md.
- **Unexplained:** in V2 the process that created the virtual display saw no modes for it when queried from a bare run
  loop, while another process saw all of them. The scaler polls for up to 6 s. If the mode never appears it removes
  the virtual display again and reports the failure; the monitor is not mirrored at that point.

<!-- RESULT: outcome of HW-30 to HW-41 (one bullet each, with the test ID) -->
