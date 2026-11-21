import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import ReedlesCanvas

final class TutorAnimationTests: XCTestCase {
    @MainActor
    func testPathsAndGlyphsRevealInOrderAndPencilResumesWithoutPartialObjects() async throws {
        let stage = try AnimationStage()
        defer { stage.close() }
        let calibration = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 100)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
            TutorInkColor.blue.color.setFill()
            context.fill(CGRect(x: 12, y: 6, width: 16, height: 8))
        }
        XCTAssertGreaterThan(try stage.bluePixels(in: calibration, region: CGRect(x: 12, y: 6, width: 16, height: 8)), 0)
        XCTAssertEqual(try stage.bluePixels(in: calibration, region: CGRect(x: 12, y: 86, width: 16, height: 8)), 0)
        try await stage.settle()
        XCTAssertEqual(try stage.bluePixels(in: stage.snapshot()), 0)
        let original = try stage.studentRecords()
        try stage.approve()
        let marks = stage.document.tutorMarks
        XCTAssertEqual(marks.count, 4)
        let reference = stage.completeImage()
        try await Task.sleep(for: .milliseconds(110))
        let pathFrame = try stage.snapshot()
        XCTAssertGreaterThan(try stage.bluePixels(in: pathFrame, region: marks[0].frame), 0)
        XCTAssertLessThan(try stage.bluePixels(in: pathFrame, region: marks[0].frame),
                          try stage.bluePixels(in: reference, region: marks[0].frame))
        XCTAssertEqual(try stage.bluePixels(in: pathFrame, region: marks[1].frame), 0)
        XCTAssertEqual(try stage.bluePixels(in: pathFrame, region: marks[3].frame), 0)

        try await Task.sleep(for: .milliseconds(480))
        let glyphFrame = try stage.snapshot()
        let glyphs = try stage.bluePixels(in: glyphFrame, region: marks[1].frame)
        XCTAssertGreaterThan(glyphs, 0)
        XCTAssertLessThan(glyphs, try stage.bluePixels(in: reference, region: marks[1].frame))
        XCTAssertEqual(try stage.bluePixels(in: glyphFrame, region: marks[3].frame), 0)
        stage.attach(pathFrame, named: "Progressive path")
        stage.attach(glyphFrame, named: "Progressive glyphs")

        stage.document.beginToolInteraction()
        stage.controls.pencilInUse = true
        try await stage.settle()
        try stage.assertComplete(reference)
        stage.document.endToolInteraction()
        stage.controls.pencilInUse = false
        try await stage.settle()
        try stage.assertComplete(reference)
        XCTAssertEqual(try stage.studentRecords(), original)
        XCTAssertEqual(stage.document.tutorMarks, marks)

        let reopened = DrawingDocument(fileURL: stage.noteURL)
        XCTAssertTrue(reopened.updateViewport(stage.viewport, surfaceOrigin: .zero))
        XCTAssertEqual(reopened.tutorMarks, marks)
        XCTAssertEqual(try XCTUnwrap(reopened.store).strokes(in: stage.viewport), original)
        try stage.document.undoTutor()
        try await stage.settle()
        XCTAssertEqual(try stage.bluePixels(in: stage.snapshot()), 0)
        XCTAssertTrue(stage.document.tutorMarks.isEmpty)
        XCTAssertEqual(try stage.studentRecords(), original)
        let afterUndo = DrawingDocument(fileURL: stage.noteURL)
        XCTAssertTrue(afterUndo.updateViewport(stage.viewport, surfaceOrigin: .zero))
        XCTAssertTrue(afterUndo.tutorMarks.isEmpty)
        XCTAssertEqual(afterUndo.strokeCount, 1)
    }

    @MainActor
    func testReducedMotionVisibilityAndNaturalCompletionLeaveWholeMarks() async throws {
        let stage = try AnimationStage()
        defer { stage.close() }
        stage.controls.reduceMotion = true
        try await stage.settle()
        try stage.approve()
        var reference = stage.completeImage()
        try await stage.settle()
        try stage.assertComplete(reference)

        stage.controls.reduceMotion = false
        try await stage.settle()
        try stage.document.undoTutor()
        try stage.approve()
        reference = stage.completeImage()
        try await stage.settle()
        XCTAssertLessThan(try stage.bluePixels(in: stage.snapshot()), try stage.bluePixels(in: reference))
        stage.controls.reduceMotion = true
        try await stage.settle()
        try stage.assertComplete(reference)
        stage.document.setAILayerVisible(false)
        try await stage.settle()
        XCTAssertEqual(try stage.bluePixels(in: stage.snapshot()), 0)
        stage.document.setAILayerVisible(true)
        try await stage.settle()
        try stage.assertComplete(reference)

        stage.controls.reduceMotion = false
        try await stage.settle()
        try stage.document.undoTutor()
        try stage.approve()
        reference = stage.completeImage()
        try await Task.sleep(for: .seconds(2.1))
        try stage.assertComplete(reference)
        XCTAssertEqual(stage.document.tutorMarks.count, 4)
        XCTAssertEqual(stage.document.strokeCount, 1)
    }
}

