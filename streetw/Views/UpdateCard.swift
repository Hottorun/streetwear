// UpdateCard.swift
// The visual units of the app. There are three, and the split is deliberate.
//
// `FeedLead` and `FeedTile` belong to the hype feed: they carry time, price, stock and
// the accent. `CollectionTile` belongs to the archive and carries none of that — no
// badge, no count, no "new" dot, per the positioning in ROADMAP. One shared card
// serving both rooms is exactly what that document says won't survive, so it doesn't.
//
// All three share `SaveAction` and `UpdateImage` so behaviour stays in one place.

import StreetwCore
import SwiftData
import SwiftUI

// MARK: - Navigation

// Every push in this app is **value-based**, and that is not a style preference.
//
// SwiftUI's two navigation models must not be mixed inside one stack. A destination
// -carrying `NavigationLink { … }` pushes by itself; `navigationDestination(for:)` pushes
// by appending to the stack's path. With both present the stack ends up tracking two
// notions of "what is on top", and the symptom is exactly what it sounds like: tapping a
// product on the "+36 more" page opened the product page *and pushed the +36 more page
// again on top of it*, because the destination link that had put that page there was
// re-activated by the value push.
//
// So: one route type per destination, registered once per stack via `appDestinations()`,
// and no `NavigationLink { … }` anywhere in a stack that uses them. The other reason to
// prefer values is that a destination link builds its destination eagerly for every row in
// a lazy list — a feed of 400 cards was constructing 400 product pages to show none of
// them.

/// A product page.
struct ProductRoute: Hashable {
    let update: BrandUpdate
}

/// A brand's own page.
struct BrandRoute: Hashable {
    let brand: Brand
}

/// Everything one brand has posted — where "+36 more" goes.
struct BrandFeedRoute: Hashable {
    let brand: Brand
    var unseenOnly: Bool = true
}

/// A collection announcement, and the garments that landed with it.
struct ReleaseRoute: Hashable {
    let update: BrandUpdate
}

extension View {
    /// Registers every destination this app pushes. Call once on each `NavigationStack`
    /// root — a route pushed onto a stack that hasn't registered it does nothing at all,
    /// silently, which is the one failure mode of value-based navigation.
    func appDestinations() -> some View {
        navigationDestination(for: ProductRoute.self) { ProductDetailView(update: $0.update) }
            .navigationDestination(for: BrandRoute.self) { BrandDetailView(brand: $0.brand) }
            .navigationDestination(for: BrandFeedRoute.self) {
                BrandFeedView(brand: $0.brand, unseenOnly: $0.unseenOnly)
            }
            .navigationDestination(for: ReleaseRoute.self) { CollectionReleaseView(update: $0.update) }
    }

    /// Makes this view push the product page, without taking the drag off it — the
    /// photograph in a feed card still pages, because a tap is not a drag.
    func productLink(_ update: BrandUpdate) -> some View {
        NavigationLink(value: ProductRoute(update: update)) { self }
            .buttonStyle(.plain)
    }
}

// MARK: - Feed: the lead

