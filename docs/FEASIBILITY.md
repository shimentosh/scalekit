# ScaleKit — Feasibility Report

Research date: 2026-10-09. Every value below was measured on the machine described in §1 unless it is
explicitly marked *inferred* or *unavailable*. §11 (added 2026-10-10) covers the experimental virtual-display scaling,
which uses a private API, and separates what was measured from what is still unverified.

## 1. Environment inventory

| Item | Value | How it was obtained |
|---|---|---|
| Computer | Mac mini, model identifier `Mac16,10` | `system_profiler SPHardwareDataType`, `sysctl hw.model` |
| Chip | Apple M4 (4 performance + 6 efficiency cores, 10-core GPU, Metal 4) | `system_profiler`, `sysctl machdep.cpu.brand_string` |
| Memory | 16 GB | `sysctl hw.memsize` |
| macOS | 27.0, build `26A428` (Darwin 27.0.0, arm64) | `sw_vers`, `uname -a` |
| Developer tools | **Command Line Tools only — Xcode is not installed** (`xcodebuild` unavailable) | `xcode-select -p` → `/Library/Developer/CommandLineTools` |
| Compiler | Apple Swift 6.4 (swiftlang-6.4.0.34.1), target `arm64-apple-macosx27.0.0` | `swift --version` |
| SDK | macOS SDK 27.0 (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) | `xcrun --show-sdk-version` |
| Test frameworks | **XCTest: not available** (`unable to resolve module dependency: 'XCTest'`). **Swift Testing: available** (Testing library 2084) | Smoke-test package built with `swift test` |
| Asset tools | `iconutil`, `sips`, `codesign`, `plutil` present | `which` |

### Connected displays

