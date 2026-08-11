// BrandRecommendations.swift
// What else is worth watching, so no screen in the app is ever a dead end.
//
// The feed's empty state used to say "All caught up · pull to refresh", which is honest
// and completely useless: the moment someone finishes their brands is exactly the moment
// they have attention to spare and nothing to spend it on. A watcher with five brands and
// an empty feed looks finished; the same person shown five more brands worth following
// has a reason to come back.
//
// The signal is deliberately the dullest one available — **how many people follow it** —
// and it is read as a count and nothing else. No identities, no per-person lists, nothing
// that could reconstruct what an individual watches. That rules out the recommendation
// tricks that would work better and makes the one thing this does show unobjectionable.

import StreetwCore
import SwiftData
import SwiftUI

/// Loads and caches the popular list. An `@Observable` rather than view state so the feed
/// and Discover can't each fire their own request for the same answer.
@MainActor
@Observable
final class BrandSuggestions {
    private(set) var brands: [PopularBrand] = []
    private(set) var isLoading = false
    private(set) var lastLoadedAt: Date?

    private let remote: RemoteSync
    private let settings: ServerSettings

    /// Popularity moves on the order of days, so refetching per appearance would be
    /// pure noise. Ten minutes is short enough that following something is reflected
    /// soon, long enough that scrolling in and out of the feed costs nothing.
    private static let freshness: TimeInterval = 600

    init(remote: RemoteSync, settings: ServerSettings) {
        self.remote = remote
        self.settings = settings
    }

    func loadIfNeeded(force: Bool = false) async {
        // Registration has to have happened: `/v1/brands/popular` is authenticated, and
        // on a cold launch this runs concurrently with the sync that registers the
        // device. Without the guard the first attempt 401s, returns nothing, and — since
        // a `.task` fires once per appearance — never retries, so the block stays empty
        // for the whole session. Callers key their task on `settings.token` so this reruns
        // the moment registration lands.
        guard settings.isConfigured, settings.isRegistered, !isLoading else { return }
        if !force, let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < Self.freshness {
            return
        }

        isLoading = true
        defer { isLoading = false }

        if let found = try? await remote.popularBrands(limit: 12) {
            brands = found
            lastLoadedAt = Date()
        }
    }

    /// Drops a brand from the list the moment it is followed, so the card doesn't sit
    /// there inviting the same tap again while the next sync catches up.
    func forget(_ id: UUID?) {
        guard let id else { return }
        brands.removeAll { $0.brand.id == id }
    }
}

