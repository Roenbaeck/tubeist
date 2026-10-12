import XCTest

final class WatchPagesUITests: XCTestCase {
    @MainActor
    func testExternalTextHasItsOwnPageAndIsRenderedLiterally() {
        let app = launch()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Highlight"].isHittable)
        capture(app, name: "Controls on 40mm Watch")
        app.swipeLeft()
        let text = app.staticTexts["external-status-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.label, "<b>Stage 2</b>\n**Hello**")
        XCTAssertTrue(text.isHittable)
        capture(app, name: "Separate external status page")
        XCTAssertFalse(app.buttons["Stop"].isHittable)
        app.swipeRight()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop"].isHittable)
    }

    @MainActor
    func testDisabledStatusDoesNotAddAPage() {
        let app = launch(["-watch-ui-disabled"])
        app.swipeLeft()
        XCTAssertFalse(app.staticTexts["external-status-text"].exists)
        XCTAssertTrue(app.buttons["Stop"].isHittable)
    }

    @MainActor
    func testStaleTextIsMarkedOutOfDate() {
        let app = launch(["-watch-ui-stale"])
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Out of date"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(_ additionalArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-watch-ui-fixture"] + additionalArguments
        app.launch()
        return app
    }
}
