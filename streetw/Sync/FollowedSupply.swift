// FollowedSupply.swift
// What is unread from the brands you already follow, offered to the Discover deck.
//
// **Why this is not simply the Feed again.** The two tabs ask different questions of the
// same garment. The feed asks *what happened* — it is ordered by recency, grouped by brand,
// and its unit is the event: "9 new products", with the garments as evidence. Discover asks
// *does this go with what you own*, which is a sentence the feed has never printed about a
// followed brand's drop, and which is the one thing an archive can say that a catalogue
// cannot. A new Kith jacket that pairs with your olive cargos is exactly as good an argument
// as an unfollowed brand's, and until now the app could only make it about strangers.
//
// Five rules, and each is the difference between this and a duplicate feed:
//
// - **Unread only.** Something already read is not news, and the deck is not an archive.
// - **A garment, with a photograph.** The tab is pictures first — `.pageChange` and
//   `.dropLock` have no garment, a `.post` is a brand's own marketing, and a release is
//   drawn from its members which is a query this does not do. Product, restock and markdown
//   are all a real garment somebody can be shown.
// - **Deduplicated per garment**, the rule `BrandUpdate.oncePerProduct` states: one jacket
//   that dropped and then restocked is one card, or the deck repeats itself in the way the
//   whole of `Discovery` exists to prevent.
// - **Spread across brands and capped**, so following twenty shops does not turn the
//   discovery tab into a second feed. `Discovery.interleave` is the same round-robin the
//   release mosaic uses, pointed at brands.
// - **Nothing is written.** These are read out of the store and handed over as
//   `DiscoverCard`s — the same value the server sends — so every path downstream (ranking,
//   the card, saving, the fit studio) is the one that already exists and cannot drift.
//   Scrolling past one does **not** mark it seen: `isSeen` belongs to the feed, and clearing
//   somebody's unread queue as a side effect of looking at a different tab would be the app
//   deciding they had read something they had not.

import Foundation
import StreetwCore

/// `@MainActor` because everything it touches is a SwiftData model, which is the same rule
/// the rest of the app follows — only the main actor reads or writes the store. It was
/// implicitly main-actor at every call site already; saying so is what stops the compiler
/// treating `card(from:)` as a cross-actor call.
@MainActor
enum FollowedSupply {
    /// How many cards the brands you follow may put into the deck at once.
    ///
    /// Twelve against a server page of about thirty, so this is roughly a quarter of what is
    /// on screen: enough that a drop from a brand you follow reliably turns up, nowhere near
    /// enough to make the tab about brands you already have. It is a standing set rather than
    /// a stream — as these are read, or saved, or the sync brings more, the view hands over a
    /// new set — so the number is what can be *pending* at any moment, not a rate.
    static let limit = 12

    /// The kinds that are a garment somebody can be shown and paired against.
    ///
    /// A markdown is included deliberately: "this is cheaper than it was **and** it goes with
    /// your cargos" is the strongest sentence in the app, and the feed deliberately never
    /// gives a price cut a photograph the size of a page.
    static let kinds: Set<UpdateKind> = [.product, .restock, .priceDrop]

    /// Builds the offer from the unread rows the caller already holds.
    ///
    /// Takes rows rather than a context because the view has them: `DiscoverFeedView` is
    /// already querying the store, and a second fetch inside the deck would put the deck on a
    /// table it deliberately does not subscribe to.
    /// - Note: **The order of the tests is the performance of this function.** `unread` is a
    ///   `@Query` over `isSeen` across every followed brand — thousands of rows on a synced
    ///   device — and it is walked again whenever anything is marked read or a sync lands.
    ///   `update.brand` is the only test here that touches a *relationship*, and a
    ///   relationship read faults the object in; asking it first meant every unread row in
    ///   the store was faulted to answer a question three stored scalars had already settled
    ///   for most of them. It is asked last now, of the few rows that got that far. (The
    ///   gender classifier is not a risk here any more: `BrandUpdate.passes` short-circuits
    ///   structurally when the filter is off, which is what stopped six call sites each
    ///   needing their own guard.)
    static func cards(from unread: [BrandUpdate], profile: SizeProfile) -> [DiscoverCard] {
        let eligible = BrandUpdate.oncePerProduct(
            unread.filter { update in
                guard kinds.contains(update.kind) else { return false }
                // A photograph *is* the feature on this tab — the same rule the fit tray and
                // `FitSuggestions` apply, and the reason `/v1/discover` filters on it too.
                guard update.hasPhotograph else { return false }
                guard update.passes(profile) else { return false }
                return update.brand?.followed == true
            }
        )

        // Round-robin over brands, newest first within each, so a brand mid-drop with two
        // hundred unread rows does not spend the whole allowance. `oncePerProduct` has
        // already sorted by `newestFirst`, which the interleave inherits.
        let spread = Discovery.interleave(eligible, by: { $0.brand?.id ?? UUID() })
        return spread.prefix(limit).map(card(from:))
    }

    /// One row as the deck's own currency.
    ///
    /// Keyed on the **product**, never the event: a feed row is `event:<uuid>` because one
    /// garment produces a drop, a markdown and a restock over its life, and that key cannot
    /// answer "are these the same jacket". `DiscoverSave.existingRow` matches on the product
    /// id, which is what makes saving from this card land on the row that is already here
    /// rather than minting a second one for the same garment.
    private static func card(from update: BrandUpdate) -> DiscoverCard {
        let brand = update.brand
        return DiscoverCard(
            productExternalID: update.productExternalID ?? update.externalID,
            brand: BrandDTO(
                // The **remote** id, because that is the identity every other card carries
                // and the one `BrandDismissal` and the follow list are keyed on. A local
                // `Brand.id` here would make the same shop two different brands to the
                // ranking, which is how a per-brand cap silently stops capping.
                id: brand?.remoteID ?? brand?.id,
                name: update.brandLabel ?? "",
                slug: brand?.websiteURL?.host ?? "",
                website: brand?.websiteURL?.absoluteString,
                currency: brand?.currencyCode,
                lockedForDrop: brand?.isLockedForDrop ?? false,
                logoURL: brand?.logoURLString,
                sources: []
            ),
            title: update.title,
            summary: update.summary,
            imageURLs: update.imageURLStrings,
            linkURL: update.linkURL?.absoluteString,
            priceText: update.priceText,
            priceAmount: update.priceAmount,
            isAvailable: update.isAvailable,
            productType: update.productType,
            tags: update.tags,
            // The stored verdict and the revision that produced it, exactly as the wire
            // carries them — so the deck's gender filter reads the same answer the feed does
            // rather than re-deriving a different one from the title.
            gender: update.genderRaw,
            genderVersion: update.genderVersion,
            variants: update.variants,
            publishedAt: update.publishedAt,
            // **No spread and no vector, and both absences are honest.** The spread is "six
            // more things this label makes", which is an argument for following a shop you
            // already follow; the vector is built by the server over the whole catalogue and
            // the phone has no way to compute one. A card with neither prints one less line
            // rather than inventing either — and `DiscoverDeck` treats a followed brand as
            // familiar regardless, so a missing vector cannot land it in an exploration slot.
            spread: [],
            vector: nil
        )
    }
}
