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

    private var updates: [BrandUpdate] {
        brand.updates
            .filter { unseenOnly ? !$0.isSeen : true }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                ForEach(updates) { update in
                    GalleryCard(update: update)
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
                ImageGallery(urls: update.imageURLs, kind: update.kind, drawnWidth: 400)
                SaveAction(update: update)
                    .padding(12)
            }

            NavigationLink {
                ProductDetailView(update: update)
            } label: {
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
            .buttonStyle(.plain)
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

    @State private var index = 0

    var body: some View {
        if urls.count <= 1 || !isPagingEnabled {
            UpdateImage(
                url: urls.first,
                kind: kind,
                aspect: 1,
                contentMode: .fit,
                drawnWidth: drawnWidth
            )
        } else {
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { position, url in
                    UpdateImage(
                        url: url,
                        kind: kind,
                        aspect: 1,
                        contentMode: .fit,
                        drawnWidth: drawnWidth
                    )
                    .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                // A printed count rather than dots: it says how many there are, which
                // dots only imply, and it matches the mono metadata everywhere else.
                // Laid over the photograph rather than under it so the caption block
                // below stays a clean drag target for quick-save.
                DataLabel(text: "\(index + 1)/\(urls.count)", size: 10, color: .ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.paper.opacity(0.92), in: Capsule())
                    .padding(12)
            }
        }
    }
}
