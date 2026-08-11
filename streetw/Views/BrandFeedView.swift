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
struct GalleryCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ImageGallery(urls: update.imageURLs, kind: update.kind)
                SaveAction(update: update)
                    .padding(12)
            }

            VStack(alignment: .leading, spacing: 7) {
                if let state = FeedState(update: update, profile: sizes.profile) {
                    DataLabel(text: state.text, size: 11, color: .signal)
                }
                Text(update.title)
                    .font(.editorial(19))
                    .foregroundStyle(Color.ink)
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

                if let link = update.linkURL {
                    Button("Open on site") { openURL(link) }
                        .font(.data(11, .medium))
                        .foregroundStyle(Color.muted)
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 14)
            .padding(.horizontal, 20)
        }
        .contextMenu { UpdateMenu(update: update) }
    }
}

/// A horizontally paged set of photographs.
///
/// Paging is safe here in a way it wouldn't be on the feed card: nothing else on this
/// screen claims a horizontal swipe. On the feed, left and right already mean "file" and
/// "mark read", and a gallery there would fight them for the same gesture.
struct ImageGallery: View {
    let urls: [URL]
    var kind: BrandUpdate.Kind = .product

    @State private var index = 0

    var body: some View {
        if urls.count <= 1 {
            UpdateImage(url: urls.first, kind: kind, aspect: 1, contentMode: .fit)
        } else {
            VStack(spacing: 10) {
                TabView(selection: $index) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { position, url in
                        UpdateImage(url: url, kind: kind, aspect: 1, contentMode: .fit)
                            .tag(position)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .aspectRatio(1, contentMode: .fit)

                // A printed count rather than dots: it says how many there are, which
                // dots only imply, and it matches the mono metadata everywhere else.
                DataLabel(text: "\(index + 1) / \(urls.count)", size: 10)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
