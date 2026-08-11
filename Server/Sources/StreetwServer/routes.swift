// routes.swift
// Small and delta-shaped. See BACKEND.md for the API surface.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

func routes(_ app: Application) throws {
    // Kept as a bare 200 for the platform's health check — it must stay cheap and must
    // not fail the deploy just because the database is briefly unreachable.
    app.get("health") { _ async in "ok" }

    /// The one to look at by eye. Actually queries the database, so a 200 here means
    /// the connection and the migrated schema are both real.
    app.get("status") { req async -> StatusResponse in
        var status = StatusResponse(
            database: req.application.storage[DatabaseKindKey.self] ?? "unknown",
            environment: req.application.environment.name,
            pollerRunning: req.application.storage[PollLoopKey.self] != nil,
            apnsConfigured: req.application.storage[APNSConfiguredKey.self] ?? false
        )
        do {
            status.brands = try await BrandModel.query(on: req.db).count()
            status.sources = try await SourceModel.query(on: req.db).count()
            status.products = try await ProductModel.query(on: req.db).count()
            status.events = try await EventModel.query(on: req.db).count()
            status.devices = try await DeviceModel.query(on: req.db).count()
            status.devicesWithToken = try await DeviceModel.query(on: req.db)
                .filter(\.$apnsToken != nil)
                .count()
            status.users = try await UserModel.query(on: req.db).count()
            status.pendingPushes = try await EventModel.query(on: req.db)
                .filter(\.$notifiedAt == nil)
                .count()
            status.databaseConnected = true
            if let next = try await SourceModel.query(on: req.db)
                .sort(\.$nextCheckAt).first() {
                status.nextPollAt = next.nextCheckAt
            }
        } catch {
            // Reported rather than thrown: "what exactly is wrong" beats a 500.
            status.databaseConnected = false
            status.databaseError = String(describing: error)
        }
        return status
    }

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

    authed.patch("devices", "me") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        let body = try req.content.decode(UpdateDevice.self)

        if let token = body.apnsToken { device.apnsToken = token }
        if let environment = body.environment { device.environment = environment }
        try await device.save(on: req.db)

        if let sizes = body.sizes {
            let user = try await device.$user.get(on: req.db)
            user.sizeProfile = sizes.asProfile
            try await user.save(on: req.db)
        }
        return .noContent
    }

    // MARK: Brands

    /// Search the shared catalog by name *or* address.
    ///
    /// One field for both because a person adding a brand has one of two things in hand —
    /// its name, or a link they copied — and making them say which is a question with no
    /// interesting answer. A pasted URL is reduced to its host and matched against `slug`,
    /// which is exactly what discovery keys on, so "https://www.kith.com/products/foo"
    /// finds the Kith that is already here rather than proposing to create a second one.
    v1.get("brands") { req async throws -> [BrandDTO] in
        let raw = (try? req.query.get(String.self, at: "q"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var builder = BrandModel.query(on: req.db)
        if !raw.isEmpty {
            // `ILIKE` is Postgres-only; SQLite's LIKE is already case-insensitive for
            // ASCII, so the local test database needs the plain operator.
            let insensitive: DatabaseQuery.Filter.Method =
                (req.db as? any SQLDatabase)?.dialect.name == "postgresql"
                    ? .custom("ILIKE")
                    : .custom("LIKE")

            if let host = BrandDiscovery.normalizedURL(raw)?.host()?.replacingOccurrences(of: "www.", with: ""),
               raw.contains(".") {
                builder = builder.group(.or) { group in
                    group
                        .filter(\.$slug, insensitive, "%\(host)%")
                        .filter(\.$name, insensitive, "%\(raw)%")
                }
            } else {
                builder = builder.filter(\.$name, insensitive, "%\(raw)%")
            }
        }
        return try await builder.sort(\.$name).limit(25).all().map(BrandDTO.init)
    }

    /// What other people are watching, most-followed first.
    ///
    /// The only place the app reads across users, and it reads a count and nothing else —
    /// no identities, no per-person lists. It exists so the feed is never a dead end:
    /// somebody caught up on their own brands should be shown what else is worth watching
    /// rather than an empty page.
    authed.get("brands", "popular") { req async throws -> [PopularBrand] in
        let device = try await req.authenticatedDevice()
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 12, 40)

        let follows = try await FollowModel.query(on: req.db).all()
        var counts: [UUID: Int] = [:]
        for follow in follows { counts[follow.$brand.id, default: 0] += 1 }

        // Exclude what this user already has — recommending someone their own brands is
        // the one thing this list must never do.
        let mine = Set(
            follows.filter { $0.$user.id == device.$user.id }.map(\.$brand.id)
        )
        let ranked = counts
            .filter { !mine.contains($0.key) }
            .sorted { ($0.value, $1.key.uuidString) > ($1.value, $0.key.uuidString) }
            .prefix(limit)
        guard !ranked.isEmpty else { return [] }

        let brands = try await BrandModel.query(on: req.db)
            .filter(\.$id ~~ ranked.map(\.key))
            .all()
        let byID = Dictionary(brands.compactMap { b in b.id.map { ($0, b) } }, uniquingKeysWith: { a, _ in a })

        // A few recent images per brand, so a recommendation shows the clothes rather
        // than asking someone to take a wordmark on faith.
        let products = try await ProductModel.query(on: req.db)
            .filter(\.$brand.$id ~~ ranked.map(\.key))
            .sort(\.$publishedAt, .descending)
            .limit(ranked.count * 12)
            .all()

        var previews: [UUID: [String]] = [:]
        for product in products {
            let id = product.$brand.id
            guard previews[id, default: []].count < 3, let image = product.imageURLs.first else { continue }
            previews[id, default: []].append(image)
        }

        return ranked.compactMap { entry in
            guard let brand = byID[entry.key] else { return nil }
            return PopularBrand(
                brand: BrandDTO(brand),
                followers: entry.value,
                previewImageURLs: previews[entry.key] ?? []
            )
        }
    }

    /// Dry run: what would we watch here? Creates nothing. Exists so the client's
    /// "check site" preview doesn't have to fetch storefronts from the phone, which
    /// would sidestep the server's politeness budget entirely.
    v1.get("brands", "probe") { req async throws -> BrandProbe in
        guard let raw = try? req.query.get(String.self, at: "url"),
              BrandDiscovery.normalizedURL(raw) != nil else {
            throw Abort(.badRequest, reason: "Not a usable URL")
        }
        let found = await BrandDiscovery.discover(website: raw, instagramHandle: nil)
        return BrandProbe(
            suggestedName: found.suggestedName,
            sources: found.sources.map {
                BrandProbe.Source(
                    kind: $0.kind.rawValue,
                    url: $0.url.absoluteString,
                    isAutomatic: $0.kind.isAutomatic
                )
            }
        )
    }

    /// Probe a URL and, if it is watchable, create the shared brand. Runs outside the
    /// poll loop so a slow discovery can't stall routine checks.
    v1.post("brands", "discover") { req async throws -> BrandDTO in
        let body = try req.content.decode(DiscoverBrand.self)
        guard let base = BrandDiscovery.normalizedURL(body.url) else {
            throw Abort(.badRequest, reason: "Not a usable URL")
        }
        let slug = base.host() ?? body.url

        if let existing = try await BrandModel.query(on: req.db).filter(\.$slug == slug).first() {
            return BrandDTO(existing)
        }

        let found = await BrandDiscovery.discover(website: body.url, instagramHandle: body.instagram)
        let brand = BrandModel(
            name: body.name ?? found.suggestedName ?? slug,
            slug: slug,
            website: base.absoluteString,
            instagramHandle: BrandDiscovery.normalizedHandle(body.instagram),
            usesGeneratedName: body.name == nil
        )
        brand.logoURL = found.logoURL?.absoluteString
        try await brand.save(on: req.db)

        let brandID = try brand.requireID()
        for source in found.sources where source.kind.isAutomatic {
            try await SourceModel(brandID: brandID, kind: source.kind, url: source.url.absoluteString)
                .save(on: req.db)
        }
        return BrandDTO(brand)
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

    /// What this device follows. The client needs this to hydrate its local brand
    /// list; `/v1/brands` is a global search and would not tell it what's mine.
    authed.get("follows") { req async throws -> [BrandDTO] in
        let device = try await req.authenticatedDevice()
        let follows = try await FollowModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .with(\.$brand)
            .all()
        return follows.map { BrandDTO($0.brand) }
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

    // MARK: Watches

    /// Create a watch on a product, identified by the external id the client already
    /// holds — it is what dedupes the feed, so the client never needs a second identity
    /// for the same thing.
    authed.post("watches") { req async throws -> WatchDTO in
        let device = try await req.authenticatedDevice()
        let body = try req.content.decode(CreateWatch.self)

        guard let product = try await ProductModel.query(on: req.db)
            .filter(\.$brand.$id == body.brandID)
            .filter(\.$externalID == body.productExternalID)
            .first()
        else { throw Abort(.notFound, reason: "No such product") }

        let productID = try product.requireID()
        let userID = device.$user.id

        // Idempotent: tapping the button twice is a mis-tap, not a request for two
        // notifications. Returns the existing row rather than 409ing, because from the
        // client's side "I am watching this" is already true.
        if let existing = try await WatchModel.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$product.$id == productID)
            .group(.and, { group in
                group.filter(\.$size == body.size).filter(\.$color == body.color)
            })
            .first() {
            return WatchDTO(existing, product: product)
        }

        let watch = WatchModel(
            userID: userID,
            brandID: body.brandID,
            productID: productID,
            size: body.size,
            color: body.color
        )
        try await watch.save(on: req.db)

        // Watching something implies wanting the brand's signal too, and a watch that
        // outlives its follow would otherwise be a row nothing ever polls.
        let alreadyFollows = try await FollowModel.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$brand.$id == body.brandID)
            .first() != nil
        if !alreadyFollows {
            try await FollowModel(userID: userID, brandID: body.brandID).save(on: req.db)
        }

        return WatchDTO(watch, product: product)
    }

    authed.get("watches") { req async throws -> [WatchDTO] in
        let device = try await req.authenticatedDevice()
        let watches = try await WatchModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .sort(\.$createdAt, .descending)
            .with(\.$product)
            .all()
        return watches.map { WatchDTO($0, product: $0.product) }
    }

    authed.delete("watches", ":watchID") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        guard let watchID = req.parameters.get("watchID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        // Scoped to the caller's own rows: the id alone must not be enough to delete
        // somebody else's watch.
        try await WatchModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .filter(\.$id == watchID)
            .delete()
        return .noContent
    }

    // MARK: Ops

    /// Manual kick, for development and for verifying a new brand without waiting.
    app.post("admin", "poll") { req async throws -> String in
        guard let poller = req.application.poller else { throw Abort(.serviceUnavailable) }
        let count = await poller.tick()
        return "checked \(count)"
    }

    /// Fan out anything pending without waiting for the loop. Reports what it did, so
    /// "did my push actually go anywhere" has an answer that isn't a log grep.
    app.post("admin", "notify") { req async throws -> String in
        guard let notifier = req.application.notifier else { throw Abort(.serviceUnavailable) }
        let result = await notifier.dispatch()
        return "events \(result.events), sent \(result.sent), failed \(result.failed), pruned \(result.prunedTokens)"
    }

    /// Send a test push right now, to every registered device or to one named device.
    ///
    /// Answers "does APNs work" without waiting for a storefront to restock something.
    /// Writes nothing, so it can be run repeatedly and cannot swallow a real alert.
    app.post("admin", "push-test") { req async throws -> String in
        guard let notifier = req.application.notifier else { throw Abort(.serviceUnavailable) }
        let deviceID = try? req.query.get(UUID.self, at: "device")
        return await notifier.probe(deviceID: deviceID).summary
    }

    app.post("admin", "sweep") { req async throws -> String in
        guard let reaper = req.application.reaper else { throw Abort(.serviceUnavailable) }
        let result = await reaper.sweep()
        return "pruned \(result.events) events, \(result.products) products"
    }
}
