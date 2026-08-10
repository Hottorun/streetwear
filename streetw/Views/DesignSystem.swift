// DesignSystem.swift
// The app's visual language, in one place.
//
// The brief is two rooms in one app (see ROADMAP's positioning): a **hype feed** that is
// allowed urgency, and a **collection** that is permanent and quiet. Rather than styling
// those separately and hoping they cohere, the whole app is achromatic — photographs
// carry every bit of colour — and exactly one accent exists, spent only on things that
// are time-critical. The feed is therefore the only place chroma ever appears, which is
// the calm/hype boundary made visible instead of merely intended.
//
// Three type roles, deliberately not "SF Pro at four sizes":
//
// - **New York** (serif) for titles. iOS ships it, almost nothing uses it, and it gives
//   the editorial voice a lookbook needs without bundling a font file.
// - **SF Pro in tracked caps** for brand names — a wordmark treatment, the way a credit
//   line is set under a photograph.
// - **SF Mono** for sizes, prices and times. Monospacing is not decoration here: it is
//   what makes the size run on one card align with the next one down the page.

import StreetwCore
import SwiftUI

// MARK: - Colour

extension Color {
    /// Near-black with a green cast rather than a blue one — reads as ink on paper
    /// instead of as a screen colour.
    static let ink = adaptive(light: 0x14140F, dark: 0xF5F5F0)
    /// Gallery wall. Barely off-white, so photographs sit on it rather than glow.
    static let paper = adaptive(light: 0xFAFAF7, dark: 0x0E0E0C)
    /// Where an image will be, and where one failed to load.
    static let wash = adaptive(light: 0xEFEEE9, dark: 0x1C1C19)
    static let muted = adaptive(light: 0x8A8A80, dark: 0x87877D)
    /// The only accent in the app. Vermilion, and strictly rationed: a restock, a size
    /// you wear, a storefront locking before a drop. If it stops meaning "this is
    /// happening now", it stops working.
    static let signal = adaptive(light: 0xD93A1E, dark: 0xFF5436)
    static let hairline = adaptive(light: 0xE2E1DB, dark: 0x262622)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Type

extension Font {
    /// Serif, for titles and mastheads. The editorial voice of the app.
    static func editorial(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Monospaced, for anything that is data: sizes, prices, times, counts.
    static func data(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Grotesque caps, for brand names. Always paired with `.tracking`.
    static func wordmark(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

/// A brand name, set as a wordmark: caps, widely tracked, never truncated mid-word.
struct Wordmark: View {
    let name: String
    var size: CGFloat = 13
    var color: Color = .ink

    var body: some View {
        Text(name.uppercased())
            .font(.wordmark(size))
            .tracking(size * 0.14)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Small monospaced label for metadata — a time, a count, a state.
struct DataLabel: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = .muted

    var body: some View {
        Text(text)
            .font(.data(size))
            .tracking(0.4)
            .foregroundStyle(color)
    }
}

// MARK: - The size run

/// The app's signature element, and the one place the data model shows through as
/// typography rather than as a sentence.
///
/// A product's full size run is printed the way a shop prints it — `XS S M L XL` — with
/// sold-out sizes struck through and the sizes *you wear* ruled in vermilion. It answers
/// "is this for me" in one glance, which is the entire point of holding a size profile,
/// and it does it without a badge, a pill or a sentence.
///
/// Degrades on purpose: server-synced items carry no variants, so the run falls back to
/// whatever came back in a restock. An empty run renders nothing rather than an empty box.
struct SizeRun: View {
    struct Entry: Hashable {
        var token: String
        var isAvailable: Bool
        /// In the user's profile — the thing worth the accent.
        var isMine: Bool
    }

    let entries: [Entry]
    var size: CGFloat = 12
    /// Above this many tokens the run stops printing sold-out sizes. A hoodie runs
    /// XS–XXL and fits; a sneaker runs 5 through 13 in half sizes and does not — and an
    /// overflowing run truncates every token to an ellipsis, which is worse than useless.
    var limit: Int = 8

    /// Long runs are narrowed to what you can actually buy. The line therefore always
    /// means the same thing — "these sizes are available" — with the struck-through
    /// sold-out sizes as extra texture whenever there is room for them.
    private var shown: [Entry] {
        guard entries.count > limit else { return entries }
        let available = entries.filter(\.isAvailable)
        return Array(available.prefix(limit))
    }

    var body: some View {
        if !shown.isEmpty {
            HStack(spacing: size * 0.7) {
                ForEach(shown, id: \.self) { entry in
                    Text(entry.token)
                        // Without this the stack compresses each token to "…" rather
                        // than letting the row overflow.
                        .fixedSize()
                        .font(.data(size, entry.isMine ? .semibold : .regular))
                        .strikethrough(!entry.isAvailable, color: .muted)
                        .foregroundStyle(color(for: entry))
                        .overlay(alignment: .bottom) {
                            // A rule under your size rather than a highlight behind it:
                            // it marks the run without interrupting the line of type.
                            if entry.isMine && entry.isAvailable {
                                Rectangle()
                                    .fill(Color.signal)
                                    .frame(height: 1.5)
                                    .offset(y: 3)
                            }
                        }
                        .accessibilityLabel(accessibilityLabel(for: entry))
                }
            }
            .lineLimit(1)
        }
    }

    private func color(for entry: Entry) -> Color {
        guard entry.isAvailable else { return .muted }
        return entry.isMine ? .signal : .ink
    }

    private func accessibilityLabel(for entry: Entry) -> String {
        switch (entry.isAvailable, entry.isMine) {
        case (false, _): "\(entry.token), sold out"
        case (true, true): "\(entry.token), your size, available"
        case (true, false): "\(entry.token), available"
        }
    }
}

extension SizeRun {
    /// Builds the run from an update, ordered the way a size run is actually printed:
    /// XS through XXXL, then shoe sizes ascending, then anything unrecognised.
    static func entries(for update: BrandUpdate, profile: SizeProfile) -> [Entry] {
        let meaningful = update.variants.filter(\.isMeaningfulSize)

        if meaningful.isEmpty {
            // Server-mode items ship without variants. What we do know is which sizes
            // just came back, and those are all available by definition.
            return update.restockedSizes
                .filter { $0 != "Default Title" && !$0.isEmpty }
                .map { Entry(token: $0.uppercased(), isAvailable: true, isMine: profile.matches($0)) }
        }

        // Collapse duplicates: a product with a colour axis repeats every size once per
        // colour, and printing "M M M L L L" would be nonsense. A size counts as
        // available if it is available in any colour.
        var byToken: [String: Entry] = [:]
        var order: [String] = []
        for variant in meaningful {
            let raw = variant.displaySize
            let token = SizeNormalizer.normalize(raw)?.token ?? raw.uppercased()
            if var existing = byToken[token] {
                existing.isAvailable = existing.isAvailable || variant.available
                byToken[token] = existing
            } else {
                byToken[token] = Entry(
                    token: token,
                    isAvailable: variant.available,
                    isMine: profile.matches(raw)
                )
                order.append(token)
            }
        }

        return order.compactMap { byToken[$0] }.sorted(by: canonical)
    }

    /// Apparel in shop order, then shoes numerically, then the rest as they came.
    private static func canonical(_ a: Entry, _ b: Entry) -> Bool {
        func rank(_ token: String) -> (Int, Double, String) {
            if let index = SizeProfile.apparelOptions.firstIndex(of: token) {
                return (0, Double(index), token)
            }
            if let value = Double(token) { return (1, value, token) }
            return (2, 0, token)
        }
        let (ga, va, ta) = rank(a.token)
        let (gb, vb, tb) = rank(b.token)
        if ga != gb { return ga < gb }
        if va != vb { return va < vb }
        return ta < tb
    }
}

// MARK: - Small pieces

/// Time, printed the way a drop is announced: relative while it matters, then the date.
enum Stamp {
    static func short(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d ago"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            return formatter.string(from: date).uppercased()
        }
    }
}

/// Navigation titles are the one piece of type SwiftUI won't let a view style, and left
/// alone they arrive as SF Bold — the single loudest thing on a page otherwise set in a
/// serif. Pushed through the UIKit appearance proxy so "Feed", "Brands", "Saved" and
/// "Style" speak in the same voice as everything under them.
enum Appearance {
    static func configure() {
        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        standard.largeTitleTextAttributes = [.font: serif(34, weight: .semibold)]
        standard.titleTextAttributes = [.font: serif(17, weight: .semibold)]

        UINavigationBar.appearance().standardAppearance = standard
        UINavigationBar.appearance().scrollEdgeAppearance = standard
        UINavigationBar.appearance().compactAppearance = standard
    }

    private static func serif(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// A hairline used as punctuation, not as furniture — one under a masthead, one between
/// brands. Anywhere else, whitespace does the job.
struct Rule: View {
    var color: Color = .hairline

    var body: some View {
        Rectangle().fill(color).frame(height: 0.5)
    }
}

/// Empty and error states get the same editorial voice as everything else: a serif line
/// that says what's true, a mono line that says what to do.
struct EditorialEmptyState: View {
    let title: String
    let action: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.editorial(24))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text(action)
                .font(.data(12))
                .tracking(0.4)
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
