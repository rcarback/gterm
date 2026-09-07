import XCTest

final class KeyGenerationUITests: XCTestCase {
    func testGeneratePublicKeyAndPersistAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenWelcome", "YES"]
        app.launch()
        app.tabBars.buttons["Keys"].tap()
        app.navigationBars["Keys"].buttons["Add"].tap()
        app.buttons["Generate Key"].tap()
        let name = "UI key " + UUID().uuidString.prefix(8)
        app.textFields["Optional name"].tap()
        app.textFields["Optional name"].typeText(String(name))
        app.buttons["Create"].doubleTap()
        XCTAssertTrue(app.buttons["Copy Public Key"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Share Public Key"].exists)
        let publicLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 ")).firstMatch
        XCTAssertTrue(publicLine.exists)
        let expected = publicLine.label
        XCTAssertFalse(expected.contains("PRIVATE KEY"))
        XCTAssertTrue(expected.hasSuffix(" " + String(name)))
        app.buttons["Copy Public Key"].tap()
        app.buttons["Done"].tap()
        assertClipboard(expected, in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", String(name))).count, 1)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Keys"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", String(name))).firstMatch.tap()
        XCTAssertTrue(app.buttons["Copy Public Key"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 ")).firstMatch.label, expected)
        app.buttons["Share Public Key"].tap()
        let shareCopy = app.cells["Copy"].firstMatch
        XCTAssertTrue(shareCopy.waitForExistence(timeout: 5))
        shareCopy.tap()
        app.buttons["Done"].tap()
        assertClipboard(expected, in: app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", String(name))).firstMatch
        row.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete " + String(name)].tap()
        XCTAssertFalse(row.exists)
    }

    func testGenerateCustom8192BitRSAKey() {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenWelcome", "YES"]
        app.launch()
        app.tabBars.buttons["Keys"].tap()
        app.navigationBars["Keys"].buttons["Add"].tap()
        app.buttons["Generate Key"].tap()
        let name = "RSA UI " + UUID().uuidString.prefix(8)
        app.textFields["Optional name"].tap()
        app.textFields["Optional name"].typeText(String(name))
        app.buttons["Algorithm, Ed25519"].tap()
        app.buttons["RSA"].tap()
        let size = app.textFields["RSA size (bits)"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        size.tap()
        size.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1024")
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        size.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "8192")
        XCTAssertTrue(app.buttons["Create"].isEnabled)
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Copy Public Key"].waitForExistence(timeout: 180))
        XCTAssertTrue(app.staticTexts["RSA 8192"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-rsa ")).firstMatch.exists)
        app.buttons["Done"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", String(name))).firstMatch
        row.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete " + String(name)].tap()
        XCTAssertFalse(row.exists)
    }

    private func assertClipboard(_ expected: String, in app: XCUIApplication) {
        app.navigationBars["Keys"].buttons["Add"].tap()
        app.buttons["Enter Text"].tap()
        app.buttons["Paste"].tap()
        XCTAssertEqual(app.textViews.firstMatch.value as? String, expected)
        app.buttons["Cancel"].tap()
    }

}
