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

    /// Prefix for attachment names, so a landscape run's captures sort apart
    private var snapPrefix = ""

    @MainActor
    func testScreenshotTour() throws {
        runTour()
    }

    /// The same tour with the device rotated: iPhone landscape is compact height,
    /// iPad landscape is the wide regular layout
    @MainActor
    func testScreenshotTourLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        snapPrefix = "L-"
        runTour()
        XCUIDevice.shared.orientation = .portrait
    }

    /// The setup wizard step by step, opened by a DEBUG launch flag without touching
    /// settings; the folded iPhone Duo (382×644 window) is where its text truncated
    @MainActor
    func testSetupWizardTour() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GEORECORDS_SHOW_SIZE_CLASS"] = "1"
        app.launchEnvironment["GEORECORDS_FORCE_SETUP_WIZARD"] = "1"
        app.launch()
        sleep(3)
        snap(app, "W1-welcome")
        tap(app, "Next"); dismissSystemAlert(); sleep(1); snap(app, "W2-units")
        tap(app, "Next"); sleep(2)
        if !app.buttons["Next"].isEnabled, app.maps.firstMatch.waitForExistence(timeout: 3) {
            app.maps.firstMatch.tap()  // sets the home location
            sleep(2)
        }
        snap(app, "W3-home")
        tap(app, "Next"); sleep(1); snap(app, "W4-notifications")
        tap(app, "Next"); dismissSystemAlert(); sleep(1); snap(app, "W5-summaries")
        tap(app, "Next"); sleep(1); snap(app, "W6-photo-prompts")
        tap(app, "Next"); sleep(1); snap(app, "W7-photo-import")
    }

    /// Taps through a system permission alert (location, notifications) if one is up
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    @MainActor
    private func runTour() {
        let app = XCUIApplication()
        // Debug builds stamp each capture with its size classes and window size
        app.launchEnvironment["GEORECORDS_SHOW_SIZE_CLASS"] = "1"
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

        selectTab(app, "Stats"); sleep(3); snap(app, "04-stats-lifetime")
        scrollUp(app); snap(app, "05-stats-lifetime-scrolled")
        scrollUp(app); scrollUp(app); snap(app, "06-stats-lifetime-bottom")
        tap(app, "This Year"); sleep(3)
        scrollUp(app); scrollUp(app); scrollUp(app); snap(app, "07-stats-year-bottom")
        tap(app, "This Month"); sleep(3); snap(app, "07b-stats-month")

        selectTab(app, "Regions"); sleep(4); snap(app, "08-regions-states")
        if app.buttons["Show regions not yet visited"].waitForExistence(timeout: 3) {
            app.buttons["Show regions not yet visited"].tap(); sleep(3); snap(app, "09-regions-not-yet")
            app.buttons["Show visited"].tap(); sleep(1)
        }
        tap(app, "Continents"); sleep(4); snap(app, "10-regions-continents")
        swipeCards(app); sleep(4); snap(app, "10b-regions-continents-second")
        swipeCards(app); sleep(4); snap(app, "10c-regions-continents-third")
        tap(app, "Countries"); sleep(4); snap(app, "11-regions-countries")

        selectTab(app, "History"); sleep(3); snap(app, "12-history")
        selectTab(app, "Settings"); sleep(2); snap(app, "13-settings")
        app.swipeUp(); sleep(1); snap(app, "14-settings-scrolled")
    }

    /// Selects a tab wherever the platform draws it: the iPhone tab bar, the iPad top
    /// tab bar or sidebar, or the iPhone Duo inner display's vertical rail
    private func selectTab(_ app: XCUIApplication, _ name: String) {
        let inTabBar = app.tabBars.buttons[name]
        if inTabBar.waitForExistence(timeout: 2) {
            inTabBar.tap()
            return
        }
        let anywhere = app.buttons[name]
        if anywhere.waitForExistence(timeout: 2) {
            anywhere.tap()
            return
        }
        app.staticTexts[name].firstMatch.tap()
    }

    /// Drags upward along the left margin, outside the cards: the Stats charts own a
    /// scrub gesture that swallows swipes started on them
    private func scrollUp(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.85))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: end)
        sleep(1)
    }

    /// Swipes the region card pager (bottom of the Regions tab) to the next card,
    /// away from the map so the map doesn't pan instead
    private func swipeCards(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.72))
        start.press(forDuration: 0.05, thenDragTo: end)
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
        attachment.name = snapPrefix + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
