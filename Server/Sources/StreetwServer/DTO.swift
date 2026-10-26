// DTO.swift
// The wire types themselves live in StreetwCore so the app and server cannot drift.
// Here we only add Vapor's `Content` conformance and the model-backed initialisers,
// which depend on Fluent and therefore can't live in the shared layer.

import Fluent
import Foundation
import StreetwCore
import Vapor

extension SizePayload: @retroactive Content {}
extension CreateWatch: @retroactive Content {}
extension WatchDTO: @retroactive Content {}
extension PopularBrand: @retroactive Content {}
extension RegisterDevice: @retroactive Content {}
extension UpdateDevice: @retroactive Content {}
extension DiscoverBrand: @retroactive Content {}
extension FollowBrand: @retroactive Content {}
extension UpdateFollow: @retroactive Content {}
extension DeviceResponse: @retroactive Content {}
extension BrandDTO: @retroactive Content {}
extension FeedItem: @retroactive Content {}
extension BrandProbe: @retroactive Content {}
extension StartBrandCheck: @retroactive Content {}
extension WatchBrandCheck: @retroactive Content {}
extension BrandCheck: @retroactive Content {}
extension FeedResponse: @retroactive Content {}
extension StatusResponse: @retroactive Content {}
extension DeliveryStatus: @retroactive Content {}
extension PollHint: @retroactive Content {}
extension PollHintSync: @retroactive Content {}
extension PollHintsResponse: @retroactive Content {}
extension DiscoverCard: @retroactive Content {}
extension DiscoverResponse: @retroactive Content {}
extension UsageReport: @retroactive Content {}
extension UsageReceipt: @retroactive Content {}
extension StorefrontDTO: @retroactive Content {}

extension BrandSourceDTO {
    init(_ source: SourceModel) {
        self.init(
            id: source.id ?? UUID(),
            kind: source.kind,
            url: source.url,
            enabled: source.enabled,
            lastCheckedAt: source.lastCheckedAt,
            lastError: source.lastError,
            failureCount: source.failureCount
        )
    }
}

extension BrandDTO {
    /// Sources are passed in rather than read off `brand.$sources`.
    ///
    /// Fluent's `@Children` accessor traps at runtime when the relation was not eager
    /// loaded, and the callers here are four routes with four different query shapes. An
    /// explicit parameter turns "somebody forgot a `.with`" from a crash on a production
    /// route into a compile error at the call site.
    /// - Parameter followMode: the caller's own follow, for the one route that is about
    ///   the caller's follows. Nil everywhere else, which the client reads as "not said".
    /// - Parameter storefront: the country shop serving the caller (`Storefronts.serving`), or
    ///   nil for the main shop. **The sources and the currency are that shop's**, and only that
    ///   shop's: a brand page lists how the shop it is showing is watched, and a main shop's
    ///   page that listed a British shop's sources beside its own — which is what `sources`
    ///   holds once one is attached — would be describing two shops as one.
    init(
        _ brand: BrandModel,
        sources: [SourceModel],
        followMode: FollowMode? = nil,
        storefront: StorefrontModel? = nil
    ) {
        let shop = storefront?.id
        self.init(
            id: brand.id,
            name: brand.name,
            slug: brand.slug,
            website: brand.website,
            instagramHandle: brand.instagramHandle,
            currency: storefront.map(\.currency) ?? brand.currency,
            lockedForDrop: brand.lockedForDrop,
            logoURL: brand.logoURL,
            sources: sources.filter { $0.$storefront.id == shop }.map(BrandSourceDTO.init),
            followMode: followMode,
            storefront: storefront?.asDTO
        )
    }
}

extension FeedItem {
    /// Builds a feed row from an event plus its hydrated product, narrowing sizes to the
    /// ones this user actually wears.
    init?(event: EventModel, profile: SizeProfile) {
        guard let eventID = event.id, let createdAt = event.createdAt else { return nil }

        let product = event.product
        let variants = (product?.variants ?? []).map(\.asVariantInfo)
        let context = product?.sizeContext(sizes: variants.map(\.displaySize) + event.sizes) ?? .unknown
        let mine = event.sizes.filter { profile.matches($0, in: context) }

        self.init(
            eventID: eventID,
            kind: event.kind,
            createdAt: createdAt,
            brandID: event.$brand.id,
            brandName: event.brand.name,
            // An event's own words first: a `.sale` has no product to be named after. Its
            // link is the shop, which is where a sale is.
            title: event.title ?? product?.title ?? event.brand.name,
            summary: event.summary ?? product?.summary,
            linkURL: product?.linkURL ?? (event.title == nil ? nil : event.brand.website),
            imageURLs: product?.imageURLs ?? [],
            priceText: product?.priceText,
            priceAmount: product?.priceAmount,
            // The shop's own, so the phone can write it the reader's way — and never a
            // different shop's: see `ProductModel.priceCurrency`.
            currency: product?.priceCurrency(main: event.brand.currency),
            previousPriceText: event.previousPriceText,
            previousPriceAmount: event.previousPriceAmount,
            // The product's own, beside its price — both what is true now.
            originalPriceText: product?.originalPriceText,
            originalPriceAmount: product?.originalPriceAmount,
            isAvailable: product?.isAvailable,
            // Fall back to every returned size when no profile is set, so the card can
            // still say "Back in M, L".
            restockedSizes: profile.isEmpty ? event.sizes : mine,
            availableInMySize: variants.isEmpty
                ? false
                : variants.contains { $0.available && profile.claims($0, in: context) },
            // Sent in full so the client's size run, colourway swatches and restock
            // watcher have something to work with. Withholding these is what made the
            // whole size feature inert in the app's default server-backed mode.
            variants: variants,
            gender: product?.gender.rawValue,
            // Shipped alongside the verdict rather than instead of it: the server decides
            // gender so both platforms agree, but the client re-derives whenever its own
            // classifier moves ahead of this deploy's, and it can only do that if it was
            // given the text the answer was read from.
            productType: product?.productType,
            tags: product?.tags,
            genderVersion: product == nil ? nil : GenderClassifier.version,
            // What the garment is, not what happened to it. A feed row is keyed by its
            // event, and one product produces several — so nothing downstream could tell
            // that a shared link and a feed card were the same thing.
            productExternalID: product?.externalID,
            // For a release, the garments the storefront listed in it. The phone cannot ask
            // — it never polls in server mode — and without this every collection page falls
            // back to matching a word from the title, which is what printed five board
            // shorts under ISLAND PUFF PRINT TRUCKER HAT.
            memberExternalIDs: product?.memberExternalIDs
        )
    }
}

