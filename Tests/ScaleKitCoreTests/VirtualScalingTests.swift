import Foundation
import Testing
@testable import ScaleKitCore

/// Pure arithmetic and policy for the experimental virtual-display scaling.
/// Nothing here creates a virtual display or touches the display configuration.
@Suite("Virtual scaling plan")
struct VirtualScalingPlanTests {
    let ultrawide = PixelSize(width: 3440, height: 1440)
    let uhd = PixelSize(width: 3840, height: 2160)
    let fullHD = PixelSize(width: 1920, height: 1080)

    private func make(_ percent: Int, _ native: PixelSize, refresh: Double = 120) -> VirtualScalingPlan? {
        VirtualScalingPlan(target: ScalingTarget(percent: percent), native: native, refreshRate: refresh)
    }

    // MARK: Sizes

    @Test("125/150/175% on 3440 × 1440", arguments: [
        (125, PixelSize(width: 2752, height: 1152)),
        (150, PixelSize(width: 2293, height: 960)),
        (175, PixelSize(width: 1966, height: 823)),
    ])
    func ultrawideSizes(percent: Int, points: PixelSize) throws {
        let plan = try #require(make(percent, ultrawide))
        #expect(plan.target == ScalingTarget(percent: percent))
        #expect(plan.native == ultrawide)
        #expect(plan.points == points)
        #expect(plan.pixels == PixelSize(width: points.width * 2, height: points.height * 2))
        #expect(plan.refreshRate == 120)
        #expect(plan.points.hasSameAspect(as: ultrawide))
        #expect(plan.pixels.hasSameAspect(as: ultrawide))
    }

    @Test("Backing store is exactly twice the points and keeps the panel's shape for every supported percent",
          arguments: [
            PixelSize(width: 3440, height: 1440), PixelSize(width: 3840, height: 2160),
            PixelSize(width: 1920, height: 1080), PixelSize(width: 2560, height: 1440),
            PixelSize(width: 2560, height: 1080), PixelSize(width: 1920, height: 1200),
          ])
    func everyPercentKeepsShape(native: PixelSize) throws {
        for percent in VirtualScalingPlan.supportedPercents {
            let plan = try #require(make(percent, native), "\(percent)% on \(native)")
            #expect(plan.pixels.width == plan.points.width * 2)
            #expect(plan.pixels.height == plan.points.height * 2)
            #expect(plan.points.hasSameAspect(as: native), "\(percent)% on \(native): \(plan.points)")
            #expect(abs(plan.effectiveScale - plan.target.factor) < 0.005, "\(percent)% on \(native)")
        }
    }

    @Test("16:9 panels", arguments: [
        (PixelSize(width: 3840, height: 2160), 125, PixelSize(width: 3072, height: 1728)),
        (PixelSize(width: 3840, height: 2160), 150, PixelSize(width: 2560, height: 1440)),
        (PixelSize(width: 3840, height: 2160), 175, PixelSize(width: 2194, height: 1234)),
        (PixelSize(width: 1920, height: 1080), 125, PixelSize(width: 1536, height: 864)),
        (PixelSize(width: 1920, height: 1080), 150, PixelSize(width: 1280, height: 720)),
        (PixelSize(width: 1920, height: 1080), 175, PixelSize(width: 1097, height: 617)),
    ])
    func sixteenByNine(native: PixelSize, percent: Int, points: PixelSize) throws {
        let plan = try #require(make(percent, native, refresh: 60))
        #expect(plan.points == points)
        #expect(plan.pixels == PixelSize(width: points.width * 2, height: points.height * 2))
        #expect(plan.points.hasSameAspect(as: native))
    }

    // MARK: Rejections

    @Test("100% and 200% have native modes and are never planned", arguments: [100, 200])
    func cleanPercentsRejected(percent: Int) {
        #expect(make(percent, ultrawide) == nil)
        #expect(make(percent, uhd) == nil)
    }

    @Test("Percentages outside 105–195 are rejected", arguments: [-50, 0, 50, 99, 104, 196, 250, 400])
    func outOfRange(percent: Int) {
        #expect(make(percent, ultrawide) == nil)
    }

    @Test("The range ends are accepted")
    func rangeEnds() throws {
        #expect(VirtualScalingPlan.supportedPercents == 105...195)
        let low = try #require(make(105, ultrawide))
        #expect(low.points == PixelSize(width: 3276, height: 1371))
        let high = try #require(make(195, ultrawide))
        #expect(high.points == PixelSize(width: 1764, height: 738))
    }

