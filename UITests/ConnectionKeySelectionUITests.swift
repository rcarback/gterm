import XCTest

final class ConnectionKeySelectionUITests: XCTestCase {
    func testChooseKeyFromConnectionPromptAndRememberIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenWelcome", "YES"]
        app.launch()
        let name = "Picker " + UUID().uuidString.prefix(8)
        app.tabBars.buttons["Keys"].tap()
        app.navigationBars["Keys"].buttons["Add"].tap()
        app.buttons["Generate Key"].tap()
        app.textFields["Optional name"].tap()
        app.textFields["Optional name"].typeText(String(name))
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Copy Public Key"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.tabBars.buttons["Hosts"].tap()
        app.navigationBars["Hosts"].buttons["Add"].tap()
        for (field, value) in [("name (optional)", String(name)), ("host", "127.0.0.1"), ("username", "test")] {
            app.textFields[field].tap()
            app.textFields[field].typeText(value)
        }
        app.buttons["Save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(name))).firstMatch
        row.tap()
        XCTAssertFalse(app.buttons["Connect"].isEnabled)
        app.buttons["Select SSH Key"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", String(name))).firstMatch.tap()
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        app.buttons["Connect"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["Hosts"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("1 key"))
        row.swipeLeft()
        app.buttons["Delete"].tap()
        app.tabBars.buttons["Keys"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", String(name))).firstMatch.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete " + String(name)].tap()
    }
}
