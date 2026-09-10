import CoreGraphics
import Foundation
import simd

/// How the matter behaves once it is off its grid.
///
/// Three, and only three. Each one is a different answer to the same question,
/// which is what a field of loosely bound matter does when something disturbs
/// it, and each is legible at a glance from the preview alone. A fourth would
/// have to be explained.
enum MotionStyle: String, CaseIterable, Identifiable {
    /// Currents. The picture flows like something suspended in water.
    case fluid
    /// A shockwave from the middle that the picture keeps pulling itself back
    /// from, so it breathes rather than simply exploding.
    case burst
    /// Slow wander. Each glyph goes its own way and the picture never quite
    /// settles.
    case drift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fluid: return "Fluid"
        case .burst: return "Burst"
        case .drift: return "Drift"
        }
    }
}

/// One glyph, as the GPU wants it.
///
/// Field order and padding match `GlyphInstance` in Shaders.metal exactly. If
/// one side gains a field the other must too, or every glyph draws in the wrong
/// place with the wrong colour and the cause is not obvious from looking at it.
struct GlyphInstance {
    var position: SIMD2<Float>
    var size: Float
    var glyph: Float
    var color: SIMD4<Float>
}

/// What the shader needs to know that is the same for every glyph.
struct FieldUniforms {
    var viewport: SIMD2<Float>
    var atlasCell: SIMD2<Float>
    var atlasColumns: Float
    var pad0: Float
    var pad1: SIMD2<Float>
}

/// A picture, held as loose matter.
///
/// Every cell of the source image becomes a glyph with a home, a mass and a
/// velocity, bound to that home by a spring. Nothing here is a filter over
/// pixels: the characters are objects, and what makes the output move is the
/// same thing that makes a hanging chain move, which is why it does not look
/// like the other ASCII apps.
///
/// The source image sets each glyph's *character and colour*; it does not set
/// where the glyph is. That separation is the whole design. Feed it a video and
/// the homes stay put while the characters change underneath, so the matter
/// chases the moving picture instead of being rebuilt every frame.
final class GlyphField {
    private(set) var columns: Int = 0
    private(set) var rows: Int = 0

    /// Where each glyph is trying to be, in view points.
    private var home: [SIMD2<Float>] = []
    private var position: [SIMD2<Float>] = []
    private var velocity: [SIMD2<Float>] = []
    /// A fixed per-glyph random number, so identical glyphs do not move
    /// identically. Without it the whole field pulses as one object.
    private var phase: [Float] = []
    private var glyph: [Float] = []
    private var color: [SIMD4<Float>] = []

    /// The buffer handed to the renderer each frame.
    private(set) var instances: [GlyphInstance] = []

    /// Size of one cell in view points.
    private(set) var cellWidth: Float = 8
    private(set) var cellHeight: Float = 14

    /// Seconds since the field was built, driving every time-varying field.
    private var clock: Float = 0

    /// How hard a glyph is pulled back to its home.
    ///
    /// This is the number that decides whether the output still reads as the
    /// original picture. Too low and the image dissolves into soup within a
    /// second; too high and the motion is a tremble. Tuned so a glyph knocked a
    /// full cell out of place returns in about a third of a second.
    private let stiffness: Float = 46

    /// Fraction of velocity kept per second. Below 1 or the field never settles.
    private let damping: Float = 0.02

    // MARK: - Building

