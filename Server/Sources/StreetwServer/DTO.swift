// DTO.swift
// The wire types themselves live in StreetwCore so the app and server cannot drift.
// Here we only add Vapor's `Content` conformance and the model-backed initialisers,
// which depend on Fluent and therefore can't live in the shared layer.

import Fluent
import Foundation
import StreetwCore
import Vapor

extension SizePayload: @retroactive Content {}
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
                : variants.contains { $0.available && profile.matches($0.asVariantInfo) }
        )
    }
}
