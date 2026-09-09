//
//  TubeistUITests.swift
//  TubeistUITests
//
//  Created by Lars Rönnbäck on 2024-11-10.
//

import XCTest

final class TubeistUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryControlsHaveAccessibleNames() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Battery saving"].exists)
        XCTAssertTrue(app.buttons["Camera selection"].exists)
        XCTAssertTrue(app.buttons["Monitor selection"].exists)
        XCTAssertTrue(app.buttons["Journal"].exists)
        XCTAssertTrue(app.buttons["Start stream"].exists)
        XCTAssertTrue(app.images["Stream health"].exists)
    }

    @MainActor
    func testLandscapeControlsRemainOnScreenAndHittable() throws {
        let app = launchForUITesting()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)

        let controlNames = [
            "Settings",
            "Start stream",
            "Battery saving",
            "Camera selection",
            "Video stabilization",
            "Monitor selection",
            "Style and effects",
            "Focus lock",
            "Exposure lock",
            "White balance lock",
            "Overlays",
            "Journal"
        ]

        for name in controlNames {
            let control = app.buttons[name]
            XCTAssertTrue(control.waitForExistence(timeout: 2), "Missing \(name)")
            XCTAssertTrue(control.isHittable, "\(name) is outside the interactive viewport")
            XCTAssertTrue(
                window.frame.contains(control.frame),
                "\(name) extends beyond the landscape window: \(control.frame)"
            )
        }
    }

    @MainActor
    func testCancellingSettingsDiscardsStreamKeyDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let keyField = app.secureTextFields["YouTube HLS Stream Key"]
        // The stream-key control proves that the Settings sheet is presented.
        // Navigation-bar titles changed element type in iOS 26, so querying the
        // field avoids coupling this behavior test to framework internals.
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("draft-key-1234")
        app.buttons["Cancel"].tap()

        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let reopenedKeyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(reopenedKeyField.waitForExistence(timeout: 3))
        XCTAssertEqual(reopenedKeyField.value as? String, "YouTube HLS Stream Key")
    }

    @MainActor
    func testInvalidManualKeyShowsAnActionableSaveError() throws {
        let app = launchForUITesting()
        app.buttons["Settings"].tap()
        let keyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("invalid/key")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.alerts["Could Not Save Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The YouTube HLS ingestion endpoint is invalid"].exists)
        app.alerts["Could Not Save Settings"].buttons["OK"].tap()
        XCTAssertTrue(keyField.exists)
    }

    @MainActor
    func testSavingAValidManualKeyPersistsTheDraft() throws {
        let app = launchForUITesting()
        let settings = app.buttons["Settings"]
        settings.tap()
        let keyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("abcd-efgh-1234")
        app.buttons["Save"].tap()

        let saveError = app.alerts["Could Not Save Settings"]
        XCTAssertFalse(
            saveError.waitForExistence(timeout: 1),
            "Saving a valid manual key unexpectedly failed: \(saveError.debugDescription)"
        )
        XCTAssertFalse(keyField.exists, "Settings should dismiss after a successful Save")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let persistedField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(persistedField.waitForExistence(timeout: 3))
        XCTAssertNotEqual(persistedField.value as? String, "YouTube HLS Stream Key")
    }

    @MainActor
    func testOverlayOrderCanBeSavedAndCancelled() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = originalOrientation }
        let app = launchForUITesting()
        app.buttons["Settings"].tap()
        let keyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("abcd-efgh-1234\n")

        func scrollTo(_ element: XCUIElement) {
            let form = app.collectionViews.firstMatch
            XCTAssertTrue(form.exists)
            for _ in 0..<25 {
                if element.exists && element.isHittable { return }
                form.swipeUp()
            }
            XCTAssertTrue(element.isHittable, "Could not reach \(element)\n\(app.debugDescription)")
        }

        let suffix = UUID().uuidString.prefix(8)
        let backURL = "http://127.0.0.1:9/back-\(suffix)"
        let frontURL = "http://127.0.0.1:9/front-\(suffix)"
        let urlField = app.textFields["New Overlay URL"]
        for url in [backURL, frontURL] {
            scrollTo(urlField)
            urlField.tap()
            urlField.typeText(url)
            app.buttons["Add overlay"].tap()
            urlField.typeText("\n")
        }

        func openOrder() {
            let reorder = app.buttons["reorder-overlays"]
            scrollTo(reorder)
            reorder.tap()
            XCTAssertTrue(app.navigationBars["Overlay Order"].waitForExistence(timeout: 3))
        }
        func row(_ url: String) -> XCUIElement {
            app.cells.containing(.staticText, identifier: "overlay-order-\(url)").firstMatch
        }
        func moveBelow(_ source: String, _ destination: String) {
            let start = row(source).coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            let end = row(destination).coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9))
            start.press(forDuration: 0.5, thenDragTo: end)
        }

        openOrder()
        XCTAssertLessThan(row(frontURL).frame.minY, row(backURL).frame.minY, "New overlay should start on top")
        moveBelow(frontURL, backURL)
        XCTAssertLessThan(row(backURL).frame.minY, row(frontURL).frame.minY)
        app.buttons["Done"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        openOrder()
        XCTAssertLessThan(row(backURL).frame.minY, row(frontURL).frame.minY, "Save should preserve the new order")
        moveBelow(backURL, frontURL)
        XCTAssertLessThan(row(frontURL).frame.minY, row(backURL).frame.minY)
        app.buttons["Done"].tap()
        app.buttons["Cancel"].tap()

        app.buttons["Settings"].tap()
        openOrder()
        XCTAssertLessThan(row(backURL).frame.minY, row(frontURL).frame.minY, "Cancel should discard the draft order")
        app.buttons["Done"].tap()
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testEssentialControlsRemainReachableAtLargestDynamicTypeSize() throws {
        let app = launchForUITesting(additionalArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        ])

        let settings = app.buttons["Settings"]
        let startStream = app.buttons["Start stream"]
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(startStream.exists)

        settings.tap()
        let keyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    @MainActor
    private func launchForUITesting(
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
