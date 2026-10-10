import Testing
@testable import ScaleKitCore

@Suite("Display arrangement while a monitor is scaled")
struct DisplayArrangementTests {
    let asus = DisplayBounds(x: 0, y: 0, width: 3440, height: 1440)

    @Test("The MSI to the right of the ASUS follows its new right edge at 125%")
    func rightNeighbourOnThisMac() {
        let msi = DisplayBounds(x: 3440, y: 173, width: 1920, height: 1080)
        let result = DisplayArrangement.placements(
            resized: asus, newSize: PixelSize(width: 2752, height: 1152), others: [(1, msi)])
        #expect(result == [.init(displayID: 1, x: 2752, y: 138)])
    }

    @Test("A neighbour below follows the new bottom edge")
    func belowNeighbour() {
        let below = DisplayBounds(x: 1000, y: 1440, width: 1920, height: 1080)
        let result = DisplayArrangement.placements(
            resized: asus, newSize: PixelSize(width: 2752, height: 1152), others: [(7, below)])
        #expect(result == [.init(displayID: 7, x: 800, y: 1152)])
    }

    @Test("A left neighbour keeps its edge; only its vertical offset scales")
    func leftNeighbour() {
        let left = DisplayBounds(x: -1920, y: 200, width: 1920, height: 1080)
        let result = DisplayArrangement.placements(
            resized: asus, newSize: PixelSize(width: 2752, height: 1152), others: [(2, left)])
        #expect(result == [.init(displayID: 2, x: -1920, y: 160)])
    }

    @Test("Neighbours whose origin does not change are not returned")
    func unchanged() {
        let left = DisplayBounds(x: -1920, y: 0, width: 1920, height: 1080)
        let result = DisplayArrangement.placements(
            resized: asus, newSize: PixelSize(width: 2752, height: 1152), others: [(2, left)])
        #expect(result.isEmpty)
    }

    @Test("Same size: nothing moves")
    func sameSize() {
        let msi = DisplayBounds(x: 3440, y: 173, width: 1920, height: 1080)
        #expect(DisplayArrangement.placements(
            resized: asus, newSize: PixelSize(width: 3440, height: 1440), others: [(1, msi)]).isEmpty)
    }
}
