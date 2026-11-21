import XCTest

final class TutorExampleUITests: XCTestCase {
    @MainActor
    func testApprovalRelaunchAndTutorOnlyUndo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["REEDLE_UI_TEST_ID"] = UUID().uuidString
        app.launch()

        let mainCount = app.staticTexts["canvas.strokeCount"]
        XCTAssertTrue(mainCount.waitForExistence(timeout: 8))
        let originalMainCount = mainCount.label
        openExample(app)

        tap("tutor.exampleMenu", in: app)
        tap("tutor.exampleReply", in: app)
        XCTAssertTrue(app.staticTexts["2 + 2를 다시 계산해 볼래?"].waitForExistence(timeout: 5))
        tap("tutor.cancel", in: app)
        tap("tutor.exampleMenu", in: app)
        XCTAssertFalse(app.buttons["tutor.annotations"].isEnabled)
        tap("tutor.exampleReply", in: app)
        tap("tutor.apply", in: app)
        showAnnotation(app)

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Approved tutor annotation"
        evidence.lifetime = .keepAlways
        add(evidence)

        app.terminate()
        app.launch()
        openExample(app)
        showAnnotation(app)
        tap("tutor.exampleMenu", in: app)
        tap("tutor.undo", in: app)
        tap("tutor.exampleMenu", in: app)
        XCTAssertFalse(app.buttons["tutor.annotations"].isEnabled)
        // Open and dismiss the preview to close the menu without applying anything.
        tap("tutor.exampleReply", in: app)
        tap("tutor.cancel", in: app)
        XCTAssertEqual(app.staticTexts["tutor.exampleStrokeCount"].label, "7획")
        tap("tutor.closeExample", in: app)
        XCTAssertEqual(mainCount.label, originalMainCount)
    }

    @MainActor
    private func openExample(_ app: XCUIApplication) {
        tap("tutor.menu", in: app)
        tap("tutor.openExample", in: app)
        let count = app.staticTexts["tutor.exampleStrokeCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 8))
        XCTAssertEqual(count.label, "7획")
    }

    @MainActor
    private func showAnnotation(_ app: XCUIApplication) {
        tap("tutor.exampleMenu", in: app)
        tap("tutor.annotations", in: app)
        XCTAssertTrue(app.staticTexts["2 + 2를 다시 계산해 볼래?"].waitForExistence(timeout: 5))
        tap("tutor.closeAnnotations", in: app)
    }

    @MainActor
    private func tap(_ id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"),
                                              object: button)
        guard XCTWaiter.wait(for: [ready], timeout: 8) == .completed else {
            XCTFail("Button did not become available: \(id)", file: file, line: line)
            return
        }
        button.tap()
    }
}