/// One brand's most recent item, printed large. The image is the argument; everything
/// else is a caption under it.
struct FeedLead: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    private var runEntries: [SizeRun.Entry] {
        SizeRun.entries(for: update, profile: sizes.profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No photograph, no photo block. A collection announcement or a page change
            // has nothing to show, and a full-width grey rectangle is worse than none —
            // it reads as a broken image rather than as a text item.
            if update.primaryImageURL != nil {
                ZStack(alignment: .topTrailing) {
                    // Square, not the 4:5 a lookbook would use. Storefront product shots
                    // are a centred object in a big white field, so a portrait crop
                    // mostly enlarges the emptiness — and pushed the size run, the one
                    // thing worth reading, below the fold on a large phone.
                    //
                    // All of the brand's photographs, not just the first: they were
                    // always fetched and stored, and the front of a garment is rarely the
                    // whole argument for it. Paging lives here and quick-save lives on
                    // the caption below, so the two never fight for the same swipe.
                    ImageGallery(
                        urls: update.imageURLs,
                        kind: update.kind,
                        drawnWidth: 400,
                        mark: update.brand?.name
                    )
                    SaveAction(update: update)
                        .padding(12)
                }
                // The photograph is the largest object on the screen and was the only
                // one that did nothing. Paging is a *drag*, so a tap costs it nothing —
                // the comment above is about the swipe, and a tap was never claimed.
                //
                // A **value** link, not `navigationDestination(isPresented:)`. That
                // modifier may be declared only once per stack, and there is one card per
                // brand in a `LazyVStack` — so every card registered its own and whichever
                // registered last answered for all of them. Tapping the lead opened the
                // card below it. The destination is registered once, on `FeedView`'s
                // stack, and every card here just names a value.
                .contentShape(.rect)
                .productLink(update)
            }

            // Tapping opens the app's own page rather than ejecting to Safari. The
            // caption is also where quick-save listens, so the two coexist: a tap opens,
            // a horizontal drag files or dismisses, and the photograph above keeps its
            // paging.
            Group {
                VStack(alignment: .leading, spacing: 7) {
                    if let state = FeedState(update: update, profile: sizes.profile) {
                        HStack(spacing: 6) {
                            // The dot is the "this is live" marker, so it only appears
                            // when the line is actually about you.
                            if state.isForMe {
                                Circle()
                                    .fill(Color.signal)
                                    .frame(width: 5, height: 5)
                            }
                            Text(state.text)
                                .font(.data(11, .medium))
                                .tracking(0.6)
                                .foregroundStyle(state.color)
                        }
                    }

                    Text(update.title)
                        .font(.editorial(21))
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .firstTextBaseline) {
                        SizeRun(entries: runEntries)
                        Spacer(minLength: 12)
                        if let price = update.priceText {
                            Text(price)
                                .font(.data(12, .medium))
                                .foregroundStyle(Color.ink)
                                .fixedSize()
                                // The price is short and never worth eliding; if anything
                                // has to give, it's the tail of the size run.
                                .layoutPriority(1)
                        }
                    }
                    .clipped()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .padding(.horizontal, 20)
                .contentShape(.rect)
            }
            .productLink(update)
            .quickSaveHandle()
        }
        .contentShape(.rect)
        .contextMenu { UpdateMenu(update: update) }
        .quickSave(update)
    }
}

// MARK: - Feed: the briefs

/// Everything else the brand posted. Small, cropped square, title only — enough to
/// recognise something, not enough to compete with the lead.
struct FeedTile: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    private var isMine: Bool { update.isInMySize(sizes.profile) }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                // Three to a row: a third of the screen, so the smallest rendition.
                // No gallery on a tile — at this size a second photograph is unreadable,
                // and it would put a paging gesture inside a grid that scrolls.
                UpdateImage(
                    url: update.primaryImageURL,
                    kind: update.kind,
                    aspect: 1,
                    drawnWidth: 130,
                    mark: update.brand?.name
                )
                    .overlay(alignment: .bottomLeading) {
                        // The accent again, at the smallest possible dose: a rule along
                        // the bottom edge means "your size is in there".
                        if isMine {
                            Rectangle()
                                .fill(Color.signal)
                                .frame(height: 2)
                        }
                    }

                Text(update.title)
                    .font(.editorial(12))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .productLink(update)
        .contextMenu { UpdateMenu(update: update) }
    }
}

// MARK: - Collection

/// The archive. No price, no stock, no time, no accent — a thing you kept, on a wall.
/// Resisting the urge to badge these is the whole difference between the two rooms.
struct CollectionTile: View {
    let save: SavedItem
    /// Varying heights are what make the wall read as a collection rather than a table.
    var aspect: CGFloat = 1
    /// Tapping opens the item's own page, not the storefront. In the feed the question
    /// is "can I buy this"; here it is "what did I think", and the note lives there.
    var onOpen: () -> Void = {}
    /// Whether the wall this tile is on is showing more than one label.
    ///
    /// A brand name earns its place by marking a *change* of brand. On a view that is
    /// entirely one label — a board, a collection early on — it repeats the same words
    /// down every tile, which makes the most-repeated element the one saying the least.
    /// Silent there instead.
    var showsBrand: Bool = true

