import SwiftUI

/// The look.
///
/// Hard flat colour on a near-black ground, with no gradients, no glass and no
/// shadows. The reason is not fashion: the artwork this app makes is dense
/// coloured text, and any chrome with texture in it competes with the thing the
/// user is trying to look at. Flat blocks recede. They also happen to be the
/// cheapest possible UI to build and the easiest to read at a glance, which is
/// what a two-screen app wants.
enum Theme {
    /// The ground, everywhere. Not pure black: a near-black with a violet cast
    /// reads as a deliberate colour, where #000 reads as a screen that is off.
    static let ground = Color(red: 0.043, green: 0.039, blue: 0.063)

    /// One step up, for panels that need to separate from the ground without a
    /// border doing the work.
    static let raised = Color(red: 0.086, green: 0.078, blue: 0.118)

    /// The accents. Four, saturated, and deliberately unbalanced: three warm
    /// against one cold, so the cold one is always the thing being pointed at.
    static let vermilion = Color(red: 0.98, green: 0.29, blue: 0.24)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.16)
    static let magenta = Color(red: 0.93, green: 0.24, blue: 0.62)
    static let cyan = Color(red: 0.20, green: 0.86, blue: 0.90)

    static let ink = Color.white
    static let inkDim = Color.white.opacity(0.55)

    /// The accent a given motion style is drawn in, so the three options are
    /// told apart by colour before the label is even read.
    static func color(for style: MotionStyle) -> Color {
        switch style {
        case .fluid: return cyan
        case .burst: return vermilion
        case .drift: return amber
        }
    }
}

/// A big flat rectangle you press. The only button shape in the app.
struct BlockButtonStyle: ButtonStyle {
    var fill: Color
    var text: Color = Theme.ground

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .heavy, design: .monospaced))
            .kerning(1.5)
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(fill)
            // Square, apart from the smallest possible softening. A true right
            // angle looks like an unfinished view; a rounded one looks like
            // every other app.
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A label above a control, in the app's one small type style.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .kerning(2)
            .foregroundStyle(Theme.inkDim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
