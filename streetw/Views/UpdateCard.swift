// UpdateCard.swift
// The routes every card pushes, and the archive's tile.
//
// The feed's cards live in `Views/Feed/` now (`FeedCard`): one picture card per event. What
// stays here is shared by both rooms — `SaveAction` and `UpdateMenu`, so saving behaves the
// same everywhere — and `CollectionTile`, which belongs to the archive and carries none of
// the feed's urgency: no badge, no count, no "new" dot, per the positioning in ROADMAP. One
// shared card serving both rooms is exactly what that document says won't survive.

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
            .navigationDestination(for: ReleaseRoute.self) { CollectionReleaseView(update: $0.update) }
            .navigationDestination(for: DropRoute.self) {
                DropPiecesView(brand: $0.brand, kind: $0.kind, pieces: $0.pieces)
            }
    }

    /// Makes this view push the product page.
    func productLink(_ update: BrandUpdate) -> some View {
        NavigationLink(value: ProductRoute(update: update)) { self }
            .buttonStyle(.plain)
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
    /// Nil when the wall is not selecting; otherwise whether this tile is in the selection.
    /// While selecting, a tap is `onOpen` — which the wall points at the selection instead
    /// of at the item's page — and the long-press menu is withheld, because a menu of
    /// one-item actions over a many-item selection would act on the wrong thing.
    var isSelected: Bool?
    /// Starts selecting with this tile, from its long-press menu. Nil where the host has no
    /// select mode.
    var onSelect: (() -> Void)?

    private var update: BrandUpdate? { save.update }

    var body: some View {
        // Nothing for a save deleted out from under the wall — a bulk delete removes rows the
        // lazy stack may still hold for one pass, and every read below would trap.
        if save.isGone {
            Color.clear.frame(width: 0, height: 0)
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Two to a row on the collection wall, and never cropped. The feed fills its
            // tiles because a grid of thumbnails needs one rhythm; the archive is the
            // opposite — you kept these particular photographs, so they keep their own
            // proportions and a lookbook shot doesn't lose its top and bottom to a
            // square. The tile takes the picture's shape, so `.fit` letterboxes nothing
            // in the normal case and only rescues the extremes the clamp catches.
            //
            // The cover, not the brand's lead shot — see `SavedItem.coverURLString`. The
            // aspect the wall lays this tile out at is the cover's own, so the two agree.
            UpdateImage(
                url: save.coverURL,
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
            .overlay(alignment: .topTrailing) {
                if let isSelected { SelectionMark(isOn: isSelected).padding(8) }
            }

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
        .contextMenu {
            if isSelected == nil, let update {
                UpdateMenu(update: update)
                if let onSelect {
                    Divider()
                    Button("Select", systemImage: "checkmark.circle", action: onSelect)
                }
            }
        }
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
    }
}

/// Whether a tile on the wall is in the selection.
///
/// A ring and a tick, in ink — never the accent, which is rationed to things happening *to*
/// somebody, and a selection is a thing they are doing. Drawn on a paper disc so it reads on
/// a white sweep and on a black jacket alike.
struct SelectionMark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Color.ink : Color.paper.opacity(0.92))
            Circle()
                .strokeBorder(isOn ? Color.ink : Color.muted, lineWidth: 1)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.paper)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
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
            let context = update.sizeContext
            let mine = printable.filter { profile.claims($0, in: context) }

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
            // The cut first, measured from the brand's own tag where it published one —
            // "−33%" is the claim, and the "was" is how to check it.
            let was = update.wasPriceText.map { "WAS \($0.uppercased())" }
            self.text = [update.percentOffText ?? "PRICE DROP", was].compactMap { $0 }.joined(separator: " · ")
            // A markdown on something you can't buy in your size isn't yours either.
            self.isForMe = profile.isEmpty || update.isInMySize(profile)
        case .collection:
            self.text = "NEW COLLECTION"
            self.isForMe = false
        case .sale:
            // News about the brand, not about you: the words are on the row itself.
            self.text = "SALE"
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
                if let save = update.save, isAuthored(save) {
                    confirmation.removingSave = update
                } else {
                    removeSave(update, in: context)
                }
            } else {
                setSave(update, .inspiration, in: context, confirm: confirmation)
            }
        } label: {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSaved ? Color.signal : Color.ink)
                .frame(width: 30, height: 30)
                .background(Color.paper.opacity(0.92), in: Circle())
                // **The drawn size stays 30pt; the target becomes 44.** This is the app's
                // commonest action and it sits on a photograph in a scrolling feed, which is
                // the worst place to be a third under Apple's minimum. Making the circle
                // itself bigger would put a chip over the artwork; making the *hit area*
                // bigger costs nothing visible.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
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
                        // Each board on its own — a save can be on several, so ticking one
                        // no longer takes it off another.
                        Label(board.name, systemImage: update.save?.isFiled(on: board) == true ? "checkmark" : "square")
                    }
                }
            }
        }

        if let save = update.save {
            // On the menu as well as on the item's page and in a selection: leaving one thing
            // out is usually decided while looking at it, wherever that is. See `TasteRule`.
            Button(
                save.isExcludedFromTaste ? "Use for my taste" : "Don't use for my taste",
                systemImage: save.isExcludedFromTaste ? "eye" : "eye.slash"
            ) {
                CollectionEdit.exclude([save], !save.isExcludedFromTaste, in: context)
            }
        }

        if update.save != nil {
            Button("Remove from saved", systemImage: "trash", role: .destructive) {
                // Through the app-level question, for two reasons: a `Menu` builder cannot
                // host a `confirmationDialog` of its own, and the menu's host view is a card
                // in a lazy stack that may be recycled before an answer arrives.
                if let save = update.save, isAuthored(save) {
                    confirmation.removingSave = update
                } else {
                    removeSave(update, in: context)
                }
            }
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
        CollectionEdit.toggle([save], on: board, in: context)
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
        UsageCounts.record(.saveAdded)
    }
    update.isSeen = true
    try? context.save()
    confirm?.confirm(update, destination: update.save?.destinationLabel ?? type.label)
}

@MainActor
func removeSave(_ update: BrandUpdate, in context: ModelContext) {
    guard let save = update.save else { return }
    context.delete(save)
    try? context.save()
}

/// Whether un-saving this would throw away something the person made, rather than just a
/// bookmark they can put back with one tap.
///
/// `SaveDetailView` asks before removing and says exactly what goes — "Your note and where
/// you filed it go too. Fits it appears in are left alone." The bookmark on a card and the
/// Remove item in its menu did the identical thing and asked nothing, and the bookmark is
/// the worse of the two: a small target on a photograph in a scrolling feed, where the
/// gesture to un-save is indistinguishable from the gesture to save.
///
/// So the confirmation is conditional rather than universal. Asking every time would make
/// the commonest action in the app a two-step one to protect the case that does not need
/// protecting; asking never loses work. This asks exactly when there is work to lose.
@MainActor
private func isAuthored(_ save: SavedItem) -> Bool {
    if let note = save.note, !note.isEmpty { return true }
    if let sizeNote = save.sizeNote, !sizeNote.isEmpty { return true }
    if !save.boards.isEmpty { return true }
    return !save.fits.isEmpty
}

// `UpdateCarousel` used to live here, and `BrandDetailView` was its only caller. A
// horizontal strip is the wrong shape for a brand's output: it can only be read by
// swiping, one and a half tiles at a time, so seeing twenty things took twenty gestures
// and seeing two hundred was not possible at all. The brand page draws a vertical grid
// now. `EmptyStateView` went with it — it forwarded to `EditorialEmptyState` and had no
// callers left.
