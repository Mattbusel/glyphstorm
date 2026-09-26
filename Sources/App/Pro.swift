import StoreKit
import SwiftUI

/// Glyphstorm Pro: one non-consumable.
///
/// Free: every photo and video, all three motions, both sliders, and export.
/// Free exports carry a small GLYPHSTORM mark in the corner, render at screen
/// resolution, and stop videos at five seconds. Pro removes the mark, renders at
/// twice the resolution, and runs videos to the full fifteen seconds.
///
/// Anyone who first installed a build before `firstFreemiumBuild` bought the app
/// outright and keeps everything. AppTransaction's originalAppVersion is that
/// build number. Only trusted in production: sandbox and Xcode report made-up
/// values, and App Review must see the real paywall.
@MainActor
final class Pro: ObservableObject {
    static let productID = "com.mattbusel.asciimotion.pro"
    static let firstFreemiumBuild = 2

    /// What the free tier is allowed.
    static let freeVideoSeconds: Double = 5

    @Published private(set) var unlocked: Bool
    @Published private(set) var product: Product?
    @Published var busy = false
    @Published var message: String?
    @Published var showPaywall = false

    private var grandfathered = false
    private var updates: Task<Void, Never>?
    private let key = "glyphstorm.pro.unlocked"
    private let forced: Bool

    /// Screenshot runs never touch StoreKit. The store shots show the editor
    /// clean; `-showPaywall` shows the paywall for the purchase's review shot.
    init() {
        let args = ProcessInfo.processInfo.arguments
        forced = args.contains("-screenshots")
        if forced {
            unlocked = !args.contains("-showPaywall")
            showPaywall = args.contains("-showPaywall")
            return
        }
        unlocked = UserDefaults.standard.bool(forKey: key)
        updates = Task { [weak self] in
            for await result in Transaction.updates { await self?.apply(result) }
        }
        Task { await refresh() }
    }

    var price: String { product?.displayPrice ?? "$4.99" }

    func refresh() async {
        guard !forced else { return }
        if product == nil { product = try? await Product.products(for: [Pro.productID]).first }
        for await result in Transaction.currentEntitlements { await apply(result) }
        if case .verified(let app)? = try? await AppTransaction.shared,
           app.environment == .production,
           (Int(app.originalAppVersion) ?? Int.max) < Pro.firstFreemiumBuild {
            grandfathered = true
            grant()
        }
    }

    func buy() async {
        guard !forced, !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        if product == nil { product = try? await Product.products(for: [Pro.productID]).first }
        guard let product else {
            message = "The App Store did not answer. Check your connection and try again."
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let result):
                await apply(result)
                if !unlocked { message = "Apple could not confirm the purchase. Try Restore in a minute." }
            case .pending:
                message = "Waiting for approval. Pro unlocks by itself once it is approved."
            case .userCancelled:
                break
            @unknown default:
                message = "Something unexpected happened. You were not charged."
            }
        } catch {
            message = "The purchase did not go through: \(error.localizedDescription)"
        }
    }

    func restore() async {
        guard !forced, !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do { try await AppStore.sync() } catch {
            if let e = error as? StoreKitError, case .userCancelled = e { return }
            message = "Could not reach the App Store. Check your connection and try again."
            return
        }
        await refresh()
        message = unlocked ? "Pro is unlocked. Welcome back." : "No Pro purchase found on this Apple ID."
    }

    private func apply(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let t) = result, t.productID == Pro.productID else { return }
        if t.revocationDate == nil { grant() } else if !grandfathered { revoke() }
        await t.finish()
    }

    private func grant() {
        guard !unlocked else { return }
        unlocked = true
        showPaywall = false
        UserDefaults.standard.set(true, forKey: key)
    }

    private func revoke() {
        unlocked = false
        UserDefaults.standard.set(false, forKey: key)
    }
}

// MARK: - Paywall

/// Flat blocks on the dark ground, like the rest of the app. The four accent
/// squares become the four things Pro changes.
struct PaywallView: View {
    @EnvironmentObject private var pro: Pro

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        HStack(spacing: 4) {
                            ForEach([Theme.vermilion, Theme.amber, Theme.magenta, Theme.cyan], id: \.self) {
                                Rectangle().fill($0).frame(width: 10, height: 10)
                            }
                        }
                        Spacer()
                        Button("CLOSE") { pro.showPaywall = false }
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .kerning(1.5)
                            .foregroundStyle(Theme.inkDim)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text("GLYPH")
                            .font(.system(size: 44, weight: .black, design: .monospaced))
                            .kerning(5)
                            .foregroundStyle(Theme.ink)
                        HStack(spacing: 10) {
                            Text("STORM")
                                .font(.system(size: 44, weight: .black, design: .monospaced))
                                .kerning(5)
                                .foregroundStyle(Theme.cyan)
                            Text("PRO")
                                .font(.system(size: 16, weight: .black, design: .monospaced))
                                .kerning(2)
                                .foregroundStyle(Theme.ground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Theme.amber)
                        }
                    }

                    Text("Everything is free to make. Pro is for exports you want to post as they are.")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 10) {
                        row(Theme.vermilion, "NO MARK", "Exports without the GLYPHSTORM corner mark.")
                        row(Theme.amber, "2X SHARP", "Rendered at twice the resolution, crisp on any screen.")
                        row(Theme.magenta, "15 SECONDS", "Videos run to fifteen seconds instead of five.")
                        row(Theme.cyan, "ONCE", "One payment, yours for good. No subscription.")
                    }

                    if let m = pro.message {
                        Text(m)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 12) {
                        Button(pro.busy ? "ONE MOMENT" : "UNLOCK PRO  \(pro.price)") {
                            Task { await pro.buy() }
                        }
                        .buttonStyle(BlockButtonStyle(fill: Theme.cyan))
                        .disabled(pro.busy)

                        Button("RESTORE PURCHASE") { Task { await pro.restore() } }
                            .buttonStyle(BlockButtonStyle(fill: Theme.raised, text: Theme.ink))
                            .disabled(pro.busy)
                    }

                    Text("Family Sharing works. Nothing you make is ever locked; free exports are yours to keep and share.")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Rectangle().fill(color).frame(width: 18, height: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .kerning(1.5)
                    .foregroundStyle(color)
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
