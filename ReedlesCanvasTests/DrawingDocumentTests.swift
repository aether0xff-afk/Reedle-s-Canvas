import CoreImage
import PencilKit
import SQLite3
import UIKit
import XCTest
@testable import ReedlesCanvas

final class DrawingDocumentTests: XCTestCase {
    private let homeViewport = CGRect(x: 0, y: 0, width: 1024, height: 768)
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    func testThousandStrokesRetainOrderGeometryTimingAndStyleAfterReopening() throws {
        let url = try temporaryDirectory().appendingPathComponent("drawing.pkdrawing")
        let original = PKDrawing(strokes: (0..<1_000).map(makeStroke))
        do {
            let document = DrawingDocument(fileURL: url)
            let canvas = PagedCanvasView()
            document.attach(canvas)
            XCTAssertTrue(document.updateViewport(homeViewport, surfaceOrigin: .zero))
            canvas.drawing = original
            document.drawingDidChange(canvas)
            document.saveNow()
            XCTAssertNil(document.saveError)
        }

        let reopened = DrawingDocument(fileURL: url)
        let restoredCanvas = PKCanvasView()
        reopened.attach(restoredCanvas)
        XCTAssertTrue(reopened.updateViewport(homeViewport, surfaceOrigin: .zero))
        XCTAssertNil(reopened.loadError)
        XCTAssertEqual(reopened.strokeCount, 1_000)
        let strokes = restoredCanvas.drawing.strokes
        XCTAssertEqual(strokes.count, 1_000)
        for (index, pair) in zip(original.strokes, strokes).enumerated() {
            assertEquivalent(pair.0, pair.1, index: index)
        }
    }

    @MainActor
    func testLegacyInkKeepsItsAssignedStrokeIDsAfterSavingAndReopening() throws {
        let url = try temporaryDirectory().appendingPathComponent("drawing.pkdrawing")
        let original = PKDrawing(strokes: [makeStroke(3), makeStroke(8)])
        try original.dataRepresentation().write(to: url, options: .atomic)

        let document = DrawingDocument(fileURL: url)
        let canvas = PKCanvasView()
        document.attach(canvas)
        XCTAssertTrue(document.updateViewport(homeViewport, surfaceOrigin: .zero))
        let ids = document.worldStrokes().map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
        document.saveNow()
        XCTAssertNil(document.saveError)

        let reopened = DrawingDocument(fileURL: url)
        XCTAssertTrue(reopened.updateViewport(homeViewport, surfaceOrigin: .zero))
        XCTAssertEqual(reopened.worldStrokes().map(\.id), ids)
        let nativeInk = reopened.drawing
        XCTAssertEqual(nativeInk.strokes.count, original.strokes.count)
        for (index, pair) in zip(original.strokes, nativeInk.strokes).enumerated() {
            assertEquivalent(pair.0, pair.1, index: index)
        }
    }

