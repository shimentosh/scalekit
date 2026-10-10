import Foundation
import Testing
@testable import ScaleKitCore

@Suite("Refresh-rate comparison")
struct RefreshRateTests {
    @Test("Same rate is unchanged")
    func unchanged() {
        #expect(RefreshComparison.compare(from: 120, to: 120) == .unchanged(120))
        #expect(!RefreshComparison.compare(from: 120, to: 120).isReduction)
    }

    @Test("Rates within half a hertz are the same")
    func tolerance() {
        #expect(RefreshComparison.compare(from: 60, to: 59.94) == .unchanged(59.94))
        #expect(RefreshComparison.compare(from: 120, to: 119.88) == .unchanged(119.88))
        #expect(RefreshRate.isSame(59.94, 60))
        #expect(RefreshRate.isSame(60.5, 60))
        #expect(!RefreshRate.isSame(59.4, 60))
        #expect(!RefreshRate.isSame(59.94, 60, tolerance: 0.01))
    }

    @Test("Higher rate is an increase")
    func increase() {
        let comparison = RefreshComparison.compare(from: 120, to: 250)
        #expect(comparison == .increased(from: 120, to: 250))
        #expect(!comparison.isReduction)
        #expect(comparison.summary == "Rises from 120 Hz to 250 Hz")
    }

    @Test("Lower rate is a reduction")
    func decrease() {
        let comparison = RefreshComparison.compare(from: 120, to: 60)
        #expect(comparison == .decreased(from: 120, to: 60))
        #expect(comparison.isReduction)
        #expect(comparison.summary == "Drops from 120 Hz to 60 Hz")
    }

    @Test("A zero rate on either side is unknown")
    func unknown() {
        #expect(RefreshComparison.compare(from: 0, to: 60) == .unknown)
        #expect(RefreshComparison.compare(from: 60, to: 0) == .unknown)
        #expect(RefreshComparison.compare(from: 0, to: 0) == .unknown)
        #expect(!RefreshComparison.unknown.isReduction)
        #expect(RefreshComparison.unknown.summary == "Refresh rate change cannot be determined")
        #expect(RefreshComparison.unchanged(120).summary == "Stays at 120 Hz")
    }

    @Test("Labels: whole hertz, fractional hertz and unknown")
    func labels() {
        #expect(RefreshRate.label(120) == "120 Hz")
        #expect(RefreshRate.label(119.999) == "120 Hz")
        #expect(RefreshRate.label(59.94) == "59.94 Hz")
        #expect(RefreshRate.label(23.976) == "23.98 Hz")
        #expect(RefreshRate.label(0) == "unknown refresh")
        #expect(RefreshRate.label(-1) == "unknown refresh")
        #expect(makeMode(1, 1920, 1080, 1920, 1080, 0, RawFlags.plain).refreshLabel == "unknown refresh")
    }

    @Test("Mode signatures round refresh to millihertz")
    func signatures() {
        let a = ModeSignature(logical: PixelSize(width: 1720, height: 720), pixels: PixelSize(width: 3440, height: 1440), refreshRate: 120)
        let b = ModeSignature(logical: PixelSize(width: 1720, height: 720), pixels: PixelSize(width: 3440, height: 1440), refreshRate: 120.000_000_1)
        let ntsc = ModeSignature(logical: PixelSize(width: 1920, height: 1080), pixels: PixelSize(width: 1920, height: 1080), refreshRate: 59.94)
        #expect(a == b)
        #expect(a.refreshMilliHz == 120_000)
        #expect(ntsc.refreshMilliHz == 59_940)
        #expect(ntsc.refreshRate == 59.94)
        #expect(a.description == "1720 × 720 HiDPI (3440 × 1440) @ 120 Hz")
        #expect(ntsc.description == "1920 × 1080 @ 59.94 Hz")
    }

    @Test("Refresh comparisons survive a JSON round trip")
    func codable() throws {
        let values: [RefreshComparison] = [.unchanged(120), .increased(from: 60, to: 120), .decreased(from: 120, to: 60), .unknown]
        let data = try JSONCoding.encoder().encode(values)
        #expect(try JSONCoding.decoder().decode([RefreshComparison].self, from: data) == values)
    }
}
