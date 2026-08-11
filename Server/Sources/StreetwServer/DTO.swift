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
extension DeviceResponse: @retroactive Content {}
extension BrandDTO: @retroactive Content {}
extension FeedItem: @retroactive Content {}
extension BrandProbe: @retroactive Content {}
extension FeedResponse: @retroactive Content {}
extension StatusResponse: @retroactive Content {}

extension BrandDTO {
    init(_ brand: BrandModel) {
        self.init(
            id: brand.id,
            name: brand.name,
            slug: brand.slug,
            website: brand.website,
            instagramHandle: brand.instagramHandle,
            currency: brand.currency,
            lockedForDrop: brand.lockedForDrop,
            logoURL: brand.logoURL
        )
    }
}

extension FeedItem {
    /// Builds a feed row from an event plus its hydrated product, narrowing sizes to the
    /// ones this user actually wears.
    init?(event: EventModel, profile: SizeProfile) {
        guard let eventID = event.id, let createdAt = event.createdAt else { return nil }

        let product = event.product
        let variants = product?.variants ?? []
        let mine = event.sizes.filter { profile.matches($0) }

        self.init(
            eventID: eventID,
            kind: event.kind,
            createdAt: createdAt,
            brandID: event.$brand.id,
            brandName: event.brand.name,
            title: product?.title ?? event.brand.name,
            summary: product?.summary,
            linkURL: product?.linkURL,
            imageURLs: product?.imageURLs ?? [],
            priceText: product?.priceText,
            isAvailable: product?.isAvailable,
            // Fall back to every returned size when no profile is set, so the card can
            // still say "Back in M, L".
            restockedSizes: profile.isEmpty ? event.sizes : mine,
            availableInMySize: variants.isEmpty
                ? false
                : variants.contains { $0.available && profile.matches($0.asVariantInfo) },
            // Sent in full so the client's size run, colourway swatches and restock
            // watcher have something to work with. Withholding these is what made the
            // whole size feature inert in the app's default server-backed mode.
            variants: variants.map(\.asVariantInfo),
            gender: product?.gender.rawValue
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
}
