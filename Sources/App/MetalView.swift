import MetalKit
import SwiftUI

/// The live preview.
///
/// A thin wrapper: MTKView already does everything wanted here, which is to
/// call a delegate once per display refresh on the main thread. The only thing
/// added is pausing, which is what keeps the export task and the preview from
/// touching the same field at once.
struct MetalView: UIViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = model.renderer?.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.model = model
        // The single point of coordination between preview and export.
        view.isPaused = model.isExporting
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var model: EditorModel

        init(model: EditorModel) {
            self.model = model
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            let points = CGSize(
                width: view.bounds.width,
                height: view.bounds.height
            )
            // Hop rather than assume: this can arrive during layout, and
            // mutating published state synchronously inside a layout pass is
            // how "Publishing changes from within view updates" warnings start.
            Task { @MainActor [model] in
                model.setViewSize(points)
            }
        }

        func draw(in view: MTKView) {
            // MTKView drives its delegate from the main run loop, so this is
            // already the main actor and the assumption is safe rather than
            // hopeful.
            MainActor.assumeIsolated {
                // Report the size on the first real frame too. `drawableSizeWillChange`
                // does not always fire before the first draw when a view is
                // installed at its final size.
                model.setViewSize(view.bounds.size)
                model.pumpVideo()
                model.renderer?.draw(in: view)
            }
        }
    }
}
