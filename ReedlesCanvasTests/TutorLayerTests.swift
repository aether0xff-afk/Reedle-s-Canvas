import Foundation
import SQLite3
import XCTest
#if !os(Linux)
@testable import ReedlesCanvas
#endif

final class TutorLayerTests: XCTestCase {
    private let target = UUID()

    private func context(_ metadata: NoteMetadata) -> TutorContext {
        TutorContext(requestID: UUID(), noteID: metadata.noteID, inkRevision: metadata.inkRevision,
                     entityIDs: [target], policyEpoch: metadata.tutorEpoch)
    }

    private func proposal(_ context: TutorContext, actionID: UUID = UUID(),
                          edit: (inout [String: Any], inout [String: Any]) -> Void = { _, _ in }) throws -> TutorProposal? {
        var action: [String: Any] = [
            "actionId": actionID.uuidString, "type": "write", "targetEntityId": target.uuidString,
            "placementIntent": "near_right", "content": "x^2 + 1"
        ]
        var response: [String: Any] = [
            "schemaVersion": 1, "requestId": context.requestID.uuidString, "noteId": context.noteID.uuidString,
            "observedRevision": context.inkRevision, "decision": "act"
        ]
        edit(&response, &action)
        if response["actions"] == nil { response["actions"] = [action] }
        return try TutorProposal.decode(JSONSerialization.data(withJSONObject: response),
                                        for: context, model: "test", reason: "Check the work")
    }

    private func withNote(_ body: (NoteStore, URL, StoredStroke) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.sqlite")
        let store = try NoteStore(url: url)
        let ink = StoredStroke(id: target, bounds: CGRect(x: 100, y: 100, width: 42, height: 24),
                               zIndex: 0, data: Data([1, 2, 3]))
        try store.commit(upserts: [ink])
        try body(store, url, ink)
    }

    func testDeclaredAuthorityAndBindingAreEnforcedBeforeApproval() throws {
        try withNote { store, _, _ in
            let now = context(try store.metadata())
            XCTAssertThrowsError(try proposal(now) { _, action in action["worldX"] = 400 })
            XCTAssertThrowsError(try proposal(now) { _, action in action["type"] = "delete_user_ink" })
            XCTAssertThrowsError(try proposal(now) { _, action in
                action["targetEntityId"] = UUID().uuidString
            })
            XCTAssertThrowsError(try proposal(now) { reply, _ in reply["noteId"] = UUID().uuidString })
            XCTAssertThrowsError(try proposal(now) { reply, _ in reply["requestId"] = UUID().uuidString })
            XCTAssertThrowsError(try proposal(now) { reply, _ in reply["observedRevision"] = 0 })
            XCTAssertThrowsError(try proposal(now) { reply, action in reply["actions"] = [action, action] })
            XCTAssertThrowsError(try proposal(now) { _, action in
                action["type"] = "draw"
                action["content"] = "load('https://example.invalid/code')"
            })
            XCTAssertNil(try proposal(now) { reply, _ in
                reply["decision"] = "observe_only"
                reply["actions"] = []
            })
            let accepted = try XCTUnwrap(proposal(now))
            XCTAssertEqual(accepted.actions.first?.ink, .math(TutorFormula("x^2 + 1")))
            XCTAssertTrue(try store.tutorAnnotations(anchoredIn: CGRect(x: 0, y: 0, width: 500, height: 500)).isEmpty)
        }
    }

