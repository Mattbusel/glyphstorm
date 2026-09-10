import XCTest

/// Drives the app to produce the App Store screenshots.
///
/// The app is launched with `-screenshots`, which makes it load a generated
/// demo image instead of opening the photo picker. That is deliberate and it
/// matters twice over: the picker is a separate process that UI tests cannot
/// reliably tap through, and a synthetic image means the store listing contains
/// no photograph whose rights anyone has to argue about.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // @MainActor because SnapshotHelper's setupSnapshot and snapshot are both
    // main actor isolated, and calling them from a plain nonisolated test method
    // is a hard compile error under Swift 6's concurrency checking rather than a
    // warning.
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-screenshots"]
        app.launch()

        // The editor loads the demo image itself, so the first useful frame is
        // the effect already running. Give the field a moment to form before
        // capturing, or the first shot is a picture of nothing.
        sleep(3)
        snapshot("01_Fluid")

        // Each style is a different colour and a different motion, which is the
        // clearest thing the listing can show. Tapping by label keeps this
        // working if the buttons move.
        tapStyle(app, "BURST")
        sleep(3)
        snapshot("02_Burst")

        tapStyle(app, "DRIFT")
        sleep(3)
        snapshot("03_Drift")

        // Back to the home screen for the title shot, which is what a browsing
        // user sees as the thumbnail.
        let back = app.buttons["← NEW"]
        if back.waitForExistence(timeout: 5) {
            back.tap()
            sleep(2)
            snapshot("04_Home")
        }
    }

    @MainActor
    private func tapStyle(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 5) {
            button.tap()
        }
    }
}