@MainActor
private final class AnimationControls: ObservableObject {
    @Published var pencilInUse = false
    @Published var reduceMotion = false
}

@MainActor
private struct AnimationHost: View {
    @ObservedObject var controls: AnimationControls
    let document: DrawingDocument
    let projection: CanvasProjection

    var body: some View {
        TutorInkCanvas(document: document, projection: projection, pencilInUse: controls.pencilInUse)
            .environment(\.accessibilityReduceMotion, controls.reduceMotion)
            .background(Color.white)
            .ignoresSafeArea()
    }
}

@MainActor
private final class AnimationStage {
    let controls: AnimationControls
    let document: DrawingDocument
    let noteURL: URL
    let viewport = CGRect(x: 0, y: 0, width: 760, height: 680)
    private let directory: URL
    private let canvas = PagedCanvasView()
    private let host: UIHostingController<AnimationHost>
    private let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    private let oldColor: Any?
    private let oldSize: Any?

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let noteURL = directory.appendingPathComponent("drawing.pkdrawing")
        let document = DrawingDocument(fileURL: noteURL)
        let controls = AnimationControls()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: AnimationHost(controls: controls, document: document,
                                                              projection: CanvasProjection()))
        let window = UIWindow(windowScene: scene)
        self.directory = directory
        self.noteURL = noteURL
        self.document = document
        self.controls = controls
        self.host = host
        self.window = window
        let defaults = UserDefaults.standard
        oldColor = defaults.object(forKey: TutorInkColor.defaultsKey)
        oldSize = defaults.object(forKey: TutorLetterSize.defaultsKey)
        defaults.set(TutorInkColor.blue.rawValue, forKey: TutorInkColor.defaultsKey)
        defaults.set(TutorLetterSize.standard.rawValue, forKey: TutorLetterSize.defaultsKey)
        document.attach(canvas)
        XCTAssertTrue(document.updateViewport(viewport, surfaceOrigin: .zero))
        let points = [CGPoint(x: 280, y: 220), CGPoint(x: 340, y: 240)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        document.drawingDidChange(canvas)
        try document.flushPendingEdits()
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window.frame = viewport
        window.rootViewController = host
        host.view.backgroundColor = .white
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
        UserDefaults.standard.set(oldColor, forKey: TutorInkColor.defaultsKey)
        UserDefaults.standard.set(oldSize, forKey: TutorLetterSize.defaultsKey)
        try? FileManager.default.removeItem(at: directory)
    }

    func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }

    func studentRecords() throws -> [StoredStroke] {
        try XCTUnwrap(document.store).strokes(in: viewport)
    }

    func approve() throws {
        let target = try XCTUnwrap(document.worldStrokes().first?.id)
        let context = try document.makeTutorContext(around: [target])
        let actions = [
            TutorAction(id: UUID(), kind: .draw, targetID: target, intent: .onTarget, content: "circle"),
            TutorAction(id: UUID(), kind: .write, targetID: target, intent: .nearRight,
                        content: "천천히 한 단계씩 다시 계산해 볼까요?"),
            TutorAction(id: UUID(), kind: .write, targetID: target, intent: .below, content: #"\frac{1}{2}+x^{2}"#),
            TutorAction(id: UUID(), kind: .draw, targetID: target, intent: .above, content: "plot:sine")
        ]
        let response = TutorResponse(schemaVersion: 1, requestID: context.requestID, noteID: context.noteID,
                                     observedRevision: context.inkRevision, decision: .act, actions: actions)
        let proposal = try XCTUnwrap(TutorProposal.decode(JSONEncoder().encode(response), for: context,
                                                         model: "animation-test", reason: "계산을 확인합니다."))
        try document.approveTutorProposal(proposal)
    }

    private var renderer: UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: host.view.bounds.size, format: format)
    }

    func snapshot() throws -> UIImage {
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(host.view.bounds)
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        return image
    }

    func completeImage() -> UIImage {
        renderer.image { context in
            UIColor.white.setFill()
            context.fill(host.view.bounds)
            TutorInkCanvas.draw(marks: document.tutorMarks, in: host.view.bounds, context: context.cgContext)
        }
    }

    func bluePixels(in image: UIImage, region: CGRect? = nil) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let crop = (region?.insetBy(dx: -3, dy: -3) ?? CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
            .applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height)).integral
        let cg = try XCTUnwrap(source.cropping(to: crop))
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            var pixels = 0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let r = Int(buffer[offset]), g = Int(buffer[offset + 1]), b = Int(buffer[offset + 2])
                    if b > r + 30 && b > g + 20 { pixels += 1 }
                }
            }
            return pixels
        }
        return count
    }

    func assertComplete(_ reference: UIImage, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(document.tutorMarks.count, 4, file: file, line: line)
        let image = try snapshot()
        for mark in document.tutorMarks {
            let expected = try bluePixels(in: reference, region: mark.frame)
            XCTAssertGreaterThan(expected, 0, file: file, line: line)
            XCTAssertEqual(Double(try bluePixels(in: image, region: mark.frame)), Double(expected),
                           accuracy: max(12, Double(expected) * 0.08), file: file, line: line)
        }
        attach(image, named: "Complete tutor marks")
    }

    func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(attachment) }
    }
}
