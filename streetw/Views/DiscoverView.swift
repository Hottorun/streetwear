// DiscoverView.swift
// The whole list of brands worth following, on a screen you asked for.
//
// The inline block on the feed, the brands tab and the style tab prints three. This is
// where the rest live. That split is the point: a suggestion offered in passing should be
// small enough to ignore, and a person who actually wants to browse should get a page
// rather than a longer interruption on the one they were already reading.

import StreetwCore
import SwiftUI

struct DiscoverView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [PopularBrand]
    var reason: (PopularBrand) -> [String] = { _ in [] }
    let onFollow: (PopularBrand) async -> Void
    var onDismiss: (PopularBrand) -> Void = { _ in }

    @State private var previewed: PopularBrand?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    // Reachable by following the last suggestion while this is open.
                    EditorialEmptyState(
                        title: "Nothing left to suggest",
                        action: "YOU'RE FOLLOWING EVERYTHING STREETW KNOWS ABOUT — ADD ONE BY ITS WEBSITE"
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(items) { item in
                                SuggestedBrandCard(
                                    item: item,
                                    reason: reason(item),
                                    onOpen: { previewed = item },
                                    onFollow: { await onFollow(item) },
                                    onDismiss: { onDismiss(item) }
                                )
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Color.paper)
            .navigationTitle("Discover")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $previewed) { item in
                BrandPreviewSheet(
                    item: item,
                    reason: reason(item),
                    onFollow: { await onFollow(item) },
                    onDismiss: { onDismiss(item) }
                )
            }
        }
        .tint(.ink)
    }
}
