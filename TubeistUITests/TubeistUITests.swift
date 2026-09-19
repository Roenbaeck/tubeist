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
    func testHorizonLevelTogglePersistsAndFollowsPreviewVisibility() throws {
        let app = launchForUITesting(additionalArguments: [
            "-horizon-test-angle", "6", "-Overlays", "[]"
        ])
        let hand = app.buttons["Video stabilization"]
        let toggle = app.switches["horizon-level-toggle"]
        let switchControl = toggle.switches.firstMatch
        let level = app.otherElements["horizon-level"]
        hand.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(toggle.frame.minY, app.buttons["Stabilization Selection"].frame.maxY)
        if toggle.value as? String == "1" { switchControl.tap() }
        XCTAssertFalse(level.exists)
        switchControl.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(level.waitForExistence(timeout: 3))
        XCTAssertEqual(level.value as? String, "6.0°")
        hand.tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 2))

        app.buttons["Monitor selection"].tap()
        XCTAssertTrue(level.waitForExistence(timeout: 3))
        app.buttons["Journal"].tap()
        XCTAssertFalse(level.exists)
        app.buttons["Journal"].tap()
        XCTAssertTrue(level.waitForExistence(timeout: 3))

        app.buttons["Battery saving"].tap()
        app.buttons["Turn On"].tap()
        XCTAssertTrue(level.waitForNonExistence(timeout: 5))
        app.buttons["restore-battery-saving-view"].tap()
        XCTAssertTrue(level.waitForExistence(timeout: 3))

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        XCTAssertFalse(level.exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(level.waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(level.waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(level.waitForExistence(timeout: 5))
        hand.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        switchControl.tap()
        XCTAssertFalse(level.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(hand.waitForExistence(timeout: 5))
        XCTAssertFalse(level.exists)
    }

    @MainActor
    func testBatterySavingHidesPreviewsAndRestoresTheSelectedMonitor() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = originalOrientation }
        let app = launchForUITesting(additionalArguments: ["-Overlays", "[]"])
        let monitor = app.buttons["Monitor selection"]
        let restore = app.buttons["restore-battery-saving-view"]
        let metalPreview = app.otherElements["metal-output-preview"]

        for output in [false, true] {
            if output { monitor.tap() }
            app.buttons["Battery saving"].tap()
            app.buttons["Turn On"].tap()
            XCTAssertTrue(restore.waitForExistence(timeout: 5))
            XCTAssertTrue(restore.isHittable)
            XCTAssertTrue(app.staticTexts["battery-saving-activity"].exists)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(restore.frame))
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["battery-saving-activity"].frame))
            XCTAssertFalse(metalPreview.exists)
            XCTAssertFalse(monitor.isHittable)
            XCTAssertFalse(app.buttons["Settings"].isHittable)
            XCTAssertFalse(app.buttons["Start stream"].isHittable)
            if output {
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "Battery saving status screen"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            restore.tap()
            XCTAssertTrue(monitor.waitForExistence(timeout: 5))
            XCTAssertEqual(monitor.value as? String, output ? "Output" : "Input")
            if output {
                XCTAssertTrue(metalPreview.waitForExistence(timeout: 3)
                    || app.staticTexts["Output preview is unavailable.\nTap Monitor to return to input."].exists)
            }
        }
    }

    @MainActor
    func testStartupJournalKeepsTheVersionAnnouncement() throws {
        let app = launchForUITesting(additionalArguments: ["-JournalInfo", "YES"])
        let monitor = app.buttons["Monitor selection"]
        monitor.tap()
        monitor.tap()
        app.buttons["Journal"].tap()
        let announcement = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Starting Tubeist version ")
        ).firstMatch
        XCTAssertTrue(announcement.waitForExistence(timeout: 5))
        XCTAssertFalse(announcement.label.contains("unknown"))
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
    func testOutputPreviewCanBeOpenedAndRestored() throws {
        let app = launchForUITesting()
        let monitor = app.buttons["Monitor selection"]
        let label = app.staticTexts["output-preview-label"]
        let metalPreview = app.otherElements["metal-output-preview"]
        let unavailablePreview = app.staticTexts[
            "Output preview is unavailable.\nTap Monitor to return to input."
        ]

        func checkMetalPreview() {
            // Virtual CI hosts may not expose a Metal device. The monitor
            // toggle must still work and explain how to return to input.
            XCTAssertTrue(metalPreview.waitForExistence(timeout: 3) || unavailablePreview.exists)
        }

        func openOutput() {
            XCTAssertEqual(monitor.value as? String, "Input")
            monitor.tap()
            XCTAssertTrue(label.waitForExistence(timeout: 3))
            XCTAssertEqual(label.label, "OUTPUT MONITORING")
            XCTAssertEqual(monitor.value as? String, "Output")
            checkMetalPreview()
        }

        openOutput()

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        checkMetalPreview()
        XCTAssertEqual(label.label, "OUTPUT MONITORING")

        monitor.tap()
        XCTAssertFalse(label.exists)
        XCTAssertFalse(metalPreview.exists)
        openOutput()

        app.terminate()
        app.launch()
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        openOutput()

        monitor.tap()
        XCTAssertFalse(metalPreview.exists)
        XCTAssertFalse(unavailablePreview.exists)
        XCTAssertFalse(label.exists)
        XCTAssertEqual(monitor.value as? String, "Input")
    }

    @MainActor
    func testYouTubeSignInIsAvailableWithoutAStreamKey() throws {
        let app = launchForUITesting()
        app.buttons["Settings"].tap()
        let keyField = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        XCTAssertEqual(keyField.value as? String, "YouTube HLS Stream Key")
        let signIn = app.buttons["Sign in with Google"]
        // A fresh simulator shows the permission notice above the form; the
        // sign-in section can therefore start below the visible viewport.
        scrollTo(signIn, in: app)
        XCTAssertTrue(signIn.isHittable)
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
            self.scrollTo(element, in: app)
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
            let handle = row(source).buttons["Reorder \(source)"]
            XCTAssertTrue(handle.waitForExistence(timeout: 5))
            XCTAssertTrue(handle.isHittable)
            XCTAssertTrue(row(destination).waitForExistence(timeout: 5))
            let handleFrame = handle.frame
            let destinationFrame = row(destination).frame
            let window = app.windows.firstMatch
            let windowFrame = window.frame
            let origin = window.coordinate(withNormalizedOffset: .zero)
            // Use the native reorder handle, whose hit target does not scale
            // with the row width. Freeze the coordinates against the window
            // because both rows move while the drag is in progress.
            let start = origin.withOffset(CGVector(
                dx: handleFrame.midX - windowFrame.minX,
                dy: handleFrame.midY - windowFrame.minY
            ))
            let end = origin.withOffset(CGVector(
                dx: handleFrame.midX - windowFrame.minX,
                dy: destinationFrame.minY + destinationFrame.height * 0.75 - windowFrame.minY
            ))
            // Edit mode already exposes the drag handle; a long stationary
            // hold can leave iOS 26's lifted cell presentation unsettled.
            // Cross the destination's midpoint, but keep the drop inside the
            // row. Dropping below its bottom edge can land in the section
            // footer and cancel the move when this is the final row.
            // Let the insertion animation settle before releasing.
            start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)

            // During a native reorder, cells and their lifted snapshots can
            // temporarily report stale frames/labels. Reopen the list to check
            // the resulting draft instead of inspecting that presentation.
            app.buttons["Done"].tap()
            openOrder()
            let reordered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    guard row(source).exists, row(destination).exists else { return false }
                    return row(destination).frame.minY < row(source).frame.minY
                }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed,
                           "Dragging \(source) below \(destination) should update the draft order")
        }

        openOrder()
        XCTAssertLessThan(row(frontURL).frame.minY, row(backURL).frame.minY, "New overlay should start on top")
        moveBelow(frontURL, backURL)
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
        app.buttons["Done"].tap()
        app.buttons["Cancel"].tap()

        app.buttons["Settings"].tap()
        openOrder()
        XCTAssertLessThan(row(backURL).frame.minY, row(frontURL).frame.minY, "Cancel should discard the draft order")
        app.buttons["Done"].tap()
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testOverlayScaleCanBeSavedAndCancelled() throws {
        let app = launchForUITesting()
        app.buttons["Settings"].tap()
        let key = app.secureTextFields["YouTube HLS Stream Key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("abcd-efgh-1234\n")
        let url = "http://127.0.0.1:9/scale-\(UUID().uuidString.prefix(8))"
        let newURL = app.textFields["New Overlay URL"]
        scrollTo(newURL, in: app)
        newURL.tap()
        newURL.typeText(url + "\n")
        let row = app.buttons["edit-overlay-\(url)"]
        scrollTo(row, in: app, searchDirection: -1)
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit Overlay"].waitForExistence(timeout: 5),
                      "The editor must open directly, without a collapsed sidebar button")
        let slider = app.sliders["overlay-scale"]
        scrollTo(slider, in: app)
        slider.adjust(toNormalizedSliderPosition: 0) // Use an exact endpoint; drag positions are approximate.
        XCTAssertEqual(slider.value as? String, "25 percent")
        let editor = XCTAttachment(screenshot: app.screenshot())
        editor.name = "Overlay scale editor"
        editor.lifetime = .keepAlways
        add(editor)
        app.navigationBars["Edit Overlay"].buttons["Save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        app.navigationBars["Settings"].buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.buttons["Settings"].tap()
        scrollTo(row, in: app)
        row.tap()
        scrollTo(slider, in: app)
        XCTAssertEqual(slider.value as? String, "25 percent")
        scrollTo(app.buttons["Reset to 100%"], in: app)
        app.buttons["Reset to 100%"].tap()
        app.navigationBars["Edit Overlay"].buttons["Save"].tap()
        // Cancelling Settings must discard the accepted editor draft too.
        app.navigationBars["Settings"].buttons["Cancel"].tap()
        app.buttons["Settings"].tap()
        scrollTo(row, in: app)
        row.tap()
        scrollTo(slider, in: app)
        XCTAssertEqual(slider.value as? String, "25 percent")
        app.navigationBars["Edit Overlay"].buttons["Cancel"].tap()
        app.navigationBars["Settings"].buttons["Cancel"].tap()
    }

    @MainActor
    func testOverlayEditExplainsInvalidAndDuplicateURLs() throws {
        let app = launchForUITesting()
        app.buttons["Settings"].tap()
        let suffix = UUID().uuidString.prefix(8)
        let first = "http://127.0.0.1:9/edit-first-\(suffix)"
        let second = "http://127.0.0.1:9/edit-second-\(suffix)"
        let newURL = app.textFields["New Overlay URL"]
        for url in [first, second] {
            scrollTo(newURL, in: app)
            newURL.tap()
            newURL.typeText(url)
            app.buttons["Add overlay"].tap()
            newURL.typeText("\n")
        }
        let row = app.buttons["edit-overlay-\(second)"]
        scrollTo(row, in: app, searchDirection: -1)
        row.tap()
        let field = app.textFields["Overlay URL"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        func replaceURL(_ value: String) {
            field.tap()
            let existing = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            field.typeText(value)
        }
        replaceURL("invalid-url")
        app.navigationBars["Edit Overlay"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Enter a valid overlay URL starting with http:// or https://"].exists)
        XCTAssertTrue(field.exists)
        replaceURL(first)
        app.navigationBars["Edit Overlay"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["An overlay with this URL already exists. Enter a different URL."].exists)
        XCTAssertTrue(field.exists)
        let corrected = second + "-corrected"
        replaceURL(corrected)
        app.navigationBars["Edit Overlay"].buttons["Save"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["edit-overlay-\(corrected)"].exists)
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
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, searchDirection: CGFloat = 1) {
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.exists)
        let window = app.windows.firstMatch
        for _ in 0..<40 {
            let bounds = window.frame
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = app.keyboards.firstMatch.exists
                ? app.keyboards.firstMatch.frame.minY - 8 : bounds.maxY - 24
            let target = element.exists ? element.frame : nil
            if let target, target.minY >= top, target.maxY <= bottom, element.isHittable { return }

            // Short, overlapping scrolls cannot jump past a control.
            // Keep the entire target clear of the navigation bar/keyboard;
            // isHittable alone can accept a partially covered button.
            let middle = (top + bottom) / 2
            let distance = min(60, (bottom - top) / 4)
            let direction: CGFloat = target.map { $0.minY < top ? -1 : 1 } ?? searchDirection
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.width / 2,
                                                   dy: middle + direction * distance - bounds.minY))
            let end = origin.withOffset(CGVector(dx: bounds.width / 2,
                                                 dy: middle - direction * distance - bounds.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Could not reach \(element)\n\(app.debugDescription)")
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
