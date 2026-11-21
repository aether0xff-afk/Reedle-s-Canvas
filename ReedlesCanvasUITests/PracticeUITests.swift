import XCTest

final class PracticeUITests: XCTestCase {
    @MainActor
    func testSolvingPracticePersistsAcrossRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["REEDLE_UI_TEST_NOTE_ID"] = UUID().uuidString
        app.launch()
        openMenu(in: app)
        app.buttons["practice.new"].tap()
        openPractice(in: app)
        let prompt = app.staticTexts["practice.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let terms = prompt.label.split(separator: "+").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(terms.count, 2)
        let answer = app.textFields["practice.answer"]
        answer.tap()
        answer.typeText(String(terms.reduce(0, +)))
        app.buttons["practice.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.correct"].waitForExistence(timeout: 8))
        app.terminate()

        app.launch()
        openPractice(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["practice.correct"].waitForExistence(timeout: 8))
        app.buttons["닫기"].tap()
        XCTAssertEqual(app.staticTexts["canvas.strokeCount"].label, "0획")
    }

    @MainActor
    private func openMenu(in app: XCUIApplication) {
        let menu = app.buttons["practice.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
    }

    @MainActor
    private func openPractice(in app: XCUIApplication) {
        openMenu(in: app)
        let solve = app.buttons["practice.solve"]
        XCTAssertTrue(solve.waitForExistence(timeout: 8))
        solve.tap()
    }
}
