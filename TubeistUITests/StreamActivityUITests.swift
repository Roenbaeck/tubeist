import XCTest

final class StreamActivityUITests: XCTestCase {
    @MainActor
    func testWatchLayoutShowsMetricsAndFinishingWithoutStartingAStream() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-live-activity-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Live Activity simulator"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["12.8 Mbps"].exists)
        XCTAssertTrue(app.staticTexts["72%"].exists)
        XCTAssertTrue(app.staticTexts["Normal"].exists)
        let healthy = XCTAttachment(screenshot: app.screenshot())
        healthy.name = "Watch compact Full layout"
        healthy.lifetime = .keepAlways
        add(healthy)

        app.buttons["Problem"].tap()
        XCTAssertTrue(app.staticTexts["Stream problem"].waitForExistence(timeout: 3))
        app.buttons["Finishing"].tap()
        XCTAssertTrue(app.staticTexts["Finalizing output"].waitForExistence(timeout: 3))
        app.buttons["Ended"].tap()
        XCTAssertTrue(app.staticTexts["Session finished"].waitForExistence(timeout: 3))

        app.buttons["New session"].tap()
        app.buttons["Healthy"].tap()
        app.switches["Stale preview"].tap()
        XCTAssertTrue(app.staticTexts["Status unavailable"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["12.8 Mbps"].exists)
        app.switches["Stale preview"].tap()
        app.switches["Full detail"].tap()
        XCTAssertFalse(app.staticTexts["12.8 Mbps"].exists)
        XCTAssertTrue(app.staticTexts["YouTube healthy"].exists)
    }
}