    /// Lay out a grid that fills `size` with cells about `targetCell` points
    /// wide, keeping the source image's proportions.
    ///
    /// Rebuilding throws away the physics state, and deliberately: a field that
    /// kept its velocities across a resolution change would inherit motion from
    /// a grid that no longer exists. Re-forming from scratch reads as the
    /// picture reassembling, which is worth watching anyway.
    func build(viewSize: CGSize, imageSize: CGSize, targetCell: Float, atlasAspect: Float) {
        let viewW = Float(max(viewSize.width, 1))
        let viewH = Float(max(viewSize.height, 1))
        let imgW = Float(max(imageSize.width, 1))
        let imgH = Float(max(imageSize.height, 1))

        // A glyph cell is taller than it is wide, so a square grid of them
        // would stretch the picture. Cells are sized in that ratio and the grid
        // counts are worked out from the image's aspect, not the view's.
        let cellW = max(targetCell, 2)
        let cellH = max(cellW / max(atlasAspect, 0.2), 2)

        // Fit the image inside the view without cropping it.
        let scale = min(viewW / imgW, viewH / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale

        let cols = max(Int(drawW / cellW), 2)
        let rws = max(Int(drawH / cellH), 2)

        columns = cols
        rows = rws
        cellWidth = cellW
        cellHeight = cellH

        let count = cols * rws
        home = Array(repeating: .zero, count: count)
        position = Array(repeating: .zero, count: count)
        velocity = Array(repeating: .zero, count: count)
        phase = Array(repeating: 0, count: count)
        glyph = Array(repeating: 0, count: count)
        color = Array(repeating: SIMD4<Float>(1, 1, 1, 1), count: count)
        instances = Array(
            repeating: GlyphInstance(position: .zero, size: cellW, glyph: 0, color: .zero),
            count: count
        )

        // Centre the grid in the view.
        let gridW = Float(cols) * cellW
        let gridH = Float(rws) * cellH
        let originX = (viewW - gridW) / 2 + cellW / 2
        let originY = (viewH - gridH) / 2 + cellH / 2

        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for r in 0..<rws {
            for c in 0..<cols {
                let i = r * cols + c
                let p = SIMD2<Float>(
                    originX + Float(c) * cellW,
                    originY + Float(r) * cellH
                )
                home[i] = p
                position[i] = p
                phase[i] = GlyphField.nextUnit(&seed) * .pi * 2
            }
        }
        clock = 0
    }

    /// Whether there is a grid to draw at all.
    var isEmpty: Bool { columns == 0 || rows == 0 }

    // MARK: - Source

    /// Read a picture into the field, setting every glyph's character and
    /// colour without touching where any of them is.
    ///
    /// `pixels` is tightly packed RGBA8, `columns` by `rows`, which is exactly
    /// what `ImageSampler` produces.
    func apply(pixels: [UInt8]) {
        let count = columns * rows
        guard pixels.count >= count * 4, count > 0 else { return }

        for i in 0..<count {
            let o = i * 4
            let r = Float(pixels[o]) / 255
            let g = Float(pixels[o + 1]) / 255
            let b = Float(pixels[o + 2]) / 255

            // Rec. 601 luma. The eye is far more sensitive to green than to
            // blue, and a flat average turns a blue sky into the same grey as
            // grass, which throws away most of the tonal range the ramp exists
            // to show.
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            glyph[i] = Float(Ramp.index(forLuminance: luma))

            // The glyph carries the colour of the pixel it came from, lifted
            // toward full saturation. Characters are thin and a dim one at its
            // true brightness reads as black on black.
            let lift: Float = 0.45
            color[i] = SIMD4<Float>(
                min(r + lift * (1 - r), 1),
                min(g + lift * (1 - g), 1),
                min(b + lift * (1 - b), 1),
                1
            )
        }
    }

    // MARK: - Physics

    /// Advance the field.
    ///
    /// `amount` is the slider, 0 to 1: at zero the picture stands perfectly
    /// still and reads as a plain ASCII rendering, which is a legitimate thing
    /// to want and a useful floor for the effect to grow out of.
    func step(dt: Float, style: MotionStyle, amount: Float) {
        guard !isEmpty else { return }
        // A frame the app was suspended for arrives as one enormous dt and
        // launches every glyph off screen. Clamped to the length of a slow
        // frame, so a stall costs a dropped frame rather than the picture.
        let dt = min(max(dt, 0), 1.0 / 20.0)
        guard dt > 0 else { return }

        clock += dt
        let t = clock
        let amt = min(max(amount, 0), 1)
        // The field's own strength, in points per second squared. Scaled by the
        // cell so the effect looks the same at every character size rather than
        // becoming a tremble when the glyphs get small.
        let power = amt * amt * 900 * (cellWidth / 8)
        let keep = powf(damping, dt)

        let centre = SIMD2<Float>(
            home.isEmpty ? 0 : (home[0].x + home[home.count - 1].x) * 0.5,
            home.isEmpty ? 0 : (home[0].y + home[home.count - 1].y) * 0.5
        )
        // Burst inhales and exhales rather than pushing forever, so the picture
        // is legible again every couple of seconds.
        let pulse = sinf(t * 1.7)

        for i in 0..<position.count {
            let p = position[i]
            let h = home[i]
            let ph = phase[i]

            // The spring. This is what keeps it a picture.
            var accel = (h - p) * stiffness

            switch style {
            case .fluid:
                // Cheap curl-like flow: a divergence-free-ish pair of waves
                // sampled off the glyph's own home, so neighbours share a
                // current and the field moves in sheets rather than as dust.
                let sx = h.x * 0.011
                let sy = h.y * 0.013
                accel.x += sinf(sy * 3.1 + t * 0.9 + ph * 0.15) * power
                accel.y += cosf(sx * 2.7 - t * 1.1 + ph * 0.15) * power

            case .burst:
                var d = p - centre
                let len = simd_length(d)
                if len > 0.0001 {
                    d /= len
                    // Falls off with distance so the middle of the picture
                    // moves hardest and the edges hold the composition.
                    let falloff = 1 / (1 + len * 0.006)
                    accel += d * (pulse * power * 2.1 * falloff)
                }

            case .drift:
                // Every glyph on its own slow errand.
                accel.x += sinf(t * 0.6 + ph) * power * 0.55
                accel.y += cosf(t * 0.43 + ph * 1.7) * power * 0.55
            }

            var v = velocity[i]
            v += accel * dt
            v *= keep
            velocity[i] = v
            position[i] = p + v * dt
        }

        // Pack for the GPU.
        let size = cellHeight
        for i in 0..<instances.count {
            instances[i] = GlyphInstance(
                position: position[i],
                size: size,
                glyph: glyph[i],
                color: color[i]
            )
        }
    }

    /// Put every glyph back on its home and stop it dead.
    ///
    /// Used when a still is exported, so the saved frame is the composed image
    /// rather than whatever the physics happened to be doing.
    func settle() {
        for i in 0..<position.count {
            position[i] = home[i]
            velocity[i] = .zero
        }
        for i in 0..<instances.count {
            instances[i] = GlyphInstance(
                position: home[i],
                size: cellHeight,
                glyph: glyph[i],
                color: color[i]
            )
        }
    }

    // MARK: - Helpers

    /// SplitMix64, for the per-glyph phase. Deterministic so a rebuilt field
    /// moves the same way twice.
    private static func nextUnit(_ state: inout UInt64) -> Float {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Float(z >> 11) / Float(1 << 53)
    }
}