    @Test("Zero or negative sizes and refresh rates are rejected")
    func degenerateInputs() {
        #expect(make(150, PixelSize(width: 0, height: 1440)) == nil)
        #expect(make(150, PixelSize(width: 3440, height: 0)) == nil)
        #expect(make(150, PixelSize(width: 0, height: 0)) == nil)
        #expect(make(150, PixelSize(width: -3440, height: 1440)) == nil)
        #expect(make(150, ultrawide, refresh: 0) == nil)
        #expect(make(150, ultrawide, refresh: -60) == nil)
    }

    @Test("The smallest panel still gets at least one point each way")
    func tinyPanel() throws {
        // n / 1.95 ≥ 0.51 rounds up, so the zero-size guard cannot trigger for positive input.
        let plan = try #require(make(195, PixelSize(width: 1, height: 1)))
        #expect(plan.points == PixelSize(width: 1, height: 1))
        #expect(plan.pixels == PixelSize(width: 2, height: 2))
    }

    // MARK: Backing-store limit

    @Test("Backing store may reach but not exceed 8192 pixels wide")
    func widthLimit() throws {
        #expect(VirtualScalingPlan.maxBackingDimension == 8192)
        let fiveK = PixelSize(width: 5120, height: 2880)
        // 5120 / 1.25 = 4096 pt → exactly 8192 px.
        let atLimit = try #require(make(125, fiveK, refresh: 60))
        #expect(atLimit.pixels == PixelSize(width: 8192, height: 4608))
        // 5120 / 1.2 = 4266.67 → 4267 pt → 8534 px.
        #expect(make(120, fiveK, refresh: 60) == nil)
    }

    @Test("An 8K panel only fits at the top of the range", arguments: [
        (105, false), (125, false), (150, false), (175, false), (187, false), (188, true), (195, true),
    ])
    func eightK(percent: Int, fits: Bool) {
        // 7680 / 1.05 = 7314 pt → 14628 px; 7680 / 1.87 = 4107 pt → 8214 px; 7680 / 1.88 = 4085 pt → 8170 px.
        let result = make(percent, PixelSize(width: 7680, height: 4320), refresh: 60)
        #expect((result != nil) == fits, "\(percent)%: \(String(describing: result?.pixels))")
    }

    @Test("The height is limited too")
    func heightLimit() throws {
        // Portrait 2160 × 5120 at 125%: 1728 × 4096 pt → 3456 × 8192 px, allowed.
        let fits = try #require(make(125, PixelSize(width: 2160, height: 5120), refresh: 60))
        #expect(fits.pixels == PixelSize(width: 3456, height: 8192))
        // 2160 × 5200 at 125%: 1728 × 4160 pt → 8320 px high, rejected although the width is fine.
        #expect(make(125, PixelSize(width: 2160, height: 5200), refresh: 60) == nil)
    }

    // MARK: Sampling and load

    /// (percent, sampling, render load, effective scale) on 3440 × 1440.
    static let ultrawideExpectations: [(Int, Double, Double, Double)] = [
        (125, 1.6, 2.56, 1.25),
        (150, 4586.0 / 3440.0, 8_805_120.0 / 4_953_600.0, 3440.0 / 2293.0),  // 4586 × 1920 px
        (175, 3932.0 / 3440.0, 6_472_072.0 / 4_953_600.0, 3440.0 / 1966.0),  // 3932 × 1646 px
    ]

    @Test("Sampling, render load and effective scale on 3440 × 1440", arguments: ultrawideExpectations)
    func ultrawideSampling(percent: Int, sampling: Double, load: Double, scale: Double) throws {
        let plan = try #require(make(percent, ultrawide))
        #expect(approximately(plan.sampling, sampling))
        #expect(approximately(plan.renderLoad, load))
        #expect(approximately(plan.effectiveScale, scale))
        #expect(plan.isDownsampled)
        #expect(plan.sampling > 1.14)
    }

    @Test("16:9 sampling: 1080p and 4K at 150% are both rendered at 4/3 of the panel and downsampled",
          arguments: [PixelSize(width: 1920, height: 1080), PixelSize(width: 3840, height: 2160)])
    func sixteenByNineSampling(native: PixelSize) throws {
        let plan = try #require(make(150, native, refresh: 60))
        #expect(approximately(plan.sampling, 4.0 / 3))
        #expect(approximately(plan.renderLoad, 16.0 / 9))
        #expect(approximately(plan.effectiveScale, 1.5))
        #expect(plan.isDownsampled)
    }

