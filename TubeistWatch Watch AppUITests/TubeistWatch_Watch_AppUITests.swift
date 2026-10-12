import XCTest

final class WatchPagesUITests: XCTestCase {
    @MainActor
    func testFormattedStatusHasItsOwnPage() {
        let app = launch()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Highlight"].isHittable)
        capture(app, name: "Watch controls")
        for _ in 0..<3 {
            swipePage(app, left: true)
            let text = app.staticTexts["external-status-text"]
            XCTAssertTrue(text.waitForExistence(timeout: 5))
            XCTAssertEqual(text.label, "Lund – Hylte\nSets: 1–2\nPoints: 23–21")
            XCTAssertTrue(text.isHittable)
            capture(app, name: "Separate external status page")
            XCTAssertFalse(app.buttons["Stop"].isHittable)
            swipePage(app, left: false)
            XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Stop"].isHittable)
        }
    }

    @MainActor
    func testGenericMarkdownPreservesLinesWithoutLinkActions() {
        let app = launch(["-watch-ui-markdown"])
        swipePage(app, left: true)
        let text = app.staticTexts["external-status-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.label, "Stage 2\nNext speaker\n12:30\nDetails")
        XCTAssertEqual(app.links.count, 0)
        capture(app, name: "Generic Markdown status")
    }

    @MainActor
    func testDisabledStatusDoesNotAddAPage() {
        let app = launch(["-watch-ui-disabled"])
        swipePage(app, left: true)
        XCTAssertFalse(app.staticTexts["external-status-text"].exists)
        XCTAssertTrue(app.buttons["Stop"].isHittable)
    }

    @MainActor
    func testStaleTextIsMarkedOutOfDate() {
        let app = launch(["-watch-ui-stale"])
        swipePage(app, left: true)
        XCTAssertTrue(app.staticTexts["Out of date"].waitForExistence(timeout: 5))
        capture(app, name: "Stale status footer")
    }

    @MainActor
    private func swipePage(_ app: XCUIApplication, left: Bool) {
        // Keep the gesture inside the page. XCTest's default app swipe starts
        // 5 points from the screen edge and can miss paging on hosted Watches.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
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
