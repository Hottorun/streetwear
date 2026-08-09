// routes.swift
// Small and delta-shaped. See BACKEND.md for the API surface.

import Fluent
import Foundation
import StreetwCore
import Vapor

func routes(_ app: Application) throws {
    app.get("health") { _ async in "ok" }

    let v1 = app.grouped("v1")

    // MARK: Devices

    /// Anonymous registration: no login and no PII. Returns the bearer token every
    /// other route requires.
    v1.post("devices") { req async throws -> DeviceResponse in
        let body = try req.content.decode(RegisterDevice.self)

        let user = UserModel()
        if let sizes = body.sizes { user.sizeProfile = sizes.asProfile }
        try await user.save(on: req.db)

        guard let userID = user.id else { throw Abort(.internalServerError) }
        let device = DeviceModel(
            userID: userID,
            apnsToken: body.apnsToken,
            environment: body.environment ?? "production",
            locale: body.locale
        )
        try await device.save(on: req.db)
        return DeviceResponse(deviceID: try device.requireID(), token: device.authToken)
    }

    let authed = v1.grouped(DeviceAuthenticator())

    v1.patch("devices", "me") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        let body = try req.content.decode(UpdateDevice.self)

        if let token = body.apnsToken { device.apnsToken = token }
        try await device.save(on: req.db)

        if let sizes = body.sizes {
            let user = try await device.$user.get(on: req.db)
            user.sizeProfile = sizes.asProfile
            try await user.save(on: req.db)
        }
        return .noContent
    }

    // MARK: Brands

    v1.get("brands") { req async throws -> [BrandResponse] in
        let query = try? req.query.get(String.self, at: "q")
        var builder = BrandModel.query(on: req.db)
        if let query, !query.isEmpty {
            builder = builder.filter(\.$name, .custom("ILIKE"), "%\(query)%")
        }
        return try await builder.sort(\.$name).limit(50).all().map(BrandResponse.init)
    }

    /// Probe a URL and, if it is watchable, create the shared brand. Runs outside the
    /// poll loop so a slow discovery can't stall routine checks.
    v1.post("brands", "discover") { req async throws -> BrandResponse in
        let body = try req.content.decode(DiscoverBrand.self)
        guard let base = BrandDiscovery.normalizedURL(body.url) else {
            throw Abort(.badRequest, reason: "Not a usable URL")
        }
        let slug = base.host() ?? body.url

        if let existing = try await BrandModel.query(on: req.db).filter(\.$slug == slug).first() {
            return BrandResponse(existing)
        }

        let found = await BrandDiscovery.discover(website: body.url, instagramHandle: body.instagram)
        let brand = BrandModel(
            name: body.name ?? found.suggestedName ?? slug,
            slug: slug,
            website: base.absoluteString,
            instagramHandle: BrandDiscovery.normalizedHandle(body.instagram),
            usesGeneratedName: body.name == nil
        )
        try await brand.save(on: req.db)

        let brandID = try brand.requireID()
        for source in found.sources where source.kind.isAutomatic {
            try await SourceModel(brandID: brandID, kind: source.kind, url: source.url.absoluteString)
                .save(on: req.db)
        }
        return BrandResponse(brand)
    }

    // MARK: Follows

    authed.post("follows") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        let body = try req.content.decode(FollowBrand.self)

        let existing = try await FollowModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .filter(\.$brand.$id == body.brandID)
            .first()
        if existing == nil {
            try await FollowModel(userID: device.$user.id, brandID: body.brandID).save(on: req.db)
        }
        return .created
    }

    authed.delete("follows", ":brandID") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        guard let brandID = req.parameters.get("brandID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        try await FollowModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .filter(\.$brand.$id == brandID)
            .delete()
        return .noContent
    }

    // MARK: Feed

    /// Events since a cursor, hydrated with their product. Cursor is the timestamp of
    /// the last event the client saw, so paging is stable as new events arrive.
    authed.get("feed") { req async throws -> FeedResponse in
        let device = try await req.authenticatedDevice()
        let user = try await device.$user.get(on: req.db)
        let since = (try? req.query.get(Date.self, at: "since")) ?? Date().addingTimeInterval(-7 * 86_400)
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 100, 200)

        let followed = try await FollowModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .all()
            .map(\.$brand.id)
        guard !followed.isEmpty else { return FeedResponse(items: [], nextCursor: nil) }

        let events = try await EventModel.query(on: req.db)
            .filter(\.$brand.$id ~~ followed)
            .filter(\.$createdAt > since)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .with(\.$brand)
            .with(\.$product) { $0.with(\.$variants) }
            .all()

        let profile = user.sizeProfile
        let items = events.compactMap { event -> FeedItem? in
            FeedItem(event: event, profile: profile)
        }
        return FeedResponse(items: items, nextCursor: events.first?.createdAt)
    }

    // MARK: Ops

    /// Manual kick, for development and for verifying a new brand without waiting.
    app.post("admin", "poll") { req async throws -> String in
        guard let poller = req.application.poller else { throw Abort(.serviceUnavailable) }
        let count = await poller.tick()
        return "checked \(count)"
    }
}