    func testTutorBatchPersistsIsIdempotentAndUndoesWithoutWritingStudentInk() throws {
        try withNote { store, url, ink in
            let actionID = UUID()
            let now = context(try store.metadata())
            let approved = try XCTUnwrap(proposal(now, actionID: actionID) { reply, action in
                let outline: [String: Any] = [
                    "actionId": UUID().uuidString, "type": "draw", "targetEntityId": target.uuidString,
                    "placementIntent": "on_target", "content": "circle"
                ]
                reply["actions"] = [action, outline]
            })
            try store.commit(camera: CanvasCamera(origin: CGPoint(x: 5, y: 8), scale: 2), aiLayerVisible: false)
            XCTAssertTrue(try store.applyTutorProposal(approved))
            XCTAssertFalse(try store.applyTutorProposal(approved))
            let duplicate = try XCTUnwrap(proposal(context(try store.metadata()), actionID: actionID))
            XCTAssertThrowsError(try store.applyTutorProposal(duplicate))
            let reopened = try NoteStore(url: url)
            let annotations = try reopened.tutorAnnotations(anchoredIn: ink.bounds)
            XCTAssertEqual(annotations.count, 2)
            let recorded = try XCTUnwrap(annotations.first)
            XCTAssertEqual(recorded.action.id, actionID)
            XCTAssertEqual(recorded.requestID, now.requestID)
            XCTAssertEqual(recorded.inkRevision, now.inkRevision)
            XCTAssertEqual(recorded.model, "test")
            XCTAssertEqual(recorded.reason, "Check the work")
            XCTAssertEqual(recorded.version, 1)
            XCTAssertEqual(recorded.action.ink, .math(TutorFormula("x^2 + 1")))
            XCTAssertFalse(try reopened.metadata().aiLayerVisible)
            XCTAssertEqual(try reopened.strokes(in: ink.bounds), [ink])
            XCTAssertTrue(try reopened.undoLatestTutorBatch())
            XCTAssertFalse(try reopened.undoLatestTutorBatch())
            XCTAssertFalse(try reopened.applyTutorProposal(approved))
            XCTAssertTrue(try reopened.tutorAnnotations(anchoredIn: ink.bounds).isEmpty)
            XCTAssertEqual(try reopened.strokes(in: ink.bounds), [ink])
            XCTAssertEqual(try reopened.metadata().inkRevision, now.inkRevision)
        }
    }

    func testVersionOneNoteMigratesItsSavedDataAndExportsTutorLayers() throws {
        try withNote { original, url, ink in
            let camera = CanvasCamera(origin: CGPoint(x: -42, y: 9), scale: 3)
            try original.commit(camera: camera, aiLayerVisible: false)
            let before = try original.metadata()
            // Put the database back in the shape version 1 wrote before reopening it.
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
            defer { sqlite3_close(connection) }
            XCTAssertEqual(sqlite3_exec(connection, """
                DROP TABLE note_practice;
                DROP TABLE note_pdf_pages;
                DROP TABLE note_pdfs;
                DROP TABLE note_source_links;
                DROP TABLE tutor_events;
                DROP TABLE tutor_annotations;
                DROP TABLE tutor_batches;
                ALTER TABLE note DROP COLUMN tutor_epoch;
                ALTER TABLE note DROP COLUMN ink_revision;
                PRAGMA user_version=1;
                """, nil, nil, nil), SQLITE_OK)
            let migrated = try NoteStore(url: url)
            let metadata = try migrated.metadata()
            XCTAssertEqual(metadata.noteID, before.noteID)
            XCTAssertEqual(metadata.revision, before.revision)
            XCTAssertEqual(metadata.inkRevision, before.revision)
            XCTAssertEqual(metadata.camera, camera)
            XCTAssertFalse(metadata.aiLayerVisible)
            XCTAssertEqual(try migrated.strokes(in: ink.bounds), [ink])
            let approved = try XCTUnwrap(proposal(context(metadata)))
            XCTAssertTrue(try migrated.applyTutorProposal(approved))
            let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
            try migrated.export(to: backup)
            let snapshot = try NoteStore(url: backup)
            XCTAssertEqual(try snapshot.strokes(in: ink.bounds), [ink])
            XCTAssertEqual(try snapshot.tutorAnnotations(anchoredIn: ink.bounds).first?.requestID, approved.id)
        }
    }

