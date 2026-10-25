// FeedPass.swift
// The one pass from stored rows to the feed's cards.
//
// `FeedTimeline` decides what is a card and where it goes, from plain values. This is the
// part that has to touch SwiftData to produce those values — and it is the part that has to
// stay cheap, because it runs once per evaluation of `FeedView.body`.

import Foundation
import StreetwCore
import SwiftData

/// Everything `FeedView` draws from, derived once per `body` and passed down — the rule in
/// `docs/performance.md`, and the shape 1.0's `FeedView.Feed` already had.
@MainActor
struct FeedPass {
    var timeline = FeedTimeline.Result()
    /// The rows behind the cards, by `externalID`. Cards read their photographs and prices
    /// from these live, so a photograph that lands after the pass redraws its own card
    /// rather than the screen.
    var rows: [String: BrandUpdate] = [:]
    /// The brands behind the cards, by the key the timeline uses.
    var brands: [String: Brand] = [:]
    /// Whether the gender setting hid anything — the difference between "nothing yet" and
    /// "nothing matches your filter".
    var isHidingSome = false

    /// The members of one card, in the card's order.
    func rows(of card: FeedTimeline.Card) -> [BrandUpdate] {
        card.entries.compactMap { rows[$0] }
    }

    /// - Parameter news: rows with an arrival — the feed's timeline is news, never history.
    ///   See `BrandUpdate.arrivedAt`.
    init(news: [BrandUpdate], profile: SizeProfile, since boundary: Date?, now: Date = Date()) {
        // **The order of the tests is the cost of this function**, the lesson
        // `FollowedSupply.cards` wrote down: stored scalars first, the relationship after.
        var kept: [(update: BrandUpdate, arrived: Date, brand: Brand)] = []
        kept.reserveCapacity(news.count)
        for update in news {
            guard let arrived = update.arrivedAt else { continue }
            // A gift card is not news about a brand's output and is never on the feed; it is
            // not something the reader's setting hid either.
            guard !update.isMerchandise else { continue }
            guard let brand = update.brand, brand.followed else { continue }
            guard update.passes(profile) else {
                isHidingSome = true
                continue
            }
            guard rows[update.externalID] == nil else { continue }
            rows[update.externalID] = update
            brands[brand.id.uuidString] = brand
            kept.append((update, arrived, brand))
        }

        let releases = kept.filter { $0.update.kind == .collection }
        var entries: [FeedTimeline.Entry] = []
        entries.reserveCapacity(kept.count)
        for (update, arrived, brand) in kept {
            let kind = update.kind
            let key = brand.id.uuidString
            if kind == .post, releases.contains(where: { release in
                release.brand.id == brand.id
                    && abs(release.update.publishedAt.timeIntervalSince(update.publishedAt)) <= FeedTimeline.releaseWindow
                    && Self.restates(release.update.title, as: update.title, ignoring: brand.name)
            }) {
                // **One release, stated once.** A brand that runs a blog announces its drop
                // twice — the collection, and a post about the collection — and BBC's Yankees
                // edit arrived as both. The release card says it.
                continue
            }
            entries.append(FeedTimeline.Entry(
                id: update.externalID,
                brand: key,
                kind: kind,
                happenedAt: update.publishedAt,
                arrivedAt: arrived,
                product: update.productExternalID ?? update.externalID,
                // `claims`, never `matches` — the label is a statement about the reader.
                isYours: kind == .restock && !profile.isEmpty && !update.restockedSizes(matching: profile).isEmpty,
                releaseMembers: kind == .collection ? members(of: update, brand: brand, among: kept) : []
            ))
        }
        timeline = FeedTimeline.build(entries, since: boundary, now: now)
    }

    /// The garments a release is known to hold, as product keys: the storefront's own list,
    /// else the word match — `Brand.members(of:)`'s order, so the card and the page it opens
    /// agree about what is in it.
    ///
    /// Matched against this timeline's own rows rather than the brand's catalogue: the
    /// question is only what to fold, and `members(of:)` faults the whole relationship to
    /// answer a wider one. The guess admits `.product` alone, the same restraint the guess
    /// there keeps — a re-shelved garment from the same season carries the same season code.
    private func members(
        of release: BrandUpdate,
        brand: Brand,
        among kept: [(update: BrandUpdate, arrived: Date, brand: Brand)]
    ) -> Set<String> {
        if !release.memberExternalIDs.isEmpty { return Set(release.memberExternalIDs) }
        let words = BrandUpdate.distinctiveWords(in: release.title)
        guard !words.isEmpty else { return [] }
        var members = Set<String>()
        for row in kept where row.brand.id == brand.id && row.update.kind == .product && row.update.mentionsAny(of: words) {
            members.insert(row.update.productExternalID ?? row.update.externalID)
        }
        return members
    }

    /// Whether a blog post is announcing a release.
    ///
    /// A page name and a headline are never identical — BBC's read "The Women's Edit: New
    /// York Yankees™ | Billionaire Boys Club" and "New York Yankees™ | Billionaire Boys Club".
    /// Containment over letters and digits catches that pair; the words carry the rest.
    ///
    /// **The brand's own name is struck out first**, because nearly every post a brand writes
    /// names it. What is left has to overlap in at least two words — one is a coincidence,
    /// every drop is "denim" sooner or later — and then the post may add **one** word of its
    /// own: "Introducing the New York Yankees Collection" adds words to a page name, and a
    /// strict subset test folded neither of the pairs it was written for. The cost, accepted
    /// knowingly: a genuinely separate post sharing two words and adding one is folded too.
    /// Nothing is lost either way — the release card is above it, and the post is still on
    /// the brand's page.
    static func restates(_ release: String, as post: String, ignoring brandName: String) -> Bool {
        let a = release.lowercased().filter { $0.isLetter || $0.isNumber }
        let b = post.lowercased().filter { $0.isLetter || $0.isNumber }
        if a.count >= 12, b.count >= 12, a.contains(b) || b.contains(a) { return true }

        let brand = Set(BrandUpdate.distinctiveWords(in: brandName))
        let release = Set(BrandUpdate.distinctiveWords(in: release)).subtracting(brand)
        let post = Set(BrandUpdate.distinctiveWords(in: post)).subtracting(brand)
        guard !release.isEmpty, !post.isEmpty else { return false }
        guard release.intersection(post).count >= 2 else {
            return release.isSubset(of: post) || post.isSubset(of: release)
        }
        return post.subtracting(release).count <= 1 || release.subtracting(post).isEmpty
    }
}
