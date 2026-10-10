# ScaleKit Compatibility

This page lists where ScaleKit was developed and evaluated, what it requires, and how its results are expected to
differ on other hardware.

- **Evaluated** means the read-only research probes in [FEASIBILITY.md](FEASIBILITY.md) were run on that
  configuration.
- **Validated** means trial tests are recorded in FEASIBILITY §6 (IDs D1, T1–T7, run with `scalekit-diag trial`).
- The experimental virtual-display scaling has only probe measurements so far (FEASIBILITY §11, IDs V1–V4). None of
  them counts as validation of the shipped feature.

Checks that need a person at the Mac are pending (TESTING.md §3). Only one configuration has been evaluated or
validated so far, the one in §1.

## 1. Reference configuration

All measured facts in the documentation come from this one machine (FEASIBILITY §1).

### Computer and toolchain

| Item | Value |
|---|---|
| Computer | Mac mini, model identifier `Mac16,10` |
| Chip | Apple M4 (4 performance + 6 efficiency cores, 10-core GPU) |
| Memory | 16 GB |
| macOS | 27.0, build `26A428` (arm64) |
| Developer tools | Command Line Tools only. **Xcode is not installed** |
| Compiler / SDK | Apple Swift 6.4, macOS SDK 27.0 |
| Test framework | Swift Testing (XCTest unavailable without Xcode) |

### Displays

| | Display A (target) | Display B |
|---|---|---|
| Name (`NSScreen.localizedName`) | VG34WQML5A (ASUS TUF Gaming) | MSI MP223 |
| EDID vendor / product | `0x06B3` (AUS) / `0x342B` | `0x3669` (MSI) / `0x30B9` |
| Role | Main, external | Secondary, external |
| Size | 34.3″ (801.6 × 338.7 mm) | 21.4″ (478.1 × 258.8 mm) |
| Native resolution | 3440 × 1440 (21:9) | 1920 × 1080 (16:9) |
| Pixel density (*inferred*) | ≈ 109 PPI | ≈ 102 PPI |
| Active mode at research time | 3440 × 1440 @ 120 Hz, 1×, native flag | 1920 × 1080 @ 100 Hz, 1× |
| Refresh rates offered at native | 250, 240, 180, 120, 60 Hz | Not recorded |
| EDID refresh range (*inferred*) | 48–250 Hz, VRR, HDR (PQ) | 48–100 Hz |
| Connection (*inferred*, IORegistry `Transport`) | Mac mini HDMI port (upstream DP → downstream HDMI) | HDMI (upstream DP → downstream HDMI) |
| HiDPI modes with native output and panel aspect | One: 1720 × 720 HiDPI (backing 3440 × 1440). Applied and verified at 120 Hz (T6) | Not evaluated |
| Scaled (supersampled) HiDPI modes | None offered | Not evaluated |

ScaleKit's profiles and recommendations target Display A. The trial mechanism tests T1–T5 deliberately used Display B
(a refresh change only), so the main display and window layout weren't disturbed (FEASIBILITY §6).

## 2. Requirements

| Requirement | Value | Basis |
|---|---|---|
| macOS (deployment target) | **14.0 or later** | `Package.swift` `.macOS(.v14)`. `Resources/Info.plist` `LSMinimumSystemVersion` 14.0 |
| macOS actually evaluated | **27.0 only** | FEASIBILITY §1. Versions 14–26 are untested |
| Mac architecture | Apple silicon. Evaluated on M4 only | Other Apple silicon chips and Intel are untested (§4) |
| Build tools | Swift 6 toolchain (`swift-tools-version:6.0`). Command Line Tools are enough. Xcode is optional | FEASIBILITY §7 |
| Privileges | Normal user account. No administrator rights, no SIP or Gatekeeper changes | ARCHITECTURE.md §9 |
| Network | None | ARCHITECTURE.md §9 |
| Private API (experimental virtual-display scaling only) | CoreGraphics' `CGVirtualDisplay` classes must exist at run time. Checked before use; if missing, the feature is shown as unavailable and everything else works | Present on macOS 27.0 (FEASIBILITY §11, V1). Other macOS versions untested |

The package declares a macOS 14 deployment target, so the compiler checks every API call for availability on macOS
14. Nothing has been run on macOS 14–26. Whether those releases offer the same modes for a given monitor, and whether
the undocumented IORegistry and `system_profiler` keys exist there, is unknown.

