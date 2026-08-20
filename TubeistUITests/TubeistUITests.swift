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
    func testClosingSettingsDiscardsStreamKeyDraft() throws {
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
        app.buttons["Close"].tap()

        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let reopenedKeyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(reopenedKeyField.waitForExistence(timeout: 3))
        XCTAssertEqual(reopenedKeyField.value as? String, "YouTube HLS Stream Key")
    }

    @MainActor
    func testInvalidManualKeyShowsAnActionableApplyError() throws {
        let app = launchForUITesting()
        app.buttons["Settings"].tap()
        let keyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("invalid/key")
        app.buttons["Apply"].tap()

        XCTAssertTrue(app.alerts["Could Not Apply Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The YouTube HLS ingestion endpoint is invalid"].exists)
        app.alerts["Could Not Apply Settings"].buttons["OK"].tap()
        XCTAssertTrue(keyField.exists)
    }

    @MainActor
    func testApplyingAValidManualKeyPersistsTheDraft() throws {
        let app = launchForUITesting()
        let settings = app.buttons["Settings"]
        settings.tap()
        let keyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("abcd-efgh-1234")
        app.buttons["Apply"].tap()

        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let persistedField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(persistedField.waitForExistence(timeout: 3))
        XCTAssertNotEqual(persistedField.value as? String, "YouTube HLS Stream Key")
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
        XCTAssertTrue(app.buttons["Apply"].exists)
        XCTAssertTrue(app.buttons["Close"].exists)
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