    func testErasureKeepsStudentInkAndPracticeAndRejectsLateTutorWrites() throws {
        try withNote { store, url, ink in
            let old = context(try store.metadata())
            let onScreen = try XCTUnwrap(proposal(old))
            XCTAssertTrue(try store.applyTutorProposal(onScreen))
            let pending = try XCTUnwrap(proposal(context(try store.metadata())))
            let privateTranscript = "tutor-private-transcript-1234-test"
            let originalEvent = TutorRecentEvent(revision: old.inkRevision, kind: .math,
                                                 transcript: privateTranscript, feedback: "맞아요.", isFollowUp: true)
            try store.recordTutorEvent(originalEvent, crop: ink.bounds, for: old)
            XCTAssertEqual(try store.currentTutorFollowUp(), TutorFollowUp(requestID: old.requestID,
                                                                         text: "맞아요.", anchor: ink.bounds))
            let practiced = try store.updatePractice { journal in
                journal.start(skill: .addition, excluding: "2+2=5", frame: ink.bounds.offsetBy(dx: 42, dy: 0))
                _ = journal.revealHint()
            }.journal

            let beforeErase = url.deletingLastPathComponent().appendingPathComponent("before-erase.sqlite")
            try store.export(to: beforeErase)
            let olderBackup = try NoteStore(url: beforeErase)
            XCTAssertEqual(try olderBackup.allRecentTutorEvents(), [originalEvent])
            XCTAssertEqual(try olderBackup.tutorAnnotations(anchoredIn: ink.bounds).first?.requestID, onScreen.id)

            try store.eraseTutorData()
            let reopened = try NoteStore(url: url)
            XCTAssertEqual(try reopened.metadata().tutorEpoch, old.policyEpoch + 1)
            XCTAssertEqual(try reopened.metadata().inkRevision, old.inkRevision)
            XCTAssertEqual(try reopened.strokes(in: ink.bounds), [ink])
            XCTAssertEqual(try reopened.practiceJournal(), practiced)
            XCTAssertTrue(try reopened.allRecentTutorEvents().isEmpty)
            XCTAssertNil(try reopened.currentTutorFollowUp())
            XCTAssertTrue(try reopened.tutorAnnotations(anchoredIn: ink.bounds).isEmpty)
            XCTAssertThrowsError(try reopened.applyTutorProposal(pending))
            XCTAssertThrowsError(try reopened.recordTutorEvent(originalEvent, crop: ink.bounds, for: old))

            let afterErase = url.deletingLastPathComponent().appendingPathComponent("after-erase.sqlite")
            try reopened.export(to: afterErase)
            XCTAssertNil(try Data(contentsOf: afterErase).range(of: Data(privateTranscript.utf8)))
            let newBackup = try NoteStore(url: afterErase)
            XCTAssertTrue(try newBackup.allRecentTutorEvents().isEmpty)
            XCTAssertTrue(try newBackup.tutorAnnotations(anchoredIn: ink.bounds).isEmpty)
            XCTAssertEqual(try newBackup.strokes(in: ink.bounds), [ink])
            XCTAssertEqual(try newBackup.practiceJournal(), practiced)
            XCTAssertEqual(try olderBackup.allRecentTutorEvents(), [originalEvent])
            let fresh = try XCTUnwrap(proposal(context(try reopened.metadata())))
            XCTAssertTrue(try reopened.applyTutorProposal(fresh))
        }
    }

    func testPracticeAnswersAndCountersSurviveReopenAndBackup() throws {
        try withNote { store, url, ink in
            let before = try store.metadata()
            let frame = ink.bounds.offsetBy(dx: 60, dy: 0)
            let initial = try store.updatePractice { $0.start(skill: .multiplication, excluding: nil, frame: frame) }
            let reopened = try NoteStore(url: url)
            let card = try XCTUnwrap(initial.journal.current)
            let submitted = try reopened.updatePractice { $0.submit(String(card.problem.answer)) }
            XCTAssertEqual(submitted.value, .correct)
            XCTAssertTrue(submitted.journal.current?.solved == true)
            XCTAssertEqual(try store.practiceJournal(), submitted.journal)
            XCTAssertEqual(try reopened.metadata().inkRevision, before.inkRevision)
            XCTAssertEqual(try reopened.strokeGeometry(in: ink.bounds), [ink.bounds])
            let backup = url.deletingLastPathComponent().appendingPathComponent("practice-backup.sqlite")
            try reopened.export(to: backup)
            XCTAssertEqual(try NoteStore(url: backup).practiceJournal(), submitted.journal)
        }
    }