## 3. How results depend on the monitor

ScaleKit's profiles never create display modes. They report, score and apply only what macOS already offers for the
connected display, so the profile results are a property of the monitor, the Mac and the connection together. The
experimental virtual-display scaling is the exception and is covered at the end of this section.

A profile is **Available** only when a *clean* mode exists for it:

- the mode carries `kDisplayModeNativeFlag`;
- it renders sharply (native 1×, native HiDPI or supersampled HiDPI);
- it has the panel's aspect ratio;
- its interface size is within 3% of the target.

See ARCHITECTURE.md §3.4.

| Display class | What macOS is expected to offer | Expected ScaleKit result | Status |
|---|---|---|---|
| **This monitor** (34″ 3440 × 1440, ≈ 109 PPI) | Native 1× and one native HiDPI mode (1720 × 720, 200%). No scaled HiDPI modes | 100% Verified (current mode). 200% Verified on the reference Mac, because T6 saved a verification record. On a fresh install it is Available until applied. 125/150/175% Unsupported, with alternatives that include the softer 168% (2048 × 858) and 179% (1920 × 804) modes | Mode list measured (FEASIBILITY §4). 200% HiDPI @ 120 Hz verified (T6). 168% behaves as predicted (T7) |
| **High-density external** (for example 27″ 4K or 5K) | Apple generates "scaled" HiDPI modes (backing larger than the panel, downsampled) for displays it classifies as high density (FEASIBILITY §5) | Intermediate profiles **may** be Available, classified as *supersampled HiDPI*. They qualify only if macOS also flags those modes native. Whether it does on such displays is untested | Untested |
| **≈ 109 PPI and lower** (27″ 1440p, 24″ or 27″ 1080p, other 1440p ultrawides) | Expected to resemble this monitor: no scaled HiDPI modes, and at most a 2× HiDPI mode at half the native size | Expected to look like this monitor: 100% and possibly 200% clean, intermediate sizes Unsupported | Untested |
| **Built-in panels** (MacBook) | Apple-defined scaled HiDPI modes. CoreGraphics may report 0 Hz for variable-refresh panels | Refresh is reported as *unavailable* when CoreGraphics returns 0 Hz, which lowers the refresh score to 7.5/15 and adds a validation warning | Untested (the reference Mac has no built-in display) |

Apple does not document how it classifies a display as high density. The rows above other than the first are
expectations, not results.

### Experimental virtual-display scaling

The app offers it only for a size that has no clean native mode (FEASIBILITY §11).

| Display class | Expected | Status |
|---|---|---|
| **This monitor** | 125/150/175% offered. Planned sizes 2752 × 1152, 2293 × 960 and 1966 × 823 pt, rendered at twice that and downsampled to 3440 × 1440 | Partly measured with probe code (V1–V4). Mirroring works and the monitor recovered when the process exited. The HiDPI mode was not selected in V3; the fix is untested. Sharpness and 120 Hz in HiDPI unverified |
| **≈ 109 PPI and lower** | Same mechanism. A 1080p panel at 150% would render 2560 × 1440 and downsample to 1920 × 1080 | Untested |
| **High-density external** | Usually not offered, because macOS's own scaled modes cover the common sizes | Untested |
| **Very large panels** (for example 8K) | Backing stores above 8192 px are refused, so only sizes near 200% are possible | Untested |
| **Built-in panels, AirPlay, Sidecar, DisplayLink** | Unknown. Mirroring to a virtual display may not be allowed or may behave differently | Untested |

## 4. Mac hardware

| Mac | Status | Notes |
|---|---|---|
| Mac mini (M4, `Mac16,10`) | Evaluated and validated (FEASIBILITY §6). Manual checks pending | Reference configuration |
| Other Apple silicon Macs | Untested | The same public APIs apply. Mode lists depend on the GPU, display engine and ports |
| Intel Macs | **Untested** | Only arm64 has been targeted. `RegistryReader` matches the `IOMobileFramebuffer` IORegistry class used on Apple silicon. On Intel Macs the connection type and EDID refresh range are expected to be reported as *unavailable* |

## 5. Connections

