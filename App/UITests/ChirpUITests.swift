import XCTest

final class ChirpUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding"]
    }

    /// Home and Settings are in the sidebar whichever features are switched on.
    func testSidebarShowsHomeAndSettings() {
        app.launch()
        for section in ["home", "settings"] {
            XCTAssertTrue(app.descendants(matching: .any)["sidebar.\(section)"].waitForExistence(timeout: 10), section)
        }
    }
}