    @MainActor
    func testUnreadableDrawingSurvivesAnAttemptedSave() throws {
        let url = try temporaryDirectory().appendingPathComponent("drawing.pkdrawing")
        let original = Data("invalid PencilKit archive".utf8)
        try original.write(to: url)
        let document = DrawingDocument(fileURL: url)
        XCTAssertNotNil(document.loadError)

        let canvas = PKCanvasView()
        document.attach(canvas)
        canvas.drawing = PKDrawing(strokes: [makeStroke(0)])
        document.drawingDidChange(canvas)
        document.saveNow()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testFailedSaveRetainsDrawingAcrossCanvasReplacementAndRetry() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("drawing.pkdrawing")
        let document = DrawingDocument(fileURL: url)
        XCTAssertTrue(document.updateViewport(homeViewport, surfaceOrigin: .zero))
        let databaseURL = directory.appendingPathComponent("drawing.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        // Fail native ink commits without damaging the note. Releasing the lock makes retry possible.
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let stroke = makeStroke(7)
        do {
            let canvas = PKCanvasView()
            document.attach(canvas)
            canvas.drawing = PKDrawing(strokes: [stroke])
            document.drawingDidChange(canvas)
            document.saveNow()
            XCTAssertNotNil(document.saveError)
        }

        let replacement = PKCanvasView()
        document.attach(replacement)
        let retained = try XCTUnwrap(replacement.drawing.strokes.first)
        assertEquivalent(stroke, retained, index: 0)

        XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        document.saveNow()
        XCTAssertNil(document.saveError)
        let reopened = DrawingDocument(fileURL: url)
        XCTAssertTrue(reopened.updateViewport(homeViewport, surfaceOrigin: .zero))
        XCTAssertNil(reopened.loadError)
        XCTAssertEqual(reopened.strokeCount, 1)
        let saved = try XCTUnwrap(reopened.drawing.strokes.first)
        assertEquivalent(stroke, saved, index: 0)
    }

    @MainActor
    func testCompletedInkAutosavesDuringFollowingToolAndCameraUpdates() async throws {
        let url = try temporaryDirectory().appendingPathComponent("drawing.pkdrawing")
        let document = DrawingDocument(fileURL: url)
        let canvas = PagedCanvasView()
        document.attach(canvas)
        XCTAssertTrue(document.updateViewport(homeViewport, surfaceOrigin: .zero))
        canvas.drawing = PKDrawing(strokes: [makeStroke(0)])
        document.drawingDidChange(canvas)
        document.beginToolInteraction()
        for step in 1...10 {
            document.updateCamera(CanvasCamera(origin: CGPoint(x: step, y: step), scale: 1))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let persisted = try NoteStore(url: url.deletingPathExtension().appendingPathExtension("sqlite"))
        XCTAssertEqual(try persisted.metadata().strokeCount, 1)
        document.endToolInteraction()
    }

    @MainActor
    func testLockedSaveAutomaticallyRetriesAndRestoresTheCameraAndLayer() async throws {
        let folder = try temporaryDirectory()
        let url = folder.appendingPathComponent("drawing.pkdrawing")
        let databaseURL = folder.appendingPathComponent("drawing.sqlite")
        let document = DrawingDocument(fileURL: url)
        let canvas = PagedCanvasView()
        document.attach(canvas)
        XCTAssertTrue(document.updateViewport(homeViewport, surfaceOrigin: .zero))
        let camera = CanvasCamera(origin: CGPoint(x: -120, y: 75), scale: 1.75)
        document.updateCamera(camera)
        document.setAILayerVisible(false)

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let stroke = makeStroke(3)
        canvas.drawing = PKDrawing(strokes: [stroke])
        document.drawingDidChange(canvas)
        document.saveNow()
        XCTAssertNotNil(document.saveError)
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)

        for _ in 0..<40 where document.saveError != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(document.saveError)
        let reopened = DrawingDocument(fileURL: url)
        XCTAssertEqual(reopened.restoredCamera, camera)
        XCTAssertFalse(reopened.aiLayerVisible)
        XCTAssertTrue(reopened.updateViewport(homeViewport, surfaceOrigin: .zero))
        XCTAssertEqual(reopened.strokeCount, 1)
        assertEquivalent(stroke, try XCTUnwrap(reopened.drawing.strokes.first), index: 0)
    }

    @MainActor
    func testDeletingAndUndoingAfterPagingTouchOnlyTheirWorldEntities() throws {
        let url = try temporaryDirectory().appendingPathComponent("drawing.pkdrawing")
        let document = DrawingDocument(fileURL: url)
        let canvas = PagedCanvasView()
        document.attach(canvas)
        XCTAssertTrue(document.updateViewport(homeViewport, surfaceOrigin: .zero))
        canvas.drawing = PKDrawing(strokes: [makeStroke(1)])
        document.drawingDidChange(canvas)
        let firstID = try XCTUnwrap(document.worldStrokes().first?.id)
        let origin = CGPoint(x: -100_000_000.25, y: 100_000_000.25)
        let distantViewport = homeViewport.offsetBy(dx: origin.x, dy: origin.y)
        XCTAssertTrue(document.updateViewport(distantViewport, surfaceOrigin: origin))
        XCTAssertEqual(canvas.drawing.strokes.count, 0)
        let farStroke = makeStroke(3)
        canvas.drawing = PKDrawing(strokes: [farStroke])
        document.drawingDidChange(canvas)
        let distant = try XCTUnwrap(document.worldStrokes().first)
        let corner = try XCTUnwrap(distant.points.first?.position)
        let local = try XCTUnwrap(farStroke.path.first).location.applying(farStroke.transform)
        XCTAssertEqual(corner.x, origin.x + local.x, accuracy: 0.001)
        XCTAssertEqual(corner.y, origin.y + local.y, accuracy: 0.001)
        XCTAssertEqual(document.strokeCount, 2)
        canvas.drawing = PKDrawing()
        document.drawingDidChange(canvas)
        XCTAssertEqual(document.strokeCount, 1)
        XCTAssertTrue(document.updateViewport(homeViewport, surfaceOrigin: .zero))
        XCTAssertEqual(document.worldStrokes().map(\.id), [firstID])
        document.undo()
        XCTAssertEqual(document.strokeCount, 2)
        XCTAssertEqual(document.worldStrokes().map(\.id), [firstID])
        document.redo()
        XCTAssertEqual(document.strokeCount, 1)
        document.undo()
        XCTAssertTrue(document.updateViewport(distantViewport, surfaceOrigin: origin))
        XCTAssertEqual(document.worldStrokes().map(\.id), [distant.id])
        let restoredCorner = try XCTUnwrap(document.worldStrokes().first?.points.first?.position)
        XCTAssertEqual(corner.x, restoredCorner.x, accuracy: 0.01)
        XCTAssertEqual(corner.y, restoredCorner.y, accuracy: 0.01)
        document.updateCamera(CanvasCamera(origin: origin, scale: 2))
        document.setAILayerVisible(false)
        document.saveNow()

        let reopened = DrawingDocument(fileURL: url)
        XCTAssertEqual(reopened.strokeCount, 2)
        XCTAssertFalse(reopened.aiLayerVisible)
        XCTAssertEqual(reopened.restoredCamera, CanvasCamera(origin: origin, scale: 2))
        XCTAssertTrue(reopened.updateViewport(distantViewport, surfaceOrigin: origin))
        XCTAssertEqual(reopened.worldStrokes().map(\.id), [distant.id])
    }

    @MainActor
    func testMiddleInsertionReordersOnlyVisibleSlotsAndSupportsUndoOnAnotherPage() throws {
        let url = try temporaryDirectory().appendingPathComponent("drawing.pkdrawing")
        let doc = DrawingDocument(fileURL: url)
        let canvas = PagedCanvasView()
        doc.attach(canvas)
        let far = CGPoint(x: 80_000, y: -60_000)
        func go(_ origin: CGPoint) {
            XCTAssertTrue(doc.updateViewport(homeViewport.offsetBy(dx: origin.x, dy: origin.y), surfaceOrigin: origin))
        }
        func append(_ number: Int) throws -> UUID {
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [makeStroke(number)])
            doc.drawingDidChange(canvas)
            return try XCTUnwrap(doc.worldStrokes().last?.id)
        }

        go(.zero)
        let a = try append(1)
        go(far)
        let hidden = try append(2)
        go(.zero)
        let b = try append(3)
        go(far)
        let top = try append(4)
        doc.saveNow()
        go(.zero)
        let first = try XCTUnwrap(canvas.drawing.strokes.first)
        let last = try XCTUnwrap(canvas.drawing.strokes.last)
        canvas.drawing = PKDrawing(strokes: [last, makeStroke(5), first])
        doc.drawingDidChange(canvas)
        let inserted = try XCTUnwrap(doc.worldStrokes().first { $0.id != a && $0.id != b }?.id)
        go(far)
        XCTAssertEqual(doc.worldStrokes().map(\.id), [hidden, top])
        doc.saveNow()

        let db = try NoteStore(url: url.deletingPathExtension().appendingPathExtension("sqlite"))
        let reordered: [UUID: Int64] = [b: 0, hidden: 1, inserted: 2, a: 3, top: 4]
        XCTAssertEqual(try db.strokeIndices(), reordered)
        doc.undo()
        XCTAssertEqual(try db.strokeIndices(), [a: 0, hidden: 1, b: 2, top: 3])
        XCTAssertEqual(doc.worldStrokes().map(\.id), [hidden, top])
        doc.redo()
        XCTAssertEqual(try db.strokeIndices(), reordered)
        go(.zero)
        XCTAssertEqual(doc.worldStrokes().map(\.id), [b, inserted, a])
    }

