import CoreImage
import PencilKit
import UIKit
import XCTest
@testable import ReedlesCanvas

final class DrawingDocumentTests: XCTestCase {
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
            let canvas = PKCanvasView()
            document.attach(canvas)
            canvas.drawing = original
            document.drawingDidChange(canvas)
            document.saveNow()
            XCTAssertNil(document.saveError)
        }

        let reopened = DrawingDocument(fileURL: url)
        let restoredCanvas = PKCanvasView()
        reopened.attach(restoredCanvas)
        XCTAssertNil(reopened.loadError)
        XCTAssertEqual(reopened.strokeCount, 1_000)
        let strokes = restoredCanvas.drawing.strokes
        XCTAssertEqual(strokes.count, 1_000)
        for (index, pair) in zip(original.strokes, strokes).enumerated() {
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
        let directory = try temporaryDirectory().appendingPathComponent("missing", isDirectory: true)
        let url = directory.appendingPathComponent("drawing.pkdrawing")
        let document = DrawingDocument(fileURL: url)
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

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        document.saveNow()
        XCTAssertNil(document.saveError)
        let reopened = DrawingDocument(fileURL: url)
        XCTAssertNil(reopened.loadError)
        XCTAssertEqual(reopened.strokeCount, 1)
        let saved = try XCTUnwrap(reopened.drawing.strokes.first)
        assertEquivalent(stroke, saved, index: 0)
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
