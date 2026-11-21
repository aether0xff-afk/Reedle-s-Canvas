import Foundation
import SQLite3
import XCTest
#if !os(Linux)
@testable import ReedlesCanvas
#else
import Glibc
#endif

final class NoteStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func stroke(x: CGFloat, z: Int64, id: UUID = UUID()) -> StoredStroke {
        StoredStroke(id: id, bounds: CGRect(x: x, y: -5, width: 0.25, height: 3),
                     zIndex: z, data: Data(repeating: 13, count: 256))
    }

    func testTenThousandStrokesLoadOnlyIntersectingArchivesInDrawOrder() throws {
        let store = try NoteStore(url: directory().appendingPathComponent("note.sqlite"))
        let records = (0..<10_000).map { index in
            stroke(x: -1_000_000_000 + CGFloat(index) * 4.5, z: Int64(10_000 - index))
        }
        let crossing = StoredStroke(id: UUID(), bounds: CGRect(x: -1_000_000_001, y: -4,
                                                               width: 3_000_000_000, height: 1),
                                    zIndex: 0, data: Data([42]))
        try store.commit(upserts: records + [crossing])
        XCTAssertEqual(try store.metadata().strokeCount, 10_001)
        let start = ProcessInfo.processInfo.systemUptime
        for index in stride(from: 0, to: 10_000, by: 50) {
            let rect = records[index].bounds
            let result = try store.strokes(in: rect)
            XCTAssertEqual(result, [crossing, records[index]])
        }
        print("10,001 strokes, 200 viewport queries, 257 bytes of ink per query, " +
              "\(Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)) ms total")
        XCTAssertTrue(try store.strokes(in: CGRect(x: 0, y: 500, width: 10, height: 10)).isEmpty)
    }

    func testMovingAndDeletingUpdatesBoundsAndPersistsCameraAndLayer() throws {
        let url = try directory().appendingPathComponent("note.sqlite")
        let camera = CanvasCamera(origin: CGPoint(x: -400.25, y: 911.75), scale: 1.5)
        let old = stroke(x: -50, z: 0)
        let moved = stroke(x: 9_000, z: 0, id: old.id)
        let other = stroke(x: 9_001, z: 1)
        let id: UUID
        do {
            let store = try NoteStore(url: url)
            id = try store.metadata().noteID
            try store.commit(upserts: [old, other])
            try store.commit(upserts: [moved], deleting: [other.id])
            try store.commit(camera: camera, aiLayerVisible: false)
        }
        let reopened = try NoteStore(url: url)
        let meta = try reopened.metadata()
        XCTAssertEqual(meta.noteID, id)
        XCTAssertEqual(meta.camera, camera)
        XCTAssertEqual(meta.revision, 3)
        XCTAssertFalse(meta.aiLayerVisible)
        XCTAssertEqual(meta.strokeCount, 1)
        XCTAssertEqual(meta.nextZIndex, 1)
        XCTAssertTrue(try reopened.strokes(in: old.bounds).isEmpty)
        XCTAssertTrue(try reopened.strokes(in: other.bounds).isEmpty)
        XCTAssertEqual(try reopened.strokes(in: moved.bounds), [moved])
    }

    func testAppendingMovingAndErasingUseOnlyVisibleOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let old: [UUID: Int64] = [a: 2, b: 7]
        for ids in [[a, b], [a], [b, c], []] {
            let plan = StrokeOrder(edited: ids, oldVisible: old, nextZ: 11) {
                XCTFail("The common edit path should not load another page's order")
                return [:]
            }
            XCTAssertTrue(plan.hiddenShifts.isEmpty)
            XCTAssertEqual(ids.compactMap { plan.visible[$0] }, ids.map { old[$0] ?? 11 })
        }
    }

    func testReorderAndInsertPreserveHiddenSlotsAndUndoAfterReopen() throws {
        let url = try directory().appendingPathComponent("note.sqlite")
        let store = try NoteStore(url: url)
        let left = stroke(x: 0, z: 0), middle = stroke(x: 30, z: 2)
        let hidden = stroke(x: 50_000, z: 1), top = stroke(x: 100_000, z: 3)
        let inserted = stroke(x: 20, z: 10)
        try store.commit(upserts: [left, hidden, middle, top])
        let original = try store.strokeIndices()
        let page: [UUID: Int64] = [left.id: 0, middle.id: 2]

        let insertion = try StrokeOrder(edited: [left.id, inserted.id, middle.id], oldVisible: page,
                                        nextZ: 4, allIndices: store.strokeIndices)
        XCTAssertEqual(insertion.visible, [left.id: 0, inserted.id: 2, middle.id: 3])
        let edited = [middle, inserted, left]
        let plan = try StrokeOrder(edited: edited.map(\.id), oldVisible: page, nextZ: 4,
                                   allIndices: store.strokeIndices)
        XCTAssertEqual(plan.visible, [middle.id: 0, inserted.id: 2, left.id: 3])
        let shifts = Dictionary(uniqueKeysWithValues: plan.hiddenShifts.map { ($0.id, $0.to) })
        XCTAssertEqual(shifts, [top.id: 4])
        let changed = try edited.map { $0.withZIndex(try XCTUnwrap(plan.visible[$0.id])) }
        try store.commit(upserts: changed, reordering: shifts)

        let reopened = try NoteStore(url: url)
        XCTAssertEqual(try reopened.strokes(in: hidden.bounds), [hidden])
        XCTAssertEqual(try reopened.strokes(in: top.bounds), [top.withZIndex(4)])
        let editedOrder = try reopened.strokeIndices()
        try reopened.commit(upserts: [left, middle], deleting: [inserted.id],
                            reordering: Dictionary(uniqueKeysWithValues: plan.hiddenShifts.map { ($0.id, $0.from) }))
        XCTAssertEqual(try reopened.strokeIndices(), original)
        try reopened.commit(upserts: changed, reordering: shifts)
        XCTAssertEqual(try reopened.strokeIndices(), editedOrder)
    }

    func testFailedEditRollsBackDeleteAndEarlierInsertTogether() throws {
        let url = try directory().appendingPathComponent("note.sqlite")
        let store = try NoteStore(url: url)
        let first = stroke(x: -42, z: 0)
        let next = stroke(x: 100, z: 1)
        let invalid = StoredStroke(id: UUID(), bounds: next.bounds, zIndex: 2, data: Data())
        try store.commit(upserts: [first])
        let hidden = stroke(x: 50_000, z: 1)
        try store.commit(upserts: [hidden])
        let beforeEdit = try store.metadata()
        XCTAssertThrowsError(try store.commit(upserts: [next, invalid], deleting: [first.id],
                                              reordering: [hidden.id: 8], aiLayerVisible: false))
        let reopened = try NoteStore(url: url)
        XCTAssertEqual(try reopened.metadata(), beforeEdit)
        XCTAssertEqual(try reopened.strokes(in: hidden.bounds), [hidden])
        XCTAssertEqual(try reopened.strokes(in: first.bounds), [first])
        XCTAssertTrue(try reopened.strokes(in: next.bounds).isEmpty)
    }

    func testExportIsIndependentSnapshotAndCannotOverwriteExistingBackup() throws {
        let folder = try directory()
        let original = try NoteStore(url: folder.appendingPathComponent("note.sqlite"))
        let backup = folder.appendingPathComponent("backup.reedlenote")
        let record = stroke(x: -8.125, z: 9)
        try original.commit(upserts: [record], aiLayerVisible: false)
        let exported = try original.metadata()
        try original.export(to: backup)
        try original.commit(deleting: [record.id], aiLayerVisible: true)
        XCTAssertThrowsError(try original.export(to: backup))
        let copy = try NoteStore(url: backup)
        XCTAssertEqual(try copy.metadata(), exported)
        XCTAssertEqual(try copy.strokes(in: record.bounds), [record])
    }

    func testForeignDatabaseRejectedAndOriginalTableSurvives() throws {
        let url = try directory().appendingPathComponent("other.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE other(id); INSERT INTO other VALUES (19);", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try NoteStore(url: url))
        var read: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT id FROM other", -1, &read, nil), SQLITE_OK)
        defer { sqlite3_finalize(read) }
        XCTAssertEqual(sqlite3_step(read), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(read, 0), 19)
    }

    func testContentionHasABoundedRetryAndPreservesTheWriteForAfterTheLock() throws {
        let url = try directory().appendingPathComponent("note.sqlite")
        let store = try NoteStore(url: url, busyTimeoutMilliseconds: 0)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let record = stroke(x: 48, z: 0)
        var lockFailure: Error?
        XCTAssertThrowsError(try store.commit(upserts: [record])) { lockFailure = $0 }
        let error = try XCTUnwrap(lockFailure)
        var retry = NoteSaveRetry()
        XCTAssertEqual((0..<4).compactMap { _ in retry.nextDelay(after: error) }, [0.16, 0.32, 0.64, 1.28])
        XCTAssertNil(retry.nextDelay(after: error))
        XCTAssertTrue(try store.strokes(in: record.bounds).isEmpty)

        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try store.commit(upserts: [record])
        retry.reset()
        XCTAssertEqual(retry.nextDelay(after: error), 0.16)
        let invalid = StoredStroke(id: UUID(), bounds: record.bounds, zIndex: 1, data: Data())
        XCTAssertThrowsError(try store.commit(upserts: [invalid])) { XCTAssertNil(retry.nextDelay(after: $0)) }
        XCTAssertEqual(try NoteStore(url: url).strokes(in: record.bounds), [record])
    }

    #if os(Linux)
    func testForcedExitRecoversCommittedInkCameraAndTutorLayer() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("note.sqlite")
        let ready = folder.appendingPathComponent("write-in-progress")
        let original = stroke(x: 31, z: 0)
        let far = stroke(x: 28_400, z: 1)
        let camera = CanvasCamera(origin: CGPoint(x: -1_024, y: 780), scale: 2.25)
        let metadata: NoteMetadata
        let requestID: UUID
        let actionID: UUID
        let event: TutorRecentEvent
        do {
            let store = try NoteStore(url: url)
            try store.commit(upserts: [original, far], camera: camera, aiLayerVisible: false)
            let saved = try store.metadata()
            let context = TutorContext(requestID: UUID(), noteID: saved.noteID, inkRevision: saved.inkRevision,
                                       entityIDs: [original.id], policyEpoch: saved.tutorEpoch)
            let action = TutorAction(id: UUID(), kind: .draw, targetID: original.id, intent: .onTarget,
                                     content: "underline")
            let response = TutorResponse(schemaVersion: 1, requestID: context.requestID, noteID: context.noteID,
                                         observedRevision: context.inkRevision, decision: .act, actions: [action])
            let proposal = try XCTUnwrap(TutorProposal.decode(JSONEncoder().encode(response), for: context,
                                                               model: "test", reason: "Check"))
            XCTAssertTrue(try store.applyTutorProposal(proposal))
            event = TutorRecentEvent(revision: context.inkRevision, kind: .math, transcript: "2+2=5",
                                     feedback: "Check", offeredHint: true)
            try store.recordTutorEvent(event, crop: original.bounds, for: context)
            requestID = context.requestID
            actionID = action.id
            metadata = try store.metadata()
        }
        let committedBytes = try Data(contentsOf: url)
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        writer.arguments = ["--interrupt-transaction", url.path, ready.path]
        try writer.run()
        defer {
            if writer.isRunning { _ = kill(writer.processIdentifier, SIGKILL) }
            writer.waitUntilExit()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while writer.isRunning, !FileManager.default.fileExists(atPath: ready.path),
              ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        guard writer.isRunning, FileManager.default.fileExists(atPath: ready.path) else {
            XCTFail("The writer did not reach the uncommitted write.")
            return
        }
        XCTAssertNotEqual(try Data(contentsOf: url), committedBytes)
        let journal = URL(fileURLWithPath: url.path + "-journal")
        XCTAssertGreaterThan(try Data(contentsOf: journal).count, 512)
        XCTAssertEqual(kill(writer.processIdentifier, SIGKILL), 0)
        writer.waitUntilExit()

        XCTAssertEqual(writer.terminationReason, .uncaughtSignal)
        XCTAssertEqual(writer.terminationStatus, SIGKILL)
        let reopened = try NoteStore(url: url)
        XCTAssertEqual(try reopened.metadata(), metadata)
        XCTAssertEqual(try reopened.strokes(in: original.bounds), [original])
        XCTAssertEqual(try reopened.strokes(in: far.bounds), [far])
        let annotation = try XCTUnwrap(reopened.tutorAnnotations(anchoredIn: original.bounds).first)
        XCTAssertEqual(annotation.requestID, requestID)
        XCTAssertEqual(annotation.id, actionID)
        XCTAssertEqual(try reopened.allRecentTutorEvents(), [event])

        let next = stroke(x: 90, z: 2)
        try reopened.commit(upserts: [next])
        let anotherOpen = try NoteStore(url: url)
        XCTAssertEqual(try anotherOpen.metadata().revision, metadata.revision + 1)
        XCTAssertEqual(try anotherOpen.strokes(in: next.bounds), [next])
    }
    #endif
}