    func testPracticeStartsBesideRecentSupportedWorkAndKeepsItsGradeAfterReopen() throws {
        try withNote { store, url, ink in
            let recognized = context(try store.metadata())
            try store.recordTutorEvent(TutorRecentEvent(revision: recognized.inkRevision, kind: .math,
                                                       transcript: "２４ ÷ ６ ＝ ４", feedback: ""),
                                       crop: ink.bounds, for: recognized)
            let note = StoredStroke(id: UUID(), bounds: CGRect(x: 770, y: 95, width: 80, height: 35),
                                    zIndex: 1, data: Data([5]))
            try store.commit(upserts: [note])
            let metadata = try store.metadata()
            let textContext = TutorContext(requestID: UUID(), noteID: metadata.noteID, inkRevision: metadata.inkRevision,
                                           entityIDs: [note.id], policyEpoch: metadata.tutorEpoch)
            try store.recordTutorEvent(TutorRecentEvent(revision: textContext.inkRevision, kind: .text,
                                                       transcript: "수학 숙제", feedback: ""),
                                       crop: note.bounds, for: textContext)

            let viewport = CGRect(x: 0, y: 0, width: 1_100, height: 510)
            let annotation = CGRect(x: 166, y: 33, width: 125, height: 97)
            let journal = try store.startPractice(for: nil, in: viewport, avoiding: [annotation])
            let card = try XCTUnwrap(journal.current)
            XCTAssertEqual(card.problem.skill, .division)
            XCTAssertNotEqual(card.problem.prompt, "24 ÷ 6")
            XCTAssertTrue(viewport.contains(card.frame))
            XCTAssertLessThan(card.frame.maxX, note.bounds.minX)
            XCTAssertFalse(card.frame.intersects(ink.bounds))
            XCTAssertFalse(card.frame.intersects(annotation))

            let revision = try store.metadata().revision
            let reopened = try NoteStore(url: url)
            XCTAssertEqual(try reopened.practiceJournal().current, card)
            let submitted = try reopened.updatePractice { journal in
                XCTAssertTrue(journal.revealHint())
                return journal.submit(String(card.problem.answer))
            }
            XCTAssertEqual(submitted.value, .correct)
            XCTAssertEqual(try store.practiceJournal().current?.solved, true)
            XCTAssertEqual(try store.practiceJournal().statistics[.division]?.assistedSolutions, 1)
            XCTAssertThrowsError(try store.updatePractice(matchingRevision: revision) { journal in
                journal.start(skill: .addition, excluding: nil, frame: card.frame)
            })
            XCTAssertEqual(try store.practiceJournal().current?.id, card.id)
            XCTAssertEqual(try store.strokes(in: viewport), [ink, note])
        }
    }

    func testRecentRecognitionSurvivesReopenAndOnlyReturnsOlderNearbyEvents() throws {
        try withNote { store, url, ink in
            let first = context(try store.metadata())
            let event = TutorRecentEvent(revision: first.inkRevision, kind: .math, transcript: "2+2=5",
                                         feedback: "다시 계산해 볼래?")
            try store.recordTutorEvent(event, crop: ink.bounds, for: first)
            try store.recordTutorEvent(event, crop: ink.bounds, for: first)
            XCTAssertTrue(try store.tutorHistory(near: ink.bounds, before: first.inkRevision).isEmpty)
            let corrected = StoredStroke(id: ink.id, bounds: ink.bounds, zIndex: ink.zIndex, data: Data([4]))
            try store.commit(upserts: [corrected])
            let reopened = try NoteStore(url: url)
            let next = try reopened.metadata().inkRevision
            XCTAssertEqual(try reopened.tutorHistory(near: ink.bounds, before: next), [event])
            XCTAssertTrue(try reopened.tutorHistory(near: ink.bounds.offsetBy(dx: 3000, dy: 0), before: next).isEmpty)
            XCTAssertThrowsError(try reopened.recordTutorEvent(event, crop: ink.bounds, for: first))
            let wrongNote = TutorContext(requestID: UUID(), noteID: UUID(), inkRevision: next, entityIDs: [target])
            XCTAssertThrowsError(try reopened.recordTutorEvent(
                TutorRecentEvent(revision: next, kind: .math, transcript: "2+2=4", feedback: ""),
                crop: ink.bounds, for: wrongNote))
        }
    }

    func testTutorBatchRejectsInkChangedThroughAnotherConnectionAndMovesWithAnchor() throws {
        try withNote { store, url, ink in
            let old = try XCTUnwrap(proposal(context(try store.metadata())))
            let writer = try NoteStore(url: url)
            let moved = StoredStroke(id: ink.id, bounds: ink.bounds.offsetBy(dx: -5000, dy: 4000),
                                     zIndex: ink.zIndex, data: ink.data)
            try writer.commit(upserts: [moved])
            XCTAssertThrowsError(try store.applyTutorProposal(old))
            let fresh = try XCTUnwrap(proposal(context(try writer.metadata())))
            XCTAssertTrue(try store.applyTutorProposal(fresh))
            XCTAssertTrue(try writer.tutorAnnotations(anchoredIn: ink.bounds).isEmpty)
            XCTAssertEqual(try writer.tutorAnnotations(anchoredIn: moved.bounds).first?.action.targetID, moved.id)
            try writer.commit(deleting: [moved.id])
            XCTAssertTrue(try store.tutorAnnotations(anchoredIn: moved.bounds).isEmpty)
        }
    }

