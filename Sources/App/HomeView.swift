import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A picked video, copied somewhere this app can actually read it.
///
/// The picker hands over a file in a sandbox that stops being readable the
/// moment the transfer finishes, so it has to be copied out. Skipping the copy
/// works in the simulator and fails on a device, which is the worst kind of bug
/// to find after submitting.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Screen one. A title and two buttons.
struct HomeView: View {
    var onPick: (Source) -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // The mark: four flat bars, which is the app's own output
                // reduced to its simplest possible form.
                HStack(spacing: 6) {
                    ForEach(
                        [Theme.vermilion, Theme.amber, Theme.magenta, Theme.cyan],
                        id: \.self
                    ) { color in
                        Rectangle()
                            .fill(color)
                            .frame(width: 34, height: 34)
                    }
                }
                .padding(.bottom, 28)

                Text("ASCII")
                    .font(.system(size: 52, weight: .black, design: .monospaced))
                    .kerning(6)
                    .foregroundStyle(Theme.ink)
                Text("MOTION")
                    .font(.system(size: 52, weight: .black, design: .monospaced))
                    .kerning(6)
                    .foregroundStyle(Theme.cyan)

                Text("Pictures, rebuilt out of characters that move.")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.inkDim)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 14) {
                    PhotosPicker(
                        selection: $photoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Text("CHOOSE PHOTO")
                            .font(.system(size: 17, weight: .heavy, design: .monospaced))
                            .kerning(1.5)
                            .foregroundStyle(Theme.ground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Theme.amber)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    PhotosPicker(
                        selection: $videoItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Text("CHOOSE VIDEO")
                            .font(.system(size: 17, weight: .heavy, design: .monospaced))
                            .kerning(1.5)
                            .foregroundStyle(Theme.ground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Theme.magenta)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .padding(.horizontal, 24)
                .disabled(isLoading)
                .opacity(isLoading ? 0.5 : 1)

                if isLoading {
                    ProgressView()
                        .tint(Theme.cyan)
                        .padding(.top, 22)
                } else {
                    // Reserve the space so the buttons do not jump when a
                    // spinner appears under them.
                    Color.clear.frame(height: 42)
                }

                Spacer().frame(height: 24)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadPhoto(item)
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            loadVideo(item)
        }
        .alert(
            "Could not open that",
            isPresented: Binding(
                get: { loadError != nil },
                set: { if !$0 { loadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        isLoading = true
        Task {
            defer { isLoading = false; photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                loadError = "That photo could not be read."
                return
            }
            // Redrawn through UIImage so the picture arrives upright. A CGImage
            // taken straight off the file ignores its EXIF orientation, and
            // every photo shot in portrait comes out on its side.
            guard let upright = image.uprightCGImage() else {
                loadError = "That photo could not be read."
                return
            }
            onPick(.photo(upright))
        }
    }

    private func loadVideo(_ item: PhotosPickerItem) {
        isLoading = true
        Task {
            defer { isLoading = false; videoItem = nil }
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self),
                  let source = VideoSource(url: movie.url)
            else {
                loadError = "That video could not be read."
                return
            }
            await source.loadNaturalSize()
            onPick(.video(source))
        }
    }
}

extension UIImage {
    /// This image as a CGImage with its orientation already applied.
    ///
    /// Also caps the long edge. A modern phone photo is 48 megapixels and the
    /// app only ever samples it down to a few thousand cells, so carrying the
    /// full resolution around costs memory and buys nothing.
    func uprightCGImage(maxEdge: CGFloat = 2400) -> CGImage? {
        let longest = max(size.width, size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let drawn = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return drawn.cgImage
    }
}
