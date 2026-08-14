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
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let brand: Brand
    /// Show only what hasn't been seen, matching the feed the user arrived from.
    var unseenOnly: Bool = true

    /// The same filter the feed applies, from the same place. Arriving here from
    /// "+36 more" and being shown the womenswear a Menswear setting had just hidden reads
    /// as the setting being broken — the page you came from and the page you land on have
    /// to agree about what you asked for.
    private var updates: [BrandUpdate] {
        let profile = sizes.profile
        return brand.updates
            .filter { unseenOnly ? !$0.isSeen : true }
            .filter { $0.passes(profile) }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                ForEach(updates) { update in
                    // A release is not a garment and must not be drawn as one here either
                    // — this page is reached from "+36 more", so it holds exactly the same
                    // mix the feed does.
                    if update.kind == .collection {
                        CollectionCard(update: update)
                    } else {
                        GalleryCard(update: update)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle(brand.name)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark all seen", systemImage: "checkmark") {
                    for update in updates { update.isSeen = true }
                    brand.lastOpenedAt = Date()
                    try? context.save()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ImageGallery(
                    urls: update.imageURLs,
                    kind: update.kind,
                    drawnWidth: 400,
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
    private var index: Binding<Int> {
        selection ?? $localIndex
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