    func testPlacementKeepsFarAwayLabelClearOfNeighboringInkAndScalesWithCamera() throws {
        let bounds = CGRect(x: -100_000, y: 100_000, width: 36, height: 26)
        let blocker = CGRect(x: bounds.maxX + 6, y: bounds.minY - 72, width: 130, height: 174)
        let viewport = bounds.insetBy(dx: -230, dy: -134)
        let placement = try XCTUnwrap(TutorPlacement.label(size: CGSize(width: 94, height: 42),
                                                           near: bounds, toward: .nearRight,
                                                           occupancy: [bounds, blocker], inside: viewport))
        XCTAssertFalse(placement.intersects(bounds))
        XCTAssertFalse(placement.intersects(blocker))
        XCTAssertTrue(viewport.contains(placement))
        let camera = CanvasCamera(origin: viewport.origin, scale: 1)
        let anchor = camera.screenPoint(for: bounds.origin)
        let zoom = camera.zoomed(to: 2, around: anchor)
        XCTAssertEqual(zoom.screenPoint(for: bounds.origin), anchor)
        let dx = camera.screenPoint(for: placement.origin).x - anchor.x
        XCTAssertEqual(zoom.screenPoint(for: placement.origin).x - anchor.x, dx * 2)
        XCTAssertNil(TutorPlacement.label(size: CGSize(width: 94, height: 42), near: bounds,
                                          toward: .nearRight, occupancy: [viewport], inside: viewport))
    }

    func testArrowChoosesAnotherSideWhenItsPreferredRouteCrossesInk() throws {
        let anchor = CGRect(x: 90, y: 90, width: 20, height: 20)
        let blocker = CGRect(x: 120, y: 98, width: 2, height: 4)
        let viewport = CGRect(x: 0, y: 0, width: 240, height: 240)
        let action = TutorAction(id: UUID(), kind: .draw, targetID: target, intent: .nearRight, content: "arrow")
        let annotation = TutorAnnotation(requestID: UUID(), inkRevision: 1, model: "test", reason: "",
                                         version: 1, action: action)
        let neighbor = UUID()
        let mark = try XCTUnwrap(TutorMark.layout([annotation], anchors: [target: anchor, neighbor: blocker],
                                                in: viewport) { _ in .zero }.first)
        XCTAssertEqual(mark.leader.count, 2)
        XCTAssertGreaterThan(mark.frame.minY, anchor.maxY)
        XCTAssertFalse(mark.frame.intersects(anchor))

        let translation = CGPoint(x: -5_000, y: 10_000)
        func moved(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: translation.x, dy: translation.y) }
        let afterPan = try XCTUnwrap(TutorMark.layout([annotation], anchors: [target: moved(anchor), neighbor: moved(blocker)],
                                                    in: moved(viewport)) { _ in .zero }.first)
        XCTAssertEqual(afterPan.frame, moved(mark.frame))
        XCTAssertEqual(afterPan.leader, mark.leader.map { CGPoint(x: $0.x + translation.x, y: $0.y + translation.y) })
        XCTAssertTrue(TutorMark.layout([annotation], anchors: [target: anchor, neighbor: viewport],
                                       in: viewport) { _ in .zero }.isEmpty)
    }

    func testDiagonalLeaderAvoidsOnlyInkAlongItsPath() {
        let anchor = CGRect(x: 90, y: 90, width: 20, height: 20)
        let frame = CGRect(x: 170, y: 170, width: 24, height: 24)
        let nearCorner = CGRect(x: 119, y: 160, width: 4, height: 4)
        let crossing = CGRect(x: 140, y: 140, width: 4, height: 4)
        XCTAssertEqual(TutorPlacement.leader(from: frame, to: anchor, avoiding: [nearCorner]).count, 2)
        XCTAssertTrue(TutorPlacement.leader(from: frame, to: anchor, avoiding: [crossing]).isEmpty)
    }

    func testTallLabelFitsBesideAnAnchorNearTheUpperEdge() throws {
        let region = CGRect(x: 0, y: 0, width: 330, height: 245)
        let anchor = CGRect(x: 120, y: 6, width: 20, height: 20)
        let label = try XCTUnwrap(TutorPlacement.label(size: CGSize(width: 98, height: 231), near: anchor,
                                                       toward: .nearRight, occupancy: [anchor], inside: region))
        XCTAssertTrue(region.contains(label))
        XCTAssertEqual(label.minY, region.minY)
        XCTAssertGreaterThan(label.minX, anchor.maxX)
    }

    func testRevealFollowsTheApprovedOrderAndPastMarksStayVisible() throws {
        try withNote { store, _, ink in
            let current = try XCTUnwrap(proposal(context(try store.metadata())) { reply, action in
                var underline = action
                underline["actionId"] = UUID().uuidString
                underline["type"] = "draw"
                underline["content"] = "underline"
                reply["actions"] = [action, underline]
            })
            XCTAssertTrue(try store.applyTutorProposal(current))
            let bounds = ink.bounds.insetBy(dx: -180, dy: -140)
            let marks = TutorMark.layout(try store.tutorAnnotations(anchoredIn: bounds), anchors: [target: ink.bounds],
                                         in: bounds) { _ in CGSize(width: 54, height: 28) }
            XCTAssertEqual(marks.map(\.id), current.actions.map(\.id))
            let sequence = TutorRevealSequence(marks: marks, requestID: current.id)
            let first = current.actions[0].id, second = current.actions[1].id
            XCTAssertEqual(sequence.progress(for: first, elapsed: sequence.duration / 4), 0.5, accuracy: 0.001)
            XCTAssertEqual(sequence.progress(for: second, elapsed: sequence.duration / 4), 0)
            XCTAssertEqual(sequence.progress(for: first, elapsed: sequence.duration * 0.75), 1)
            XCTAssertEqual(sequence.progress(for: second, elapsed: sequence.duration * 0.75), 0.5, accuracy: 0.001)
            XCTAssertEqual(sequence.progress(for: second, elapsed: sequence.duration), 1)
            XCTAssertEqual(sequence.progress(for: UUID(), elapsed: 0), 1)
        }
    }
}

