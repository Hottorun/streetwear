// FeedView.swift
// The hype room: what changed, newest brand first.
//
// Laid out as a magazine front page rather than a list — each brand gets a wordmark
// header, one lead item printed large, and the rest as briefs. That is not only a look:
// a brand can publish an entire collection in one poll (Kith wrote 250 items in a single
// sweep), and a flat list of 250 equal rows is unreadable. Lead-plus-briefs stays
// legible at any batch size, and the "+N more" link is the honest overflow.

import StreetwCore
import SwiftData
import SwiftUI

struct FeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings

    @Query(filter: #Predicate<Brand> { $0.followed }, sort: \Brand.name)
    private var brands: [Brand]

    @State private var isShowingCalendar = false

    /// How many briefs sit under a lead before the rest go behind "+N more".
    private static let briefLimit = 6

    private var isFiltering: Bool {
        sizes.filterFeedToMySize && !sizes.profile.isEmpty
    }

    private var groups: [BrandGroup] {
        let profile = sizes.profile
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
                    EditorialEmptyState(
                        title: "Nothing on watch yet",
                        action: "ADD A BRAND AND STREETW STARTS WATCHING ITS CATALOG"
                    )
                } else if groups.isEmpty {
                    EditorialEmptyState(
                        title: "All caught up",
                        action: engine.lastSyncedAt == nil
                            ? "PULL TO CHECK YOUR BRANDS FOR THE FIRST TIME"
                            : "PULL TO REFRESH"
                    )
                } else {
                    stream
                }
            }
            .background(Color.paper)
            .navigationTitle("Feed")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                if !sizes.profile.isEmpty {
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
                    Button("Upcoming", systemImage: "calendar") { isShowingCalendar = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if engine.isSyncing || remote.isSyncing {
                        ProgressView()
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await refresh() }
                        }
                    }
                }
            }
            .refreshable { await refresh() }
            .overlay(alignment: .bottom) { syncStatus }
            .sheet(isPresented: $isShowingCalendar) { DropCalendarView() }
        }
        .tint(.ink)
    }

    private var stream: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                masthead

                ForEach(groups) { group in
                    BrandSpread(group: group, briefLimit: Self.briefLimit) {
                        markSeen(group)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    /// The count, set as a standfirst. Says what's true and how it's narrowed — no
    /// decoration, because it is the one piece of chrome above the photographs.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(totalNew) new from \(groups.count) \(groups.count == 1 ? "brand" : "brands")")
                .font(.editorial(15))
                .foregroundStyle(Color.ink)
            if isFiltering {
                DataLabel(text: "FILTERED TO \(sizes.profile.summary.uppercased())")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var syncStatus: some View {
        if engine.isSyncing, let progress = engine.progress {
            DataLabel(text: "CHECKING \(progress.uppercased())", color: .paper)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.ink, in: Capsule())
                .padding(.bottom, 10)
                .transition(.opacity)
        }
    }

    /// Server mode when one is configured; otherwise the app polls sources itself.
    private func refresh() async {
        if settings.isConfigured {
            await remote.sync(sizes: sizes.profile)
        } else {
            await engine.syncAll()
        }
    }

    private func markSeen(_ group: BrandGroup) {
        for update in group.updates { update.isSeen = true }
        group.brand.lastOpenedAt = Date()
        try? context.save()
    }
}

// MARK: - One brand's spread

private struct BrandSpread: View {
    let group: BrandGroup
    let briefLimit: Int
    let onDismiss: () -> Void

    /// The newest item *that has a photograph*. A lead is carried by its image, and the
    /// newest thing a brand posts is often a collection announcement or a page change
    /// with nothing to show — leading on that wastes the biggest slot on the page.
    private var lead: BrandUpdate? {
        group.updates.first { $0.primaryImageURL != nil } ?? group.updates.first
    }

    private var briefs: [BrandUpdate] {
        Array(group.updates.filter { $0.id != lead?.id }.prefix(briefLimit))
    }

    private var overflow: Int { max(0, group.updates.count - 1 - briefLimit) }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            header

            if let lead {
                FeedLead(update: lead)
                    .padding(.bottom, briefs.isEmpty ? 0 : 20)
            }

            if !briefs.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(briefs) { update in
                        FeedTile(update: update)
                    }
                }
                .padding(.horizontal, 20)
            }

            if overflow > 0 {
                NavigationLink {
                    BrandFeedView(brand: group.brand)
                } label: {
                    // Underlined so it reads as the link it is; a bare mono line looked
                    // like another caption.
                    DataLabel(text: "+\(overflow) MORE FROM \(group.brand.name.uppercased())", color: .ink)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.ink).frame(height: 1).offset(y: 3)
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                }
            }
        }
        .padding(.bottom, 36)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            NavigationLink {
                BrandDetailView(brand: group.brand)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Wordmark(name: group.brand.name, size: 15)
                    DataLabel(
                        text: group.headline.uppercased(),
                        color: group.brand.isLockedForDrop ? .signal : .muted
                    )
                }
            }

            Spacer(minLength: 0)

            if let latest = group.latest {
                DataLabel(text: Stamp.short(latest).uppercased())
            }

            Button(action: onDismiss) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.muted)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Mark \(group.brand.name) seen")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
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
        case .priceDrop: return count == 1 ? "Price drop" : "\(count) price drops"
        }
    }
}

#Preview {
    FeedView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}