    /// The backing store is 2 × native / factor, so sampling is about 2 / factor:
    /// every supported percent (≤ 195) renders at least ~1.026× the panel width.
    @Test("Every supported percent is downsampled, so the softer-text note never appears",
          arguments: [
            PixelSize(width: 3440, height: 1440), PixelSize(width: 1920, height: 1080),
            PixelSize(width: 1366, height: 768), PixelSize(width: 3840, height: 2160),
          ])
    func alwaysDownsampled(native: PixelSize) throws {
        for percent in VirtualScalingPlan.supportedPercents {
            let plan = try #require(make(percent, native, refresh: 60))
            #expect(plan.isDownsampled, "\(percent)% on \(native): sampling \(plan.sampling)")
            #expect(abs(plan.sampling - 2 / plan.target.factor) < 0.01)
            #expect(!plan.tradeOffs.contains { $0.contains("softer") })
        }
    }

    @Test("An upscaled backing store is reported as soft")
    func upscaledBranch() throws {
        // Unreachable through init today; exercise the branch by editing the stored size.
        var plan = try #require(make(150, fullHD, refresh: 60))
        plan.pixels = PixelSize(width: 1280, height: 720)
        #expect(approximately(plan.sampling, 2.0 / 3))
        #expect(!plan.isDownsampled)
        #expect(plan.tradeOffs.contains { $0.contains("softer") })
    }

    @Test("A render exactly the panel's size counts as downsampled")
    func samplingOfOne() throws {
        var plan = try #require(make(150, fullHD, refresh: 60))
        plan.pixels = fullHD
        #expect(plan.sampling == 1)
        #expect(plan.isDownsampled)
    }

    // MARK: Presentation

    @Test("modeInfo describes the virtual display's HiDPI mode")
    func modeInfo() throws {
        let plan = try #require(make(150, ultrawide))
        let mode = plan.modeInfo
        #expect(mode.modeID == -1)
        #expect(mode.logical == PixelSize(width: 2293, height: 960))
        #expect(mode.pixels == PixelSize(width: 4586, height: 1920))
        #expect(mode.refreshRate == 120)
        #expect(mode.flags == [.valid, .safe])
        #expect(!mode.hasNativeFlag)
        #expect(mode.isUsableForDesktopGUI)
        #expect(mode.isHiDPI)
        #expect(mode.scaleFactor == 2)
        #expect(mode.signature == ModeSignature(logical: plan.points, pixels: plan.pixels, refreshRate: 120))
    }

    @Test("Summary")
    func summary() throws {
        let plan = try #require(make(125, ultrawide))
        #expect(plan.summary == "2752 × 1152 pt HiDPI · rendered at 5504 × 2304 · 120 Hz")
        let odd = try #require(make(150, uhd, refresh: 59.94))
        #expect(odd.summary == "2560 × 1440 pt HiDPI · rendered at 5120 × 2880 · 59.94 Hz")
    }

    @Test("Trade-offs name the private API, the run-time dependency, the GPU load and mirroring",
          arguments: [(125, "2.6×"), (150, "1.8×"), (175, "1.3×")])
    func tradeOffs(percent: Int, load: String) throws {
        let notes = try #require(make(percent, ultrawide)).tradeOffs
        #expect(notes.count == 4)
        #expect(notes[0].contains("private macOS API"))
        #expect(notes[1].contains("only while ScaleKit is running"))
        #expect(notes[2] == "The GPU renders \(load) the pixels of the native desktop.")
        #expect(notes[3].contains("mirrored display"))
    }

    // MARK: Codable

    @Test("A plan survives a JSON round trip")
    func planCodable() throws {
        let plan = try #require(make(175, ultrawide))
        let data = try JSONCoding.encoder().encode(plan)
        #expect(try JSONCoding.decoder().decode(VirtualScalingPlan.self, from: data) == plan)
    }
}

@Suite("Virtual scaling preference")
struct VirtualScalingPreferenceTests {
    let preference = VirtualScalingPreference(
        displayKey: Fixtures.asus.key, displayName: "VG34WQML5A", percent: 150, savedAt: Fixtures.fixedDate)

    @Test("Round trip through the app's JSON coding")
    func roundTrip() throws {
        let data = try JSONCoding.encoder().encode(preference)
        let decoded = try JSONCoding.decoder().decode(VirtualScalingPreference.self, from: data)
        #expect(decoded == preference)
        #expect(decoded.savedAt == Fixtures.fixedDate)
    }