| Connection | Status | Notes |
|---|---|---|
| HDMI (Mac mini HDMI port) | Evaluated and validated (both displays, FEASIBILITY §6) | The only observed path. It negotiates modes up to 250 Hz at 3440 × 1440, so 120 Hz is not bandwidth-limited (FEASIBILITY §7). The HDMI signal timing itself has not been confirmed (no public API, and not yet checked on the OSD) |
| DisplayPort over USB-C / Thunderbolt | Untested | The mode list, refresh ceiling and HDR/VRR may differ. ScaleKit reports whatever the link offers |
| Adapters, docks, KVM switches | Untested | These can limit bandwidth (lower maximum refresh) or change the EDID that macOS sees |
| DisplayLink (USB graphics) | Untested | Driven by a user-space driver rather than the Mac's display engine. Mode lists, the native flag and app-only revert behaviour are unknown |
| AirPlay, Sidecar | Untested | Virtual displays. Physical size, native flag and mode lists may be missing or synthetic |
| Mirrored displays | Untested | `CGDisplayIsInMirrorSet` is reported. Trials on a mirrored display are not validated |

The connection type is always labelled *inferred*. It comes from the undocumented IORegistry `Transport` key, and no
public API reports it.

## 6. Verified results matrix

**Configuration:** Mac mini `Mac16,10` (M4, 16 GB) · macOS 27.0 (`26A428`) · both displays on HDMI ·
`scalekit-diag` 0.1.0 debug build · 2026-10-09. "Pass" entries are copied from FEASIBILITY §6. "Pending" entries
are the manual checks in [TESTING.md §3](TESTING.md).

| Capability | ASUS VG34WQML5A (display 3) | MSI MP223 (display 1) |
|---|---|---|
| Identification and diagnostics | **Pass** (D1, high confidence) | Reported (D1) |
| App-only trial → verify → Revert | **Pass** for 200% HiDPI (T6) and 168% (T7) | **Pass** (T1, 100 → 60 → 100 Hz) |
| 100% native, 3440 × 1440 @ 120 Hz restored and read back | **Pass** (T6 revert, 1×) | n/a |
| 200% HiDPI, 1720 × 720 @ 120 Hz, 3440 × 1440 backing, `backingScaleFactor` 2.0 | **Pass** (T6) | n/a |
| Lower-resolution alternative (2048 × 858, no native flag) | **Pass**, behaves as predicted (T7) | n/a |
| Exit without revert → macOS restores | Pending | **Pass** (T2) |
| `kill -9` during trial → macOS restores | Pending | **Pass** (T3) |
| Hang → watchdog restores | Pending | **Pass** (T4) |
| Keep → persists after process exit | Pending | **Pass** (T5) |
| Countdown timeout → automatic revert | Pending | Pending |
| Native input signal confirmed on monitor OSD | Pending | n/a |
| Keep persists after logout and reboot | Pending | Pending |
| Sleep/wake and disconnect/reconnect during a trial | Pending | Pending |
| Visual sharpness, Finder, menu bar and apps at 200% | Pending | n/a |
| Experimental: private `CGVirtualDisplay` classes present | **Measured** (V1, macOS 27.0) | (same Mac) |
| Experimental: mirror to a virtual display, app-only | **Partial** (V3: mirroring succeeded at 120.00 Hz per `system_profiler`, but in the virtual display's 1× mode, not HiDPI) | Pending |
| Experimental: 125/150/175% HiDPI applied and verified 2× | Pending (HW-30–HW-32) | Pending |
| Experimental: monitor restored when the process exits | **Measured** when the probe process exited (V4). `kill -9` and watchdog pending (HW-35, HW-36) | Pending |
| Experimental: other monitor unaffected | n/a | Pending (HW-39) |

<!-- RESULT: update the Pending cells above from the TESTING.md §3 manual checklist (cite the HW-xx IDs) -->
<!-- RESULT: any additional Mac / monitor / connection combinations tested, one table or column each -->

## 7. Reporting a new configuration

On the configuration in question, run:

```sh
scalekit-diag displays
scalekit-diag profiles --display <ID>
scalekit-diag report --out ~/Desktop/scalekit-report
```

These commands are read-only. The report contains the EDID vendor and product IDs, the `CGDisplaySerialNumber` value,
the display UUID, the Mac's model identifier and the macOS build. Review it before sharing. A configuration counts as
*verified* only after the hardware checklist in TESTING.md has been run on it.
