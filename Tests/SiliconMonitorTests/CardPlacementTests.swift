import AppKit
import Testing
@testable import SiliconMonitor

@Suite @MainActor struct CardPlacementTests {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: 330, height: 600)

    func anchor(midX: CGFloat) -> NSRect { NSRect(x: midX - 20, y: 876, width: 40, height: 24) }

    @Test func centersUnderTheStatusItem() {
        let f = CardPlacement.frame(anchor: anchor(midX: 700), screen: screen, size: size)
        #expect(abs(f.midX - 700) < 0.001)
        #expect(abs(f.maxY - (876 - CardStyle.gap)) < 0.001)
        #expect(f.size == size)
    }

    @Test func staysOnScreenAtTheRightEdge() {
        let f = CardPlacement.frame(anchor: anchor(midX: 1430), screen: screen, size: size)
        #expect(abs(f.maxX - (screen.maxX - 8)) < 0.001)
    }

    @Test func staysOnScreenAtTheLeftEdge() {
        let f = CardPlacement.frame(anchor: anchor(midX: 5), screen: screen, size: size)
        #expect(abs(f.minX - (screen.minX + 8)) < 0.001)
    }

    @Test func neverDropsBelowTheBottomMargin() {
        let tall = NSSize(width: 330, height: 2000)
        let f = CardPlacement.frame(anchor: anchor(midX: 700), screen: screen, size: tall)
        #expect(f.minY >= screen.minY + 8)
    }

    @Test func clicksNearTheAnchorOrCardCountAsInside() {
        let rects = [NSRect(x: 100, y: 100, width: 50, height: 50)]
        #expect(CardPlacement.isInsideAny(NSPoint(x: 120, y: 120), rects))
        #expect(CardPlacement.isInsideAny(NSPoint(x: 99, y: 100), rects), "2 pt of slack around the edge")
        #expect(!CardPlacement.isInsideAny(NSPoint(x: 90, y: 100), rects))
        #expect(!CardPlacement.isInsideAny(NSPoint(x: 120, y: 120), []))
    }
}
