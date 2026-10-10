import ScaleKitCore
import SwiftUI

/// Content of the confirmation panel shown on every screen during a trial.
struct TrialPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            if let session = model.trialSession {
                countdown
                header(session)
                VerificationSummary(verification: session.verification)
                footer(session)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 120)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 440)
    }

    private var countdown: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let state = model.countdown(at: context.date)
            CountdownRing(
                fraction: state.fraction,
                seconds: Int(state.remaining.rounded(.up)),
                isPaused: model.isResolvingTrial)
        }
        .frame(width: 72, height: 72)
    }

    private func header(_ session: RecoveryService.Session) -> some View {
        VStack(spacing: 6) {
            Text("Keep these display settings?")
                .font(.title2.weight(.semibold))
            Text("\(session.displayName) now uses \(model.describe(session.target, displayKey: session.displayKey)).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func footer(_ session: RecoveryService.Session) -> some View {
        if let label = model.trialActionLabel ?? (model.isResolvingTrial ? "Restoring the previous settings…" : nil) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label).foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(height: 32)
        } else {
            VStack(spacing: 12) {
                Text("If you don't choose, ScaleKit restores \(session.previous.summary) automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        model.revertTrial()
                    } label: {
                        Text("Revert").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.cancelAction)
                    .help("Restore the previous settings now (Esc)")

                    Button {
                        model.keepTrial()
                    } label: {
                        Text("Keep Changes").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help("Save these settings (Return)")
                }
                .controlSize(.large)
            }
        }
    }
}

/// The read-back result: CoreGraphics' active mode plus AppKit's view of the screen.
struct VerificationSummary: View {
    let verification: ApplyVerification

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Read back from macOS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                VerificationBadge(level: verification.level)
            }
            InfoRow(
                label: "Active mode",
                value: verification.observed?.summary ?? "Not reported",
                source: "CGDisplayCopyDisplayMode")
            InfoRow(
                "AppKit scale", fact: verification.screenScale,
                format: { Format.scale($0) })
            InfoRow(
                "AppKit size", fact: verification.screenSize,
                format: { "\($0) pt" })
            if verification.level != .verified, !verification.notes.isEmpty {
                Text(verification.notes.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: 12)
    }
}

/// Remaining seconds inside a draining ring.
struct CountdownRing: View {
    let fraction: Double
    let seconds: Int
    var isPaused = false

    private var tint: Color {
        isPaused ? .secondary : (seconds <= 5 ? .orange : .accentColor)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(seconds)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: seconds)
                Text("sec")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(seconds) seconds left to keep the change")
    }
}
