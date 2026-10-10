# Changelog

## Unreleased

- Virtual scaling: the virtual display now uses the monitor's own color profile. macOS gave it a generic ~2.2
  tone curve, and frames that reached the panel without color conversion (during some transitions and page loads)
  looked briefly lighter on monitors with a different curve. `scalekit-diag virtual --no-color-match` turns it off.

## 0.1.0 (2026-10-10)

First public release.

- Sharp HiDPI interface sizes at 125%, 150% and 175% on low-density monitors through a virtual HiDPI display
  (private `CGVirtualDisplay` API, isolated and checked at run time).
- Native 100% and 200% HiDPI modes through public CoreGraphics APIs.
- Safe change flow: review sheet, countdown panel on every screen, automatic revert, app-only changes, watchdog
  helper, launch recovery.
- Refresh rate protection (keeps 120 Hz; confirmation required to lower it) and a fixed refresh rate while mirrored.
- Display layout preserved while scaling; self-repair after sleep, wake and reconnect.
- Status labels (Verified, Available, Experimental, Unsupported, Unknown) with measured / inferred / unavailable
  provenance for every value.
- Transparent recommendation score, illustrative preview, per-app zoom guide, menu bar extra, open at login.
- `scalekit-diag` command-line diagnostics and validation harness.
- 236 automated tests (Swift Testing).
