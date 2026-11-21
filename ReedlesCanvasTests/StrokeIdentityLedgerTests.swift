import Foundation
import XCTest
#if !os(Linux)
@testable import ReedlesCanvas
#endif

final class StrokeIdentityLedgerTests: XCTestCase {
    private func stroke(_ seed: UInt32, x: CGFloat = 0) -> StrokeDescriptor {
        StrokeDescriptor(origin: StrokeOrigin(createdAt: Date(timeIntervalSinceReferenceDate: 42), seed: seed),
                         a: 1, b: 0, c: 0, d: 1, tx: x, ty: 0, pointCount: 3,
                         firstTime: 0, lastTime: 0.125)
    }

    func testRestoredAndNewIDsFollowStrokesThroughReordering() {
        let a = stroke(1), b = stroke(2), c = stroke(3)
        let idA = UUID(), idB = UUID()
        var ledger = StrokeIdentityLedger()
        ledger.restore([a, b], ids: [idA, idB])
        XCTAssertEqual(ledger.reconcile([a, b]), [idA, idB])
        let inserted = ledger.reconcile([b, c, a])
        XCTAssertEqual(inserted[0], idB)
        XCTAssertEqual(inserted[2], idA)
        XCTAssertEqual(Set(inserted).count, 3)
        XCTAssertEqual(ledger.reconcile([a, b, c]), [idA, idB, inserted[1]])
    }

    func testMovingACopyLeavesTheUnchangedCopyWithItsOwnID() {
        let original = stroke(5)
        let copy = stroke(5, x: 10)
        let moved = stroke(5, x: 60)
        var ledger = StrokeIdentityLedger()
        let ids = ledger.reconcile([original, copy])
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(ledger.reconcile([moved, original]), [ids[1], ids[0]])
        XCTAssertEqual(ledger.reconcile([original, copy]), ids)
    }

    func testUndoAndRedoCanRepeatedlyRestoreDeletedIDs() {
        let a = stroke(7), b = stroke(8), c = stroke(9)
        var ledger = StrokeIdentityLedger()
        let ids = ledger.reconcile([a, b, c])
        for _ in 0..<3 {
            XCTAssertEqual(ledger.reconcile([c]), [ids[2]])
            XCTAssertEqual(ledger.reconcile([b, c]), [ids[1], ids[2]])
            XCTAssertEqual(ledger.reconcile([a, b, c]), ids)
        }
    }

    func testRemovalHistoryKeepsTheNewest4096IDs() {
        let strokes = (0..<4_097).map { stroke(UInt32($0)) }
        var ledger = StrokeIdentityLedger()
        let ids = ledger.reconcile(strokes)
        XCTAssertEqual(ledger.reconcile([]), [])
        let restored = ledger.reconcile(strokes)
        XCTAssertNotEqual(restored[0], ids[0])
        XCTAssertEqual(restored.dropFirst(), ids.dropFirst())
        XCTAssertEqual(Set(restored).count, strokes.count)
    }
}

#if os(Linux)
@main
private enum StrokeIdentityTestRunner {
    static func main() {
        XCTMain([testCase([
            ("testRestoredAndNewIDsFollowStrokesThroughReordering", StrokeIdentityLedgerTests.testRestoredAndNewIDsFollowStrokesThroughReordering),
            ("testMovingACopyLeavesTheUnchangedCopyWithItsOwnID", StrokeIdentityLedgerTests.testMovingACopyLeavesTheUnchangedCopyWithItsOwnID),
            ("testUndoAndRedoCanRepeatedlyRestoreDeletedIDs", StrokeIdentityLedgerTests.testUndoAndRedoCanRepeatedlyRestoreDeletedIDs),
            ("testRemovalHistoryKeepsTheNewest4096IDs", StrokeIdentityLedgerTests.testRemovalHistoryKeepsTheNewest4096IDs)
        ])])
    }
}
#endif
