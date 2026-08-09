// FeedView.swift
// "New since yesterday" — updates grouped by brand, newest brand first.

import StreetwCore
import SwiftData
import SwiftUI

struct FeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine?
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore?

    @Query(filter: #Predicate<Brand> { $0.followed }, sort: \Brand.name)
    private var brands: [Brand]

    private var isFiltering: Bool {
        guard let sizes else { return false }
        return sizes.filterFeedToMySize && !sizes.profile.isEmpty
    }

    private var groups: [BrandGroup] {
        let profile = sizes?.profile ?? SizeProfile()
        let filtering = isFiltering

        return brands
            .compactMap { brand in
                var unseen = brand.updates.filter { !$0.isSeen }
                if filtering {
                    unseen = unseen.filter { $0.isAvailable(in: profile) }
                }
                guard !unseen.isEmpty else { return nil }
                return BrandGroup(
                    brand: brand,
                    updates: unseen.sorted { $0.publishedAt > $1.publishedAt }
                )
            }
            .sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
    }

    private var totalNew: Int {
        groups.reduce(0) { $0 + $1.updates.count }
    }

    var body: some View {
        NavigationStack {
            Group {
                if brands.isEmpty {
                    EmptyStateView(
                        symbol: "tag",
                        title: "No brands yet",
                        message: "Add a brand and streetw starts watching its catalog and feeds for new drops."
                    )
                } else if groups.isEmpty {
                    EmptyStateView(
                        symbol: "checkmark.circle",
                        title: "All caught up",
                        message: engine?.lastSyncedAt == nil
                            ? "Pull down to check your brands for the first time."
                            : "Nothing new since you last looked. Pull to refresh."
                    )
                } else {
                    feedList
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                if let sizes, !sizes.profile.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        @Bindable var sizes = sizes
                        Toggle(isOn: $sizes.filterFeedToMySize) {
                            Label("My size", systemImage: "line.3.horizontal.decrease")
                        }
                        .toggleStyle(.button)
                        .labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if engine?.isSyncing == true {
                        ProgressView()
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await engine?.syncAll() }
                        }
                    }
                }
            }
            .refreshable { await engine?.syncAll() }
            .overlay(alignment: .bottom) { syncStatus }
        }
    }

    private var feedList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(totalNew) new \(totalNew == 1 ? "thing" : "things") from \(groups.count) \(groups.count == 1 ? "brand" : "brands")")
                    if isFiltering, let sizes {
                        Text("Filtered to \(sizes.profile.summary)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
            }

            ForEach(groups) { group in
                Section {
                    UpdateCarousel(updates: group.updates)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                        .listRowSeparator(.hidden)
                } header: {
                    FeedSectionHeader(group: group) {
                        markSeen(group)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let engine, engine.isSyncing, let progress = engine.progress {
            Text("Checking \(progress)…")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 8)
                .transition(.opacity)
        }
    }

    private func markSeen(_ group: BrandGroup) {
        for update in group.updates { update.isSeen = true }
        group.brand.lastOpenedAt = Date()
        try? context.save()
    }
}

struct BrandGroup: Identifiable {
    var brand: Brand
    var updates: [BrandUpdate]

    var id: UUID { brand.id }
    var latest: Date? { updates.first?.publishedAt }

    /// "12 new products", "3 restocked", "New FW26 collection" — the line the user reads.
    var headline: String {
        if brand.isLockedForDrop { return "Locked — drop incoming" }

        let counts = Dictionary(grouping: updates, by: \.kind)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }

        guard let (kind, count) = counts.first else { return "Updated" }

        switch kind {
        case .product: return count == 1 ? "New product" : "\(count) new products"
        case .restock: return count == 1 ? "Restocked" : "\(count) restocked"
        case .collection: return updates.first(where: { $0.kind == .collection })?.title ?? "New collection"
        case .post: return count == 1 ? "New post" : "\(count) new posts"
        case .pageChange: return "Page changed"
        case .dropLock: return "Locked — drop incoming"
        }
    }
}

private struct FeedSectionHeader: View {
    let group: BrandGroup
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            NavigationLink {
                BrandDetailView(brand: group.brand)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.brand.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(group.headline)
                        .font(.subheadline)
                        .foregroundStyle(group.brand.isLockedForDrop ? .orange : .secondary)
                }
            }

            Spacer()

            Button("Mark seen", systemImage: "checkmark") { onDismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

#Preview {
    FeedView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}
