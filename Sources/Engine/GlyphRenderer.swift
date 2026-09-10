import CoreGraphics
import Foundation
import Metal
import MetalKit
import simd

/// Draws a `GlyphField`.
///
/// One draw call a frame, whatever the picture is. Every glyph is an instance
/// of the same six vertices, built entirely from its own instance record, so a
/// forty thousand character field costs the GPU one command and the CPU one
/// memcpy. That is what lets the physics run at full rate on a phone.
final class GlyphRenderer: NSObject {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let atlas: FontAtlas

    let field = GlyphField()

    /// Rotating instance buffers.
    ///
    /// The CPU writes next frame's glyphs while the GPU is still reading last
    /// frame's, so one buffer would tear. Three is the standard depth: enough
    /// that the CPU never waits in practice, few enough that the memory is
    /// trivial.
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var capacity = 0

    /// Wall clock of the last frame, for a real dt rather than an assumed one.
    private var lastFrame: CFTimeInterval = 0

    /// What the physics is doing. Set from the UI.
    var style: MotionStyle = .fluid
    var amount: Float = 0.5

    /// The ground the picture sits on. Not black: a near-black with a cast to
    /// it reads as a chosen colour rather than as a switched-off screen.
    var background: SIMD4<Float> = SIMD4<Float>(0.043, 0.039, 0.063, 1.0)

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let atlas = FontAtlas(device: device),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "glyph_vertex"),
              let fragmentFunction = library.makeFunction(name: "glyph_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Premultiplied alpha, matching what the fragment shader returns.
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        // Clamp, or a glyph sampling at the edge of its cell bleeds the
        // neighbouring character into itself.
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        self.atlas = atlas
        super.init()
    }

    var atlasAspect: Float { atlas.cellAspect }

    // MARK: - Buffers

    private func ensureCapacity(_ count: Int) {
        guard count > capacity else { return }
        // Grown with headroom, so dragging the character-size slider does not
        // reallocate on every value.
        let want = max(count, capacity * 2)
        let bytes = want * MemoryLayout<GlyphInstance>.stride
        buffers = (0..<3).compactMap {
            _ in device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        capacity = buffers.count == 3 ? want : 0
    }

    private func uniforms(viewport: SIMD2<Float>) -> FieldUniforms {
        FieldUniforms(
            viewport: viewport,
            atlasCell: atlas.cellUV,
            atlasColumns: Float(atlas.columns),
            pad0: 0,
            pad1: .zero
        )
    }

    /// Record the draw for whatever field is currently loaded.
    private func encode(
        into encoder: MTLRenderCommandEncoder,
        buffer: MTLBuffer,
        count: Int,
        viewport: SIMD2<Float>
    ) {
        guard count > 0 else { return }
        var u = uniforms(viewport: viewport)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<FieldUniforms>.stride, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: count
        )
    }

    /// Copy this frame's glyphs into the next buffer in the rotation.
    private func uploadCurrentField() -> (MTLBuffer, Int)? {
        let instances = field.instances
        guard !instances.isEmpty else { return nil }
        ensureCapacity(instances.count)
        guard capacity > 0, buffers.count == 3 else { return nil }

        bufferIndex = (bufferIndex + 1) % 3
        let buffer = buffers[bufferIndex]
        instances.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(buffer.contents(), base, src.count)
        }
        return (buffer, instances.count)
    }

    // MARK: - Offscreen

    /// Draw the current field into a new texture and read it back.
    ///
    /// Used for both exports: a still is one call to this, and a video is one
    /// call a frame. Sharing the path with the live view is deliberate, so what
    /// gets exported is what was on screen rather than a second renderer that
    /// drifts away from the first.
    /// `viewport` is the coordinate space the field was laid out in, in points,
    /// and is kept separate from the texture size on purpose. Exporting at twice
    /// the resolution means the same layout drawn into a bigger texture; if the
    /// viewport tracked the pixel size instead, the grid would re-space itself
    /// and the export would be a different composition from the preview.
    func renderToImage(width: Int, height: Int, viewport: SIMD2<Float>) -> CGImage? {
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared

        guard let target = device.makeTexture(descriptor: descriptor),
              let (buffer, count) = uploadCurrentField(),
              let command = queue.makeCommandBuffer()
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x),
            green: Double(background.y),
            blue: Double(background.z),
            alpha: 1
        )

        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(into: encoder, buffer: buffer, count: count, viewport: viewport)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()

        return GlyphRenderer.image(from: target)
    }

    /// Pull a rendered texture back into a CGImage.
    private static func image(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        // The texture is BGRA; CGImage is told so with the byte-order flag
        // rather than by swizzling the buffer by hand.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Advance the physics by a fixed step, for offscreen video export where
    /// there is no display clock to read.
    func advance(by dt: Float) {
        field.step(dt: dt, style: style, amount: amount)
    }
}

// MARK: - Live view

extension GlyphRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The field is rebuilt by the view model, which knows the source image
        // and the requested cell size. Nothing to do here.
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60.0 : now - lastFrame
        lastFrame = now

        field.step(dt: Float(dt), style: style, amount: amount)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor
        else { return }

        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x),
            green: Double(background.y),
            blue: Double(background.z),
            alpha: 1
        )

        inFlight.wait()
        guard let command = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        command.addCompletedHandler { [inFlight] _ in inFlight.signal() }

        if let (buffer, count) = uploadCurrentField(),
           let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            let scale = Float(view.drawableSize.width / max(view.bounds.width, 1))
            // The field works in view points; the drawable is in pixels.
            let viewport = SIMD2<Float>(
                Float(view.drawableSize.width) / max(scale, 0.0001),
                Float(view.drawableSize.height) / max(scale, 0.0001)
            )
            encode(into: encoder, buffer: buffer, count: count, viewport: viewport)
            encoder.endEncoding()
        }

        command.present(drawable)
        command.commit()
    }
}
