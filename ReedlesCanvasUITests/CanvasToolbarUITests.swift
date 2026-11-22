import UIKit
import XCTest

final class CanvasToolbarUITests: XCTestCase {
    @MainActor
    func testFastPanAndZoomRestoreTheSavedInkAndTutorViewport() async throws {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["REEDLE_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["REEDLE_UI_TEST_NOTE_ID"] = UUID().uuidString
        app.launch()
        try openExample(app)
        app.buttons["tutor.exampleMenu"].tap()
        app.buttons["tutor.exampleReply"].tap()
        let apply = app.buttons["tutor.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.tap()
        let canvas = try activeCanvas(in: app)
        let baseline = try await settledInk(in: canvas, named: "Before fast pan and zoom")
        XCTAssertGreaterThan(baseline.pixels, 100)
        app.buttons["tutor.exampleViewMenu"].tap()
        app.buttons["현재 위치 기억"].tap()

        // XCTest synthesizes the requested velocities on a best-effort basis.
        // Inspect the actual visible geometry rather than assuming the scale was exact.
        canvas.pinch(withScale: 0.7, velocity: -4)
        let zoomed = try await settledInk(in: canvas, named: "Native pinch zoomed out")
        XCTAssertLessThan(zoomed.bounds.width, baseline.bounds.width * 0.9,
                          "The native pinch must visibly reduce the ink size")
        XCTAssertGreaterThan(zoomed.pixels, 0)
        canvas.pinch(withScale: 2, velocity: 4)
        canvas.swipeLeft(velocity: .fast)
        canvas.swipeUp(velocity: .fast)
        canvas.swipeRight(velocity: .fast)
        canvas.swipeDown(velocity: .fast)
        XCTAssertEqual(app.staticTexts["tutor.exampleStrokeCount"].label, "7획")

        app.buttons["tutor.exampleViewMenu"].tap()
        app.buttons["기억한 위치로"].tap()
        let returned = try await settledInk(in: canvas, named: "Returned after fast native gestures")
        assertSameVisibleInk(baseline, returned)
        let save = try XCTUnwrap(app.buttons.matching(identifier: "canvas.save").allElementsBoundByIndex.first { $0.isHittable })
        save.tap()
        app.terminate()
        app.launch()
        try openExample(app)
        let reopened = try await settledInk(in: activeCanvas(in: app), named: "Relaunched saved gesture viewport")
        assertSameVisibleInk(baseline, reopened)
        XCTAssertEqual(app.staticTexts["tutor.exampleStrokeCount"].label, "7획")
        let data: [String: Any] = ["baseline": baseline.json, "zoomedOut": zoomed.json,
                                  "returned": returned.json, "reopened": reopened.json,
                                  "pinchScalesRequested": [0.7, 2], "pinchVelocitiesRequested": [-4, 4],
                                  "swipes": "left/up/right/down at XCTest fast velocity",
                                  "scope": "simulator gestures and rendered ink; not physical Pencil latency or device frame rate"]
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]),
                                  uniformTypeIdentifier: "public.json")
        proof.name = "Native fast pan zoom and viewport restoration"
        proof.lifetime = .keepAlways
        add(proof)
    }

    @MainActor
    func testNarrowContentKeepsPrimaryControlsInsideAndUsable() {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        for width in [320, 512] {
            let app = XCUIApplication()
            app.launchEnvironment["REEDLE_UI_TEST_NOTE_ID"] = UUID().uuidString
            app.launchEnvironment["REEDLE_UI_TEST_CONTENT_WIDTH"] = String(width)
            app.launch()
            guard app.staticTexts["canvas.strokeCount"].waitForExistence(timeout: 8) else {
                XCTFail("The constrained canvas did not open")
                app.terminate()
                continue
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Canvas toolbar at \(width) points"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            let frame = app.windows.firstMatch.frame
            let left = frame.midX - CGFloat(width) / 2
            let right = frame.midX + CGFloat(width) / 2
            var usable = true
            for id in ["resources.menu", "practice.menu", "tutor.menu", "canvas.save"] {
                let button = app.buttons[id]
                guard button.waitForExistence(timeout: 5) else {
                    XCTFail("Missing \(id) at \(width) points")
                    usable = false
                    continue
                }
                let rect = button.frame
                let inside = rect.minX >= left - 1 && rect.maxX <= right + 1
                XCTAssertTrue(inside, "\(id) extends outside \(width)-point content: \(rect)")
                XCTAssertTrue(button.isHittable, "\(id) is inaccessible at \(width) points")
                XCTAssertGreaterThanOrEqual(rect.width, 43, "\(id) has a compressed touch target")
                XCTAssertGreaterThanOrEqual(rect.height, 43, "\(id) has a compressed touch target")
                usable = usable && inside && button.isHittable
            }
            if usable {
                app.buttons["resources.menu"].tap()
                XCTAssertTrue(app.buttons["PDF 가져오기"].waitForExistence(timeout: 5))
                dismissMenu(app)
                app.buttons["practice.menu"].tap()
                XCTAssertTrue(app.buttons["practice.new"].waitForExistence(timeout: 5))
                dismissMenu(app)
                app.buttons["tutor.menu"].tap()
                XCTAssertTrue(app.buttons["튜터 연결 설정"].waitForExistence(timeout: 5))
                dismissMenu(app)
                app.buttons["canvas.save"].tap()
                XCTAssertEqual(app.staticTexts["canvas.strokeCount"].label, "0획")
            }
            app.terminate()
        }
    }

    @MainActor
    private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
    }

    @MainActor
    private func openExample(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["tutor.menu"].waitForExistence(timeout: 8))
        app.buttons["tutor.menu"].tap()
        app.buttons["tutor.openExample"].tap()
        XCTAssertTrue(app.staticTexts["tutor.exampleStrokeCount"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["tutor.exampleStrokeCount"].label, "7획")
    }

    @MainActor
    private func activeCanvas(in app: XCUIApplication) throws -> XCUIElement {
        let candidates = app.descendants(matching: .any).matching(identifier: "canvas.ink")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 8))
        return try XCTUnwrap(candidates.allElementsBoundByIndex.first { $0.isHittable })
    }

    private struct VisibleInk: Equatable {
        let pixels: Int
        let bounds: CGRect
        var json: [String: Any] {
            ["pixels": pixels, "x": bounds.minX, "y": bounds.minY,
             "width": bounds.width, "height": bounds.height]
        }
    }

    @MainActor
    private func settledInk(in canvas: XCUIElement, named name: String) async throws -> VisibleInk {
        let deadline = Date().addingTimeInterval(15)
        var previous: VisibleInk?
        var stable = 0
        while Date() < deadline {
            let screenshot = canvas.screenshot()
            let ink = try measureInk(screenshot, frame: canvas.frame)
            stable = ink == previous ? stable + 1 : 0
            if stable >= 2 {
                let evidence = XCTAttachment(screenshot: screenshot)
                evidence.name = name
                evidence.lifetime = .keepAlways
                add(evidence)
                return ink
            }
            previous = ink
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("The canvas did not settle after its animation or gesture")
        return try XCTUnwrap(previous)
    }

    private func measureInk(_ screenshot: XCUIScreenshot, frame: CGRect) throws -> VisibleInk {
        let source = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(source.width) / frame.width
        // Exclude the floating system Pencil picker at the bottom of the canvas.
        let crop = CGRect(x: 16 * scale, y: 16 * scale,
                          width: CGFloat(source.width) - 32 * scale,
                          height: CGFloat(source.height) - 196 * scale).integral
        let image = try XCTUnwrap(source.cropping(to: crop))
        let width = max(1, Int(CGFloat(image.width) / scale))
        let height = max(1, Int(CGFloat(image.height) / scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let stats = try bytes.withUnsafeMutableBytes { buffer -> VisibleInk in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let pixels = buffer.bindMemory(to: UInt8.self)
            var count = 0, x0 = width, y0 = height, x1 = 0, y1 = 0
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
                    if (r < 105 && g < 105 && b < 105) || (r < 120 && b > r + 30 && b > g + 10) {
                        count += 1
                        x0 = min(x0, x); y0 = min(y0, y)
                        x1 = max(x1, x); y1 = max(y1, y)
                    }
                }
            }
            let bounds = count > 0 ? CGRect(x: CGFloat(x0), y: CGFloat(y0),
                                          width: CGFloat(x1-x0+1), height: CGFloat(y1-y0+1)) : .zero
            return VisibleInk(pixels: count, bounds: bounds)
        }
        return stats
    }

    private func assertSameVisibleInk(_ expected: VisibleInk, _ actual: VisibleInk,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.bounds.minX, expected.bounds.minX, accuracy: 2, file: file, line: line)
        XCTAssertEqual(actual.bounds.minY, expected.bounds.minY, accuracy: 2, file: file, line: line)
        XCTAssertEqual(actual.bounds.width, expected.bounds.width, accuracy: 3, file: file, line: line)
        XCTAssertEqual(actual.bounds.height, expected.bounds.height, accuracy: 3, file: file, line: line)
        XCTAssertEqual(Double(actual.pixels), Double(expected.pixels), accuracy: Double(expected.pixels) * 0.12,
                       file: file, line: line)
    }
}
