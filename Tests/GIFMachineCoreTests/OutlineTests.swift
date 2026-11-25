import CoreGraphics
import Testing
@testable import GIFMachineCore

struct OutlineTests {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func theLineRunsJustOutsideASection() {
        let path = Outline.path(around: CGRect(x: 100, y: 200, width: 300, height: 400), in: screen, lineWidth: 2)
        #expect(path == CGRect(x: 98, y: 198, width: 304, height: 404))
        // The line's inner edge stays a point clear of the recorded area.
        #expect(path.insetBy(dx: 1, dy: 1).contains(CGRect(x: 99, y: 199, width: 302, height: 402)))
    }

    @Test func atTheScreensEdgeTheLineRunsJustInside() {
        let path = Outline.path(around: screen, in: screen, lineWidth: 2)
        #expect(path == screen.insetBy(dx: 1, dy: 1))
        let corner = Outline.path(around: CGRect(x: 0, y: 500, width: 200, height: 617), in: screen, lineWidth: 2)
        #expect(corner.minX == 1)
        #expect(corner.maxY == 1116)
        #expect(corner.minY == 498)
    }
}
