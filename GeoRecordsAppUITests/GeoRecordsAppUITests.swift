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

    /// Stats and Settings are hosted as a split view's only column at regular width
    /// (SingleColumnTab); a drag from the leading edge must not reveal the empty
    /// sidebar. Captures before and after the drag, for eyeballing on the iPad.
    @MainActor
    /// A portrait photo is drawn cropped to 4:3; the hidden overflow must not take
    /// taps meant for the value and the rows beneath it (the seeded Furthest North
    /// record carries a 1200×1600 photo)
    func testPortraitPhotoKeepsTapsInItsBox() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GEORECORDS_SHOW_SIZE_CLASS"] = "1"
        app.launch()
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.04)).tap()
        sleep(1)
        openFirstCard(app)
        let value = app.staticTexts["69.6492° N"]
        XCTAssertTrue(value.waitForExistence(timeout: 5), "the Furthest North page did not open")
        value.tap()
        XCTAssertFalse(app.buttons["Close photo"].waitForExistence(timeout: 2),
                       "tapping the value under the photo opened the full-screen viewer")
        app.buttons["Photo"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Close photo"].waitForExistence(timeout: 3), "tapping the photo did not open the viewer")
        app.buttons["Close photo"].tap()
        sleep(1)
        goBack(app)
    }

    func testSingleColumnTabsIgnoreEdgeSwipe() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GEORECORDS_SHOW_SIZE_CLASS"] = "1"
        app.launch()
        sleep(3)
        for tab in ["Stats", "Settings"] {
            selectTab(app, tab); sleep(2)
            snap(app, "E1-\(tab)-before")
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(2)
            snap(app, "E2-\(tab)-after-edge-drag")
        }
    }

    /// History's search field sits under the title; opening it and dismissing it
    /// without submitting, with nothing typed and then with text, must leave no
    /// keyboard and no active search, with the field still there. A minimized field
    /// (searchToolbarBehavior .minimize) reopened itself after its Close button on
    /// iOS 27.0–27.2 (Apple forum thread 845737), and iOS 27's default drawer hides
    /// the field until the list is pulled down, which is why History pins it
    @MainActor
    func testHistorySearchCloses() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GEORECORDS_SHOW_SIZE_CLASS"] = "1"
        app.launch()
        sleep(3)
        selectTab(app, "History"); sleep(2)
        dismissLocationBanner(app)
        snap(app, "S-history-idle")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "no search field under the History title")
        // The field's own Cancel (iOS 18) or X (iOS 26+), inside the navigation bar
        let dismiss = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == 'Close'")).firstMatch
        for text in ["", "Bell"] {
            field.tap()
            sleep(1)
            if !text.isEmpty { app.typeText(text); sleep(1) }
            XCTAssertTrue(dismiss.waitForExistence(timeout: 3), "no Cancel or Close button beside the search field (typed '\(text)')")
            dismiss.tap()
            sleep(4)
            snap(app, text.isEmpty ? "S-search-closed-empty" : "S-search-closed-typed")
            XCTAssertEqual(app.keyboards.count, 0, "the keyboard is still up after dismissing the search (typed '\(text)')")
            XCTAssertFalse(dismiss.exists, "the search is still active after dismissing it (typed '\(text)')")
            XCTAssertTrue(field.exists, "the search field is gone after dismissing the search (typed '\(text)')")
        }
    }

    /// A simulator without Always location permission shows the "Location Disabled"
    /// or "Location Issue" banner (with a Fix button) over every screen; its Close
    /// button is labelled like a search field's. Grant the permission to avoid it:
    /// xcrun simctl privacy <udid> grant location-always org.davidlaporte.GeoRecords
    private func dismissLocationBanner(_ app: XCUIApplication) {
        if app.buttons["Fix"].waitForExistence(timeout: 2) {
            let close = app.buttons.matching(identifier: "xmark").firstMatch
            if close.exists { close.tap(); sleep(1) }
        }
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
        // Lets the interruption monitor dismiss the notifications prompt; off-centre,
        // since the screen's middle can be a record's photo (tapping it opens the viewer)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.04)).tap()
        sleep(1)
        dismissLocationBanner(app)
        sleep(1)
        snap(app, "01-records-lifetime")
        openFirstCard(app); snap(app, "01b-record-opened"); goBack(app)

        tap(app, "This Month"); sleep(2); snap(app, "02-records-month")
        tap(app, "This Year"); sleep(2); snap(app, "03-records-year")

        selectTab(app, "Stats"); sleep(3); snap(app, "04-stats-lifetime")
        scrollUp(app); snap(app, "05-stats-lifetime-scrolled")
        scrollUp(app); scrollUp(app); snap(app, "06-stats-lifetime-bottom")
        tap(app, "This Year"); sleep(3)
        scrollUp(app); scrollUp(app); scrollUp(app); snap(app, "07-stats-year-bottom")
        tap(app, "This Month"); sleep(3); snap(app, "07b-stats-month")

        selectTab(app, "Regions"); sleep(4); snap(app, "08-regions-states")
        openFirstCard(app); snap(app, "08b-region-opened"); goBack(app)
        // A tap on an unvisited state (Utah sits right of the framed Nevada) shows the callout
        app.maps.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.55)).tap(); sleep(2)
        snap(app, "08c-regions-callout")
        tap(app, "Continents"); sleep(4); snap(app, "10-regions-continents")
        swipeCards(app); sleep(4); snap(app, "10b-regions-continents-second")
        swipeCards(app); sleep(4); snap(app, "10c-regions-continents-third")
        tap(app, "Countries"); sleep(4); snap(app, "11-regions-countries")

        selectTab(app, "History"); sleep(3); snap(app, "12-history")
        if app.buttons["Filters"].waitForExistence(timeout: 3) {
            // The menu rows carry their value as a subtitle, so match the title's start
            let typeRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Type'")).firstMatch
            app.buttons["Filters"].tap(); sleep(2); snap(app, "12b-history-filters")
            typeRow.tap(); sleep(1); snap(app, "12b2-history-type-menu")
            tap(app, "Furthest North"); sleep(2); snap(app, "12c-history-filtered")
            // Reopened: the row shows the value, Clear Filters is enabled
            app.buttons["Filters"].tap(); sleep(2); snap(app, "12d-history-menu-set")
            typeRow.tap(); sleep(1); tap(app, "New State"); sleep(2)
            // A region type greys the Time Frame row
            app.buttons["Filters"].tap(); sleep(2); snap(app, "12e-history-region-type")
            tap(app, "Clear Filters"); sleep(2)
        }
        selectTab(app, "Settings"); sleep(2); snap(app, "13-settings")
        app.swipeUp(); sleep(1); snap(app, "14-settings-scrolled")

        // Display → List: Records and Regions as rows beside the map, then back to Cards
        app.swipeDown(); sleep(1)
        let listChoice = app.segmentedControls.buttons["List"]
        if listChoice.waitForExistence(timeout: 3) {
            listChoice.tap(); sleep(1)
            selectTab(app, "Records"); tap(app, "Lifetime"); sleep(3); snap(app, "15-records-list")
            // A row opens the record on a phone (selects it on an iPad); back, it is the
            // tinted row and the map frames it
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Furthest South'")).firstMatch.tap(); sleep(2)
            goBack(app); sleep(1); snap(app, "15b-records-list-selected")
            selectTab(app, "Regions"); tap(app, "States"); sleep(3); snap(app, "16-regions-list")
            selectTab(app, "Settings"); sleep(2)
            app.segmentedControls.buttons["Cards"].tap(); sleep(1)
        }
    }

    /// Taps the card under the map: on a phone it pushes the record's page, on an
    /// iPad it selects the card beside the detail column (the capture then shows
    /// the same screen)
    private func openFirstCard(_ app: XCUIApplication) {
        let card = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.72))
        card.tap()
        sleep(3)
    }

    /// Pops a pushed page, if one is up: the chevron-only back button carries the
    /// identifier BackButton on iOS 26 and later and the label Back before; on an
    /// iPad nothing was pushed
    private func goBack(_ app: XCUIApplication) {
        let back = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back'")).firstMatch
        if back.waitForExistence(timeout: 2) {
            back.tap()
            sleep(2)
        }
    }

    /// Selects a tab wherever the platform draws it: the iPhone tab bar, the iPad top
    /// tab bar or sidebar, or the iPhone Duo inner display's vertical rail
    private func selectTab(_ app: XCUIApplication, _ name: String) {
        // firstMatch: iPadOS 27 exposes each top-bar tab twice
        let inTabBar = app.tabBars.buttons[name].firstMatch
        if inTabBar.waitForExistence(timeout: 2) {
            inTabBar.tap()
            return
        }
        let anywhere = app.buttons[name].firstMatch
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