#if os(Linux)
@main
private enum NoteStoreTestRunner {
    static func main() {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--interrupt-transaction" {
            var db: OpaquePointer?
            let edits = """
                BEGIN IMMEDIATE;
                DELETE FROM tutor_annotations;
                DELETE FROM tutor_batches;
                DELETE FROM tutor_events;
                DELETE FROM strokes;
                UPDATE note SET revision=19, ink_revision=18, tutor_epoch=5, x=65, y=-22, scale=0.75, ai_visible=1;
                """
            guard sqlite3_open(CommandLine.arguments[2], &db) == SQLITE_OK,
                  sqlite3_exec(db, edits, nil, nil, nil) == SQLITE_OK,
                  sqlite3_db_cacheflush(db) == SQLITE_OK,
                  FileManager.default.createFile(atPath: CommandLine.arguments[3], contents: nil) else { _exit(1) }
            while true { _ = pause() }
        }
        XCTMain([testCase([
            ("testTenThousandStrokesLoadOnlyIntersectingArchivesInDrawOrder", NoteStoreTests.testTenThousandStrokesLoadOnlyIntersectingArchivesInDrawOrder),
            ("testMovingAndDeletingUpdatesBoundsAndPersistsCameraAndLayer", NoteStoreTests.testMovingAndDeletingUpdatesBoundsAndPersistsCameraAndLayer),
            ("testAppendingMovingAndErasingUseOnlyVisibleOrder", NoteStoreTests.testAppendingMovingAndErasingUseOnlyVisibleOrder),
            ("testReorderAndInsertPreserveHiddenSlotsAndUndoAfterReopen", NoteStoreTests.testReorderAndInsertPreserveHiddenSlotsAndUndoAfterReopen),
            ("testFailedEditRollsBackDeleteAndEarlierInsertTogether", NoteStoreTests.testFailedEditRollsBackDeleteAndEarlierInsertTogether),
            ("testExportIsIndependentSnapshotAndCannotOverwriteExistingBackup", NoteStoreTests.testExportIsIndependentSnapshotAndCannotOverwriteExistingBackup),
            ("testForeignDatabaseRejectedAndOriginalTableSurvives", NoteStoreTests.testForeignDatabaseRejectedAndOriginalTableSurvives),
            ("testContentionHasABoundedRetryAndPreservesTheWriteForAfterTheLock", NoteStoreTests.testContentionHasABoundedRetryAndPreservesTheWriteForAfterTheLock),
            ("testForcedExitRecoversCommittedInkCameraAndTutorLayer", NoteStoreTests.testForcedExitRecoversCommittedInkCameraAndTutorLayer)
        ])])
    }
}
#endif