    @MainActor
    func testTutorPNGIsLimitedToTheVisibleRegionAndWaitsForPenUp() throws {
        let url = try temporaryDirectory().appendingPathComponent("drawing.pkdrawing")
        let document = DrawingDocument(fileURL: url)
        let canvas = PagedCanvasView()
        document.attach(canvas)
        let distant = CGPoint(x: 5_000, y: -5_000)
        XCTAssertTrue(document.updateViewport(homeViewport.offsetBy(dx: distant.x, dy: distant.y), surfaceOrigin: distant))
        canvas.drawing = PKDrawing(strokes: [makeStroke(45)])
        document.drawingDidChange(canvas)
        let outside = try XCTUnwrap(document.worldStrokes().first?.id)

        XCTAssertTrue(document.updateViewport(homeViewport, surfaceOrigin: .zero))
        document.beginToolInteraction()
        canvas.drawing = PKDrawing(strokes: [makeStroke(50)])
        XCTAssertNil(try document.captureForTutor(manual: false))
        document.endToolInteraction()
        let onScreen = try XCTUnwrap(document.worldStrokes().first?.id)
        let capture = try XCTUnwrap(document.captureForTutor(manual: false))
        XCTAssertTrue(homeViewport.contains(capture.crop))
        XCTAssertLessThanOrEqual(capture.crop.width, 640)
        XCTAssertEqual(capture.context.entityIDs, [onScreen])
        XCTAssertFalse(capture.context.entityIDs.contains(outside))
        XCTAssertEqual(document.strokeCount, 2)
        XCTAssertLessThanOrEqual(capture.png.count, TutorCapture.maximumImageBytes)
        let image = try XCTUnwrap(UIImage(data: capture.png)?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 1_280)

        let recognized = TutorRecognition(kind: .math, transcript: "2+2=5", confidence: 0.95,
                                          targetEntityIds: [onScreen])
        try document.finishTutorObservation(capture, reply: TutorGatewayReply(recognition: recognized,
                                            reason: "Captured", proposal: nil))
        XCTAssertNil(try document.captureForTutor(manual: false))
        let manual = try XCTUnwrap(document.captureForTutor(manual: true))

        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [makeStroke(52)])
        document.drawingDidChange(canvas)
        XCTAssertThrowsError(try document.finishTutorObservation(manual)) { error in
            guard case TutorProposalError.stale = error else { return XCTFail("Expected a stale observation") }
        }
        let next = try XCTUnwrap(document.captureForTutor(manual: false))
        XCTAssertGreaterThan(next.context.inkRevision, capture.context.inkRevision)
        XCTAssertTrue(next.context.entityIDs.contains(onScreen))
        XCTAssertEqual(next.context.entityIDs.count, 2)
        try document.eraseTutorData()
        XCTAssertNil(try document.captureForTutor(manual: false))
        XCTAssertTrue(try document.tutorHistoryForReading().isEmpty)
    }

    @MainActor
    private func makeStroke(_ index: Int) -> PKStroke {
        let isPen = index.isMultiple(of: 2)
        let ink = PKInk(isPen ? .pen : .marker, color: isPen ? .blue : .red)
        let points = (0..<4).map { step -> PKStrokePoint in
            let width = CGFloat(2 + index % 4 + step)
            return PKStrokePoint(
                location: CGPoint(x: CGFloat(step * 3), y: CGFloat(step * step)),
                timeOffset: Double(step) / 8,
                size: CGSize(width: width, height: width),
                opacity: isPen ? 1 : 0.5,
                force: CGFloat(step + 1) / 4,
                azimuth: 0.5,
                altitude: 1
            )
        }
        let creationDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        let path = PKStrokePath(controlPoints: points, creationDate: creationDate)
        let transform = CGAffineTransform(translationX: CGFloat(index % 40 * 20), y: CGFloat(index / 40 * 20))
        return PKStroke(ink: ink, path: path, transform: transform, mask: nil)
    }

    @MainActor
    private func assertEquivalent(_ expected: PKStroke, _ actual: PKStroke, index: Int) {
        let context = "stroke \(index)"
        XCTAssertEqual(expected.ink.inkType, actual.ink.inkType, context)
        let expectedColor = CIColor(color: expected.ink.color)
        let actualColor = CIColor(color: actual.ink.color)
        XCTAssertEqual(expectedColor.red, actualColor.red, accuracy: 0.01, context)
        XCTAssertEqual(expectedColor.green, actualColor.green, accuracy: 0.01, context)
        XCTAssertEqual(expectedColor.blue, actualColor.blue, accuracy: 0.01, context)
        XCTAssertEqual(expectedColor.alpha, actualColor.alpha, accuracy: 0.01, context)
        XCTAssertEqual(expected.path.creationDate.timeIntervalSince(actual.path.creationDate), 0, accuracy: 0.001, context)
        XCTAssertEqual(expected.path.count, actual.path.count, context)
        for (pointIndex, pair) in zip(expected.path, actual.path).enumerated() {
            let (before, after) = pair
            let detail = "\(context), point \(pointIndex)"
            let originalLocation = before.location.applying(expected.transform)
            let restoredLocation = after.location.applying(actual.transform)
            XCTAssertEqual(originalLocation.x, restoredLocation.x, accuracy: 0.01, detail)
            XCTAssertEqual(originalLocation.y, restoredLocation.y, accuracy: 0.01, detail)
            XCTAssertEqual(before.size.width, after.size.width, accuracy: 0.01, detail)
            XCTAssertEqual(before.size.height, after.size.height, accuracy: 0.01, detail)
            XCTAssertEqual(before.timeOffset, after.timeOffset, accuracy: 0.001, detail)
            XCTAssertEqual(before.force, after.force, accuracy: 0.01, detail)
            XCTAssertEqual(before.opacity, after.opacity, accuracy: 0.01, detail)
            XCTAssertEqual(before.azimuth, after.azimuth, accuracy: 0.01, detail)
            XCTAssertEqual(before.altitude, after.altitude, accuracy: 0.01, detail)
        }
    }
}
