# Contributing to ScaleKit

Thanks for helping. The most useful contributions are:

1. **Monitor reports.** Open a [Monitor report](https://github.com/shimentosh/scalekit/issues/new?template=monitor_report.yml)
   so other people with the same monitor know what to expect.
2. **Bug reports** with a diagnostic report attached (see below).
3. **Pull requests** that keep ScaleKit's safety rules intact.

## Diagnostic report

In the app: **Advanced ▸ Diagnostics ▸ Export**. From the terminal:

```sh
swift build --product scalekit-diag
.build/debug/scalekit-diag report --out reports
```

Reports include your monitor's model and, where macOS exposes them, its serial number and display UUID. Remove those
before posting if you prefer.

## Development

```sh
scripts/run-tests.sh          # all tests
scripts/build-app.sh --debug  # debug app bundle in build/
```

Only the Command Line Tools are required. With them, the app uses `@ViewState` (an alias of SwiftUI's `State`)
instead of `@State`, because the `@State` macro plugin ships only with Xcode.

## Rules for changes

- **Never apply a display change without a trial.** Every change goes through review → app-only apply → read-back
  verification → countdown → Keep or automatic revert.
- **Never claim what wasn't measured.** Values are `measured`, `inferred` or `unavailable`; statuses follow the same
  rule.
- **Private APIs stay in `Sources/ScaleKitVirtualBridge`,** looked up at run time, with a graceful fallback.
- No network access, analytics, admin rights, SIP or Gatekeeper changes.
- Tests must not touch real displays. Use `FakeDisplayHardware`.

## README screenshots

The screenshots are rendered by the app itself, offscreen and read-only (no screen-recording permission needed):

```sh
swift build --product ScaleKit
.build/debug/ScaleKit --render-screenshots /tmp/scalekit-shots
```
