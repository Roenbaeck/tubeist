import XCTest

final class StreamActivityUITests: XCTestCase {
    @MainActor
    func testHighlightFitsInCornerWithoutDisplacingWatchMetrics() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-live-activity-demo", "-highlight-layout-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Live Activity simulator"].waitForExistence(timeout: 10))
        let card = app.otherElements["watch-activity-preview"]
        let highlight = app.buttons["activity-save-highlight"]
        let metrics = [app.staticTexts["12.8 Mbps"], app.staticTexts["72%"], app.staticTexts["Normal"]]

        for small in [false, true] {
            if small { app.switches["Small Watch"].tap() }
            XCTAssertEqual(card.frame.width, small ? 152 : 191, accuracy: 1)
            XCTAssertEqual(card.frame.height, small ? 69.5 : 81.5, accuracy: 1)
            let baseline = metrics.map(\.frame)
            app.switches["Highlights"].tap()
            XCTAssertTrue(highlight.waitForExistence(timeout: 3))
            XCTAssertEqual(highlight.label, "Save highlight")
            XCTAssertFalse(app.staticTexts["Save highlight"].exists)
            XCTAssertEqual(highlight.frame.width, 28, accuracy: 1)
            XCTAssertEqual(highlight.frame.height, 28, accuracy: 1)
            XCTAssertEqual(highlight.frame.maxX, card.frame.maxX - 6, accuracy: 1)
            XCTAssertEqual(highlight.frame.minY, card.frame.minY + 4, accuracy: 1)

            for (feedback, value) in [("Ready", "Ready"), ("Saving", "Saving highlight…"),
                                      ("Saved", "Highlight saved"), ("Failed", "Highlight failed")] {
                app.buttons[feedback].tap()
                XCTAssertEqual(highlight.isEnabled, feedback != "Saving")
                XCTAssertEqual(highlight.value as? String, value)
                for (metric, before) in zip(metrics, baseline) {
                    XCTAssertTrue(metric.exists)
                    XCTAssertEqual(metric.frame.minY, before.minY, accuracy: 1)
                    XCTAssertGreaterThanOrEqual(metric.frame.minY, card.frame.minY)
                    XCTAssertLessThanOrEqual(metric.frame.maxY, card.frame.maxY)
                    XCTAssertGreaterThanOrEqual(metric.frame.minX, card.frame.minX)
                    XCTAssertLessThanOrEqual(metric.frame.maxX, card.frame.maxX)
                }
                XCTAssertTrue(app.descendants(matching: .any)["activity-phase"].firstMatch.exists)
                let timer = app.staticTexts["activity-timer"]
                XCTAssertTrue(timer.exists)
                XCTAssertLessThanOrEqual(timer.frame.maxX, highlight.frame.minX - 5)
                XCTAssertTrue(app.staticTexts["YouTube healthy"].exists)
                let screenshot = XCTAttachment(screenshot: card.screenshot())
                screenshot.name = "\(small ? "40mm" : "49mm") Watch card: \(feedback)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            app.switches["Highlights"].tap()
        }

        app.switches["Highlights"].tap()
        app.switches["Stale preview"].tap()
        XCTAssertFalse(highlight.exists)
        app.switches["Stale preview"].tap()
        app.buttons["Ready"].tap()
        app.buttons["Problem"].tap()
        XCTAssertTrue(highlight.exists)
        XCTAssertTrue(app.staticTexts["Stream problem"].exists)
        app.buttons["Saving"].tap()
        app.buttons["Finishing"].tap()
        XCTAssertFalse(highlight.exists)
        let feedback = app.descendants(matching: .any)["activity-highlight-feedback"].firstMatch
        XCTAssertTrue(feedback.exists)
        XCTAssertEqual(feedback.label, "Saving highlight…")
        app.buttons["Saved"].tap()
        app.buttons["Ended"].tap()
        XCTAssertFalse(highlight.exists)
        XCTAssertEqual(feedback.label, "Highlight saved")
    }

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
