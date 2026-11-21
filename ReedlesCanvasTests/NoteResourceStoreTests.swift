import Foundation
import SQLite3
import XCTest
#if !os(Linux)
@testable import ReedlesCanvas
#endif

final class NoteResourceStoreTests: XCTestCase {
    private let viewport = CGRect(x: -240, y: 100, width: 840, height: 650)

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func materials() -> NotePDFImport {
        let pages = (1...20).map { number in
            NotePDFImport.Page(size: CGSize(width: 600, height: 800), text: "Méthode \(number)\n문제 풀기")
        }
        return NotePDFImport(title: "Practice set", data: Data("%PDF-original-bytes".utf8), pages: pages)
    }

    func testTwentyPagesSearchAndPlacementSurviveReopeningAndBackup() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("note.sqlite")
        let store = try NoteStore(url: url)
        // The nearest strip would cover ink, even though this stroke is below the viewport.
        let ink = StoredStroke(id: UUID(), bounds: CGRect(x: 700, y: 7000, width: 520, height: 45),
                               zIndex: 0, data: Data([1]))
        try store.commit(upserts: [ink])
        let practice = CGRect(x: 1_210, y: 180, width: 290, height: 118)
        _ = try store.updatePractice { $0.start(skill: .addition, excluding: nil, frame: practice) }
        let original = materials()
        let pdf = try store.insertPDF(original, beside: viewport)
        let pages = try store.pdfPages(for: pdf.id)
        XCTAssertEqual(pages.map(\.index), Array(0..<20))
        XCTAssertEqual(Set(pages.map(\.id)).count, 20)
        XCTAssertTrue(pages.allSatisfy { $0.frame.minX > ink.bounds.maxX })
        XCTAssertTrue(pages.allSatisfy { $0.frame.minX > practice.maxX })
        XCTAssertTrue(pages.allSatisfy { $0.frame.size == CGSize(width: 600, height: 800) })
        XCTAssertEqual(pages.first?.frame.minY, viewport.minY)
        for (first, next) in zip(pages, pages.dropFirst()) {
            XCTAssertLessThan(first.frame.maxY, next.frame.minY)
        }
        let target = try XCTUnwrap(pages.last)
        XCTAssertEqual(try store.pdfPages(in: target.frame), [target])
        XCTAssertEqual(try store.resourceBounds(in: target.frame), [target.frame])
        XCTAssertTrue(try store.pdfPages(in: viewport).isEmpty)
        let link = try store.insertSourceLink(title: "Solution notes", address: "https://example.org/solution")
        XCTAssertEqual(try store.metadata().inkRevision, 1)
        XCTAssertEqual(try store.strokes(in: ink.bounds), [ink])
        let pageInk = pages.map { page in
            StoredStroke(id: UUID(), bounds: CGRect(x: page.frame.minX + 80, y: page.frame.minY + 90,
                                                    width: 140, height: 28),
                         zIndex: Int64(page.index + 1), data: Data([UInt8(page.index), 2, 3]))
        }
        try store.commit(upserts: pageInk)
        var annotations: [TutorAction] = []
        for stroke in pageInk {
            let note = try store.metadata()
            let context = TutorContext(requestID: UUID(), noteID: note.noteID, inkRevision: note.inkRevision,
                                       entityIDs: [stroke.id], policyEpoch: note.tutorEpoch)
            let action = TutorAction(id: UUID(), kind: .draw, targetID: stroke.id,
                                     intent: .onTarget, content: "underline")
            let response = TutorResponse(schemaVersion: 1, requestID: context.requestID, noteID: context.noteID,
                                         observedRevision: context.inkRevision, decision: .act, actions: [action])
            let proposal = try XCTUnwrap(TutorProposal.decode(JSONEncoder().encode(response), for: context,
                                                               model: "test", reason: "Review"))
            XCTAssertTrue(try store.applyTutorProposal(proposal))
            annotations.append(action)
        }

