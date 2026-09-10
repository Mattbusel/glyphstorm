import SwiftUI

/// Screen two. A preview and four controls.
///
/// Everything the app can do is on this screen at once, with no menus, no
/// tabs and nothing hidden behind a disclosure. There are four decisions to
/// make and they all fit, so hiding any of them would only be decoration.
struct EditorView: View {
    let source: Source
    var onBack: () -> Void

    @StateObject private var model = EditorModel()
    @State private var shareItem: ShareItem?

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                // The preview takes every point it can get. It is the product.
                MetalView(model: model)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                controls
            }

            if model.isExporting {
                exportOverlay
            }
        }
        .onAppear { model.prepare(with: source) }
        .onChange(of: model.exportedURL) { _, url in
            guard let url else { return }
            shareItem = ShareItem(url: url)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Text("← NEW")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .kerning(1.5)
                    .foregroundStyle(Theme.inkDim)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach([Theme.vermilion, Theme.amber, Theme.magenta, Theme.cyan], id: \.self) {
                    Rectangle().fill($0).frame(width: 10, height: 10)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var controls: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                FieldLabel(text: "Style")
                HStack(spacing: 8) {
                    ForEach(MotionStyle.allCases) { option in
                        styleButton(option)
                    }
                }
            }

            VStack(spacing: 8) {
                FieldLabel(text: "Amount")
                Slider(value: $model.amount, in: 0...1)
                    .tint(Theme.color(for: model.style))
            }

            VStack(spacing: 8) {
                FieldLabel(text: "Character Size")
                // Reversed feel: dragging right makes characters bigger, which
                // means fewer of them. The range tops out well before the
                // picture stops being readable.
                Slider(value: $model.cellSize, in: 5...22)
                    .tint(Theme.color(for: model.style))
            }

            Button("EXPORT") { model.export() }
                .buttonStyle(BlockButtonStyle(fill: Theme.cyan))
                .disabled(model.isExporting)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(Theme.raised.ignoresSafeArea(edges: .bottom))
    }

    private func styleButton(_ option: MotionStyle) -> some View {
        let selected = model.style == option
        let accent = Theme.color(for: option)
        return Button {
            model.style = option
        } label: {
            Text(option.title.uppercased())
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .kerning(1)
                .foregroundStyle(selected ? Theme.ground : accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(selected ? accent : Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("RENDERING")
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .kerning(3)
                    .foregroundStyle(Theme.ink)

                // A plain bar. A percentage is the one piece of information
                // that matters while waiting, so it is the only one shown.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.12))
                        Rectangle()
                            .fill(Theme.cyan)
                            .frame(width: geo.size.width * model.exportProgress)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 48)

                Text("\(Int(model.exportProgress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }
}

/// Wraps a URL so `.sheet(item:)` has something identifiable to hold.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The system share sheet.
///
/// Export goes through this rather than writing to the photo library directly,
/// which is why the app needs no photo permissions at all: the user decides
/// where the file goes, including "Save to Photos", and the system asks on
/// their behalf.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
