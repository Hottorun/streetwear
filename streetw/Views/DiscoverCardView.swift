// DiscoverCardView.swift
// One card, one screen, in one of three voices.
//
// The structure is the same whichever voice it speaks in, and that is what makes the feed
// scan: **who** at the top, **what** in the middle, **why** at the bottom. Only the
// contents change.
//
//     ┌──────────────────────────────────┐
//     │ [mark]  BRAND NAME       FOLLOW  │  who — always, and always here
//     │                                  │
//     │        photograph, or a          │  what — a garment, or a body of work
//     │        mosaic of the brand       │
//     │                                  │
//     │  ┌ [·] GOES WITH ──────┐         │  the anchor, on a pairing card only
//     │  └ YOUR KITH LAWSON TEE ┘        │
//     │ ──────────────────────────────── │
//     │ BRAND YOU MIGHT LIKE             │  why — the voice, said plainly
//     │ North Field                      │
//     │ Utility fabrics, garment-dyed…   │
//     │ 128 US$ · S M L XL               │
//     │ NOT FOR ME                  VIEW │
//     └──────────────────────────────────┘
//
// Two things it deliberately does *not* do, both of which the obvious design would.
//
// **The photograph is never cropped.** A feed like this wants to fill the frame edge to
// edge, and that works beautifully on the lookbook photography a mockup is drawn with. Real
// streetwear catalogues are packshots on a studio sweep, and filling a tall frame with a
// shoe photographed side-on cuts both ends off it. So the image fits, on `Color.sweep`, and
// the card earns its atmosphere from typography instead — which is what the rest of the app
// does anyway.
//
// **Nothing is white-on-dark.** The reading sits over the foot of a *light* sweep, so it is
// ink on paper like every other screen here. A dark scrim with white text is the house style
// of every other shopping app and none of this one.

import StreetwCore
import SwiftUI

struct DiscoverCardView: View {
    @Environment(DiscoveryAnalysis.self) private var analysis: DiscoveryAnalysis

    let entry: DeckCard
    let profile: SizeProfile
    /// The wardrobe, keyed by `pairingID`, so a `Garment` the ranking chose can be drawn.
    ///
    /// Built once by the feed rather than queried per card: a `@Query` here would put every
    /// card on screen on the `SavedItem` table, and three are realised at a time in a paging
    /// scroll.
    var wardrobe: [String: BrandUpdate] = [:]
    let onFollow: () async -> Void
    var onDismiss: () -> Void = {}
    var onSave: () -> Void = {}

    @State private var isFollowing = false
    /// The brief mark a double-tap leaves. Purely feedback — the save is already done and
    /// confirmed by the toast — but a gesture with no visible response reads as a miss.
    @State private var savedFlash = false

    private var card: DiscoverCard { entry.card }

    /// How much room the confirmation toast has to leave at the foot of this screen.
    ///
    /// The same obligation `ProductDetailView` has with its buy bar: the toast is anchored
    /// above the tab bar, which is right everywhere except the screens that put a control
    /// there.
    static let actionsHeight: CGFloat = 56

    // MARK: - What there is to draw

    /// The garment's photographs, promotional rows already refused on both ends.
    private var images: [URL] {
        BrandPreview.images(from: card.imageURLs, limit: 8)
    }

    /// The garments in a release — the only photographs it has, since a collection row
    /// carries none of its own.
    private var members: [URL] {
        BrandPreview.images(from: card.members, limit: 9)
    }

    /// The brand's range. Its lead shot is dropped where that shot is already the hero:
    /// repeating the photograph directly above wastes the row that exists to show breadth.
    private var spread: [URL] {
        let lead = entry.presentation == .brand ? nil : card.imageURLs.first
        return BrandPreview.images(from: card.spread.filter { $0 != lead }, limit: 9)
    }

    private var sizeEntries: [SizeRun.Entry] {
        SizeRun.entries(for: card.variants ?? [], profile: profile)
    }