    private var update: BrandUpdate? { save.update }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Two to a row on the collection wall, and never cropped. The feed fills its
            // tiles because a grid of thumbnails needs one rhythm; the archive is the
            // opposite — you kept these particular photographs, so they keep their own
            // proportions and a lookbook shot doesn't lose its top and bottom to a
            // square. The tile takes the picture's shape, so `.fit` letterboxes nothing
            // in the normal case and only rescues the extremes the clamp catches.
            UpdateImage(
                url: update?.primaryImageURL,
                kind: update?.kind ?? .product,
                aspect: aspect,
                contentMode: .fit,
                drawnWidth: 200,
                // Fixed, so the wall reads as photographs on paper in either appearance.
                // A brand that ships transparent PNGs was otherwise drawing a black
                // garment onto near-black at night — a caption with nothing above it —
                // while the brand next to it, shipping JPEGs on a white sweep, showed as a
                // lightbox in a dark tile. Neither was a fault in the photograph.
                backdrop: .sweep,
                mark: update?.brandLabel
            )

            VStack(alignment: .leading, spacing: 3) {
                // The garment first. The wordmark used to sit above the title in tracked
                // caps, which gave the most repeated line on the wall the most visual
                // weight — on a collection that is mostly one label, six tiles shouting
                // the same name over six different products. What you kept is the title;
                // who made it is the caption.
                Text(update?.title ?? "Saved item")
                    .font(.editorial(12))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // `brandLabel`, not `brand?.name`. A brand is only attached when the link
                // matched something followed, so anything shared from a label nobody has
                // added sat on the wall with no attribution at all — which is most of what
                // sharing is for. The site's own name for itself is the honest answer.
                if showsBrand, let label = update?.brandLabel {
                    Wordmark(name: label, size: 9, color: .muted)
                }
                // The one annotation worth showing on the wall: which size this is to
                // you. A note stays private to the item's own page — the collection is
                // meant to be looked at, not read.
                if let size = save.sizeNote, !size.isEmpty {
                    DataLabel(text: size.uppercased(), size: 9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .onTapGesture { onOpen() }
        .contextMenu { if let update { UpdateMenu(update: update) } }
    }
}

// MARK: - State

/// The one line of urgency a feed item is allowed. Nil means there is nothing
/// time-critical to say, and the card stays silent rather than inventing a status.
struct FeedState {
    let text: String
    /// Whether this is happening *to you*, which is the only thing allowed to spend the
    /// accent. A restock in a size you don't wear is still a fact worth printing — it is
    /// just not news, and printing it in vermilion said it was.
    let isForMe: Bool

    init?(update: BrandUpdate, profile: SizeProfile) {
        if update.brand?.isLockedForDrop == true {
            self.text = "LOCKED · DROP IMMINENT"
            self.isForMe = true
            return
        }
        switch update.kind {
        case .restock:
            let printable = update.restockedSizes.filter { $0 != "Default Title" && !$0.isEmpty }
            let mine = printable.filter { profile.matches($0) }

            // The bug this replaces: when nothing that came back was a size the user
            // wears, the card fell back to printing *every* returned size in the accent —
            // so a profile of S, M, L was told "BACK IN XL" in the colour reserved for
            // things that are happening to you. Now the sizes still print, because a
            // restock is genuinely news about the product, but the card only claims it is
            // yours when it is.
            let isMine = !mine.isEmpty
            let shown = isMine ? mine : printable

            self.isForMe = isMine
            self.text = shown.isEmpty
                ? "BACK IN STOCK"
                : "BACK IN \(shown.prefix(3).joined(separator: ", ").uppercased())"
        case .dropLock:
            self.text = "LOCKED · DROP IMMINENT"
            self.isForMe = true
        case .priceDrop:
            if let was = update.previousPriceText {
                self.text = "PRICE DROP · WAS \(was.uppercased())"
            } else {
                self.text = "PRICE DROP"
            }
            // A markdown on something you can't buy in your size isn't yours either.
            self.isForMe = profile.isEmpty || update.isInMySize(profile)
        case .collection:
            self.text = "NEW COLLECTION"
            self.isForMe = false
        default:
            guard update.isInMySize(profile) else { return nil }
            self.text = "IN YOUR SIZE"
            self.isForMe = true
        }
    }

    /// Vermilion only when it is actually about you; otherwise this is metadata.
    var color: Color { isForMe ? .signal : .muted }
}

// MARK: - Shared pieces

/// Save toggle. Deliberately unlabelled and quiet — it sits on a photograph.
struct SaveAction: View {
    @Environment(\.modelContext) private var context
    @Environment(SaveConfirmation.self) private var confirmation: SaveConfirmation
    let update: BrandUpdate

    private var isSaved: Bool { update.save != nil }

    var body: some View {
        Button {
            if isSaved {
                removeSave(update, in: context)
            } else {
                setSave(update, .inspiration, in: context, confirm: confirmation)
            }
        } label: {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSaved ? Color.signal : Color.ink)
                .frame(width: 30, height: 30)
                .background(Color.paper.opacity(0.92), in: Circle())
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.selection, trigger: isSaved)
        .accessibilityLabel(isSaved ? "Remove from saved" : "Save")
    }
}

/// One menu for all three cards, so the actions never drift apart.
struct UpdateMenu: View {
    @Environment(\.modelContext) private var context
    @Environment(SaveConfirmation.self) private var confirmation: SaveConfirmation
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    let update: BrandUpdate