| | Display A (target) | Display B |
|---|---|---|
| CoreGraphics display ID | `3` | `1` |
| Name (`NSScreen.localizedName`) | VG34WQML5A | MSI MP223 |
| EDID vendor / product (`CGDisplayVendorNumber` / `CGDisplayModelNumber`) | `0x06B3` (PNP "AUS" = ASUS) / `0x342B` | `0x3669` (PNP "MSI") / `0x30B9` |
| CG serial number | 0 (not populated by the monitor) | 1 |
| Role | Main display, external | Secondary, external |
| Physical size (`CGDisplayScreenSize`) | 801.6 × 338.7 mm → 34.3″ diagonal | 478.1 × 258.8 mm → 21.4″ |
| Pixel density (*inferred* from size + native width) | ≈ 109 PPI | ≈ 102 PPI |
| Active mode | 3440 × 1440 pt, 3440 × 1440 px, **120 Hz**, mode ID 119, flags `0x02000003` (valid · safe · native) | 1920 × 1080 pt/px, 100 Hz, mode ID 63, flags `0x02000007` |
| `NSScreen.backingScaleFactor` | **1.0** (not HiDPI) | 1.0 |
| `NSScreen.maximumFramesPerSecond` | 120 | 100 |
| Logical desktop (`NSScreen.frame`) | 3440 × 1440 at (0, 0) | 1920 × 1080 at (3440, 187) |
| Connection (*inferred*, undocumented IORegistry `Transport` key) | Upstream `DP` → Downstream `HDMI` (the Mac mini's HDMI port) | Upstream `DP` → Downstream `HDMI` |
| EDID refresh range (*inferred*, IORegistry `DisplayAttributes`) | 48–250 Hz, variable refresh supported, HDR (PQ) supported | 48–100 Hz |
| `system_profiler` "UI Looks like" | 3440 × 1440 @ 120.00Hz | 1920 × 1080 @ 100.00Hz |

The display's own EDID reports a "native format" of 1920 × 1080 in IORegistry (`NativeFormatHorizontalPixels`). That
contradicts the mode list and the monitor's specification. ScaleKit therefore ignores that key and derives the native
resolution from the mode that the driver flags with `kDisplayModeNativeFlag`.

## 2. Verified public APIs

Every API below is declared in the macOS 27.0 SDK headers and was exercised by the probe program (§4).

| Purpose | API | Header |
|---|---|---|
| Enumerate displays | `CGGetOnlineDisplayList`, `CGGetActiveDisplayList` | `CoreGraphics/CGDirectDisplay.h` |
| Identity | `CGDisplayVendorNumber`, `CGDisplayModelNumber`, `CGDisplaySerialNumber`, `CGDisplayIsMain`, `CGDisplayIsBuiltin`, `CGDisplayIsInMirrorSet` | `CGDirectDisplay.h`, `CGDisplayConfiguration.h` |
| Stable identifier | `CGDisplayCreateUUIDFromDisplayID` | `ColorSync/ColorSyncDevice.h:270` |
| Physical size | `CGDisplayScreenSize` (millimetres, from EDID) | `CGDisplayConfiguration.h` |
| Current mode | `CGDisplayCopyDisplayMode` | `CGDirectDisplay.h:144` |
| All modes **including HiDPI** | `CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes = true` | `CGDirectDisplay.h:128–137` |
| Mode properties | `CGDisplayModeGetWidth/Height` (points), `GetPixelWidth/Height` (backing pixels), `GetRefreshRate`, `GetIOFlags`, `GetIODisplayModeID`, `IsUsableForDesktopGUI` | `CGDirectDisplay.h` |
| Mode flags | `kDisplayModeValidFlag` 0x1, `SafeFlag` 0x2, `DefaultFlag` 0x4, `InterlacedFlag` 0x40, `NeverShowFlag` 0x80, `StretchedFlag` 0x800, **`NativeFlag` 0x02000000** | `IOKit/graphics/IOGraphicsTypes.h:162–185` |
| Apply a mode | `CGBeginDisplayConfiguration` → `CGConfigureDisplayWithDisplayMode` → `CGCompleteDisplayConfiguration(option)` | `CGDisplayConfiguration.h:68, 175` |
| Change lifetime | `kCGConfigureForAppOnly` (0), `kCGConfigureForSession` (1), `kCGConfigurePermanently` (2) | `CGDisplayConfiguration.h:170–174` |
| Restore saved settings | `CGRestorePermanentDisplayConfiguration` | `CGDisplayConfiguration.h:184` |
| Change notifications | `CGDisplayRegisterReconfigurationCallback` (add/remove/set-mode/move/mirror flags) | `CGDisplayConfiguration.h:235` |
| Mirroring (experimental virtual scaling only, §11) | `CGConfigureDisplayMirrorOfDisplay`, `CGConfigureDisplayOrigin`, `CGDisplayMirrorsDisplay`, `CGDisplayIsOnline` | `CGDisplayConfiguration.h`, `CGDirectDisplay.h` |
| Logical size & scale as AppKit sees it | `NSScreen.frame`, `.backingScaleFactor`, `.localizedName`, `.maximumFramesPerSecond`, `deviceDescription["NSScreenNumber"]` | AppKit |
| Sleep / wake | `NSWorkspace.willSleepNotification`, `didWakeNotification`, `screensDidSleepNotification`, `screensDidWakeNotification` | AppKit |
| Screen changes | `NSApplication.didChangeScreenParametersNotification` | AppKit |

### Documented guarantees that the safety design relies on

`CGDisplayConfiguration.h:150–166` (SDK 27.0):

> A configuration change can apply for the life of an application, the life of a login session, or permanently. …
> When the system reverts configurations at app termination, the configuration reverts to the session or permanent
> configuration setting.

`CGDirectDisplay.h:152–155` (`CGDisplaySetDisplayMode`):

> The selected display mode persists for the life of the program, and automatically reverts to the permanent setting
> when the program terminates.

**Consequence:** if a trial change is applied with `kCGConfigureForAppOnly`, WindowServer reverts it automatically when
the app terminates, including when it crashes or is force-quit. The change is written as permanent only after the user
presses **Keep**. §6 records whether this held on the actual hardware.

### Non-public or undocumented sources (classified)

| Source | Used for | Classification |
|---|---|---|
| IORegistry `IOMobileFramebuffer` → `DisplayAttributes`, `Transport` | Connection type, EDID refresh range, VRR/HDR support | Public IOKit calls, **undocumented keys** → values reported as *inferred* |
| `system_profiler SPDisplaysDataType -json` | Secondary cross-check of the active mode | Supported tool, **undocumented output format** → *inferred*, never the only evidence |
| `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings` | Only by the opt-in experimental virtual-display scaling (§11), in the `ScaleKitVirtualBridge` target. Looked up with `NSClassFromString`; nothing links against a private symbol | **Private.** Classes are present at runtime on macOS 27.0 but absent from all public SDK headers |

## 3. Current display configuration (target monitor)

- Physical panel: 3440 × 1440 (mode flagged `kDisplayModeNativeFlag`).
- Logical desktop: 3440 × 1440 points. **1 point = 1 pixel.** The UI is drawn at 1× (no HiDPI).
- Refresh: 120 Hz (the EDID-preferred `kDisplayModeDefaultFlag` mode is 3440 × 1440 @ **250 Hz**. The user has
  chosen 120 Hz).
- At ≈ 109 PPI and 1×, one point measures ≈ 0.233 mm. Apple's 27″ Studio Display at its default "looks like
  2560 × 1440" gives about the same physical point size (218 PPI ÷ 2). The UI is therefore not abnormally small for
  macOS. It is the size Apple designs for. The user wants it larger, and the only ways to make it larger are fewer
  logical points or HiDPI scaling.

## 4. Available display modes (target monitor)

`CGDisplayCopyAllDisplayModes` returned **99** modes without the duplicate option and **187** with
`kCGDisplayShowDuplicateLowResolutionModes`. HiDPI modes only appear with that option. The table lists the
desktop-usable (`IsUsableForDesktopGUI`) resolutions grouped by aspect ratio. "UI size" is 3440 ÷ logical width.

### 21:9 (matches the panel)

| Looks like (pt) | Backing (px) | HiDPI | Native flag | UI size | Refresh rates (Hz) | Rendering path |
|---|---|---|---|---|---|---|
| 3440 × 1440 | 3440 × 1440 | — | ✅ | 100% | 250, 240, 180, **120**, 60 | 1:1 native |
| 2048 × 858 | 2048 × 858 | — | — | 168% | 250, 240, 180, 120, 60 | Scaled up (soft) |
| 1920 × 804 | 1920 × 804 | — | — | 179% | 250, 240, 180, 120, 60 | Scaled up (soft) |
| **1720 × 720** | **3440 × 1440** | **✅ 2×** | **✅** | **200%** | 250, 240, 180, **120**, 60 | **HiDPI at native resolution** |
| 1720 × 720 | 1720 × 720 | — | — | 200% | 250, 240, 180, 120, 60 | Scaled up (soft) |
| 1600 × 670 | 1600 × 670 | — | — | 215% | 250 … 60 | Scaled up |
| 1344 × 562 | 1344 × 562 | — | — | 256% | 250 … 60 | Scaled up |
| 1280 × 536 | 1280 × 536 | — | — | 269% | 250 … 60 | Scaled up |

### Other aspect ratios (would letterbox or stretch on a 21:9 panel)

16:9: 2560 × 1440, 1920 × 1080 (1× and HiDPI 3840 × 2160), 1280 × 720 (1× and HiDPI 2560 × 1440), 960 × 540 HiDPI.
4:3 / 5:4: 1600 × 1200, 1344 × 1008, 1280 × 1024, 1280 × 960, 1024 × 768, 800 × 600 (1× and HiDPI). None of the
16:9 or 4:3 HiDPI modes carry the native flag.

## 5. HiDPI findings

1. macOS **does** expose HiDPI for this monitor. Exactly one HiDPI mode both matches the panel's aspect ratio and
   renders at native resolution: **1720 × 720 HiDPI (backing 3440 × 1440)**, available at 120 Hz. With it, every app,
   Finder, and the menu bar draw text with 2× glyphs. The panel receives a native 3440 × 1440 signal (native flag set)
   and the UI is twice the current size.
2. macOS exposes **no "scaled" HiDPI modes**, meaning backing stores larger than the panel that are downsampled, such
   as 2752 × 1152 pt → 5504 × 2304 px for 125%. Those are the modes System Settings offers on 4K/5K displays. Apple
   only generates them for displays it classifies as high-density, and this 109 PPI panel does not qualify.
3. Consequently, **125%, 150% and 175% at native output with HiDPI text are not achievable through public APIs** on
   this monitor. The only 21:9 modes near those sizes (2048 × 858 ≈ 168%, 1920 × 804 ≈ 179%) are 1× modes without
   the native flag. They are rendered at lower resolution and enlarged, so text is softer. macOS does not report
   whether the GPU or the monitor performs that enlargement (*unavailable*). §11 describes the experimental,
   private-API route ScaleKit now offers for these sizes.
4. A HiDPI flag alone is not proof of quality. The 16:9 HiDPI modes (e.g. 1280 × 720 → 2560 × 1440) are HiDPI but
   smaller than the panel and the wrong shape.

## 6. Hardware validation results (Phase 5)

**Configuration for every result in this section:** 2026-10-09 · Mac mini `Mac16,10` (Apple M4, 16 GB) · macOS 27.0
(`26A428`) · ASUS VG34WQML5A (display ID 3, HDMI) + MSI MP223 (display ID 1, HDMI) · `scalekit-diag` 0.1.0 debug
build. Each test ran ScaleKit's `RecoveryService` through `scalekit-diag trial`, the same code path the app uses.

Mechanism tests T1–T5 used the **secondary MSI display** and changed only its refresh rate (100 → 60 Hz), so the
main display and window layout were never disturbed.

| ID | Test | Result | Evidence |
|---|---|---|---|
| D1 | Diagnostic tool against the real monitors | **Pass** | ASUS identified with *high* confidence (EDID `AUS`, product `0x342B`, name match, native 3440 × 1440). All values labelled measured, inferred or unavailable. |
| T1 | App-only trial → verify → explicit Revert (MSI 100 → 60 → 100 Hz) | **Pass** | Verified in 1.2 s by CoreGraphics (mode 65), AppKit (1×, 1920 × 1080) and system_profiler (`@ 60.00Hz`). Revert verified, mode 63 @ 100 Hz restored. Watchdog started and exited when the journal resolved. |
| T2 | Trial, then the process exits without reverting | **Pass** | 100 Hz was active immediately after exit. macOS reverted the app-only change and the watchdog recorded `revertedBySystem`. |
| T3 | Trial, then `kill -9` (simulated crash) | **Pass** | 60 Hz during the trial. Immediately after SIGKILL (exit 137), 100 Hz was active again. |
| T4 | Trial with a frozen main thread (simulated hang) | **Pass** | The watchdog sent SIGTERM 8 s after the deadline (exit 143), mode 63 @ 100 Hz was active, and the journal reads `revertedByGuard`. |
| T5 | Keep → permanent, then the process exits | **Pass** | 60 Hz persisted after exit (`forAppOnly` followed by `permanently` saves the change). Three further Keep cycles (100 → 60 → 100 Hz) each verified in about 1 s. The display was left at the original 100 Hz. |
| T5a | Unplanned: one Keep run stalled after the trial started | **Recovered by the watchdog** | The process stopped responding before printing verification output. The watchdog terminated it 33 s later (provisional deadline + grace) and 100 Hz was active afterwards. Root cause **not confirmed**: the info-level logs were not persisted. The most likely candidate was the `system_profiler` cross-check, which had no timeout. It is now bounded at 6 s, the app does not use it in the apply path, and each step logs at notice level (persisted). It did not recur in the 5 trials run after the fix. |
| T6 | **200% HiDPI on the ASUS**: mode 80, 1720 × 720 HiDPI @ 120 Hz | **Pass — verified** | CoreGraphics: 1720 × 720 pt, **3440 × 1440 px backing**, flags `0x02000003` (native), **120 Hz**. AppKit: `backingScaleFactor` **2.0**, frame 1720 × 720. system_profiler: `Resolution: 3440 x 1440`, `UI Looks like: 1720 x 720 @ 120.00Hz`. Revert restored 3440 × 1440 @ 120 Hz, 1×. Verification record saved. |
| T7 | Lower-resolution alternative on the ASUS: mode 110, 2048 × 858 @ 120 Hz | **Pass (behaves as predicted)** | Rendered at 2048 × 858 px, 1× (not HiDPI), flags `0x00000003` (no native flag). The output signal is unavailable. system_profiler also reports `pixels 2048 x 858`, which is the render size, not the HDMI timing. Reverted cleanly. |

### What this proves and what it does not

- **Proven on this hardware:** a system-wide 200% interface with HiDPI (2×) text, rendered at the panel's native 3440 ×
  1440 and delivered at 120 Hz in 21:9, through public CoreGraphics APIs alone. This covers Finder, the menu bar and
  every app, because it is a real display mode and not an in-app zoom.
- **Proven:** the apply → verify → countdown → revert/keep cycle, and recovery from a clean exit, a crash (SIGKILL) and
  a hang (watchdog).
- **Not proven by software:** the physical HDMI signal timing. "Native output" is inferred from
  `kDisplayModeNativeFlag`. system_profiler reports the backing size, not the link timing. Confirm it on the monitor's
  OSD (Information page).
- **Not performed (needs a person at the Mac):** visual sharpness assessment, sleep/wake, cable disconnect/reconnect,
  logout/reboot persistence, and app-by-app behaviour (Finder, menu bar, browsers, VS Code) at 200%. These are listed in
  [TESTING.md](TESTING.md).

## 7. Technical limitations

- **No intermediate sharp scaling.** Public APIs can only select modes that macOS already generates. They cannot
  create new HiDPI modes.
- **Physical output timing is not exposed.** No public API reports the signal timing on the HDMI link. ScaleKit
  infers native output from `kDisplayModeNativeFlag`, and the manual checklist asks the user to confirm it on the
  monitor's OSD.
- **Workspace at 200% is small.** 1720 × 720 points is a quarter of the native area, smaller than a 13″ MacBook Air.
- **HDMI path.** The monitor is on HDMI. It currently negotiates up to 250 Hz, so 120 Hz is not bandwidth-limited.
  Behaviour on other cables or ports is untested.
- **No Xcode.** The project is a Swift Package (Xcode opens `Package.swift` directly). Tests use Swift Testing
  because XCTest ships only with Xcode. The `.app` bundle is assembled by a script.

## 8. Experimental approaches

| Approach | How it would work | Why it is not in ScaleKit |
|---|---|---|
| Virtual HiDPI display + mirroring | Create a private `CGVirtualDisplay` with custom HiDPI modes (e.g. 2752 × 1152 @ 2×), then mirror the physical display to it with public `CGConfigureDisplayMirrorOfDisplay`. This is how BetterDisplay-style tools offer arbitrary HiDPI sizes. | Private API (not in SDK headers). It can break on any macOS update. Mirroring can drop HDR and VRR and adds a GPU composition pass. The virtual display disappears when the process exits. Arrangement changes can strand windows. **Implemented as an opt-in experimental mode (§11).** Not part of the stable, public-API path. |
| Display override plist (`/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-6b3/DisplayProductID-342b`, `scale-resolutions`) | Ask the display stack to generate extra HiDPI modes | Needs administrator write access to `/Library`. The format is undocumented. Behaviour on Apple Silicon is not verified here. **Unsupported — not implemented.** |
| EDID or timing injection via private SkyLight / IOAVService calls | Pretend the panel is higher density | Private, risky, can blank the display. **Unsupported.** |
| Global UI injection, forced window resizing, accessibility hacks | Fake "scaling" | Explicitly out of scope. Not a real scaling path. **Rejected.** |

## 9. Go / no-go decisions

| Feature | Decision | Basis |
|---|---|---|
| Display discovery, identification, physical vs logical dimensions | **GO** | Public CG + AppKit, measured |
| Mode enumeration including HiDPI, refresh rates, flags | **GO** | Public CG, measured |
| Connection type, EDID refresh range | **GO (as *inferred*)** | Undocumented IORegistry keys |
| 100% — 3440 × 1440 native @ 120 Hz | **GO** | Active mode, measured |
| 200% — 1720 × 720 HiDPI, native output @ 120 Hz | **GO — verified (§6 T6)** | Applied and read back via CG, AppKit and system_profiler |
| 125% / 150% / 175% with HiDPI text at native output | **NO-GO (public API)** | macOS exposes no such modes for this monitor |
| 125% / 150% / 175% through a virtual HiDPI display + mirroring | **EXPERIMENTAL, opt-in (§11)** | Private API. Mechanism partly measured (§11.2); sharpness, 120 Hz output in HiDPI and the app flow unverified (§11.3) |
| ~168% / ~179% lower-resolution 21:9 modes | **GO only as explicit opt-in** | Available but softer. Never selected automatically |
| Safe apply with confirmation countdown and auto-revert | **GO — verified (§6 T1, T5)** | `kCGConfigureForAppOnly` trial, then `kCGConfigurePermanently` on Keep |
| Crash recovery | **GO — verified (§6 T2, T3)** | Documented app-termination revert held for a clean exit and for SIGKILL |
| Hang recovery (app alive but unresponsive) | **GO — verified (§6 T4, T5a)** | Unprivileged watchdog child process. No admin rights, no SIP changes |
| Display connect / disconnect / sleep / wake monitoring | **GO** | Public callbacks and notifications |
| Live scaling preview | **GO (illustrative only)** | Drawn inside the app window |
| App-specific zoom guidance | **GO (guidance only)** | Never presented as system scaling |
| Virtual-display HiDPI as a default or stable feature | **NO-GO** | Private API (§8, §11). Offered only as an opt-in experiment |
| Xcode project + XCTest | **Adapted** | Xcode not installed → Swift Package + Swift Testing |

## 10. Safest implementation strategy

1. Read everything through public CoreGraphics and AppKit. Label every value as measured, inferred, or unavailable.
2. Build scaling profiles **only** from modes macOS already offers. A profile is "Available" when a mode exists with
   native output, a sharp rendering path, the native aspect ratio and the preferred refresh rate. It becomes
   "Verified" after ScaleKit has applied it and read it back on this Mac. Otherwise it is "Unsupported", with the
   reason and the closest alternatives listed.
3. Apply changes as `kCGConfigureForAppOnly` trials. Verify the mode through CoreGraphics and AppKit, and show a
   countdown on every screen. Make the change permanent only on **Keep**. Revert on timeout, Revert, sleep, failure
   or termination.
4. Back up the previous mode before every change, journal the trial to disk, and run an unprivileged watchdog that
   force-terminates a hung app so WindowServer restores the saved configuration.
5. Keep private-API code out of the stable path. The one experiment that uses it (§11) lives in its own targets,
   is opt-in, is applied for this process only, and goes through the same journal, watchdog and countdown as every
   other change.

## 11. Experimental: virtual-display scaling

Added 2026-10-10 because the user asked for 125%, 150% and 175% on this monitor even if that needs a private API.
§5 still holds: **no public API produces these sizes sharply on this panel.** This section describes the private-API
route, what was measured on E1 and what is still unverified.

### 11.1 How it works

1. `SKVirtualDisplay` (`Sources/ScaleKitVirtualBridge`, Objective-C) creates a private `CGVirtualDisplay` with
   `hiDPI = 1` and a single mode of *points* = native ÷ scale. The private classes are looked up with
   `NSClassFromString`, and `isSupported` checks every class and selector first, so a macOS release without them
   makes the feature unavailable instead of crashing. This is the only private-API code in ScaleKit.
2. `VirtualDisplayScaler` (`Sources/ScaleKitVirtual`) waits for the virtual display's HiDPI mode (points × 2 pixels)
   and, in one configuration transaction, selects that mode explicitly, places the virtual display at the monitor's
   origin and mirrors the monitor to it with the public `CGConfigureDisplayMirrorOfDisplay`. The transaction is
   completed with `kCGConfigureForAppOnly`.
3. macOS renders the desktop at twice the "looks like" size and scales that image to the panel. Every supported size
   renders more pixels than the panel has (sampling = 2 ÷ scale, at least 1.03× for 195%), so the image is
   downsampled, as on Apple's scaled modes for high-density displays.
4. `VirtualScalingService` runs the same safety sequence as other changes: journal first (`virtual-trial.json`,
   watched by ScaleKitGuard), app-only change, verification, countdown, revert unless kept. **Keep** saves
   `virtual-scaling.json`, and the scaling is re-applied when ScaleKit next starts. It is never saved to the display
   preferences, so it lasts only while ScaleKit runs.

Sizes `VirtualScalingPlan` computes for this monitor (arithmetic, covered by unit tests, not measurements):

| Size | Looks like (pt) | Rendered (px) | Sampling | GPU pixels vs 100% |
|---|---|---|---|---|
| 125% | 2752 × 1152 | 5504 × 2304 | 1.60× | 2.56× |
| 150% | 2293 × 960 | 4586 × 1920 | 1.33× | 1.78× |
| 175% | 1966 × 823 | 3932 × 1646 | 1.14× | 1.31× |

The plan accepts 105–195% (100% and 200% have clean native modes) and refuses backing stores wider or taller than
8192 px.

### 11.2 Measured on E1 (2026-10-10)

Mac mini M4, macOS 27.0, ASUS VG34WQML5A on HDMI at 120 Hz, MSI MP223 connected. These runs used development probe
code, not the ScaleKit app, and not the final `scalekit-diag virtual --percent` command.

| ID | Test | Result |
|---|---|---|
| V1 | Private classes present | `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings` and `CGVirtualDisplayMode` exist with the expected selectors |
| V2 | Virtual display with `hiDPI = 1` and modes 2752 × 1152, 2294 × 960 and 1966 × 822 @ 120 Hz | A separate process saw HiDPI modes 2752 × 1152 pt (5504 × 2304 px), 2294 × 960 pt (4588 × 1920 px) and 1966 × 822 pt (3932 × 1644 px), all at 120 Hz. The creating process itself saw **no** modes when it queried them from a bare run loop. This is unexplained; the scaler polls for up to 6 s |
| V3 | Mirror the ASUS to a 2294 × 960 virtual display with `kCGConfigureForAppOnly` | `CGError` 0. `system_profiler` listed the virtual display as Main Display, "Master Mirror", and the VG34WQML5A as "Hardware Mirror" @ 120.00 Hz. **But macOS chose the virtual display's 1× mode (4588 × 1920 pt), not the HiDPI mode**, so the result was a smaller UI, not a larger one |
| V4 | Probe process exits while mirrored | Mirroring ended and the ASUS returned to 3440 × 1440 on its own |

After V3 the scaler was changed to select the HiDPI mode explicitly (step 2 of §11.1).

Later the same day, with the shipped code (`scalekit-diag virtual --percent 125 --seconds 8`):

| ID | Test | Result |
|---|---|---|
| V5 | User report with an earlier build: brightness pulsing while mirrored | WindowServer had saved a display set for the virtual display's identity with the ASUS at **250 Hz, VRR on** (written when System Settings ▸ Displays ▸ "Optimise for" reversed the mirror) and re-applied it on every creation. Fixed by giving the virtual display a new identity, bumped again whenever the mirror is reversed outside ScaleKit |
| V6 | User report: "The monitor is not mirroring the virtual display" | The mirror was requested before macOS had finished bringing the new display up. Fixed by waiting for the virtual display's mode list, then retrying the mirror up to 3 times |
| V7 | 125% with the fixed code | **VERIFIED in 2.0 s.** Mirroring active; virtual display 2752 × 1152 HiDPI @ 120 Hz; `NSScreen` 2.0× / 2752 × 1152 pt; the ASUS, while mirrored, in a 2752 × 1152 @ **120 Hz** mode (same bounds as the virtual desktop); no verification notes |
| V8 | Turn-off after V7 | The virtual display was removed and the ASUS returned to 3440 × 1440 @ 120 Hz, with the MSI moved back, in one reconfiguration (no intermediate extended display) |

### 11.3 Not verified

- 150% and 175% with the shipped code (only 125% was run, V7).
- The exact sizes the plan computes for 150% and 175% (2293 × 960 and 1966 × 823). V2 used 2294 × 960 and
  1966 × 822. Only 2752 × 1152 was created exactly as planned.
- The refresh rate on the monitor's own OSD while mirrored (V7's 120 Hz is what CoreGraphics reports).
- Whether V5's fix ends the brightness pulsing (needs the user's eyes).
- Text sharpness compared with 100% and 200%. No visual check has been made.
- GPU load, power and frame pacing; HDR, VRR and screen recording while mirrored.
- The app flow: review sheet, countdown, Keep, re-apply at the next launch, turn-off.
- `kill -9`, a hang caught by ScaleKitGuard, sleep/wake, disconnect/reconnect, and the MSI staying unaffected.
- Any macOS other than 27.0, any other Mac or monitor.

The manual checks are HW-30 to HW-41 in [TESTING.md](TESTING.md) §3.7.

### 11.4 Risks

- **Private API.** Apple can change or remove `CGVirtualDisplay` in any release. A missing class or selector is
  detected; a changed argument or behaviour behind an unchanged selector is not.
- **Only while ScaleKit runs.** Quitting ScaleKit or a crash removes the virtual display (V4), and the monitor
  returns to its normal mode. Between login and ScaleKit's launch the monitor runs at its saved mode.
- **Mirroring side effects.** The physical monitor becomes a mirror of a virtual one: HDR, VRR, color profiles and
  screen recording of the physical monitor can behave differently, and the virtual display appears in System
  Settings ▸ Displays while it exists.
- **GPU work.** The desktop is rendered at up to 2.56× the native pixel count (125%) and then scaled.

### 11.5 Decision

| Feature | Decision |
|---|---|
| Virtual-display scaling at 105–195% on monitors without a clean native mode | **EXPERIMENTAL, opt-in.** Offered only when macOS has no clean mode for the size, always as a trial with countdown |
| Virtual-display scaling as a default or a replacement for clean modes | **NO-GO** |
| Admin rights, SIP changes, display override plists, EDID injection | **Still NO-GO** (§8) |