    /// The wardrobe piece this card was matched against.
    ///
    /// One, not three. The old row showed the garment plus two of yours and read as a
    /// shopping basket; what makes the sentence land is naming **the** thing it goes with,
    /// which is also all the sentence itself claims.
    private var anchor: BrandUpdate? {
        guard !entry.isExploration, entry.presentation == .pairing else { return nil }
        return entry.pairs.first.flatMap { wardrobe[$0.id] }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            hero
            reading
        }
        .background(Color.sweep)
        // Measured only when it is actually being looked at: a fetch, a decode and two
        // Vision requests per card, on a screen built to be scrolled past.
        .task(id: card.productExternalID) { await analysis.analyse(card) }
        .contentShape(.rect)
        // The discoverable version of a gesture this deliberately does not have — see
        // `DiscoverFeedView` for why refusing is a button and never a flick.
        .contextMenu {
            Button("Not for me", systemImage: "hand.thumbsdown") { onDismiss() }
        }
    }

    private var hero: some View {
        ZStack(alignment: .top) {
            switch entry.presentation {
            case .release, .brand:
                // Both of these are cards about a body of work rather than one garment, so
                // both are drawn as a wall of it. The difference is what the wall *is*: a
                // release shows its own contents, a brand shows its range.
                DiscoverMosaic(
                    urls: entry.presentation == .release ? members : spread,
                    mark: card.brand.name
                )
            case .pairing:
                DiscoverPhotos(urls: images, mark: card.brand.name)
            }

            // **The save target is its own layer, above the pager.** Attached to the card as
            // a whole it never fires: the photographs are a paging `TabView`, which takes the
            // touch before an outer gesture is consulted.
            Color.clear
                .contentShape(.rect)
                .onTapGesture(count: 2) { flashSave() }

            identity
            if let anchor { anchorChip(anchor) }

            if savedFlash {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(Color.sweepInk.opacity(0.85))
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Who

    /// The brand, at the top of every card whatever it is about.
    ///
    /// It used to sit at the foot under the photograph, which buried the one fact the whole
    /// tab exists to deliver — and put Follow, the action the card is *for*, at the bottom of
    /// a stack of secondary controls. A card whose subject is a label should say the label
    /// first.
    private var identity: some View {
        HStack(spacing: 11) {
            BrandMonogram(
                name: card.brand.name,
                logoURL: card.brand.logoURL.flatMap(URL.init(string:)),
                size: 32
            )
            Wordmark(name: card.brand.name, size: 13, color: .sweepInk)
                .lineLimit(1)

            Spacer(minLength: 8)

            FollowButton(isWorking: $isFollowing, action: onFollow, width: 84)
        }
        .padding(.horizontal, 18)
        // Clears the status bar by hand: the feed ignores safe areas so a card and a page
        // are exactly one screen, which leaves every overlay to inset itself.
        .padding(.top, 64)
    }

    /// "Goes with your Kith Lawson Tee", with the thing itself beside it.
    ///
    /// The photograph is the point. A line of text claiming a match is a claim; the same line
    /// with your own jacket next to it is checkable at a glance, which is the difference
    /// between a recommendation and an assertion.
    private func anchorChip(_ item: BrandUpdate) -> some View {
        HStack(spacing: 9) {
            DiscoverSticker(
                image: LocalImage.load(item.cutoutURL),
                fallback: FitPieceImage.source(for: item),
                mark: item.brandLabel ?? item.title,
                side: 34
            )
            VStack(alignment: .leading, spacing: 2) {
                DataLabel(text: "GOES WITH", size: 9, color: .sweepInk.opacity(0.5))
                Text(item.title)
                    .font(.editorial(12))
                    .foregroundStyle(Color.sweepInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: 168, alignment: .leading)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Color.paper.opacity(0.95))
        .overlay { Rectangle().stroke(Color.hairline, lineWidth: 0.5) }
        .padding(.horizontal, 18)
        .padding(.top, 112)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Why

    private var reading: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
                .padding(.bottom, 14)

            // The voice, said plainly rather than left to be inferred from the layout.
            // Vermilion only on the pairing, which is the only one of the three that is
            // about *this person* — the accent is rationed to things that are, and spending
            // it on all three would spend it on none.
            DataLabel(
                text: contextLabel,
                size: 10,
                color: entry.presentation == .pairing ? .signal : .sweepInk.opacity(0.5)
            )
            .padding(.bottom, 7)

            Text(headline)
                .font(.editorial(entry.presentation == .pairing ? 21 : 25))
                .foregroundStyle(Color.sweepInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let subline {
                Text(subline)
                    .font(.editorial(14))
                    .foregroundStyle(Color.sweepInk.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }

            if !metaTokens.isEmpty || showsSizeRun {
                metaRow.padding(.top, 12)
            }

            actions.padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        // Clears the floating tab bar. Without enough of it the controls are unreachable —
        // see the note on the feed's safe-area handling.
        .padding(.bottom, 108)
    }

    /// What kind of card this is, in the app's own words.
    private var contextLabel: String {
        switch entry.presentation {
        case .release:
            let count = card.memberCount
            return count > 0 ? "NEW COLLECTION · \(count) PIECES" : "NEW COLLECTION"
        case .pairing:
            // The verdict's own sentence where there is one — `Pairing` returns none until a
            // photograph has been read, and inventing one would be a claim we cannot back.
            return (entry.reason ?? "Goes with what you own").uppercased()
        case .brand:
            return entry.isExploration ? "NEW TO YOU" : "BRAND YOU MIGHT LIKE"
        }
    }

    /// A release and a brand card are *about* the label, so the label is the headline. Only a
    /// pairing is about a particular garment.
    private var headline: String {
        switch entry.presentation {
        case .release: return card.title
        case .pairing: return card.title
        case .brand: return card.brand.name
        }
    }

    /// One line of prose, and every version of it is either the storefront's own words or a
    /// statement of measured fact. Nothing here is written *about* a brand by this app.
    private var subline: String? {
        switch entry.presentation {
        case .release:
            // A season's page usually says what the season is, and it is the only sentence in
            // this whole system a human actually wrote.
            return card.summary?.condensed
        case .pairing:
            return card.summary?.condensed ?? makesLine
        case .brand:
            return makesLine ?? card.summary?.condensed
        }
    }

    /// What the catalogue is mostly made of, and where it sits on price. The same reading
    /// `BrandPreviewSheet` prints off the same vector, so two screens cannot disagree about
    /// one shop.
    private var makesLine: String? {
        guard let vector = card.vector else { return nil }
        let named = vector.categories
            .filter { $0.key != GarmentSlot.unknown.rawValue && $0.value >= 0.12 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .compactMap { GarmentSlot(rawValue: $0.key)?.label.lowercased() }
        guard !named.isEmpty else { return nil }

        var line = named.joined(separator: ", ")
        if let band = priceBand { line += " · \(band)" }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Words rather than an amount, because `pricePercentile` is a *rank*: brands store their
    /// own currency and there are no exchange rates anywhere in this system.
    private var priceBand: String? {
        switch card.vector?.pricePercentile {
        case .some(..<0.25): return "among the cheaper here"
        case .some(..<0.5): return "below the middle"
        case .some(..<0.75): return "above the middle"
        case .some: return "among the dearest here"
        case nil: return nil
        }
    }

    /// **A price and a size run describe a garment, so only a garment card carries them.**
    /// They were on all three, which put "44 US$" and a vermilion L under a card whose
    /// headline was *Gymshark US* — pricing a company at the cost of whichever product
    /// happened to carry the card. A brand card names where to find it instead.
    private var metaTokens: [String] {
        switch entry.presentation {
        case .pairing:
            return card.priceText.map { [$0] } ?? []
        case .brand:
            return card.brand.website
                .flatMap { URL(string: $0)?.host() }
                .map { [$0.replacingOccurrences(of: "www.", with: "")] } ?? []
        case .release:
            return []
        }
    }

    private var showsSizeRun: Bool {
        entry.presentation == .pairing && !sizeEntries.isEmpty
    }

    private var metaRow: some View {
        HStack(spacing: 9) {
            ForEach(Array(metaTokens.enumerated()), id: \.offset) { index, token in
                if index > 0 {
                    Circle()
                        .fill(Color.sweepInk.opacity(0.28))
                        .frame(width: 3, height: 3)
                }
                Text(token)
                    .font(.data(13, .semibold))
                    .foregroundStyle(Color.sweepInk)
                    .lineLimit(1)
            }
            if showsSizeRun {
                // Unwrapped, so `limit` has to keep it short — a `.fixedSize()` run that does
                // not clip sets the width of everything beside it, and a sneaker's full
                // ladder measured 892pt on a 402pt phone.
                SizeRun(entries: sizeEntries, size: 11, limit: 6)
            }
            Spacer(minLength: 0)
        }
    }

    /// The two secondary actions. Follow is not among them — it lives at the top, beside the
    /// brand it applies to.
    private var actions: some View {
        HStack(spacing: 0) {
            Button(action: onDismiss) {
                DataLabel(text: "NOT FOR ME", size: 11, color: .sweepInk.opacity(0.5))
                    .frame(height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)

            if let link = card.linkURL.flatMap(URL.init(string:)) {
                Link(destination: link) {
                    DataLabel(text: "VIEW", size: 11, color: .sweepInk)
                        .frame(height: 30)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.sweepInk).frame(height: 1).offset(y: -6)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func flashSave() {
        onSave()
        withAnimation(.easeOut(duration: 0.18)) { savedFlash = true }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.easeIn(duration: 0.25)) { savedFlash = false }
        }
    }
}

private extension String {
    /// A storefront description as one readable line.
    ///
    /// These arrive as `body_html` — tags, entities and newlines — and a card has room for a
    /// sentence. Nil rather than empty when there is nothing left after stripping, so the
    /// caller prints one less line instead of an empty one.
    var condensed: String? {
        let stripped = replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return stripped.isEmpty ? nil : stripped
    }
}

/// A wall of a brand's work — a release's contents, or a label's range.
///
/// **A collection row carries no photograph**, and a brand is not one garment either, so both
/// of these cards are drawn out of many. A mosaic rather than a strip because both are about
/// plurality: a row of three suggests three things where there are sixty, and the count in
/// the caption says the real number.
private struct DiscoverMosaic: View {
    let urls: [URL]
    let mark: String

    /// Three across. Two reads as a comparison and four is a contact sheet; at three a
    /// nine-up grid still shows each garment large enough to want.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        if urls.isEmpty {
            Wordmark(name: mark, size: 15, color: .sweepInk.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Whole rows only. Eight photographs left a hole in the bottom-right corner
            // that read as a tile still loading rather than as the end of the wall.
            let whole = Array(urls.prefix((urls.count / 3) * 3))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(whole.isEmpty ? urls : whole, id: \.self) { url in
                        UpdateImage(
                            url: url,
                            aspect: 1,
                            // `.fill` here, unlike a single garment. A mosaic's job is the
                            // rhythm of the grid — nine tiles each letterboxing to a
                            // different shape reads as a broken layout rather than as a
                            // collection. The garment is shown whole on its own card.
                            contentMode: .fill,
                            drawnWidth: 400,
                            backdrop: .sweep,
                            mark: mark
                        )
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A full-bleed pager over one garment's photographs.
///
/// **Not `ImageGallery`.** That component is hardcoded to `aspect: 1, contentMode: .fit` — a
/// square on a wash — which is right for a feed card sitting in a column of other notices,
/// and wrong for a card that *is* the screen. Adding an aspect and a content mode there would
/// have reached five other callers to serve one.
///
/// What is carried over are the two behaviours that were bugs there first: the index resets
/// on `urls` (a card in a lazy stack is a view *description*, so a stale index opened the next
/// garment on its seventh frame, or on no frame at all), and neighbours are warmed (a
/// `TabView` builds a page only when reached, so every swipe arrived on an empty frame).
private struct DiscoverPhotos: View {
    let urls: [URL]
    let mark: String

    @State private var index = 0

    /// Not the original: Palace ships 3200² PNGs, which decode to a 41MB bitmap, and
    /// `ImageRendition` snaps to a ladder so nearby widths share one cache entry.
    private static let drawnWidth = 1200

    private var neighbours: [URL] {
        [index + 1, index + 2, index - 1]
            .filter { urls.indices.contains($0) }
            .map { urls[$0] }
    }

    private var clamped: Binding<Int> {
        // Clamped on the way out: `onChange` resets a reused pager, but it runs *after* the
        // body that first sees the new photographs.
        Binding(
            get: { min(max(index, 0), max(urls.count - 1, 0)) },
            set: { index = $0 }
        )
    }

    var body: some View {
        Group {
            if urls.isEmpty {
                Wordmark(name: mark, size: 15, color: .sweepInk.opacity(0.4))
            } else if urls.count == 1 {
                photo(urls[0])
            } else {
                TabView(selection: clamped) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { position, url in
                        photo(url).tag(position)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .task(id: clamped.wrappedValue) {
                    ImageLoader.shared.prefetch(neighbours, width: Self.drawnWidth)
                }
                .overlay(alignment: .bottom) {
                    // Rules rather than dots, and at the foot of the photograph rather than
                    // over its corner: the top of this card belongs to the brand, and a count
                    // in a capsule up there competed with the wordmark for the same glance.
                    HStack(spacing: 3) {
                        ForEach(urls.indices, id: \.self) { position in
                            Rectangle()
                                .fill(
                                    position == clamped.wrappedValue
                                        ? Color.sweepInk.opacity(0.55)
                                        : Color.sweepInk.opacity(0.16)
                                )
                                .frame(height: 2)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                }
            }
        }
        .onChange(of: urls) { _, _ in index = 0 }
    }

    /// **`.fit`, not `.fill`, and this one is measured rather than taste.** Filling looks
    /// right on a model shot and destroys a packshot: Allbirds photographs its shoes wide and
    /// side-on, so filling a tall frame cropped both ends off the shoe while leaving a band of
    /// empty sweep above it. Fitting letterboxes instead, which is the same choice the
    /// collection wall makes — *the wall never crops*.
    private func photo(_ url: URL) -> some View {
        CachedImage(url: url, width: Self.drawnWidth) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            Color.sweep
        } failure: {
            Wordmark(name: mark, size: 14, color: .sweepInk.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One garment, cut out where that was possible and honest where it wasn't.
///
/// The fallback is why this is a view rather than an `Image`. Subject lifting declines often
/// and for good reasons — a flat-lay has no single subject, a light garment on a light sweep
/// cannot be separated from it by construction, and **Vision does not run in the Simulator at
/// all**. A refused lift degrades to the photograph, which is what `FitPieceImage` already
/// does on the fit canvas; a missing photograph degrades to the wordmark, which is what
/// `UpdateImage.mark` does everywhere else. Each step says less; none says nothing.
private struct DiscoverSticker: View {
    let image: UIImage?
    let fallback: URL?
    let mark: String
    let side: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let fallback {
                CachedImage(url: fallback, width: Int(side * 3)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Color.clear
                } failure: {
                    Wordmark(name: mark, size: 8, color: .sweepInk.opacity(0.4))
                        .minimumScaleFactor(0.6)
                }
            } else {
                Wordmark(name: mark, size: 8, color: .sweepInk.opacity(0.4))
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: side, height: side)
    }
}