extension DiscoverCard {
    /// A garment from a brand the caller does not follow.
    ///
    /// Takes no `SizeProfile`, unlike `FeedItem`. That is not an omission: the app's rule is
    /// that a size **reorders and never hides** — a sold-out size today is the restock the
    /// whole product exists to catch — so there is nothing here for a profile to narrow. The
    /// variants travel in full and the phone decides what to rule in vermilion.
    /// - Parameter variants: passed in rather than read off `product.$variants`, for exactly
    ///   the reason `BrandDTO` takes its sources that way. Fluent's `@Children` accessor
    ///   **traps at runtime** when the relation was not eager loaded, and this initialiser
    ///   now has callers with two different query shapes: the product query eager loads
    ///   variants, and the release query deliberately does not — a collection row has none,
    ///   and loading them would be a join for nothing. Reading the accessor took the whole
    ///   server down with `Children relation not eager loaded` the first time the second
    ///   caller existed. An explicit parameter turns that into a compile error at the call
    ///   site instead.
    /// - Parameter mainCurrency: the brand's own `currency` — the main shop's, which is what a
    ///   row from before currencies were stored is in. Passed rather than read off `brand`,
    ///   whose currency is the *serving* shop's.
    init(
        _ product: ProductModel,
        brand: BrandDTO,
        mainCurrency: String?,
        variants: [VariantModel],
        spread: [String],
        vector: BrandVector?,
        members: [String] = [],
        memberCount: Int = 0
    ) {
        self.init(
            productExternalID: product.externalID,
            brand: brand,
            title: product.title,
            summary: product.summary,
            kind: product.kind,
            members: members,
            memberCount: memberCount,
            imageURLs: product.imageURLs,
            linkURL: product.linkURL,
            priceText: product.priceText,
            priceAmount: product.priceAmount,
            currency: product.priceCurrency(main: mainCurrency),
            isAvailable: product.isAvailable,
            // The classifier's inputs travel with its verdict, for the same reason they do
            // on a feed row: `GarmentSlot`, `Gender` and every judgement `Pairing` makes are
            // read off these, and a card that arrives as a bare title can only answer
            // "unknown" — which on this screen means no pairing, no reason and no argument
            // for the brand at all.
            productType: product.productType,
            tags: product.tags,
            gender: product.gender.rawValue,
            genderVersion: GenderClassifier.version,
            variants: variants.map(\.asVariantInfo),
            publishedAt: product.publishedAt,
            spread: spread,
            vector: vector
        )
    }
}

extension WatchDTO {
    /// Takes the product rather than just its title: the client keys its local watches on
    /// `externalID`, so a response without one cannot be matched back to anything.
    init(_ watch: WatchModel, product: ProductModel) {
        self.init(
            id: watch.id ?? UUID(),
            brandID: watch.$brand.id,
            productExternalID: product.externalID,
            productTitle: product.title,
            size: watch.size,
            color: watch.color,
            createdAt: watch.createdAt ?? Date(),
            firedAt: watch.firedAt,
            firedSizes: watch.firedSizes
        )
    }
}

extension ProductModel {
    /// Who this is cut for, decided here rather than on the phone so every client agrees
    /// and the notifier can target on the same answer the feed shows.
    ///
    /// Computed rather than stored: it is pure text classification over columns the row
    /// already has, so a stored copy would need a migration *and* a backfill, and would
    /// then go stale the moment the classifier improves.
    var gender: Gender {
        GenderClassifier.classify(
            title: title,
            productType: productType,
            tags: tags,
            // Shopify links are `/products/<handle>`, and the handle often carries the
            // distinction when the visible title doesn't.
            handle: linkURL.flatMap { URL(string: $0)?.lastPathComponent }
        )
    }

    /// What this garment's sizes are printed on, so a "38" is read on the ladder the phone
    /// reads it on. See `SizeContext`.
    ///
    /// - Parameter sizes: the run to read. Passed in rather than read off `$variants`, for
    ///   the reason `DiscoverCard.init` takes its variants that way: the `@Children`
    ///   accessor traps when the relation was not eager loaded, and the notifier holds
    ///   events whose products were loaded without them.
    func sizeContext(sizes: [String]) -> SizeContext {
        guard SizeContext.matters(for: sizes) else { return .unknown }
        return SizeContext.of(gender: gender, title: title, productType: productType, tags: tags, sizes: sizes)
    }
}
