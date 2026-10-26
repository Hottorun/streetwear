// FeedCard.swift
// One card in the feed: a photograph, the brand, one label, the price.
//
// **Four things, and no product name.** 1.0's first screen printed five counters and three
// lines of links before its one photograph, whose title and price sat under the tab bar. A
// feed card here says what happened and to whom, the picture says what it is, and tapping
// says the rest — the title, the size run, the time and the stock live on the page it opens.
//
// **Every event has a picture**, which is the deliberate change from 1.0's "only a sudden
// kind earns the lead photograph". That rule was about one large slot per brand; a grid has
// no lead to protect, and a price cut drawn as a sentence with no picture is the card nobody
// looks at. A product with no photograph shows the brand's wordmark in its place — a
// statement that there is no picture, never a tile that looks like one still loading
// (`UpdateImage.mark`). A sale has no garment, so it shows the brand's own marked-down stock.

import StreetwCore
import SwiftData
import SwiftUI

/// Where the page behind a card of several pieces goes: those pieces, and nothing else.
///
/// A list of rows rather than a query, because a burst is defined by the timeline — one
/// brand, one kind, thirty minutes — and the page has to hold exactly what the card counted.
/// "24 PIECES" opening onto a brand's whole catalogue would be the 1.0 "+8 MORE" lie again.
struct DropRoute: Hashable {
    let brand: Brand
    let kind: UpdateKind
    let pieces: [BrandUpdate]
}

struct FeedCard: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let card: FeedTimeline.Card
    /// The rows behind it, in the card's order — see `FeedPass.rows(of:)`.
    let rows: [BrandUpdate]
    let brand: Brand

    /// Drawn at half the phone. One rung of `ImageRendition`'s ladder, shared by every card.
    static let drawnWidth = 200

    var body: some View {
        if brand.isGone || rows.isEmpty || rows.contains(where: \.isGone) {
            // A card whose rows went in an unfollow, for the one pass the grid still holds it.
            Color.clear.frame(height: 0)
        } else {
            let face = face()
            link(face)
        }
    }

    // MARK: - What it says

    /// Everything the card prints, worked out once per body.
    private struct Face {
        var photos: [URL] = []
        var label = FeedLabel("")
        var price: String?
        var was: String?
        /// What is being looked at, for VoiceOver — the one place the title is still said.
        var subject: String
        /// The garment a bookmark saves, when the card is one.
        var garment: BrandUpdate?
    }

    private func face() -> Face {
        let profile = sizes.profile
        let lead = rows[0]
        switch card.shape {
        case .single:
            return single(lead, profile: profile)
        case .group:
            return Face(
                photos: Array(rows.lazy.compactMap(\.primaryImageURL).prefix(4)),
                label: FeedLabel.group(card.kind, deepestCut: rows.compactMap { Self.cut($0) }.max()),
                price: FeedLabel.pieces(rows.count, from: Self.cheapest(rows)),
                subject: card.kind.headline(count: rows.count)
            )
        case .release:
            // The page this opens lists `members(of:)`, so the count comes from the same place
            // — a card that says six above a page of nine is the disagreement this project
            // keeps a whole section of rules about.
            let members = brand.members(of: lead).filter { $0.passes(profile) }
            var photos = lead.primaryImageURL.map { [$0] } ?? []
            photos += members.lazy.compactMap(\.primaryImageURL).prefix(4 - photos.count)
            return Face(
                photos: photos,
                label: FeedLabel.release(title: lead.title),
                price: members.isEmpty ? nil : FeedLabel.pieces(members.count, from: Self.cheapest(members)),
                subject: lead.title
            )
        }
    }

    private func single(_ row: BrandUpdate, profile: SizeProfile) -> Face {
        let kind = row.kind
        if kind == .sale {
            return Face(
                photos: saleShelf(profile: profile),
                label: FeedLabel.single(.sale, title: row.title),
                subject: row.summary ?? row.title
            )
        }
        let isGarment = kind == .product || kind == .restock || kind == .priceDrop
        let isYours = kind == .restock && !profile.isEmpty && !row.restockedSizes(matching: profile).isEmpty
        return Face(
            photos: row.primaryImageURL.map { [$0] } ?? [],
            label: FeedLabel.single(kind, isYours: isYours, percentOff: Self.cut(row), title: row.title),
            price: isGarment ? row.priceLabel : nil,
            // Any garment the brand itself has marked down says so, a launch at a discount
            // included — the cut comes from the tag, and the "was" is how to check it.
            was: isGarment && row.priceText != nil ? row.wasPriceLabel : nil,
            subject: row.title,
            garment: isGarment ? row : nil
        )
    }

    /// The brand's own marked-down garments, newest first, else its newest garments.
    ///
    /// A sale has no garment behind it — the row is the brand's words — and a card made of a
    /// sentence is the one nobody looks at. What is on sale is the honest picture of a sale.
    /// Walks the brand's catalogue, which is acceptable for the one card a sale makes and is
    /// why nothing else here does it.
    private func saleShelf(profile: SizeProfile) -> [URL] {
        let shelf = brand.updates
            .filter { $0.kind != .sale && $0.hasPhotograph && $0.passes(profile) }
            .map { (update: $0, isMarkdown: $0.kind == .priceDrop, published: $0.publishedAt, id: $0.externalID) }
            .sorted { a, b in
                if a.isMarkdown != b.isMarkdown { return a.isMarkdown }
                return a.published == b.published ? a.id > b.id : a.published > b.published
            }
        return Array(shelf.lazy.compactMap(\.update.primaryImageURL).prefix(4))
    }

    /// The cut a card can claim, measured the way the product page measures it.
    private static func cut(_ row: BrandUpdate) -> Int? {
        PriceChange.percentOff(previous: row.previousPriceAmount, original: row.originalPriceAmount, now: row.priceAmount)
    }

    /// The cheapest way into several pieces, in its own currency.
    private static func cheapest(_ rows: [BrandUpdate]) -> String? {
        rows.filter { $0.priceAmount != nil && $0.priceText != nil }
            .min { $0.priceAmount! < $1.priceAmount! }?
            .priceLabel
    }

    // MARK: - Drawing

    @ViewBuilder
    private func link(_ face: Face) -> some View {
        let content = FeedCardFace(
            photos: face.photos,
            label: face.label,
            brand: brand.name,
            price: face.price,
            was: face.was,
            subject: face.subject,
            garment: face.garment
        )
        switch card.shape {
        case .group:
            NavigationLink(value: DropRoute(brand: brand, kind: card.kind, pieces: rows)) { content }
                .buttonStyle(.plain)
        case .release:
            NavigationLink(value: ReleaseRoute(update: rows[0])) { content }
                .buttonStyle(.plain)
                .contextMenu { siteLink(rows[0].linkURL) }
        case .single where card.kind == .sale:
            // A sale is about the brand, so its page is the destination — the same place a
            // push about one opens.
            NavigationLink(value: BrandRoute(brand: brand)) { content }
                .buttonStyle(.plain)
                .contextMenu { siteLink(rows[0].linkURL) }
        case .single:
            NavigationLink(value: ProductRoute(update: rows[0])) { content }
                .buttonStyle(.plain)
                .contextMenu {
                    if face.garment != nil { UpdateMenu(update: rows[0]) } else { siteLink(rows[0].linkURL) }
                }
        }
    }

    @ViewBuilder
    private func siteLink(_ url: URL?) -> some View {
        if let url { Link("Open on site", destination: url) }
    }
}

