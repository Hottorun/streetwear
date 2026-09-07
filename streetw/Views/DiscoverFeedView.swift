// DiscoverFeedView.swift
// The Discover tab: a full-bleed scroll of garments from brands you don't follow.
//
// Every other screen in this app is about brands somebody already chose. This one is the
// introduction, and the argument it makes is the one only an archive can make: *this goes
// with things you already own*. `GoesWith` has been writing that sentence on product pages
// for a while and its own header says what it is for —
//
//   "On something you have **not** kept it is an argument for keeping it — 'this works with
//    three things you own' is the most useful sentence a product page can print."
//
// It had never been pointed at a brand nobody here follows, which is the one place the
// sentence is worth the most.
//
// Three things about the shape, all deliberate:
//
// - **The card is a garment; the verdict is about the brand.** Nobody scrolls a wall of
//   wordmarks. So the photograph is a jacket and the thing you can act on is the label that
//   made it — Follow, or never again.
// - **No swipe-to-dismiss.** The obvious gesture is Tinder's and it is wrong here:
//   `BrandDismissal` is permanent *and* demotes brands that merely resemble the refused one,
//   so a flick landing by accident quietly poisons the recommender with no undo and nothing
//   on screen to say it happened. Horizontal belongs to the photographs.
// - **It ends honestly.** The catalogue is finite. A feed that starts again at the top is
//   claiming to have more, which is the class of quiet lie this project keeps a list of.

import StreetwCore
import SwiftData
import SwiftUI

struct DiscoverFeedView: View {
    @Environment(DiscoverDeck.self) private var deck: DiscoverDeck
    @Environment(DiscoveryAnalysis.self) private var analysis: DiscoveryAnalysis
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(StyleStatementStore.self) private var statement: StyleStatementStore
    @Environment(SaveConfirmation.self) private var confirmation: SaveConfirmation
    @Environment(\.modelContext) private var context

    /// The wardrobe, the refusals. Unpredicated on `SavedItem` for the same reason
    /// `StyleView` is — the question is genuinely about everything kept — but confined to
    /// this tab rather than the root, so a save does not rebuild the whole app.
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query private var dismissals: [BrandDismissal]

