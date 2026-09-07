// BrandFeedView.swift
// Everything one brand has posted, at full size.
//
// This is where "+39 more" goes. The feed's spread shows a lead and a grid of thumbnails
// because it has to fit several brands on one page; here there is only one brand, so
// every item gets the room the lead gets — and, crucially, *all* of its photographs.
//
// Storefronts publish eight to twelve shots of a garment: front, back, detail, on-body.
// The catalogue already hands them over and `imageURLStrings` already stores them; until
// now the app only ever showed the first. Showing the rest costs no extra fetching and is
// the difference between a listing and a lookbook.

import StreetwCore
import SwiftData
import SwiftUI

struct BrandFeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    /// Drives the haptic on "Mark all seen" — see the button. A counter, not a flag.
    @State private var clearedAll = 0

    let brand: Brand
    /// Show only what hasn't been seen, matching the feed the user arrived from.
    var unseenOnly: Bool = true
    /// One story rather than the whole spread, when that is what was tapped.
    ///
    /// Nil is everything this brand posted, which is where "ALL 15 FROM …" goes. A kind is
    /// the page behind one headline — "7 new products" — and the whole of what that page has
    /// to get right is that it holds **exactly** what the sentence claimed, so the heading is
    /// built from `UpdateKind.headline` too rather than written again here.
    var kind: UpdateKind?

    /// The same filter the feed applies, from the same place. Arriving here from
    /// "+36 more" and being shown the womenswear a Menswear setting had just hidden reads
    /// as the setting being broken — the page you came from and the page you land on have
    /// to agree about what you asked for.
    ///
    /// **This is the page where marking a card read felt slow, and the cost was measured
    /// rather than guessed at.** Marking one read is a `context.save()`, which re-renders
    /// this view, which re-derives the whole list — twice, as it happens. Broken into
    /// phases against a real 400-product Kith catalogue on an iPhone 17 Pro:
    ///
    /// | phase | cost |
    /// |---|---|
    /// | reading `brand.updates` | **0.0ms** — the relationship is already faulted and cached |
    /// | `!isSeen` + `passes` over 400 rows | 0.4ms |
    /// | `oncePerProduct` | **18–22ms** |
    ///
    /// So essentially all of it was the sort inside `oncePerProduct`, and none of it was
    /// what it looked like from the outside. Two plausible fixes were wrong and are worth
    /// naming so they are not tried again: narrowing this to a `@Query` on `BrandUpdate`
    /// with a `$0.brand?.id == brandID` predicate made it **three times slower** (54–92ms —
    /// the relationship traversal is a correlated subquery, and the relationship it replaces
    /// was free), and memoising the result buys little once the sort is cheap. The fix is in
    /// `BrandUpdate.oncePerProduct`, where it also serves every other list in the app.
    ///
    /// One mark-read, end to end: **44.3ms before, 8.2ms after** — from four dropped frames
    /// at 120Hz to none.
    private var updates: [BrandUpdate] {
        let profile = sizes.profile
        // One card per garment. This page is the longest list in the app — a brand's whole
        // output — so it is also where the same jacket appearing as a drop, a markdown and a
        // restock is most obvious and least useful. See `BrandUpdate.oncePerProduct`.
        //
        // **Deduplicated before the kind filter, never after, because the feed does it in
        // that order and this page is what the feed's count opens.** `FeedView.feed` folds a
        // brand's whole unread queue down to one row per garment and *then* buckets by kind,
        // so a jacket with an unread `.product` and an unread `.restock` is counted once, in
        // whichever bucket the surviving row belongs to. Filtering first here kept both rows
        // — one on each page — so the feed said "6 new products" and the page it opened
        // printed seven. A tap has to land on the thing it was pointed at, which is the same
        // reason `heading` prints `UpdateKind.headline` rather than a sentence of its own.
        // Reachable in server mode, where every event is a row of its own.
        let deduplicated = BrandUpdate.oncePerProduct(
            brand.updates
                .filter { unseenOnly ? !$0.isSeen : true }
                .filter { $0.passes(profile) }
        )
        guard let kind else { return deduplicated }
        return deduplicated.filter { $0.kind == kind }
    }

    /// What this page is, in the words the feed used for it.
    ///
    /// Printed only when narrowed to a story: unfiltered, the navigation title already says
    /// the brand and a second line under it repeating "everything" is furniture. Counted off
    /// the deduplicated list rather than off the raw rows, because that is what is drawn —
    /// the rule every other count in this app follows, and the one that stops a heading
    /// saying eight above a page of five.
    private func heading(_ updates: [BrandUpdate]) -> String? {
        kind.map { $0.headline(count: updates.count) }
    }

    /// The lead photographs of the next couple of items, for the card at `position` to
    /// warm while it is the one being read.
    ///
    /// A `LazyVStack` builds a card when it is nearly on screen, and this page's cards are
    /// a full-width square each — so the load for the next garment began at the moment it
    /// arrived, and marking one read (which removes it, pulling the next up under your
    /// thumb) landed on an empty frame that then filled in. That gap is the "lag" before
    /// the next item appears: nothing was slow, the picture simply had not been asked for
    /// yet. Same argument as `ImageGallery`'s neighbour warm-up, one level up.
    ///
    /// Two, not the rest of the list: a brand page can be three hundred products and
    /// fetching all of them because somebody opened the page would be a great deal of
    /// bandwidth spent on photographs nobody has asked to see.
    private static func leadImages(of updates: [BrandUpdate], after position: Int) -> [URL] {
        updates
            .dropFirst(position + 1)
            .prefix(2)
            .compactMap(\.primaryImageURL)
    }

    var body: some View {
        // **Hoisted above the `ScrollView`, not inside its content closure.**
        //
        // The `let` used to sit inside the builder, which scoped it to the content — so the
        // `.onChange(of: updates.isEmpty)` modifier applied *outside* it resolved to the
        // computed property again and re-evaluated the whole thing: a full walk of the
        // brand's catalogue, `passes` per row, and `oncePerProduct`'s sort, twice per render
        // on the longest list in the app.
        let updates = self.updates

        return ScrollView {
            // The heading is a sibling of the list rather than its first row, so it can sit
            // at its own distance from the first card — inside the `LazyVStack` it inherited
            // the 40pt that separates two full-width photographs from each other, which is
            // the gap that says "different garment" and the wrong one for a line that
            // belongs to the picture under it. Two children, so nothing here is un-lazied:
            // the `ForEach` is still inside the lazy stack.
            VStack(alignment: .leading, spacing: 22) {
                if let heading = heading(updates) {
                    Text(heading)
                        .font(.editorial(19))
                        .foregroundStyle(kind == .dropLock ? Color.signal : Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                LazyVStack(alignment: .leading, spacing: 40) {
                    ForEach(Array(updates.enumerated()), id: \.element.id) { position, update in
                        // A release is not a garment and must not be drawn as one here either
                        // — this page holds exactly the same mix the feed does.
                        if update.kind == .collection {
                            CollectionCard(update: update)
                        } else {
                            GalleryCard(update: update, warm: Self.leadImages(of: updates, after: position))
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .sensoryFeedback(.success, trigger: clearedAll)
        .navigationTitle(brand.name)
        .toolbarTitleDisplayMode(.inline)
        // **Emptying this page leaves it, whichever way it was emptied.**
        //
        // This screen *is* the unread queue for one brand: everything on it is here because
        // it hasn't been read, so reading the last of it leaves a page whose whole content
        // was the thing you just finished. Pressing the checkmark cleared all of them at
        // once and left you looking at nothing, with no statement that anything had
        // happened and a back button as the only way on — which reads as the button having
        // broken the page rather than completed it. Swiping the last card read gets there
        // too, more slowly.
        //
        // `onChange`, not a check in `body`: an already-empty page must stay put, or the
        // `unseenOnly: false` route — the brand's whole history, which is allowed to be
        // empty — would refuse to open at all.
        .onChange(of: updates.isEmpty) { _, isEmpty in
            guard isEmpty, unseenOnly else { return }
            dismiss()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark all seen", systemImage: "checkmark") {
                    // Animated for the same reason the swipe is: the cards are being
                    // removed, and the pop that follows reads as a consequence of that
                    // rather than as the screen being yanked away.
                    // Every row this page stood for, not only the cards it drew. The list is
                    // one card per garment now, so clearing `updates` alone would leave the
                    // folded-away siblings unread and the page would refuse to empty.
                    //
                    // **And no row it did not stand for.** Narrowed to one story, this button
                    // clears that story — a checkmark on a page headed "7 new products" must
                    // not also mark eight restocks read, which is a page's worth of news
                    // disappearing from the feed on a tap that named something else.
                    let profile = sizes.profile
                    let kind = self.kind
                    withAnimation(.easeOut(duration: 0.22)) {
                        for update in brand.updates where !update.isSeen {
                            guard kind == nil || update.kind == kind else { continue }
                            guard update.passes(profile) else { continue }
                            update.isSeen = true
                        }
                        brand.lastOpenedAt = Date()
                    }
                    try? context.save()
                    // The same confirmation the swipe gives, for the same act done to the
                    // whole page at once. See `FeedView.markSeen`.
                    clearedAll += 1
                }
                .labelStyle(.iconOnly)
            }
        }
    }
}

/// One product, with every photograph the brand published for it.
///
/// Behaves exactly like a feed lead, deliberately: same gallery, same tap target, same
/// swipe actions. This page used to be the one place a card couldn't be filed or
/// dismissed, which made "+39 more" a dead end — you could look at the rest of a drop but
/// not act on any of it.
struct GalleryCard: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate
    /// Photographs belonging to the cards *after* this one — see
    /// `BrandFeedView.leadImages(of:after:)`. Empty anywhere the caller has no next card
    /// to name, which is the correct behaviour rather than a missing feature.
    var warm: [URL] = []

    private static let drawnWidth = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ImageGallery(
                    urls: update.imageURLs,
                    kind: update.kind,
                    drawnWidth: Self.drawnWidth,
                    mark: update.brand?.name
                )
                SaveAction(update: update)
                    .padding(12)
            }
            // Same as the feed's lead: the photograph opens the product. This page is
            // reached from "+36 more" and behaves like the feed in every other respect,
            // so the biggest target on it being inert was doubly surprising here.
            .contentShape(.rect)
            .productLink(update)

            Group {
                VStack(alignment: .leading, spacing: 7) {
                    if let state = FeedState(update: update, profile: sizes.profile) {
                        DataLabel(text: state.text, size: 11, color: state.color)
                    }
                    Text(update.title)
                        .font(.editorial(19))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .firstTextBaseline) {
                        SizeRun(entries: SizeRun.entries(for: update, profile: sizes.profile))
                        Spacer(minLength: 12)
                        if let price = update.priceText {
                            Text(price)
                                .font(.data(12, .medium))
                                .foregroundStyle(Color.ink)
                                .fixedSize()
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
        .contextMenu { UpdateMenu(update: update) }
        .quickSave(update)
        // At the same width the next card will draw at, or the ladder in `ImageRendition`
        // mints a second URL for the same photograph and the warm-up warms nothing.
        .task(id: warm) { ImageLoader.shared.prefetch(warm, width: Self.drawnWidth) }
    }
}

/// A horizontally paged set of photographs.
///
/// The gesture question this settles: horizontal swipe is claimed twice in this app —
/// by paging through a product's photographs, and by `quickSave`'s file/mark-read. Both
/// are worth having and they cannot share a direction.
///
/// The resolution is by *region*, not by screen. The photograph pages; everything below
/// it — the title, the size run, the price — carries the quick-save drag. That reads
/// naturally (you swipe the picture to see more pictures, you swipe the card to deal with
/// the card), it works identically on the feed and on a brand page, and neither gesture
/// has to be dropped. `ImageGallery` therefore stops being brand-page-only.
struct ImageGallery: View {
    let urls: [URL]
    var kind: BrandUpdate.Kind = .product
    /// Off for a single image, and off where the caller wants the whole card to drag as
    /// one piece regardless.
    var isPagingEnabled: Bool = true
    var drawnWidth: Int = 400
    /// Whether tapping opens the full-screen viewer. Off in the feed, where a tap on the
    /// card belongs to the product page — going full-screen from a scrolling feed would
    /// hijack the commonest tap in the app.
    var isZoomable: Bool = false
    /// What sits behind each photograph. The collection passes `sweep`, which is fixed, so
    /// a saved item looks the same opened as it does on the wall — see `Color.sweep`.
    var backdrop: Color = .wash
    /// Set in place of a photograph that does not exist — see `UpdateImage.mark`. A
    /// gallery with an empty `urls` still renders one frame, and on the products whose
    /// source published no image at all that frame was the whole tile.
    var mark: String?
    /// Driven from outside when something else on the page decides which photograph is
    /// being talked about — selecting a colourway, above all. Nil keeps the gallery's own
    /// state, which is what every caller that only pages by hand wants.
    var selection: Binding<Int>?

    @State private var localIndex = 0
    @State private var isZoomed = false

    /// One index, owned in one of two places. Written as a computed binding rather than by
    /// syncing two properties: the gallery and the colourway row would otherwise each
    /// write the other's copy, and a swipe would fight the selection that caused it.
    ///
    /// Clamped on the way out. `onChange` resets a reused gallery, but it runs *after* the
    /// body that first sees the new photographs — so for one frame a stale index can point
    /// past the end of a shorter set, and a `TabView` with no page for its selection draws
    /// an empty rectangle. Clamping costs nothing and removes the flash.
    private var index: Binding<Int> {
        if let selection { return selection }
        return Binding(
            get: { min(max(localIndex, 0), max(urls.count - 1, 0)) },
            set: { localIndex = $0 }
        )
    }

    /// What to warm, in the order it is most likely to be wanted: forwards first, because
    /// that is how a gallery is read, and one back so returning is instant too.
    private var neighbours: [URL] {
        [index.wrappedValue + 1, index.wrappedValue + 2, index.wrappedValue - 1]
            .filter { urls.indices.contains($0) }
            .map { urls[$0] }
    }

    var body: some View {
        gallery
            // **A gallery belongs to a garment, and this one is reused by the next.**
            //
            // The card in a `LazyVStack` is a view *description*; SwiftUI keeps the
            // underlying instance and its `@State` when the description at that position
            // changes. So swiping to the seventh photograph of a jacket and then marking the
            // brand read — which removes that card and pulls the next one up — left the
            // index at 7, and the shirt that arrived opened on its seventh frame. Worse when
            // the next product has fewer photographs than the last: the `TabView` has no
            // page with that tag and draws nothing at all, which reads as an image that
            // failed to load.
            //
            // Keyed on `urls` rather than on an id the gallery does not have: the set of
            // photographs *is* the identity of what is being paged through, and a caller
            // that legitimately swaps them (a colourway on its own handle) wants the same
            // reset. An externally owned `selection` is left alone — that binding belongs to
            // a page that knows when its own subject changed.
            .onChange(of: urls) { _, _ in localIndex = 0 }
            .fullScreenCover(isPresented: $isZoomed) {
                ImageViewer(urls: urls, initialIndex: index.wrappedValue)
            }
    }

    /// A tap opens the viewer, and only where the caller asked for it. Attached with
    /// `contentShape` so the transparent letterboxing around a `.fit` photograph is part
    /// of the target — otherwise tapping the white margin of a product shot does nothing,
    /// which reads as the gesture being unreliable rather than as a miss.
    @ViewBuilder
    private var zoomTap: some View {
        if isZoomable {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { isZoomed = true }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if urls.count <= 1 || !isPagingEnabled {
            UpdateImage(
                url: urls.first,
                kind: kind,
                aspect: 1,
                contentMode: .fit,
                drawnWidth: drawnWidth,
                backdrop: backdrop,
                mark: mark
            )
            .overlay { zoomTap }
        } else {
            TabView(selection: index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { position, url in
                    UpdateImage(
                        url: url,
                        kind: kind,
                        aspect: 1,
                        contentMode: .fit,
                        drawnWidth: drawnWidth,
                        backdrop: backdrop
                    )
                    .overlay { zoomTap }
                    .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(1, contentMode: .fit)
            // A `TabView` builds each page as it is reached, so the load for the next
            // photograph began at the moment you landed on it — every swipe arrived on an
            // empty frame and then filled in. Warming the neighbours instead means the
            // page is already drawn by the time it is on screen.
            //
            // Keyed on `index` rather than run once: a gallery can be eight photographs,
            // and fetching all of them the instant a card scrolls past is a lot of
            // bandwidth spent on pictures nobody asked to see.
            .task(id: index.wrappedValue) { ImageLoader.shared.prefetch(neighbours, width: drawnWidth) }
            .overlay(alignment: .bottomTrailing) {
                // A printed count rather than dots: it says how many there are, which
                // dots only imply, and it matches the mono metadata everywhere else.
                // Laid over the photograph rather than under it so the caption block
                // below stays a clean drag target for quick-save.
                DataLabel(text: "\(index.wrappedValue + 1)/\(urls.count)", size: 10, color: .ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.paper.opacity(0.92), in: Capsule())
                    .padding(12)
            }
        }
    }
}
