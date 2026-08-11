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
                    ImageGallery(urls: update.imageURLs, kind: update.kind, drawnWidth: 400)
                    SaveAction(update: update)
                        .padding(12)
                }
            }

            // Tapping opens the app's own page rather than ejecting to Safari. The
            // caption is also where quick-save listens, so the two coexist: a tap opens,
            // a horizontal drag files or dismisses, and the photograph above keeps its
            // paging.
            NavigationLink {
                ProductDetailView(update: update)
            } label: {
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
            .buttonStyle(.plain)
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
        NavigationLink {
            ProductDetailView(update: update)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Three to a row: a third of the screen, so the smallest rendition.
                // No gallery on a tile — at this size a second photograph is unreadable,
                // and it would put a paging gesture inside a grid that scrolls.
                UpdateImage(url: update.primaryImageURL, kind: update.kind, aspect: 1, drawnWidth: 130)
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
        .buttonStyle(.plain)
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
                drawnWidth: 200
            )

            VStack(alignment: .leading, spacing: 3) {
                if let brand = update?.brand {
                    Wordmark(name: brand.name, size: 9, color: .muted)
                }
                Text(update?.title ?? "Saved item")
                    .font(.editorial(12))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
    let update: BrandUpdate

    private var isSaved: Bool { update.save != nil }

    var body: some View {
        Button {
            if isSaved { removeSave(update, in: context) } else { setSave(update, .inspiration, in: context) }
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
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    let update: BrandUpdate

    var body: some View {
        Button("Save to Inspiration", systemImage: "bookmark") { setSave(update, .inspiration, in: context) }
        Button("Add to Wardrobe", systemImage: "tshirt") { setSave(update, .wardrobe, in: context) }

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

@MainActor
private func setSave(_ update: BrandUpdate, _ type: SavedItem.SaveType, in context: ModelContext) {
    if let save = update.save {
        save.type = type
    } else {
        context.insert(SavedItem(update: update, type: type))
    }
    update.isSeen = true
    try? context.save()
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
