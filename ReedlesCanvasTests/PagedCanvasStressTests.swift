import PencilKit
import UIKit
import XCTest
@testable import ReedlesCanvas

final class PagedCanvasStressTests: XCTestCase {
    private let clusters = 100
    private let strokesPerCluster = 100
    private let viewportSize = CGSize(width: 320, height: 320)

    @MainActor
    func testPagingTenThousandNativeStrokesBetweenDistantClusters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        let ids = try seedDatabase(at: directory.appendingPathComponent("drawing.sqlite"))
        let document = DrawingDocument(fileURL: directory.appendingPathComponent("drawing.pkdrawing"))
        let canvas = PagedCanvasView(frame: CGRect(origin: .zero, size: viewportSize))
        document.attach(canvas)
        defer { document.detach(canvas) }
        XCTAssertNil(document.loadError)
        XCTAssertEqual(document.strokeCount, 10_000)

        // Cross both world axes, revisit two old pages and switch rendering origins each time.
        let route = [0, 99, 55, 9, 90, 99, 0]
        for cluster in route {
            let origin = clusterOrigin(cluster)
            let viewport = CGRect(origin: origin, size: viewportSize)
            XCTAssertTrue(document.updateViewport(viewport, surfaceOrigin: origin))
            XCTAssertEqual(document.loadedStrokeCount, strokesPerCluster)
            XCTAssertEqual(canvas.drawing.strokes.count, strokesPerCluster)
            let visible = document.worldStrokes()
            XCTAssertEqual(visible.map(\.id), ids[cluster])
            for (index, stroke) in visible.enumerated() {
                let expected = firstPoint(in: cluster, stroke: index)
                let point = try XCTUnwrap(stroke.points.first).position
                XCTAssertEqual(point.x, expected.x, accuracy: 0.25)
                XCTAssertEqual(point.y, expected.y, accuracy: 0.25)
                XCTAssertEqual(stroke.ink.inkType, index.isMultiple(of: 2) ? .pen : .marker)
            }
        }

        let gap = CGRect(x: 25_000, y: 30_000, width: viewportSize.width, height: viewportSize.height)
        XCTAssertTrue(document.updateViewport(gap, surfaceOrigin: gap.origin))
        XCTAssertEqual(canvas.drawing.strokes.count, 0)
        XCTAssertEqual(document.loadedStrokeCount, 0)
        XCTAssertEqual(document.strokeCount, 10_000)

        // Measure page queries, PKDrawing decoding and assignment to the real canvas.
        // The fixture and geometry assertions are outside the measured interval.
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()], options: options) {
            for cluster in route {
                let origin = self.clusterOrigin(cluster)
                let viewport = CGRect(origin: origin, size: self.viewportSize)
                XCTAssertTrue(document.updateViewport(viewport, surfaceOrigin: origin))
                XCTAssertEqual(document.loadedStrokeCount, self.strokesPerCluster)
            }
            XCTAssertTrue(document.updateViewport(gap, surfaceOrigin: gap.origin))
        }
        XCTAssertNil(document.saveError)
        XCTAssertEqual(document.strokeCount, 10_000)

        let lastCluster = 90
        let lastOrigin = clusterOrigin(lastCluster)
        let savedCamera = CanvasCamera(origin: lastOrigin, scale: 2)
        document.updateCamera(savedCamera)
        try document.flushPendingEdits()
        let reopened = DrawingDocument(fileURL: directory.appendingPathComponent("drawing.pkdrawing"))
        XCTAssertNil(reopened.loadError)
        XCTAssertEqual(reopened.restoredCamera, savedCamera)
        let restoredCanvas = PagedCanvasView(frame: CGRect(origin: .zero, size: viewportSize))
        reopened.attach(restoredCanvas)
        defer { reopened.detach(restoredCanvas) }
        XCTAssertTrue(reopened.updateViewport(CGRect(origin: lastOrigin, size: viewportSize), surfaceOrigin: lastOrigin))
        XCTAssertEqual(restoredCanvas.drawing.strokes.count, strokesPerCluster)
        XCTAssertEqual(reopened.worldStrokes().map(\.id), ids[lastCluster])
        XCTAssertEqual(reopened.strokeCount, 10_000)
    }

    private func clusterOrigin(_ cluster: Int) -> CGPoint {
        CGPoint(x: (cluster % 10 - 5) * 50_000, y: (cluster / 10 - 5) * 60_000)
    }

    private func firstPoint(in cluster: Int, stroke: Int) -> CGPoint {
        let origin = clusterOrigin(cluster)
        return CGPoint(x: origin.x + CGFloat(24 + stroke % 10 * 24),
                       y: origin.y + CGFloat(24 + stroke / 10 * 24))
    }

    @MainActor
    private func seedDatabase(at url: URL) throws -> [[UUID]] {
        let store = try NoteStore(url: url)
        var ids: [[UUID]] = []
        for cluster in 0..<clusters {
            let clusterIDs = try autoreleasepool {
                let batch = (0..<strokesPerCluster).map { index -> StoredStroke in
                    let number = cluster * strokesPerCluster + index
                    let stroke = makeInk(number)
                    let first = firstPoint(in: cluster, stroke: index)
                    let bounds = stroke.renderBounds.offsetBy(dx: first.x, dy: first.y)
                    return StoredStroke(id: UUID(), bounds: bounds, zIndex: Int64(number),
                                        data: PKDrawing(strokes: [stroke]).dataRepresentation())
                }
                // Insert backwards to exercise restoration of painter's order from zIndex.
                try store.commit(upserts: Array(batch.reversed()))
                return batch.map(\.id)
            }
            ids.append(clusterIDs)
        }
        return ids
    }

    @MainActor
    private func makeInk(_ number: Int) -> PKStroke {
        let pen = number.isMultiple(of: 2)
        let ink = PKInk(pen ? .pen : .marker, color: pen ? .blue : .red)
        let points = (0..<6).map { step -> PKStrokePoint in
            let width = CGFloat(2 + number % 3 + step)
            return PKStrokePoint(
                location: CGPoint(x: step * 2, y: step * (number % 4)),
                timeOffset: Double(step) / 60, size: CGSize(width: width, height: width),
                opacity: pen ? 1 : 0.55, force: CGFloat(step + 1) / 6, azimuth: 0.5, altitude: 1
            )
        }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(number))
        let path = PKStrokePath(controlPoints: points, creationDate: date)
        return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
    }
}