#if os(Linux)
@main
private enum TutorLayerTestRunner {
    static func main() {
        XCTMain([testCase([
            ("testDeclaredAuthorityAndBindingAreEnforcedBeforeApproval", TutorLayerTests.testDeclaredAuthorityAndBindingAreEnforcedBeforeApproval),
            ("testTutorBatchPersistsIsIdempotentAndUndoesWithoutWritingStudentInk", TutorLayerTests.testTutorBatchPersistsIsIdempotentAndUndoesWithoutWritingStudentInk),
            ("testVersionOneNoteMigratesItsSavedDataAndExportsTutorLayers", TutorLayerTests.testVersionOneNoteMigratesItsSavedDataAndExportsTutorLayers),
            ("testErasureKeepsStudentInkAndPracticeAndRejectsLateTutorWrites", TutorLayerTests.testErasureKeepsStudentInkAndPracticeAndRejectsLateTutorWrites),
            ("testPracticeAnswersAndCountersSurviveReopenAndBackup", TutorLayerTests.testPracticeAnswersAndCountersSurviveReopenAndBackup),
            ("testPracticeStartsBesideRecentSupportedWorkAndKeepsItsGradeAfterReopen", TutorLayerTests.testPracticeStartsBesideRecentSupportedWorkAndKeepsItsGradeAfterReopen),
            ("testRecentRecognitionSurvivesReopenAndOnlyReturnsOlderNearbyEvents", TutorLayerTests.testRecentRecognitionSurvivesReopenAndOnlyReturnsOlderNearbyEvents),
            ("testTutorBatchRejectsInkChangedThroughAnotherConnectionAndMovesWithAnchor", TutorLayerTests.testTutorBatchRejectsInkChangedThroughAnotherConnectionAndMovesWithAnchor),
            ("testPlacementKeepsFarAwayLabelClearOfNeighboringInkAndScalesWithCamera", TutorLayerTests.testPlacementKeepsFarAwayLabelClearOfNeighboringInkAndScalesWithCamera),
            ("testArrowChoosesAnotherSideWhenItsPreferredRouteCrossesInk", TutorLayerTests.testArrowChoosesAnotherSideWhenItsPreferredRouteCrossesInk),
            ("testDiagonalLeaderAvoidsOnlyInkAlongItsPath", TutorLayerTests.testDiagonalLeaderAvoidsOnlyInkAlongItsPath),
            ("testTallLabelFitsBesideAnAnchorNearTheUpperEdge", TutorLayerTests.testTallLabelFitsBesideAnAnchorNearTheUpperEdge),
            ("testRevealFollowsTheApprovedOrderAndPastMarksStayVisible", TutorLayerTests.testRevealFollowsTheApprovedOrderAndPastMarksStayVisible)
        ])])
    }
}
#endif
