// MarkdownsView.swift
// What got cheaper.
//
// `UpdateKind.priceDrop` was carefully built — only *drops*, only past 5%, a restock
// outranks one so a product writes at most one event per poll — and then had nowhere to
// go. A markdown landed in the feed between two new products, was scrolled past, and was
// gone: the feed is ordered by recency and a price cut is worth exactly as much a week
// later as it was on the day, which is the opposite of everything else in there.
//
// So it gets the one view a feed cannot be: a standing list, ordered by how good the cut
// is rather than by when it happened, and not emptied by marking things seen.

import StreetwCore
import SwiftData
import SwiftUI

struct MarkdownsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    // Filtered in memory rather than in the predicate: `kind` is stored as an enum and a
    // `#Predicate` over one is fragile, and this list is short enough that the cost is a
    // single pass over rows the store already holds.
    @Query(sort: \BrandUpdate.publishedAt, order: .reverse)
    private var everything: [BrandUpdate]

    /// A markdown stops being news eventually — the thing has either sold or gone back up,
    /// and a list of three-month-old prices is a list of wrong prices.
    static let window: TimeInterval = 30 * 86_400

    private var visible: [BrandUpdate] {
        let profile = sizes.profile
        let cutoff = Date().addingTimeInterval(-Self.window)
        return everything.filter {
            $0.kind == .priceDrop && $0.publishedAt >= cutoff && $0.passes(profile)
        }
    }

    /// Yours first, then the deepest cut.
    ///
    /// Not by recency, which is the feed's ordering and the reason this screen has to
    /// exist: a 40% cut on something in your size does not become less interesting because
    /// a different brand marked something down an hour ago.
    private var ordered: [BrandUpdate] {
        let profile = sizes.profile
        return visible.sorted { a, b in
            let mineA = a.isInMySize(profile), mineB = b.isInMySize(profile)
            if mineA != mineB { return mineA }
            return (a.discountShare ?? 0) > (b.discountShare ?? 0)
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if ordered.isEmpty {
                    EditorialEmptyState(
                        title: "Nothing marked down",
                        action: "WHEN A BRAND YOU FOLLOW CUTS A PRICE BY MORE THAN 5%, IT LANDS HERE"
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(ordered) { update in
                                NavigationLink {
                                    ProductDetailView(update: update)
                                } label: {
                                    MarkdownTile(update: update)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Color.paper)
            .navigationTitle("Marked down")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.ink)
    }
}

private struct MarkdownTile: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UpdateImage(
                url: update.primaryImageURL,
                kind: update.kind,
                aspect: 1,
                drawnWidth: 200,
                mark: update.brand?.name
            )
            .overlay(alignment: .topLeading) {
                if let share = update.discountShare, share > 0 {
                    Text("−\(Int((share * 100).rounded()))%")
                        .font(.data(11, .semibold))
                        .foregroundStyle(Color.paper)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.signal)
                        .padding(8)
                }
            }

            if let brand = update.brand {
                Wordmark(name: brand.name, size: 9, color: .muted)
            }

            Text(update.title)
                .font(.editorial(14))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let price = update.priceText {
                    Text(price)
                        .font(.data(12, .medium))
                        .foregroundStyle(Color.ink)
                }
                // The old price struck through, which is the whole claim being made and
                // the only way to check it.
                if let was = update.previousPriceText {
                    Text(was)
                        .font(.data(11))
                        .strikethrough(true, color: .muted)
                        .foregroundStyle(Color.muted)
                }
            }

            SizeRun(entries: SizeRun.entries(for: update, profile: sizes.profile), size: 11, limit: 5)
        }
    }
}
