// CollectionReleaseView.swift
// A release, and everything that landed with it.
//
// A collection is the one update in this app that is *about* other updates, and it was
// being drawn as though it were a garment: a product card with no photograph (a season
// page rarely has one), an empty size run, no price, and a tap that opened a product page
// with nothing on it. "DENIM TEARS FW26" — the single most interesting thing a brand
// posts all season — rendered as the emptiest card in the feed.
//
// So it gets its own two objects. `CollectionCard` announces the release in the feed, set
// as type rather than as a photograph, and carries a strip of what came with it — which
// is both the honest illustration and the only preview a collection can have.
// `CollectionReleaseView` is the page behind it: the name, whatever the brand said about
// it, and the grid of garments. `Brand.members(of:)` decides what belongs; see there for
// why it is a heuristic and why that is the right trade.

import StreetwCore
import SwiftData
import SwiftUI

struct CollectionReleaseView: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    private var members: [BrandUpdate] {
        guard let brand = update.brand else { return [] }
        return brand.members(of: update).filter { $0.passes(sizes.profile) }
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                masthead

                if members.isEmpty {
                    // Honest about which of the two it is. A collection whose garments
                    // haven't been polled yet is a different thing from one the brand
                    // published empty, and the second is common enough — a merchandiser
                    // builds the page days before the drop.
                    EditorialEmptyState(
                        title: "Nothing in it yet",
                        action: "THE BRAND HAS ANNOUNCED THIS RELEASE BUT NOT PUT ANYTHING IN IT — OR IT HASN'T BEEN CHECKED SINCE"
                    )
                    .frame(minHeight: 220)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(members) { member in
                            NavigationLink {
                                ProductDetailView(update: member)
                            } label: {
                                MemberTile(update: member)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle(update.brand?.name ?? "Release")
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let link = update.linkURL {
                StorefrontBar(url: link, isSoldOut: false)
            }
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 12) {
            DataLabel(text: "COLLECTION · \(Stamp.short(update.publishedAt).uppercased())")

            Text(update.title)
                .font(.editorial(30))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = update.summary, !summary.isEmpty {
                Text(summary)
                    .font(.editorial(15))
                    .lineSpacing(3)
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !members.isEmpty {
                DataLabel(text: "\(members.count) \(members.count == 1 ? "PIECE" : "PIECES")")
                    .padding(.top, 2)
            }

            Rule().padding(.top, 6)
        }
        .padding(.horizontal, 20)
    }
}

/// One garment inside a release. A tile, not a card: the release is the subject here and
/// the pieces are its contents.
private struct MemberTile: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            UpdateImage(
                url: update.primaryImageURL,
                kind: update.kind,
                aspect: 1,
                drawnWidth: 200,
                mark: update.brand?.name
            )

            Text(update.title)
                .font(.editorial(14))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SizeRun(entries: SizeRun.entries(for: update, profile: sizes.profile), size: 11, limit: 5)
                Spacer(minLength: 4)
                if let price = update.priceText {
                    Text(price)
                        .font(.data(11, .medium))
                        .foregroundStyle(Color.muted)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .clipped()
        }
    }
}

/// A release, announced in the feed.
///
/// No size run and no price, because a collection has neither and printing empty space
/// where they go is what made this read as a broken product. The preview strip is the
/// illustration: a season page usually publishes no image of its own, and the garments
/// are what it is actually about.
struct CollectionCard: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    private var members: [BrandUpdate] {
        guard let brand = update.brand else { return [] }
        return brand.members(of: update)
            .filter { $0.passes(sizes.profile) && $0.primaryImageURL != nil }
    }

    var body: some View {
        NavigationLink {
            CollectionReleaseView(update: update)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // The brand's own artwork when there is any — a lookbook cover is worth the
                // whole width — and nothing at all when there isn't. A collection with no
                // image must not fall back to a placeholder tile: that is precisely the
                // empty grey square this card exists to stop drawing.
                if let image = update.primaryImageURL {
                    UpdateImage(url: image, kind: .collection, aspect: 1.5, drawnWidth: 400)
                        .padding(.bottom, 14)
                }

                VStack(alignment: .leading, spacing: 8) {
                    DataLabel(text: "NEW COLLECTION", size: 11, color: .ink)

                    Text(update.title)
                        .font(.editorial(24))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let summary = update.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.editorial(14))
                            .lineSpacing(2)
                            .foregroundStyle(Color.muted)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)

                if !members.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(members.prefix(8)) { member in
                                UpdateImage(
                                    url: member.primaryImageURL,
                                    kind: member.kind,
                                    aspect: 1,
                                    drawnWidth: 130,
                                    mark: member.brand?.name
                                )
                                .frame(width: 96)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.top, 14)
                    // Not a tappable strip: every tile in it is inside the card's own
                    // link, and a nested target here would make the whole row a coin toss
                    // between opening the release and opening one garment.
                    .allowsHitTesting(false)

                    DataLabel(text: "\(members.count) \(members.count == 1 ? "PIECE" : "PIECES") IN THIS RELEASE")
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { UpdateMenu(update: update) }
    }
}
