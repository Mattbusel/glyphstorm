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

    /// The whole app as a customer uses it, for the App Review recording.
    ///
    /// Starts on the home screen so the video opens with the app launching, and
    /// goes through the real photo picker rather than the demo image. The
    /// workflow starts recording a few seconds after this runner appears, which
    /// lands inside the pause on the home screen.
    @MainActor
    func testReviewRecording() throws {
        XCUIDevice.shared.press(.home)
        sleep(9)

        let app = XCUIApplication()
        app.launch()
        sleep(3)

        app.buttons["CHOOSE PHOTO"].firstMatch.tap()
        sleep(3)
        if let photo = firstPickerPhoto(app) {
            photo.tap()
        } else {
            // The picker is another process and its tree is not always
            // exposed. The one photo in the library sits top left.
            print(app.debugDescription)
            app.windows.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.22))
                .tap()
        }

        let burst = app.buttons["BURST"]
        XCTAssertTrue(burst.waitForExistence(timeout: 20), "editor never opened")
        sleep(5)
        burst.tap()
        sleep(5)
        tapStyle(app, "DRIFT")
        sleep(5)
        tapStyle(app, "FLUID")
        sleep(2)

        // Amount up, then characters small and back to medium.
        let sliders = app.sliders
        if sliders.count >= 2 {
            sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 1.0)
            sleep(3)
            sliders.element(boundBy: 1).adjust(toNormalizedSliderPosition: 0.1)
            sleep(3)
            sliders.element(boundBy: 1).adjust(toNormalizedSliderPosition: 0.4)
            sleep(2)
        }

        app.buttons["EXPORT"].tap()
        let rendering = app.staticTexts["RENDERING"]
        if rendering.waitForExistence(timeout: 5) {
            _ = rendering.waitForNonExistence(timeout: 120)
        }
        // The share sheet, which is where the export goes.
        sleep(4)
        let close = app.buttons["Close"]
        if close.exists {
            close.tap()
        } else {
            app.windows.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
                .tap()
        }
        sleep(2)

        let back = app.buttons["← NEW"]
        if back.waitForExistence(timeout: 5) {
            back.tap()
        }
        sleep(3)
    }

    /// The first real photo in the system picker. Toolbar icons are images too,
    /// so anything small is skipped.
    @MainActor
    private func firstPickerPhoto(_ app: XCUIApplication) -> XCUIElement? {
        let queries = [app.scrollViews.otherElements.images, app.images, app.collectionViews.cells]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for query in queries {
                for element in query.allElementsBoundByIndex
                where element.exists && element.frame.width > 60 && element.isHittable {
                    return element
                }
            }
            usleep(500_000)
        }
        return nil
    }

    @MainActor
    private func tapStyle(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 5) {
            button.tap()
        }
    }
}