    /// The brands they follow, and what is still unread from them.
    ///
    /// **The other half of the supply.** `/v1/discover` is by construction the brands nobody
    /// here follows, which is the right pool for an introduction and the wrong one for the
    /// sentence this tab exists to print: *this goes with what you own* is exactly as good an
    /// argument about a new Kith jacket, and the feed — which is about what *happened* — has
    /// never made it. See `FollowedSupply` for what qualifies and why this is not the feed
    /// again.
    ///
    /// Narrowed by the store on `isSeen`, the way `FeedView` learned to: walking
    /// `brand.updates` faults in every product ever synced, and this view is rebuilt on any
    /// save. Sorted here so the interleave inherits recency.
    @Query(filter: #Predicate<Brand> { $0.followed }, sort: \Brand.name)
    private var followedBrands: [Brand]

    @Query(
        filter: #Predicate<BrandUpdate> { !$0.isSeen },
        sort: [SortDescriptor(\BrandUpdate.publishedAt, order: .reverse)]
    )
    private var unread: [BrandUpdate]

    /// An optional narrowing, because "I need a jacket" is a real reason to open this.
    @State private var slot: GarmentSlot?

    /// The card whose whole outfit is being looked at, if any, and the wardrobe piece it
    /// named on the way in.
    ///
    /// Presented from here rather than from the card, for the reason the save confirmation is
    /// owned by the app rather than by the tile that raised it: a card lives in a `LazyVStack`
    /// inside a paging scroll and is routinely torn down, and a sheet presented from a view
    /// that goes away goes away with it.
    @State private var fitting: FitRequest?

    /// The garment being looked at properly, and the brand being looked into.
    ///
    /// Both presented from here rather than from the card, for the same reason `fitting` is:
    /// a card lives in a `LazyVStack` inside a paging scroll and is routinely torn down, and
    /// a sheet presented from a view that goes away goes away with it.
    @State private var viewing: DiscoverCard?
    @State private var inspecting: DiscoverCard?
    /// A brand they already follow, opened from a card's wordmark. Its own state rather than
    /// `inspecting`, because the destination is a different screen — see `openBrand`.
    @State private var openedBrand: Brand?

    /// A subject plus the anchor the card was already showing, so the studio opens on the
    /// same garment the chip named. See `FitStudio.anchor`.
    struct FitRequest: Identifiable {
        var subject: FitSubject
        var anchor: String?
        var id: String { subject.id }
    }

    /// Everything the ranking reads about the person, built once and keyed on.
    ///
    /// Derived once per `body` and threaded down — the pattern `FeedView.Feed` uses. It is
    /// then handed to the deck through a `.task(id:)`, so the actual re-rank (a `Pairing`
    /// pass over every held card) happens when this *changes*, not when SwiftUI decides to
    /// evaluate a body.
    private var deckContext: DeckContext {
        // A save with no photograph is excluded outright, the same rule `GoesWith` and
        // `FitSuggestions` apply: this page is looked at before it is read.
        let kept = saves.filter { $0.update?.imageURLStrings.isEmpty == false }
        let owned = kept.filter { $0.type == .wardrobe }
        let wardrobe = (owned.isEmpty ? kept : owned).compactMap(\.update)

        var counts: [GarmentSlot: Int] = [:]
        for item in wardrobe { counts[item.garmentSlot, default: 0] += 1 }

        return DeckContext(
            wardrobe: wardrobe.map(\.garment),
            taste: taste(from: wardrobe),
            dismissed: Set(dismissals.map(\.remoteID)),
            owned: counts,
            gender: sizes.profile.gender,
            statement: statement.statement,
            slot: slot,
            // **Both ids, because a brand can be known by either.** The remote id is what
            // every card off the wire carries and what the follow list is keyed on — but a
            // brand added in standalone mode has never been to the server and holds only its
            // local `Brand.id`, which is then the id `FollowedSupply` puts on its cards.
            // Matching on the remote one alone left those cards dressed as an introduction to
            // a shop already in somebody's own brand rail, offering Follow and a permanent
            // refusal for it. Neither id can collide with the other's namespace, so carrying
            // both costs nothing and cannot be wrong.
            followed: Set(followedBrands.flatMap { [$0.remoteID, $0.id].compactMap { $0 } })
        )
    }

    /// What the brands they follow are offering the deck right now.
    ///
    /// Derived once per `body` and handed over through a `.task(id:)`, the pattern every
    /// other input to the ranking follows — `adopt` is a `Pairing` pass over the whole deck
    /// and must not run because SwiftUI decided to evaluate a body.
    private var followedCards: [DiscoverCard] {
        FollowedSupply.cards(from: unread, profile: sizes.profile)
    }

    /// When the offer above is worth rebuilding.
    ///
    /// Keyed on this rather than on the cards themselves, for the reason `StyleView`'s memo
    /// exists: building them runs `oncePerProduct` — a sort — and an interleave over the whole
    /// unread queue, while this is one walk of scalars that are already faulted in. The
    /// unread count moves whenever anything is read or a sync lands, which is the whole of
    /// what can change the answer; the gender filter is in it because it narrows the set, and
    /// the brand count because following or unfollowing changes who qualifies.
    private struct FollowedKey: Equatable {
        var unread: Int
        var newest: Date?
        var brands: Int
        var gender: GenderPreference
    }

    private var followedKey: FollowedKey {
        FollowedKey(
            unread: unread.count,
            newest: unread.first?.publishedAt,
            brands: followedBrands.count,
            gender: sizes.profile.gender
        )
    }

    /// Below this there is no taste to speak of, and re-ranking on three saves would be
    /// confidently wrong rather than usefully personal. Same threshold `BrandRecommendations`
    /// uses, and for the same reason.
    private static let minimumSavesToRank = 8

    private func taste(from wardrobe: [BrandUpdate]) -> BrandVector {
        guard wardrobe.count >= Self.minimumSavesToRank else { return BrandVector() }
        let vectors = deck.cards.compactMap { $0.card.vector }
        guard !vectors.isEmpty else { return BrandVector() }
        return BrandVectorBuilder.taste(
            from: wardrobe.map {
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

    /// The wardrobe keyed by `pairingID`, built once here rather than per card.
    ///
    /// `Pairing` reasons about `Garment` values, which carry no photograph — so the composite
    /// has to get back from the id the ranking chose to the row that holds the cutout. Three
    /// cards are realised at a time in a paging scroll, and a `@Query` in each of them would
    /// put all three on the `SavedItem` table.
    private var wardrobeByID: [String: BrandUpdate] {
        let kept = saves.compactMap(\.update)
        return Dictionary(kept.map { ($0.pairingID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The garments already in the collection, so a card's save control can say which it is
    /// rather than pretending every tap is the first.
    ///
    /// Keyed on the **product** as well as the event, for the reason `DiscoverSave.existingRow`
    /// is: a feed row is `event:<uuid>` because one garment produces several events over its
    /// life, and that key is useless for asking whether two things are the same jacket. Built
    /// once for the whole scroll, like the wardrobe beside it.
    private var savedKeys: Set<String> {
        var keys: Set<String> = []
        for update in saves.compactMap(\.update) {
            keys.insert(update.externalID)
            if let product = update.productExternalID { keys.insert(product) }
        }
        return keys
    }

    var body: some View {
        NavigationStack {
            Group {
                if deck.cards.isEmpty {
                    placeholder
                } else {
                    feed
                }
            }
            // The tab's own ground is the card's, so an empty state and the filter bar over
            // it are on the same surface a card would be. Fixed, like the card — see
            // `DiscoverCardView.groundTop`.
            .background(DiscoverCardView.groundTop)
            // **No navigation bar, and that is what makes the paging land.**
            //
            // A bar costs about 130pt at the top of the screen, and a `ScrollView` inside a
            // `NavigationStack` scrolls *underneath* it — so the container each card is sized
            // against was a bar taller than the region a page actually scrolls through, and
            // every card came to rest exactly that much short, with the previous card's
            // Follow row still showing above the title. It was consistent, which is what gave
            // it away: settling wrong by the same amount every time is an arithmetic
            // disagreement, not physics. Neither `.inline` nor `.viewAligned` closed it —
            // both were treating the symptom.
            //
            // Removing the bar removes the disagreement by construction, and it is the better
            // screen anyway: this is the one page in the app that is a photograph first, and
            // a serif title eating the top seventh of a phone to say "Discover" — on the tab
            // already labelled Discover — was paying for the bug twice.
            .toolbar(.hidden, for: .navigationBar)
            // **At the top, in words, and never a floating button.** See `filterBar`.
            .overlay(alignment: .top) { filterBar }
        }
        .tint(.ink)
        // Keyed on the token, not on appearance: this tab can be opened before registration
        // completes, a `.task` fires once per appearance, and a 401 swallowed by `try?`
        // would leave the feed empty for the whole session. That is exactly what happened to
        // `BrandSuggestions`.
        .task(id: settings.token) {
            await deck.loadIfNeeded(remote: remote, settings: settings)
        }
        .task(id: deckContext) {
            deck.update(context: deckContext)
        }
        // The other supply. Ordered after the context deliberately: `adopt` ranks, and
        // ranking a followed card before the deck knows which brands are followed would draw
        // it once as an introduction to a shop somebody already has.
        .task(id: followedKey) {
            deck.adopt(followed: followedCards)
        }
        // Lifts the confirmation clear of the action row — see `DiscoverCardView
        // .actionsHeight`. Cleared on the way out, or every other screen inherits the gap.
        .onAppear { confirmation.bottomClearance = DiscoverCardView.actionsHeight }
        .onDisappear { confirmation.bottomClearance = 0 }
        // The anchor travels with it, so the fit opens on the piece the card just named —
        // see `FitStudio.anchor`.
        .sheet(item: $fitting) { FitStudio(subject: $0.subject, anchor: $0.anchor) }
        // The garment, properly: the size run, the colourways, the description and the way
        // to the storefront — everything the card deliberately does not carry.
        .sheet(item: $viewing) { card in
            DiscoverProductSheet(
                card: card,
                isSaved: savedKeys.contains(card.productExternalID),
                onSave: { save(card) },
                onOpenFit: { openFit(for: card) }
            )
        }
        // A brand they already follow, at its own page. `appDestinations` is registered on
        // the stack *inside* the sheet, because a destination registered on this tab's stack
        // is invisible from within a presented one — the same trap the Upcoming sheet
        // documents, and the failure is a link that silently does nothing.
        .sheet(item: $openedBrand) { brand in
            NavigationStack { BrandDetailView(brand: brand) }
                .tint(.ink)
        }
        // The brand, before deciding to follow it — which is what this sheet has always been
        // for and why it is shared with the recommendation block rather than rewritten here.
        .sheet(item: $inspecting) { card in
            BrandPreviewSheet(
                item: PopularBrand(
                    brand: card.brand,
                    // **Not sent, and not invented.** `/v1/discover` carries no follower
                    // count — the deck's candidates are the brands nobody here follows, which
                    // is the whole point of it — and the sheet prints the line only above
                    // `Popularity.meaningfulFollowers`, so zero draws nothing rather than
                    // "1 PERSON WATCHING" under every shop.
                    followers: 0,
                    previewImageURLs: card.spread,
                    vector: card.vector
                ),
                onFollow: { await follow(card) },
                onDismiss: {
                    inspecting = nil
                    dismiss(card)
                }
            )
        }
    }

    /// Opens the whole outfit built around a card's garment, with whatever
    /// `DiscoveryAnalysis` has measured of the photograph travelling with it.
    ///
    /// Shared by the card's pairing chip and the product sheet, so the two cannot open
    /// different fits for the same garment.
    private func openFit(for card: DiscoverCard) {
        let read = analysis.result(for: card.productExternalID)
        let entry = deck.cards.first { $0.card.productExternalID == card.productExternalID }
        viewing = nil
        fitting = FitRequest(
            subject: .discovery(
                card,
                sticker: read?.sticker,
                reading: read?.reading,
                packshot: read?.packshotURL
            ),
            anchor: entry?.pairs.first?.id
        )
    }

    private var feed: some View {
        // Derived once for the whole scroll rather than per card — the pattern
        // `FeedView.Feed` uses, and the cost here is a walk over every save.
        let wardrobe = wardrobeByID
        let saved = savedKeys

        // **The scroll owns the whole screen, and each card is exactly one screen.**
        //
        // This took four wrong answers, and they are worth recording because every one of
        // them looked right. `containerRelativeFrame` inside a `NavigationStack` sizes
        // against a container that is a navigation bar taller than the region a page
        // actually travels, because the scroll runs underneath the bar — so every card came
        // to rest that much short, with the previous card's Follow row still on screen.
        // `.inline` did not fix it (the bar was still there). `.viewAligned` did not fix it
        // (the cards' own edges were still the wrong height). Hiding the bar traded it for
        // content under the status bar. A `GeometryReader` did not fix it either, because
        // the scroll view applies its own content inset *inside* the frame the reader
        // measured.
        //
        // The recipe that works is the one every full-screen feed uses: the scroll ignores
        // safe areas entirely, so the container is the screen, and each card is the
        // container. The two are then equal by construction and there is no arithmetic left
        // to disagree about — the card takes responsibility for its own insets instead,
        // which is why `reading` carries the padding that clears the tab bar.
        //
        // The tell throughout was that the error was *the same every time*. Physics varies;
        // an off-by-a-bar does not.
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(deck.cards.enumerated()), id: \.element.id) { index, card in
                    DiscoverCardView(
                        entry: card,
                        wardrobe: wardrobe,
                        onFollow: { await follow(card.card) },
                        onDismiss: { dismiss(card.card) },
                        onSave: { save(card.card) },
                        // The measured photograph travels with the card, so the fit draws the
                        // garment cut out where `DiscoveryAnalysis` has reached it and scores
                        // it on its real colour rather than on its title alone.
                        onOpenFit: { openFit(for: card.card) },
                        // A brand they already follow has a page in this app; a stranger has
                        // only the sheet that exists to answer "should I follow this". Sending
                        // a followed brand to that sheet would offer the decision back to
                        // somebody who has already made it — the same reason the card drops
                        // Follow and "not for me".
                        onOpenBrand: { openBrand(card) },
                        onOpenProduct: { viewing = card.card },
                        isSaved: saved.contains(card.card.productExternalID),
                        onMarkRead: { markRead(card.card) }
                    )
                    // Both axes. Height is the paging; width is because a
                    // `ScrollView(.horizontal)` inside the card reports its *content*
                    // width as its ideal, which made the card wider than the screen and
                    // pushed Palace's wordmark and Follow button off the left edge.
                    .containerRelativeFrame([.horizontal, .vertical])
                    .onAppear {
                        // Marked when it reaches the screen, not when it was fetched: a
                        // page held in memory that nobody scrolled to has not been seen,
                        // and writing it off would silently burn through the catalogue.
                        deck.markSeen(card.id)
                        // The next two cards' photographs are measured before they are
                        // reached, or the composite assembles itself while you watch.
                        analysis.warm(
                            deck.cards.dropFirst(index + 1).prefix(2).map(\.card)
                        )
                        Task {
                            await deck.loadMoreIfNeeded(
                                reaching: index, remote: remote, settings: settings
                            )
                        }
                    }
                }

                if deck.isExhausted {
                    ending.containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var placeholder: some View {
        if deck.isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(.sweepInk)
                DataLabel(text: "LOOKING FOR CLOTHES", color: .sweepInk.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !settings.isConfigured {
            // Standalone holds only brands somebody already followed, which is the opposite
            // of the question this tab asks. Saying so beats an empty page.
            EditorialEmptyState(
                title: "Discover needs the server",
                action: "THIS DEVICE IS RUNNING STANDALONE, SO IT ONLY KNOWS THE BRANDS YOU ADDED",
                ink: .sweepInk,
                detail: .sweepInk.opacity(0.55)
            )
        } else if slot != nil {
            EditorialEmptyState(
                title: "Nothing in that category",
                action: "CLEAR THE FILTER TO SEE THE REST",
                ink: .sweepInk,
                detail: .sweepInk.opacity(0.55)
            )
        } else {
            EditorialEmptyState(
                title: "Nothing left to show you",
                action: "YOU'VE SEEN EVERYTHING STREETW KNOWS ABOUT — ADD A BRAND BY ITS WEBSITE",
                ink: .sweepInk,
                detail: .sweepInk.opacity(0.55)
            )
        }
    }

    /// The end of the catalogue, said out loud. See the header: a feed that loops is lying.
    private var ending: some View {
        EditorialEmptyState(
            title: "That's everything, for now",
            action: "MORE ARRIVES AS BRANDS PUBLISH — AND AS YOUR WARDROBE CHANGES WHAT FITS",
            ink: .sweepInk,
            detail: .sweepInk.opacity(0.55)
        )
    }

    /// The one control on the screen, and it is a header rather than a floating button.
    ///
    /// It was a circular icon in the bottom-right corner, on the theory that the top belonged
    /// to Follow and a control over the artwork was worse than a control over the reading.
    /// Three things were wrong with that, and they are the reasons this is where it is now.
    ///
    /// - **It never said what it was.** A funnel glyph is not a category, so the *only* way to
    ///   know whether the feed was narrowed — and to what — was to open the menu. A filter you
    ///   cannot see is indistinguishable from a broken feed, which is exactly why the size
    ///   profile reorders instead of hiding and why `SavedView`'s facet chip is always visible
    ///   while it applies.
    /// - **It was two taps to a thing that should be one.** A menu to choose between five
    ///   words, on a screen whose entire interaction is a thumb travelling vertically.
    /// - **It was in the thumb's path.** Bottom-right on a full-screen paging scroll is where
    ///   the scroll is *driven from*, so the one control on the page sat under the gesture
    ///   that operates the page.
    ///
    /// **No band and no hairline.** It had an opaque `Color.paper` strip with a rule under it,
    /// which was a second horizontal division on a card that already had one — and the card's
    /// ground is flat studio sweep this far up, so the chips have something to sit on without
    /// anything being drawn to give them one. Set in fixed `sweepInk` for the same reason the
    /// card's ground is fixed: it is over the artwork, and artwork does not invert. The card's
    /// brand row insets itself below this by hand; see `DiscoverCardView.chromeTop`.
    private var filterBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    filterChip(label: "ALL", isOn: slot == nil) { slot = nil }
                    ForEach(GarmentSlot.essential, id: \.self) { option in
                        filterChip(
                            label: option.label.uppercased(),
                            isOn: slot == option
                        ) {
                            // Tapping the one already on clears it, so getting back to
                            // everything never means hunting for a word called "everything".
                            slot = slot == option ? nil : option
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.hidden)
            .frame(height: 34)
        }
        .padding(.top, 4)
        // The status bar sits on the card's own ground, which is already flat sweep up
        // there. The feed itself ignores safe areas — a card and a page are exactly one
        // screen — so this is the one place the inset is honoured rather than paid by hand.
        .background(DiscoverCardView.groundTop.ignoresSafeArea(edges: .top))
    }

    private func filterChip(
        label: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.wordmark(10, isOn ? .semibold : .regular))
                    .tracking(1.2)
                    .foregroundStyle(isOn ? Color.sweepInk : Color.sweepInk.opacity(0.45))
                Rectangle()
                    .fill(isOn ? Color.sweepInk : Color.clear)
                    .frame(height: 1)
            }
            .fixedSize()
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Acting on a card

    private func follow(_ card: DiscoverCard) async {
        guard let id = card.brand.id else { return }
        do {
            try await remote.followExisting(card.brand, sizes: sizes.profile)
            // The brand's other cards go with it — they are arguments for a decision that
            // has now been made.
            deck.forget(brandID: id)
            await remote.sync(sizes: sizes.profile)
        } catch {
            // Quiet: the card stays, so the obvious recovery is to tap it again.
        }
    }

    /// Keeps the garment, and offers to amend that — a board, or a watch.
    ///
    /// The card is *not* removed. Keeping something is not a verdict on the brand, and a
    /// card vanishing under the thumb that just saved it would read as a dismissal; the two
    /// gestures would then be indistinguishable in their effect while meaning opposite
    /// things. Follow and "not for me" are the verdicts, and only they clear the card.
    private func save(_ card: DiscoverCard) {
        guard let update = DiscoverSave.save(card, in: context) else { return }
        confirmation.confirm(update, destination: SavedItem.SaveType.inspiration.label)
    }

    /// The brand line, sent wherever that brand actually lives.
    ///
    /// Followed: its page, which is its catalogue and its watch state. Unfollowed:
    /// `BrandPreviewSheet`, which exists precisely to answer whether to follow it.
    private func openBrand(_ entry: DeckCard) {
        guard entry.isFollowed, let remoteID = entry.card.brand.id else {
            inspecting = entry.card
            return
        }
        var descriptor = FetchDescriptor<Brand>(predicate: #Predicate { $0.remoteID == remoteID })
        descriptor.fetchLimit = 1
        // A miss is survivable rather than impossible — the row is what made the card, but a
        // sync can remove a follow between the two — so it falls back to the sheet.
        if let brand = try? context.fetch(descriptor).first {
            openedBrand = brand
        } else {
            inspecting = entry.card
        }
    }

    /// Clears a followed brand's garment out of the feed's unread queue.
    ///
    /// **Every row that garment stands for, not the one card.** The deck holds one card per
    /// product and the store holds events — a jacket that dropped and then restocked is two
    /// unread rows — so clearing the one the card was built from would leave the brand's
    /// spread in the feed showing the same jacket, which is `FeedView.markSeen`'s lesson met
    /// on a different screen. Matched on the product key for the same reason
    /// `DiscoverSave.existingRow` is: the event key cannot answer "is this the same garment".
    ///
    /// The card itself stays exactly where it is — see `DiscoverDeck.adopt`.
    private func markRead(_ card: DiscoverCard) {
        let key = card.productExternalID
        var touched = false
        for update in unread where update.productExternalID == key || update.externalID == key {
            update.isSeen = true
            update.brand?.lastOpenedAt = Date()
            touched = true
        }
        guard touched else { return }
        try? context.save()
    }

    /// "Not for me." Recorded rather than merely hidden — `BrandDismissal` stores the
    /// refused brand's vector so the other four labels that look like it are quieted too.
    private func dismiss(_ card: DiscoverCard) {
        guard let id = card.brand.id else { return }
        context.insert(BrandDismissal(remoteID: id, name: card.brand.name, vector: card.vector))
        try? context.save()
        deck.forget(brandID: id)
    }
}