    @Test("Round trip through JSONFileStore")
    func fileStore() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let store = JSONFileStore<VirtualScalingPreference>(url: dir.file("virtual-scaling.json"))
        try store.save(preference)
        #expect(try store.load() == preference)
        try store.delete()
        #expect((try? store.load()) == nil)
    }

    @Test("Decodes the on-disk format")
    func onDiskFormat() throws {
        let json = """
            {
              "displayKey" : "4A1B2C3D-0003-4000-8000-ASUSFIXTURE0",
              "displayName" : "VG34WQML5A",
              "percent" : 150,
              "savedAt" : "2027-01-15T08:00:00Z"
            }
            """
        let decoded = try JSONCoding.decoder().decode(VirtualScalingPreference.self, from: Data(json.utf8))
        #expect(decoded == preference)
        let encoded = try #require(String(data: try JSONCoding.encoder().encode(preference), encoding: .utf8))
        #expect(encoded == json)
    }

    @Test("Equality covers every field")
    func equality() {
        var other = preference
        other.percent = 125
        #expect(other != preference)
        other = preference
        other.displayKey = "other"
        #expect(other != preference)
    }
}

@Suite("Virtual trial launch policy")
struct VirtualTrialLaunchPolicyTests {
    private func journal(_ state: TrialJournal.State, pid: Int32) -> TrialJournal {
        let target = DisplayModeInfo(
            modeID: -1, logical: PixelSize(width: 2293, height: 960), pixels: PixelSize(width: 4586, height: 1920),
            refreshRate: 120, flags: [.valid, .safe], isUsableForDesktopGUI: true)
        return TrialJournal(
            trialID: UUID(), state: state, appPID: pid, displayKey: Fixtures.asus.key, displayID: 3,
            displayName: "VG34WQML5A", previous: Fixtures.asus.mode(119), target: target,
            startedAt: Fixtures.fixedDate, deadline: Fixtures.fixedDate.addingTimeInterval(30),
            updatedAt: Fixtures.fixedDate, note: "Virtual display scaling 150%")
    }

    @Test("No journal needs no closing")
    func noJournal() {
        #expect(!VirtualTrialLaunchPolicy.needsClosing(nil, currentPID: 100, isProcessAlive: { _ in false }))
    }

    @Test("A resolved journal is left alone",
          arguments: [TrialJournal.State.kept, .reverted, .revertedBySystem, .revertedByGuard, .abandoned, .superseded])
    func notPending(state: TrialJournal.State) {
        #expect(!VirtualTrialLaunchPolicy.needsClosing(
            journal(state, pid: 42), currentPID: 100, isProcessAlive: { _ in false }))
    }

    @Test("A pending journal written by this process is left alone")
    func samePID() {
        var probed = false
        let result = VirtualTrialLaunchPolicy.needsClosing(
            journal(.pending, pid: 100), currentPID: 100, isProcessAlive: { _ in probed = true; return false })
        #expect(!result)
        #expect(!probed, "the process check is skipped for our own PID")
    }

    @Test("A pending journal whose process is still running is left alone")
    func alivePID() {
        #expect(!VirtualTrialLaunchPolicy.needsClosing(
            journal(.pending, pid: 42), currentPID: 100, isProcessAlive: { $0 == 42 }))
    }

    @Test("A pending journal whose process is gone needs closing")
    func deadPID() {
        var asked: [Int32] = []
        let result = VirtualTrialLaunchPolicy.needsClosing(
            journal(.pending, pid: 42), currentPID: 100, isProcessAlive: { asked.append($0); return false })
        #expect(result)
        #expect(asked == [42])
    }
}

@Suite("Recovery session")
struct RecoverySessionInitTests {
    @MainActor
    @Test("The public memberwise initializer stores every field")
    func publicInit() {
        let id = UUID()
        let previous = Fixtures.asus.mode(119)
        let target = Fixtures.asus.mode(80)
        let verification = ApplyVerification(
            level: .verified, requested: target, observed: target,
            screenScale: .measured(2, source: "test"),
            screenSize: .measured(PixelSize(width: 1720, height: 720), source: "test"),
            secondary: .unavailable("not requested"), notes: [], elapsedSeconds: 0.4)
        let session = RecoveryService.Session(
            id: id, displayID: 3, displayKey: Fixtures.asus.key, displayName: "VG34WQML5A",
            previous: previous, target: target, startedAt: Fixtures.fixedDate,
            deadline: Fixtures.fixedDate.addingTimeInterval(15), verification: verification)
        #expect(session.id == id)
        #expect(session.displayID == 3)
        #expect(session.displayKey == Fixtures.asus.key)
        #expect(session.displayName == "VG34WQML5A")
        #expect(session.previous == previous)
        #expect(session.target == target)
        #expect(session.startedAt == Fixtures.fixedDate)
        #expect(session.deadline.timeIntervalSince(session.startedAt) == 15)
        #expect(session.verification == verification)

        var other = session
        other.deadline = Fixtures.fixedDate
        #expect(other != session)
    }
}
