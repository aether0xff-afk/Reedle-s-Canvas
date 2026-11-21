import UIKit
import XCTest

final class CanvasToolbarUITests: XCTestCase {
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
}
