import CoreGraphics
import SwiftUI
import UIKit

@main
struct ASCIIMotionApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                // The screenshot tests drive the app through a launch argument
                // rather than through the photo picker, because the picker is a
                // separate process that UI tests cannot reliably tap through.
                .environment(\.isScreenshotRun, ProcessInfo.processInfo.arguments.contains("-screenshots"))
        }
    }
}

/// The whole navigation model: either something is loaded or it is not.
///
/// A NavigationStack would add a path, a destination and a set of transitions
/// to manage in exchange for nothing, because there are two screens and you can
/// only be on one of them.
struct RootView: View {
    @State private var source: Source?
    @Environment(\.isScreenshotRun) private var isScreenshotRun

    var body: some View {
        Group {
            if let source {
                EditorView(source: source) { self.source = nil }
                    .transition(.opacity)
            } else {
                HomeView { picked in
                    withAnimation(.easeOut(duration: 0.25)) { source = picked }
                }
                .transition(.opacity)
            }
        }
        .task {
            // Screenshot runs skip the picker and load a bundled still, so the
            // automated capture always produces the same frames.
            if isScreenshotRun, source == nil, let demo = DemoAsset.image() {
                source = .photo(demo)
            }
        }
    }
}

private struct ScreenshotRunKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isScreenshotRun: Bool {
        get { self[ScreenshotRunKey.self] }
        set { self[ScreenshotRunKey.self] = newValue }
    }
}

/// The picture used for App Store screenshots.
///
/// Generated rather than bundled as a photograph, for a reason that matters
/// commercially: App Review and the store listing both object to screenshots
/// containing material you cannot prove you own, and a synthetic image sidesteps
/// the question entirely while showing the effect just as well.
enum DemoAsset {
    static func image(size: CGSize = CGSize(width: 1200, height: 1600)) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let drawn = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(red: 0.05, green: 0.04, blue: 0.09, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            // Overlapping flat forms in the app's own palette: enough tonal
            // range for the ramp to have something to say, and unmistakably a
            // made object rather than a photograph.
            let shapes: [(UIColor, CGRect)] = [
                (UIColor(red: 0.98, green: 0.29, blue: 0.24, alpha: 1),
                 CGRect(x: 120, y: 200, width: 620, height: 620)),
                (UIColor(red: 1.00, green: 0.72, blue: 0.16, alpha: 1),
                 CGRect(x: 460, y: 520, width: 560, height: 560)),
                (UIColor(red: 0.20, green: 0.86, blue: 0.90, alpha: 1),
                 CGRect(x: 220, y: 860, width: 700, height: 430)),
            ]
            for (color, rect) in shapes {
                cg.setFillColor(color.withAlphaComponent(0.92).cgColor)
                cg.fillEllipse(in: rect)
            }
            cg.setFillColor(UIColor(red: 0.93, green: 0.24, blue: 0.62, alpha: 0.9).cgColor)
            cg.fill(CGRect(x: 80, y: 1180, width: 1040, height: 190))
        }
        return drawn.cgImage
    }
}
