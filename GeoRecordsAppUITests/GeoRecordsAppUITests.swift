//
//  GeoRecordsAppUITests.swift
//  GeoRecordsUITests
//
//  A screenshot tour of the main screens, for eyeballing layout after UI work.
//  It asserts nothing: every screen it reaches is attached to the test result as
//  a screenshot (export with `xcrun xcresulttool export attachments`). Seed the
//  simulator first (GeoRecordsAppTests/SimulatorSeed.swift) so the screens have
//  something to show.
//

import XCTest

final class GeoRecordsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testScreenshotTour() throws {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Allow", "Allow While Using App", "OK", "Open"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        // A stray "Open in GeoRecords?" prompt from an earlier deep link would block the tour
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Cancel"].waitForExistence(timeout: 1) {
            springboard.buttons["Cancel"].tap()
        }

        app.launch()
        sleep(3)
        app.tap()  // lets the interruption monitor dismiss the notifications prompt
        sleep(1)
        snap(app, "01-records-lifetime")

        tap(app, "This Month"); sleep(2); snap(app, "02-records-month")
        tap(app, "This Year"); sleep(2); snap(app, "03-records-year")

        app.tabBars.buttons["Stats"].tap(); sleep(3); snap(app, "04-stats-lifetime")
        app.swipeUp(); sleep(1); snap(app, "05-stats-lifetime-scrolled")
        app.swipeUp(); sleep(1); snap(app, "06-stats-lifetime-bottom")
        tap(app, "This Month"); sleep(3); snap(app, "07-stats-month")

        app.tabBars.buttons["Regions"].tap(); sleep(4); snap(app, "08-regions-states")
        if app.buttons["Show regions not yet visited"].waitForExistence(timeout: 3) {
            app.buttons["Show regions not yet visited"].tap(); sleep(3); snap(app, "09-regions-not-yet")
            app.buttons["Show visited"].tap(); sleep(1)
        }
        tap(app, "Continents"); sleep(4); snap(app, "10-regions-continents")
        tap(app, "Countries"); sleep(4); snap(app, "11-regions-countries")

        app.tabBars.buttons["History"].tap(); sleep(3); snap(app, "12-history")
        app.tabBars.buttons["Settings"].tap(); sleep(2); snap(app, "13-settings")
        app.swipeUp(); sleep(1); snap(app, "14-settings-scrolled")
    }

    /// Taps a control by its visible text, whichever element type the picker exposes
    private func tap(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 3) {
            button.firstMatch.tap()
            return
        }
        let text = app.staticTexts[label]
        if text.waitForExistence(timeout: 3) {
            text.firstMatch.tap()
        }
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
