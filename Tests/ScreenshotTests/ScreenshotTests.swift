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
        sleep(5)

        let app = XCUIApplication()
        app.launch()
        sleep(3)

        app.buttons["CHOOSE PHOTO"].firstMatch.tap()
        sleep(3)
        // The picker is another process and its tree is not exposed to the
        // test, so the photo is tapped by position. The one added for this run
        // is the newest, top left, under the "Private Access to Photos" banner.
        // It can sit on "Loading..." for ten seconds or more, so wait until the
        // photo is actually drawn there, and tap again if the editor does not
        // open.
        let spot = CGVector(dx: 0.166, dy: 0.41)
        waitForPhoto(at: spot, timeout: 60)
        let burst = app.buttons["BURST"]
        for _ in 0..<4 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: spot).tap()
            if burst.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(burst.exists, "editor never opened")
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

    /// Waits until something bright is drawn at this point of the screen. The
    /// picker's placeholder is near black; the pug photo is not.
    @MainActor
    private func waitForPhoto(at point: CGVector, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let image = XCUIScreen.main.screenshot().image.cgImage,
               brightness(of: image, at: point) > 200 {
                return
            }
            usleep(500_000)
        }
    }

    /// Sum of the red, green and blue values of one pixel.
    private func brightness(of image: CGImage, at point: CGVector) -> Int {
        let x = Int(CGFloat(image.width) * point.dx)
        let y = Int(CGFloat(image.height) * point.dy)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            // Shift the image so the wanted pixel lands on the 1x1 context.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                           width: image.width, height: image.height))
        }
        return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])
    }

    @MainActor
    private func tapStyle(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 5) {
            button.tap()
        }
    }
}