/// The block shown under a finished feed, and in Discover.
struct BrandRecommendations: View {
    @Environment(BrandSuggestions.self) private var suggestions: BrandSuggestions
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    @Query private var followed: [Brand]
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]

    var title: String = "Also worth watching"
    var blurb: String = "WHAT OTHER PEOPLE ON STREETW FOLLOW"

    /// Below this many saves there isn't a taste to speak of, and re-ranking on three
    /// items would be confidently wrong rather than usefully personal.
    private static let minimumSavesToReRank = 8

    /// Anything already followed locally is filtered out here as well as server-side —
    /// the server's answer can be a few seconds stale, and recommending someone a brand
    /// they just added reads as broken.
    private var candidates: [PopularBrand] {
        let mine = Set(followed.compactMap(\.remoteID))
        return suggestions.brands.filter { dto in
            guard let id = dto.brand.id else { return false }
            return !mine.contains(id)
        }
    }

    /// Re-ranked against a taste profile built **on this device** from what has been
    /// saved.
    ///
    /// This is the sharpest signal the app has — what someone keeps says far more than
    /// what they follow — and it is also the most personal. Sending saves to the server
    /// would rank better and would quietly undo the thing the collection is for, so the
    /// server ships the candidates *with their vectors* and the comparison happens here.
    /// Nothing about a save ever leaves the phone.
    private var visible: [PopularBrand] {
        let pool = candidates
        let usable = saves.compactMap(\.update)
        guard usable.count >= Self.minimumSavesToReRank else { return pool }

        let vectors = pool.compactMap(\.vector)
        guard !vectors.isEmpty else { return pool }

        let taste = BrandVectorBuilder.taste(
            from: usable.map {
                ProductSummary(
                    title: $0.title,
                    productType: $0.productType,
                    tags: $0.tags,
                    priceAmount: $0.priceAmount,
                    publishedAt: $0.publishedAt
                )
            },
            comparedWith: vectors
        )
        guard !taste.isEmpty else { return pool }

        return pool
            .map { item -> (item: PopularBrand, score: Double) in
                guard let vector = item.vector else {
                    // No vector to judge by. Keep whatever the server thought rather than
                    // dropping the brand to the bottom for a gap in the data.
                    return (item, item.affinity ?? 0)
                }
                // The server already blended its own affinity with popularity; this
                // nudges rather than replaces, so a brand everyone follows doesn't vanish
                // because one wardrobe leans elsewhere.
                return (item, 0.6 * taste.similarity(to: vector) + 0.4 * (item.affinity ?? 0.5))
            }
            .sorted { $0.score > $1.score }
            .map(\.item)
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.editorial(19))
                        .foregroundStyle(Color.ink)
                    DataLabel(text: blurb)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

                ForEach(visible) { item in
                    SuggestedBrandCard(item: item) { await follow(item) }
                }
            }
            .padding(.top, 8)
        } else if suggestions.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                DataLabel(text: "LOOKING FOR BRANDS")
            }
            .padding(20)
        }
    }

    private func follow(_ item: PopularBrand) async {
        do {
            try await remote.followExisting(item.brand, sizes: sizes.profile)
            suggestions.forget(item.brand.id)
            // Pull straight away: the point of following from here is to see the brand's
            // drops, and waiting for the next scheduled sync to show anything would make
            // the button feel like it did nothing.
            await remote.sync(sizes: sizes.profile)
        } catch {
            // Non-fatal and deliberately quiet. The card stays, so the obvious recovery
            // is to tap it again.
        }
    }
}

/// One recommendation: the mark, who it is, how many watch it, and what it looks like.
struct SuggestedBrandCard: View {
    let item: PopularBrand
    let onFollow: () async -> Void

    @State private var isFollowing = false

    private var images: [URL] {
        item.previewImageURLs.compactMap(URL.init(string:)).prefix(3).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                BrandMonogram(name: item.brand.name, logoURL: item.brand.logoURL.flatMap(URL.init(string:)))

                VStack(alignment: .leading, spacing: 5) {
                    Wordmark(name: item.brand.name, size: 14)
                    DataLabel(
                        text: item.followers == 1
                            ? "1 PERSON WATCHING"
                            : "\(item.followers) PEOPLE WATCHING",
                        size: 10
                    )
                }

                Spacer(minLength: 8)

                Button {
                    guard !isFollowing else { return }
                    isFollowing = true
                    Task {
                        await onFollow()
                        isFollowing = false
                    }
                } label: {
                    Group {
                        if isFollowing {
                            ProgressView().tint(.paper)
                        } else {
                            Text("FOLLOW")
                                .font(.data(11, .semibold))
                                .tracking(0.8)
                        }
                    }
                    .foregroundStyle(Color.paper)
                    .frame(width: 78, height: 32)
                    .background(Color.ink)
                }
                .buttonStyle(.borderless)
            }

            // Three recent shots. A brand recommendation without clothes in it is asking
            // someone to judge a wordmark.
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(images, id: \.self) { url in
                        UpdateImage(url: url, aspect: 1, drawnWidth: 130)
                    }
                    // Keeps a brand with one image from stretching it across the row.
                    if images.count < 3 {
                        ForEach(0..<(3 - images.count), id: \.self) { _ in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
    }
}
