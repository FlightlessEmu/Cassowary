import XCTest

final class LibraryNavigationCheck: XCTestCase {
    func testReturnSwipeRemembersGamesList() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "org.cassowary.Cassowary")
        app.launchArguments = ["-cassowary.autoPlayFirstGame", "NO",
                               "-cassowary.showSettings", "NO",
                               "-cassowary.showCoverArt", "NO"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))

        // A left swipe can open All Games before a row has been selected.
        app.swipeLeft()
        XCTAssertTrue(app.navigationBars["Games"].waitForExistence(timeout: 5))
        swipeBack(in: app)
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))

        // Vertical scrolling must leave the systems list open and usable.
        app.swipeUp()
        XCTAssertTrue(app.navigationBars["Library"].exists)
        app.swipeDown()
        let favorites = app.buttons["Favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        favorites.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5))

        // Native back navigation and the new return swipe work repeatedly,
        // restoring Favorites rather than switching to All Games.
        for _ in 0..<2 {
            swipeBack(in: app)
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
            app.swipeLeft()
            XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5))
        }
    }

    private func swipeBack(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
    }
}
