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
    @Environment(\.modelContext) private var context
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    /// **Narrowed by the store, not by walking it** — the correction `FeedView.init` already
    /// made for the badge that opens this sheet, and which was never carried across.
    ///
    /// This was an unpredicated query: every event ever synced, materialised and sorted, to
    /// show a dozen. `kind` is a Codable enum and a `#Predicate` over one is fragile, so it
    /// cannot do the narrowing — but `previousPriceAmount` is written *only* where `kind`
    /// becomes `.priceDrop`, which makes it a faithful index for the question, and the date
    /// bound is answered from an index. It is a superset rather than the answer, so the kind
    /// is still confirmed below: a marked-down product that later restocks keeps the old
    /// price and stops being a markdown.
    @Query private var candidates: [BrandUpdate]

    /// A markdown stops being news eventually — the thing has either sold or gone back up,
    /// and a list of three-month-old prices is a list of wrong prices.
    static let window: TimeInterval = 30 * 86_400

    init() {
        let cutoff = Date().addingTimeInterval(-Self.window)
        _candidates = Query(
            filter: #Predicate<BrandUpdate> {
                $0.publishedAt >= cutoff
                    && $0.previousPriceAmount != nil
                    && $0.markdownDismissedAt == nil
            },
            sort: \BrandUpdate.publishedAt,
            order: .reverse
        )
    }

    /// Waving one off. The product is untouched — this is a verdict about the *markdown*,
    /// and the thing itself stays in the feed, on its brand page and in search.
    private func dismiss(_ update: BrandUpdate) {
        update.markdownDismissedAt = Date()
        try? context.save()
    }

    /// Yours first, then the deepest cut.
    ///
    /// Not by recency, which is the feed's ordering and the reason this screen has to
    /// exist: a 40% cut on something in your size does not become less interesting because
    /// a different brand marked something down an hour ago.
    ///
    /// `isInMySize` is asked **once per row** and carried into the sort rather than called
    /// from the comparator. A comparator runs O(n log n) times, and that one scans every
    /// variant of both operands — so the size question was being asked of the same product a
    /// dozen times over to place it once.
    private func ordered() -> [BrandUpdate] {
        let profile = sizes.profile
        return candidates
            .filter { $0.kind == .priceDrop && $0.passes(profile) }
            .map { (update: $0, isMine: $0.isInMySize(profile), cut: $0.discountShare ?? 0) }
            .sorted { a, b in
                a.isMine == b.isMine ? a.cut > b.cut : a.isMine
            }
            .map(\.update)
    }

    @State private var isConfirmingClear = false

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        // Read once. It was evaluated twice — for the empty check and then for the grid —
        // each time re-filtering and re-sorting the whole list.
        let ordered = self.ordered()

        return NavigationStack {
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
                                MarkdownTile(update: update)
                                    .productLink(update)
                                    // A long press rather than a swipe: this is a grid of
                                    // tiles, not a list, and there is no row edge to pull.
                                    .contextMenu {
                                        Button(
                                            "Not interested",
                                            systemImage: "xmark.circle",
                                            role: .destructive
                                        ) {
                                            dismiss(update)
                                        }
                                    }
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
            .appDestinations()
            .toolbar {
                // Leading, so the destructive one is nowhere near "Done". Only drawn when
                // there is something to clear — a button that empties an empty list is a
                // control with no state to act on.
                if !ordered.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear all", systemImage: "xmark.circle") {
                            isConfirmingClear = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Clear these \(ordered.count) markdowns?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear all", role: .destructive) { clear(ordered) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The products stay in your feed. Only this list is emptied, and a brand cutting a price again brings the item back.")
            }
        }
        .tint(.ink)
    }

    /// One save for the lot. `context.save()` invalidates every `@Query` in the app, so
    /// stamping thirty rows one at a time would rebuild the whole view tree thirty times.
    private func clear(_ updates: [BrandUpdate]) {
        let now = Date()
        for update in updates { update.markdownDismissedAt = now }
        try? context.save()
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

            // Wrapping for the same reason `MemberTile` does: this is a half-width cell in
            // a two-column grid, and five tokens is a cap on the count rather than on the
            // width — a waist run measures wider than the column and spills into it.
            SizeRun(
                entries: SizeRun.entries(for: update, profile: sizes.profile),
                size: 11,
                limit: 5,
                wraps: true
            )
        }
    }
}
