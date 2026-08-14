// BrandRecommendations.swift
// What else is worth watching, so no screen in the app is ever a dead end.
//
// The feed's empty state used to say "All caught up · pull to refresh", which is honest
// and completely useless: the moment someone finishes their brands is exactly the moment
// they have attention to spare and nothing to spend it on. A watcher with five brands and
// an empty feed looks finished; the same person shown five more brands worth following
// has a reason to come back.
//
// Three signals, in descending order of how much they are worth:
//
// 1. **What you keep.** The taste vector, built here from saves that never leave the phone.
// 2. **What you refused.** `BrandDismissal` — the only negative signal in the app, and the
//    reason the same wrong brand no longer comes back every refresh.
// 3. **How many people follow it.** Read as a count and nothing else: no identities, no
//    per-person lists, nothing that could reconstruct what an individual watches.
//
// The third used to be the *only* one that reached the screen, and it was printed on every
// card as "1 PERSON WATCHING" — an argument against following, under every brand, on the
// block whose whole job is to make following attractive. It now has to earn its place: see
// `Popularity.confidence` for why a headcount from a handful of users is an artefact of
// its own denominator rather than evidence about a brand.

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

    @Environment(\.modelContext) private var context

    @Query private var followed: [Brand]
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query private var dismissals: [BrandDismissal]

    @State private var previewed: PopularBrand?

    var title: String = "Also worth watching"
    var blurb: String = "PICKED FROM WHAT YOU KEEP"
    /// How many cards this block prints before deferring to the full list.
    ///
    /// Three, not twelve. The block sits on the feed, the brands tab *and* the style tab,
    /// so a wall of suggestions was being served three times over to somebody who had
    /// followed one brand — the same twelve names each time, in the same order. Three
    /// reads as a suggestion; twelve reads as a demand, and the third copy of it reads as
    /// the app having nothing else to say. Everything beyond them is one tap away.
    var limit: Int = 3

    @State private var isShowingAll = false

    /// Below this many saves there isn't a taste to speak of, and re-ranking on three
    /// items would be confidently wrong rather than usefully personal.
    private static let minimumSavesToReRank = 8

    /// Anything already followed locally is filtered out here as well as server-side —
    /// the server's answer can be a few seconds stale, and recommending someone a brand
    /// they just added reads as broken.
    /// Anything already followed locally is filtered out here as well as server-side —
    /// the server's answer can be a few seconds stale, and recommending someone a brand
    /// they just added reads as broken.
    ///
    /// Matched on **domain as well as remote id**. A brand added in standalone mode or
    /// from the onboarding starter pack has no `remoteID` at all, so an id-only check sees
    /// nothing and cheerfully suggests a shop already sitting at the top of the same
    /// screen — which is exactly what Kith did, listed as followed and unfollowed at once.
    /// `RemoteSync.mergeBrands` heals those rows by adopting the id, but only once a sync
    /// has mentioned them, and this must be right before that happens.
    private var candidates: [PopularBrand] {
        let mine = Set(followed.compactMap(\.remoteID))
        let myDomains = Set(followed.compactMap { brand -> String? in
            brand.websiteURL?.host().map(BrandDiscovery.registrableDomain(of:))
        })
        let refused = Set(dismissals.map(\.remoteID))

        return suggestions.brands.filter { item in
            guard let id = item.brand.id, !mine.contains(id), !refused.contains(id) else {
                return false
            }
            guard let host = item.brand.website.flatMap({ URL(string: $0)?.host() }) else {
                return true
            }
            return !myDomains.contains(BrandDiscovery.registrableDomain(of: host))
        }
    }

    /// What this person likes and what they have refused, in the form the ranker wants.
    ///
    /// Both halves are built here, on the device, from rows that never leave it.
    private var recommender: Recommender {
        let usable = saves.compactMap(\.update)
        let vectors = candidates.compactMap(\.vector)

        var taste = BrandVector()
        if usable.count >= Self.minimumSavesToReRank, !vectors.isEmpty {
            taste = BrandVectorBuilder.taste(
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
        }

        return Recommender(taste: taste, dismissed: dismissals.compactMap(\.vector))
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
        let ranker = recommender
        guard !ranker.taste.isEmpty || !ranker.dismissed.isEmpty else { return pool }

        // The server has already damped its own popularity term, so the headcount is not
        // reapplied here — this pass is purely "does it look like what I keep, and does it
        // look like what I turned down".
        return pool
            .map { item in (item, ranker.score(candidate: item.vector, affinity: item.affinity, popularity: nil)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var shown: [PopularBrand] { Array(visible.prefix(limit)) }

    /// The words a candidate shares with this wardrobe — the line the card prints instead
    /// of a follower count.
    private func reason(for item: PopularBrand) -> [String] {
        guard let vector = item.vector else { return [] }
        let taste = recommender.taste
        guard !taste.isEmpty else { return [] }
        return vector.sharedTraits(with: taste)
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

                ForEach(shown) { item in
                    SuggestedBrandCard(
                        item: item,
                        reason: reason(for: item),
                        onOpen: { previewed = item },
                        onFollow: { await follow(item) },
                        onDismiss: { dismiss(item) }
                    )
                }

                if visible.count > shown.count {
                    Button { isShowingAll = true } label: {
                        DataLabel(text: "SEE ALL \(visible.count)", color: .ink)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color.ink).frame(height: 1).offset(y: 3)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            .sheet(isPresented: $isShowingAll) {
                DiscoverView(
                    items: visible,
                    reason: reason(for:),
                    onFollow: { await follow($0) },
                    onDismiss: { dismiss($0) }
                )
            }
            .sheet(item: $previewed) { item in
                BrandPreviewSheet(
                    item: item,
                    reason: reason(for: item),
                    onFollow: { await follow(item) },
                    onDismiss: { dismiss(item) }
                )
            }
        } else if suggestions.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                DataLabel(text: "LOOKING FOR BRANDS")
            }
            .padding(20)
        }
    }

    /// "Not this one." Recorded rather than merely hidden — see `BrandDismissal`.
    private func dismiss(_ item: PopularBrand) {
        guard let id = item.brand.id else { return }
        context.insert(BrandDismissal(remoteID: id, name: item.brand.name, vector: item.vector))
        try? context.save()
        // Drop it from the loaded list too, or it reappears until the ten-minute cache
        // expires and the tap looks like it did nothing.
        suggestions.forget(id)
        previewed = nil
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

/// One recommendation: the mark, who it is, **why**, and what it looks like.
///
/// The subtitle used to be the follower count, which at this scale read "1 PERSON
/// WATCHING" on every row — an argument against following, printed under every brand, on
/// the block whose whole job is to make following attractive. It is now the words this
/// brand shares with your own wardrobe, which is both more persuasive and checkable: you
/// can look at "workwear · denim" and tell instantly whether the match is right. The count
/// only appears once there are enough people for it to mean anything.
struct SuggestedBrandCard: View {
    let item: PopularBrand
    var reason: [String] = []
    var onOpen: () -> Void = {}
    let onFollow: () async -> Void
    var onDismiss: () -> Void = {}

    @State private var isFollowing = false

    private var images: [URL] {
        BrandPreview.images(from: item.previewImageURLs, limit: 3)
    }

    /// The line under the wordmark, in order of how much it is worth saying.
    private var subtitle: String {
        if !reason.isEmpty {
            return "LIKE YOUR " + reason.map { $0.uppercased() }.joined(separator: " · ")
        }
        // Only once a headcount is evidence rather than an artefact of a tiny sample —
        // the same threshold the ranking uses.
        if Double(item.followers) >= Popularity.meaningfulFollowers {
            return "\(item.followers) PEOPLE WATCHING"
        }
        return item.brand.website.flatMap { URL(string: $0)?.host() }?.uppercased() ?? "NEW TO STREETW"
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    BrandMonogram(name: item.brand.name, logoURL: item.brand.logoURL.flatMap(URL.init(string:)))

                    VStack(alignment: .leading, spacing: 5) {
                        Wordmark(name: item.brand.name, size: 14)
                        DataLabel(text: subtitle, size: 10)
                    }

                    Spacer(minLength: 8)

                    FollowButton(isWorking: $isFollowing, action: onFollow)
                }

                // Three recent shots. A brand recommendation without clothes in it is
                // asking someone to judge a wordmark.
                if !images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(images, id: \.self) { url in
                            UpdateImage(url: url, aspect: 1, drawnWidth: 130, mark: item.brand.name)
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
        // A swipe is the gesture people already use to reject a card, and the menu is the
        // discoverable version of it. Both write the same dismissal.
        .contextMenu {
            Button("Not for me", systemImage: "hand.thumbsdown") { onDismiss() }
        }
    }
}

/// The one control that turns a suggestion into a follow, shared by the card and the
/// preview so the two can't disagree about what it looks like or what it does.
struct FollowButton: View {
    @Binding var isWorking: Bool
    let action: () async -> Void
    var width: CGFloat = 78

    var body: some View {
        Button {
            guard !isWorking else { return }
            isWorking = true
            Task {
                await action()
                isWorking = false
            }
        } label: {
            Group {
                if isWorking {
                    ProgressView().tint(.paper)
                } else {
                    Text("FOLLOW")
                        .font(.data(11, .semibold))
                        .tracking(0.8)
                }
            }
            .foregroundStyle(Color.paper)
            .frame(width: width, height: 32)
            .background(Color.ink)
        }
        // .borderless, not .plain: this sits inside a row that is itself a button, and
        // `.plain` lets the outer target swallow the tap.
        .buttonStyle(.borderless)
    }
}
