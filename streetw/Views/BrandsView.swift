// BrandsView.swift
// The brand list and the add-brand flow.

import StreetwCore
import SwiftData
import SwiftUI

struct BrandsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings

    @Query(sort: \Brand.name) private var brands: [Brand]
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if brands.isEmpty {
                    EditorialEmptyState(
                        title: "No brands on watch",
                        action: "PASTE A BRAND'S WEBSITE AND STREETW WORKS OUT WHAT IT CAN WATCH"
                    )
                } else {
                    List {
                        ForEach(brands) { brand in
                            NavigationLink {
                                BrandDetailView(brand: brand)
                            } label: {
                                BrandRow(brand: brand)
                            }
                            .listRowBackground(Color.paper)
                            .listRowSeparatorTint(Color.hairline)
                            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
                            // Rules run the full measure. Left alone, the separator
                            // indents to the text and starts halfway past the monogram,
                            // which reads as a misalignment rather than as a decision.
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.paper)
            .navigationTitle("Brands")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add brand", systemImage: "plus") { isAdding = true }
                }
            }
            .sheet(isPresented: $isAdding) {
                AddBrandView()
            }
        }
        .tint(.ink)
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { brands[$0] }
        // Unfollow first. Deleting only locally looks like it worked, then the next
        // sync re-creates the brand from the server's follow list.
        if settings.isConfigured {
            let remote = self.remote
            Task { for brand in doomed { await remote.unfollow(brand) } }
        }
        for brand in doomed { context.delete(brand) }
        try? context.save()
    }
}

/// A brand, set as an index entry: wordmark, what we watch it with, and the count —
/// the count printed rather than badged, because this is a list of things you follow,
/// not a set of notifications to clear.
struct BrandRow: View {
    let brand: Brand

    private var watching: String {
        let kinds = brand.sources.filter(\.enabled).map { $0.kind.label.uppercased() }
        return kinds.isEmpty ? "NOT WATCHED" : kinds.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandMonogram(name: brand.name, logoURL: brand.logoURL)

            VStack(alignment: .leading, spacing: 5) {
                Wordmark(name: brand.name, size: 14)
                DataLabel(
                    text: brand.isLockedForDrop ? "LOCKED · DROP IMMINENT" : watching,
                    size: 10,
                    color: brand.isLockedForDrop ? .signal : .muted
                )
            }

            Spacer(minLength: 8)

            if brand.unseenCount > 0 {
                Text("\(brand.unseenCount)")
                    .font(.data(12, .medium))
                    .foregroundStyle(Color.ink)
            }
        }
    }
}

/// The brand's own mark, taken from the icon its site publishes for home screens —
/// a file the brand chose, at a size meant to be looked at.
///
/// Falls back to initials rather than to a broken-image box, because plenty of sites
/// serve a generic platform favicon or nothing at all, and a wrong logo is worse than
/// no logo. `.fit` with padding so a wide wordmark isn't cropped to its middle.
struct BrandMonogram: View {
    let name: String
    var logoURL: URL?

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        Rectangle()
            .fill(Color.wash)
            .frame(width: 44, height: 44)
            .overlay {
                if let logoURL {
                    AsyncImage(url: logoURL, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit().padding(5)
                        case .failure:
                            monogram
                        default:
                            Color.clear
                        }
                    }
                } else {
                    monogram
                }
            }
            .clipped()
    }

    private var monogram: some View {
        Text(initials)
            .font(.wordmark(12, .medium))
            .tracking(0.8)
            .foregroundStyle(Color.muted)
    }
}

#Preview {
    BrandsView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}
