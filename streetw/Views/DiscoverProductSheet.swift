// DiscoverProductSheet.swift
// The garment on a discovery card, looked at properly.
//
// The deck used to end at a link. A card carried a `VIEW` control in the corner of its
// action row that opened the storefront in Safari — which is the last step of a decision,
// offered as the *only* step: no size run, no colourways, no description, nothing to read.
// Everywhere else in the app a garment has a page, and tapping the photograph is how you
// get to it; here the photograph did nothing and a small underlined word threw you out of
// the app entirely.
//
// So `VIEW` is gone and this is what the picture opens. It is deliberately **not**
// `ProductDetailView`: that page takes a `BrandUpdate`, and a discovery card has no row in
// the store and must not be given one — the deck's whole no-pollution rule is that a card
// from an unfollowed brand writes nothing until somebody keeps it, since `FeedView` queries
// `!isSeen` and a stored page would empty thousands of products into the unread feed. Every
// component here is shared with that page rather than restyled, so the two cannot drift:
// `ImageGallery`, `SizeRun`, `StorefrontBar`.
//
// What the sheet says that the card deliberately does not:
//
// - **The size run.** A card carries none, on purpose — it is an argument for a *brand*, in
//   a scroll nobody is shopping in yet. This is the page where "is it in my size" is the
//   question, so it is answered here, in the app's own vermilion.
// - **The description**, in full rather than condensed to a line.
// - **The way to the storefront**, which is what `VIEW` was, now pinned at the foot where
//   every other product page in the app keeps it.

import StreetwCore
import SwiftUI

struct DiscoverProductSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let card: DiscoverCard
    /// Whether the garment is already in the collection, so the one control here that
    /// changes anything says which it is.
    var isSaved: Bool
    var onSave: () -> Void = {}
    /// Opens the whole outfit built around this garment — the same route the card's pairing
    /// chip takes, offered again here because this is the page somebody reaches when they
    /// have decided they are interested.
    var onOpenFit: (() -> Void)?

    @State private var colorway: String?

    private var imageURLs: [URL] {
        card.imageURLs.compactMap(URL.init(string:))
    }

    /// The variants in the selected colourway, or all of them.
    ///
    /// "Which sizes are left in black" is a different question from "which sizes are left",
    /// and on a product page it is usually the one being asked — the same narrowing
    /// `ProductDetailView` does through the same `ColorwaySection`.
    private var variants: [VariantInfo] {
        let all = card.variants ?? []
        guard let colorway else { return all }
        return all.filter { $0.color?.caseInsensitiveCompare(colorway) == .orderedSame }
    }

    private var colorways: [Colorway] {
        Colorways.from(card.variants ?? [])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ImageGallery(
                        urls: imageURLs,
                        drawnWidth: 900,
                        isZoomable: true,
                        // Fixed sweep, like the collection wall and like the card this was
                        // opened from: a photograph does not invert, so what it sits on
                        // must not either.
                        backdrop: .sweep,
                        mark: card.brand.name
                    )
                    .padding(.bottom, 18)

                    heading
                    if !sizeEntries.isEmpty { sizeRun }
                    if !colorways.isEmpty {
                        ColorwaySection(colorways: colorways, selected: $colorway)
                            .padding(.top, 20)
                    }
                    if let summary = card.summary?.readable { description(summary) }
                    actions
                }
                .padding(.bottom, StorefrontBar.height + 20)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle(card.brand.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let url = card.linkURL.flatMap(URL.init(string:)) {
                    StorefrontBar(url: url, isSoldOut: card.isAvailable == false)
                }
            }
        }
        .tint(.ink)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.editorial(24))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                if let price = card.priceText {
                    Text(price)
                        .font(.data(14, .semibold))
                        .foregroundStyle(Color.ink)
                }
                if card.isAvailable == false {
                    DataLabel(text: "SOLD OUT", size: 10, color: .signal)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
    }

    /// The run this page exists to print. **Wrapped**, because `limit` is raised past the
    /// card's — a sneaker's full ladder is 892pt on a 402pt phone unwrapped, and a `VStack`
    /// is as wide as its widest child, so an unwrapped run would set the width of the whole
    /// sheet and push the photograph off the screen. See `SizeRun.wraps`.
    private var sizeRun: some View {
        VStack(alignment: .leading, spacing: 8) {
            DataLabel(text: "SIZES", size: 9)
            SizeRun(entries: sizeEntries, size: 13, limit: .max, wraps: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var sizeEntries: [SizeRun.Entry] {
        SizeRun.entries(for: variants, profile: sizes.profile)
    }

    private func description(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rule().padding(.top, 22)
            Text(text)
                .font(.editorial(15))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Button(action: onSave) {
                HStack(spacing: 7) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 12, weight: .medium))
                    Text(isSaved ? "SAVED" : "SAVE")
                        .font(.data(11, .semibold))
                        .tracking(1)
                }
                .foregroundStyle(isSaved ? Color.signal : Color.ink)
                .frame(height: 34)
                .padding(.horizontal, 16)
                .overlay { Capsule().stroke(isSaved ? Color.signal : Color.ink, lineWidth: 1) }
            }
            .buttonStyle(.borderless)

            if let onOpenFit {
                Button(action: onOpenFit) {
                    HStack(spacing: 5) {
                        DataLabel(text: "BUILD A FIT", size: 11, color: .ink)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.muted)
                    }
                    .frame(height: 34)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }
}

extension String {
    /// A storefront description as readable prose.
    ///
    /// These arrive as `body_html` — tags, entities and newlines. The card condenses the
    /// same field onto one line; here the paragraphs are worth keeping, so only the markup
    /// goes. Nil rather than empty when there is nothing left, so the caller draws one less
    /// block instead of an empty one.
    var readable: String? {
        let stripped = replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}