        let backupURL = folder.appendingPathComponent("snapshot.sqlite")
        try store.export(to: backupURL)
        let next = try store.insertPDF(original, beside: viewport)
        let nextPage = try XCTUnwrap(store.pdfPages(for: next.id).first)
        XCTAssertGreaterThan(nextPage.frame.minX, target.frame.maxX)
        for reopenedURL in [url, backupURL] {
            let restored = try NoteStore(url: reopenedURL)
            XCTAssertEqual(try restored.pdfPages(for: pdf.id), pages)
            XCTAssertEqual(try restored.pdfData(for: pdf.id), original.data)
            XCTAssertEqual(try restored.sourceLinks(), [link])
            XCTAssertEqual(try restored.pdfMaterials().count, reopenedURL == url ? 2 : 1)
            for (index, page) in pages.enumerated() {
                XCTAssertEqual(try restored.pdfPages(in: page.frame), [page])
                XCTAssertEqual(try restored.strokes(in: page.frame), [pageInk[index]])
                XCTAssertEqual(try restored.tutorAnnotations(anchoredIn: page.frame).map(\.action),
                               [annotations[index]])
            }
        }
        let backup = try NoteStore(url: backupURL)
        let pageMatches = try backup.searchResources("  METHODE  20  문제  ")
        XCTAssertEqual(pageMatches.map(\.id), [target.id])
        XCTAssertTrue(try XCTUnwrap(pageMatches.first).preview.contains("Méthode 20"))
        XCTAssertEqual(try backup.searchResources("practice SET").map(\.id), [pages[0].id])
        XCTAssertEqual(try backup.searchResources("example.org").map(\.id), [link.id])
        XCTAssertTrue(try backup.searchResources("%").isEmpty)
    }

    func testInvalidPageAndNonHTTPSLinkLeaveNoteUnchanged() throws {
        let store = try NoteStore(url: directory().appendingPathComponent("note.sqlite"))
        let before = try store.metadata()
        let original = materials()
        for size in [CGSize.zero, CGSize(width: 0.1, height: 1_000), CGSize(width: CGFloat.infinity, height: 20)] {
            let invalid = NotePDFImport(title: original.title, data: original.data,
                                        pages: original.pages + [.init(size: size, text: "")])
            XCTAssertThrowsError(try store.insertPDF(invalid, beside: viewport))
        }
        for address in ["http://example.org", "https://", "https://username:password@example.org"] {
            XCTAssertThrowsError(try store.insertSourceLink(title: "Invalid", address: address))
        }
        XCTAssertEqual(try store.metadata(), before)
        XCTAssertTrue(try store.pdfMaterials().isEmpty)
        XCTAssertTrue(try store.sourceLinks().isEmpty)
    }

    func testRecognizedInkSearchUsesTranscriptAndKeepsItsWorldBounds() throws {
        let store = try NoteStore(url: directory().appendingPathComponent("note.sqlite"))
        let metadata = try store.metadata()
        let context = TutorContext(requestID: UUID(), noteID: metadata.noteID, inkRevision: metadata.inkRevision,
                                   entityIDs: [])
        let bounds = CGRect(x: -30_000, y: 10_000, width: 80, height: 22)
        let event = TutorRecentEvent(revision: metadata.inkRevision, kind: .math, transcript: "삼각형", feedback: "연습")
        try store.recordTutorEvent(event, crop: bounds, for: context)
        XCTAssertEqual(try store.searchResources("삼각").map(\.id), [context.requestID])
        XCTAssertEqual(try store.searchResources("삼각").first?.frame, bounds)
        XCTAssertTrue(try store.searchResources("연습").isEmpty)
    }

    func testVersionThreeNoteMigratesWithoutChangingInkOrCamera() throws {
        let url = try directory().appendingPathComponent("previous.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let noteID = UUID()
        let strokeID = UUID()
        let setup = sqlite3_exec(connection, """
            PRAGMA application_id = 1380205390;
            PRAGMA user_version = 3;
            CREATE TABLE note(singleton INTEGER PRIMARY KEY, id TEXT NOT NULL, revision INTEGER NOT NULL,
                x REAL NOT NULL, y REAL NOT NULL, scale REAL NOT NULL, ai_visible INTEGER NOT NULL,
                ink_revision INTEGER NOT NULL);
            INSERT INTO note VALUES(1, '\(noteID.uuidString)', 8, -20, 15, 2, 0, 5);
            CREATE TABLE strokes(key INTEGER PRIMARY KEY, uuid TEXT UNIQUE, z INTEGER,
                x0 REAL, x1 REAL, y0 REAL, y1 REAL, ink BLOB);
            CREATE TABLE stroke_bounds(key INTEGER PRIMARY KEY, x0 REAL, x1 REAL, y0 REAL, y1 REAL);
            INSERT INTO strokes VALUES(1, '\(strokeID.uuidString)', 9, -18, -9, 21, 30, X'03');
            INSERT INTO stroke_bounds VALUES(1, -18, -9, 21, 30);
            """, nil, nil, nil)
        XCTAssertEqual(setup, SQLITE_OK)
        sqlite3_close(connection)

        let migrated = try NoteStore(url: url)
        let metadata = try migrated.metadata()
        XCTAssertEqual(metadata.noteID, noteID)
        XCTAssertEqual(metadata.revision, 8)
        XCTAssertEqual(metadata.inkRevision, 5)
        XCTAssertEqual(metadata.camera, CanvasCamera(origin: CGPoint(x: -20, y: 15), scale: 2))
        XCTAssertFalse(metadata.aiLayerVisible)
        XCTAssertEqual(try migrated.strokes(in: CGRect(x: -30, y: 10, width: 30, height: 30)).map(\.id), [strokeID])
        XCTAssertTrue(try migrated.pdfMaterials().isEmpty)
        let saved = try migrated.insertPDF(materials(), beside: viewport)
        XCTAssertEqual(try migrated.pdfPages(for: saved.id).count, 20)
    }
}

#if os(Linux)
@main
private enum NoteResourceStoreTestRunner {
    static func main() {
        XCTMain([testCase([
            ("testTwentyPagesSearchAndPlacementSurviveReopeningAndBackup", NoteResourceStoreTests.testTwentyPagesSearchAndPlacementSurviveReopeningAndBackup),
            ("testInvalidPageAndNonHTTPSLinkLeaveNoteUnchanged", NoteResourceStoreTests.testInvalidPageAndNonHTTPSLinkLeaveNoteUnchanged),
            ("testRecognizedInkSearchUsesTranscriptAndKeepsItsWorldBounds", NoteResourceStoreTests.testRecognizedInkSearchUsesTranscriptAndKeepsItsWorldBounds),
            ("testVersionThreeNoteMigratesWithoutChangingInkOrCamera", NoteResourceStoreTests.testVersionThreeNoteMigratesWithoutChangingInkOrCamera)
        ])])
    }
}
#endif