    var body: some View {
        Button("Save to Inspiration", systemImage: "bookmark") {
            setSave(update, .inspiration, in: context, confirm: confirmation)
        }
        Button("Add to Wardrobe", systemImage: "tshirt") {
            setSave(update, .wardrobe, in: context, confirm: confirmation)
        }

        if !boards.isEmpty {
            Menu("Add to board", systemImage: "square.grid.2x2") {
                ForEach(boards) { board in
                    Button {
                        file(update, on: board)
                    } label: {
                        // A tick rather than a separate "remove from board" action:
                        // the menu shows where this already is, and tapping toggles it.
                        Label(board.name, systemImage: update.save?.board?.id == board.id ? "checkmark" : "square")
                    }
                }
            }
        }

        if update.save != nil {
            Button("Remove", systemImage: "trash", role: .destructive) { removeSave(update, in: context) }
        }
        if let link = update.linkURL {
            Divider()
            Link("Open on site", destination: link)
        }
    }

    /// Filing something that isn't saved yet saves it first — putting an item on a board
    /// is a stronger statement of intent than a bookmark, so it shouldn't require two
    /// actions in sequence.
    private func file(_ update: BrandUpdate, on board: Board) {
        if update.save == nil { setSave(update, .inspiration, in: context) }
        guard let save = update.save else { return }
        save.board = save.board?.id == board.id ? nil : board
        try? context.save()
    }
}

/// Keeps something, and — when a confirmation is passed — offers the two things you might
/// have meant instead.
///
/// The save is unconditional and complete before the confirmation is raised. Nothing here
/// waits on the toast, and dismissing it changes nothing: it amends an outcome rather than
/// standing between you and one.
@MainActor
private func setSave(
    _ update: BrandUpdate,
    _ type: SavedItem.SaveType,
    in context: ModelContext,
    confirm: SaveConfirmation? = nil
) {
    if let save = update.save {
        save.type = type
    } else {
        context.insert(SavedItem(update: update, type: type))
    }
    update.isSeen = true
    try? context.save()
    confirm?.confirm(update, destination: update.save?.board?.name ?? type.label)
}

@MainActor
private func removeSave(_ update: BrandUpdate, in context: ModelContext) {
    guard let save = update.save else { return }
    context.delete(save)
    try? context.save()
}

// MARK: - Compatibility

/// Still used by `BrandDetailView`'s horizontal strips.
struct UpdateCarousel: View {
    let updates: [BrandUpdate]
    var width: CGFloat = 150

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(updates) { update in
                    FeedTile(update: update)
                        .frame(width: width)
                }
            }
            .padding(.horizontal, 20)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        EditorialEmptyState(title: title, action: message)
    }
}
