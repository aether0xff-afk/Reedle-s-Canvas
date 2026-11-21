import UIKit
import XCTest

final class CanvasLifecycleUITests: XCTestCase {
    @MainActor
    func testNoteSurvivesRotationBackgroundAndRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let device = XCUIDevice.shared
        app.launchEnvironment["REEDLE_UI_TEST_NOTE_ID"] = UUID().uuidString
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        app.launch()
        let count = app.staticTexts["canvas.strokeCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 8))
        XCTAssertEqual(count.label, "0획")
        try await waitForLayout(of: app, landscape: false)

        app.buttons["practice.menu"].tap()
        app.buttons["practice.new"].tap()
        let original = prompt(in: app)
        device.orientation = .landscapeLeft
        try await waitForLayout(of: app, landscape: true)
        XCTAssertEqual(prompt(in: app), original)

        device.press(.home)
        let stillForeground = NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue)
        let changed = XCTNSPredicateExpectation(predicate: NSCompoundPredicate(notPredicateWithSubpredicate: stillForeground),
                                                object: app)
        await fulfillment(of: [changed], timeout: 8)

        app.activate()
        XCTAssertTrue(count.waitForExistence(timeout: 8))
        XCTAssertEqual(prompt(in: app), original)
        app.terminate()

        app.launch()
        XCTAssertEqual(prompt(in: app), original)
        XCTAssertEqual(count.label, "0획")
    }

    @MainActor
    private func prompt(in app: XCUIApplication) -> String {
        let menu = app.buttons["practice.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let solve = app.buttons["practice.solve"]
        XCTAssertTrue(solve.waitForExistence(timeout: 8))
        solve.tap()
        let prompt = app.staticTexts["practice.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let text = prompt.label
        app.buttons["닫기"].tap()
        return text
    }

    @MainActor
    private func waitForLayout(of app: XCUIApplication, landscape: Bool) async throws {
        for _ in 0..<80 {
            let frame = app.windows.firstMatch.frame
            if !frame.isEmpty && (frame.width > frame.height) == landscape { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The window did not rotate to the requested layout.")
    }
}