/// The drawing of a card, kept apart from deciding what it says so each can be read without
/// the other.
struct FeedCardFace: View {
    let photos: [URL]
    let label: FeedLabel
    let brand: String
    var price: String?
    var was: String?
    var subject: String = ""
    var garment: BrandUpdate?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedPicture(photos: photos, mark: brand)
                .accessibilityLabel(subject)
                .overlay(alignment: .topTrailing) {
                    // **Saving from the feed is the bookmark and the long-press menu.** There
                    // is no swipe: a half-width card dragged sideways covers its neighbour,
                    // and the one thing 1.0's swipe did that nothing else could — marking a
                    // card read — no longer exists. Filing is the confirmation's Board, or the
                    // menu's "Add to board".
                    if let garment { SaveAction(update: garment).padding(2) }
                }

            VStack(alignment: .leading, spacing: 5) {
                FeedLabelText(label: label)
                Wordmark(name: brand, size: 9.5)
                if price != nil || was != nil {
                    FeedPrice(price: price, was: was)
                }
            }
        }
        .contentShape(.rect)
    }
}

/// The label, with the dot that says it is about you when it is.
struct FeedLabelText: View {
    let label: FeedLabel
    var size: CGFloat = 10

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if label.isUrgent {
                Circle()
                    .fill(Color.signal)
                    .frame(width: 5, height: 5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            }
            Text(label.text)
                .font(.data(size, .medium))
                .tracking(0.5)
                .foregroundStyle(label.isUrgent ? Color.signal : Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The price, with what it was struck through beside it when the brand published one.
struct FeedPrice: View {
    let price: String?
    let was: String?
    var size: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let was {
                Text(was)
                    .font(.data(size))
                    .strikethrough(color: .muted)
                    .foregroundStyle(Color.muted)
            }
            if let price {
                Text(price)
                    .font(.data(size, .medium))
                    .foregroundStyle(Color.ink)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// The square at the top of a card: one photograph, or a mosaic for a card of several.
///
/// Three photographs make one large and two small, four make a two-by-two; fewer than three
/// is the first one alone, because a mosaic with a hole in it reads as a picture that failed.
struct FeedPicture: View {
    let photos: [URL]
    /// The brand, set in place of a photograph that does not exist.
    let mark: String

    private static let gap: CGFloat = 2

    var body: some View {
        if photos.count >= 3 {
            Color.wash
                .aspectRatio(1, contentMode: .fit)
                .overlay { GeometryReader { mosaic(in: $0.size) } }
                .clipped()
        } else {
            UpdateImage(url: photos.first, aspect: 1, drawnWidth: FeedCard.drawnWidth, mark: mark)
        }
    }

    @ViewBuilder
    private func mosaic(in size: CGSize) -> some View {
        let half = (size.width - Self.gap) / 2
        if photos.count >= 4 {
            VStack(spacing: Self.gap) {
                HStack(spacing: Self.gap) { tile(0, half, half); tile(1, half, half) }
                HStack(spacing: Self.gap) { tile(2, half, half); tile(3, half, half) }
            }
        } else {
            HStack(spacing: Self.gap) {
                tile(0, half, size.height)
                VStack(spacing: Self.gap) { tile(1, half, half); tile(2, half, half) }
            }
        }
    }

    private func tile(_ index: Int, _ width: CGFloat, _ height: CGFloat) -> some View {
        UpdateImage(url: photos[index], aspect: width / max(height, 1), drawnWidth: Int(width.rounded()), mark: mark)
            .frame(width: width, height: height)
            .clipped()
    }
}
