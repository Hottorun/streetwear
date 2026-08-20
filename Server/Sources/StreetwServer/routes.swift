// routes.swift
// Small and delta-shaped. See BACKEND.md for the API surface.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

/// How far back a brand's catch-up reaches when the caller names no window.
///
/// Thirty days, and the number is a judgement rather than a limit. What somebody wants on
/// following a label is *the current season* — the last drop, the collection that is out
/// now — not a year of archaeology through things that sold out long ago. A month covers a
/// weekly-drop brand's recent run and a seasonal brand's whole standing collection, and
/// where it does not, the poller fills the page in from the next drop onwards.
private let catchUpWindow: TimeInterval = 30 * 86_400

func routes(_ app: Application) throws {
    // Kept as a bare 200 for the platform's health check — it must stay cheap and must
    // not fail the deploy just because the database is briefly unreachable.
    app.get("health") { _ async in "ok" }

    /// **Who streetw is, to a storefront that asks.**
    ///
    /// This is not a route anybody using the app will ever hit. It exists because the
    /// Universal Commerce Protocol is a negotiation: before a business answers a catalogue
    /// query it fetches the *caller's* profile from the URI in the request and intersects
    /// its capabilities with its own. Without it, `UCPSource` gets
    /// `UCP discovery failed: missing ucp version` and nothing else — which is precisely
    /// what a first attempt against Supreme returns.
    ///
    /// So the poller cannot read a UCP catalogue unless this is publicly reachable, and it
    /// has to be reachable *from the merchant's network*, not from ours. If UCP sources
    /// start failing everywhere at once, this is the thing to curl first.
    ///
    /// Unauthenticated by necessity and harmless by construction: the document is a fixed
    /// statement about what this software can do, identical for every install, and names no
    /// device, user or brand. `UCPAgent` builds it, so the profile served here and the URI
    /// the adapter quotes can never disagree.
    app.get(".well-known", "ucp") { _ async throws -> Response in
        let response = Response(status: .ok, body: .init(data: try UCPAgent.profileJSON()))
        response.headers.contentType = .json
        // The spec asks for at least a minute. A business caches this between calls, and
        // without it every catalogue page we read costs the merchant a round trip back to
        // us — which is both rude and a way to make ourselves the slow part of their poll.
        response.headers.cacheControl = .init(isPublic: true, maxAge: 3600)
        return response
    }

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
        return try await builder
            .sort(\.$name)
            .limit(25)
            .with(\.$sources)
            .all()
            .map { BrandDTO($0, sources: $0.sources) }
    }

    /// What other people are watching, most-followed first.
    ///
    /// The only place the app reads across users, and it reads a count and nothing else —
    /// no identities, no per-person lists. It exists so the feed is never a dead end:
    /// somebody caught up on their own brands should be shown what else is worth watching
    /// rather than an empty page.
    /// How many photographs a recommendation carries, and how many candidate rows are
    /// examined per brand to find them. The second is larger because promotional rows —
    /// gift cards, size guides, delivery banners — are filtered out of it.
    let previewLimit = 12
    let previewFetchPerBrand = 30

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
        let candidates = counts.filter { !mine.contains($0.key) }
        guard !candidates.isEmpty else { return [] }

        // How close each candidate is to the centroid of what this user already follows.
        // Empty when they follow nothing yet, in which case the ranking below falls back
        // to pure popularity — which is the correct answer for someone with no taste on
        // record, not a degraded one.
        let affinities = await req.application.similarity?
            .affinities(for: Array(candidates.keys), followed: Array(mine)) ?? [:]

        // Popularity is normalised so the blend is between two 0…1 quantities rather than
        // between a similarity and a raw headcount, which would let one brand with forty
        // followers swamp the signal entirely.
        //
        // And it is *damped by how much headcount there is to normalise*. Dividing by the
        // maximum makes a number between 0 and 1 whatever the scale, which quietly turns a
        // two-person lead into a full unit of evidence — a bigger gap than the entire
        // spread of affinity across candidates, since every streetwear catalogue resembles
        // every other and similarities bunch. Early on, the list was therefore ordered by
        // whichever brand two people happened to follow, while looking like taste. See
        // `Popularity.confidence`.
        let mostFollowed = candidates.values.max() ?? 0
        let confidence = Popularity.confidence(mostFollowed: mostFollowed)

        func score(_ id: UUID, _ followers: Int) -> Double {
            let popularity = Popularity.normalised(followers: followers, mostFollowed: mostFollowed)
            // Taste leads, popularity floors it. Similarity here measures catalog
            // composition, which is a decent proxy for aesthetic and not the same thing —
            // so a brand nobody follows never outranks a well-liked one on vibes alone,
            // once "well-liked" means anything at all.
            return Recommender().score(
                candidate: nil,
                affinity: affinities[id],
                popularity: popularity,
                confidence: confidence
            )
        }

        let ranked = candidates
            .sorted { a, b in
                let sa = score(a.key, a.value), sb = score(b.key, b.value)
                // Tie-broken on the id so the list is stable between calls rather than
                // reshuffling on every refresh.
                return sa == sb ? a.key.uuidString > b.key.uuidString : sa > sb
            }
            .prefix(limit)

        let brands = try await BrandModel.query(on: req.db)
            .filter(\.$id ~~ ranked.map(\.key))
            .with(\.$sources)
            .all()
        let byID = Dictionary(brands.compactMap { b in b.id.map { ($0, b) } }, uniquingKeysWith: { a, _ in a })

        // Recent images per brand, so a recommendation shows the clothes rather than
        // asking someone to take a wordmark on faith.
        //
        // Twelve, not three. Three was enough for the card's single row and left the brand
        // preview — the screen whose entire job is *looking* at a brand before following
        // it — with a three-tile grid for every shop in the catalogue.
        //
        // **One query per brand, not one query with a cap applied afterwards.** This used
        // to be a single `~~` over every candidate, sorted by date and cut at
        // `ranked.count * previewFetchPerBrand`, with the per-brand budget enforced while
        // grouping the result. That is not a per-brand budget at all: the cut happens in
        // SQL, across all brands at once, so a storefront that publishes 250 items in one
        // sweep takes the whole window and the quieter brands under it are simply not in
        // the answer. Measured against production: at the limit the app actually asks for,
        // fourteen of thirty-five recommendations came back with **no photographs**, and
        // Represent came back with exactly one — a delivery graphic, because its garments
        // were all older than the global cut and the "everything here is promotional"
        // fallback then had nothing else to choose from. The tell was that a brand's
        // picture count changed when the *limit* changed, which a genuine per-brand budget
        // can never do.
        var previews: [UUID: [String]] = [:]
        for id in ranked.map(\.key) {
            let rows = try await ProductModel.query(on: req.db)
                .filter(\.$brand.$id == id)
                .sort(\.$publishedAt, .descending)
                .limit(previewFetchPerBrand)
                .all()
                .map { (title: $0.title, imageURL: $0.imageURLs.first) }
            previews[id] = PreviewImages.pick(from: rows, limit: previewLimit)
        }

        let vectors = await req.application.similarity?.all() ?? [:]

        return ranked.compactMap { entry in
            guard let brand = byID[entry.key] else { return nil }
            return PopularBrand(
                brand: BrandDTO(brand, sources: brand.sources),
                followers: entry.value,
                previewImageURLs: previews[entry.key] ?? [],
                // Sent so the client can re-rank against a taste profile built from its
                // own saves. Those never leave the phone — only the comparison crosses.
                vector: vectors[entry.key],
                affinity: affinities[entry.key]
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

        // **Matched on the registrable domain, not the exact host.**
        //
        // The slug is the hostname, and a brand is not one hostname — the rule the client
        // already learned when saves from `usa.palaceskateboards.com` were attributed to
        // nobody. Here the same fact makes *duplicate brands*: `stussy.com` and
        // `www.stussy.com` are two slugs, so the catalogue ended up holding Stüssy twice,
        // Palace twice (once as a sitemap and once as a Shopify catalog), Corteiz twice and
        // Supreme twice. Both rows poll, both fill with products, and the person adding one
        // has no way to tell which is the real one — they follow a brand and get half its
        // drops.
        //
        // The catalogue is global, so this is the one place that can prevent it. Checked
        // over loaded rows rather than in SQL because the comparison is
        // `BrandDiscovery.registrableDomain`, which is Swift and shared with the client so
        // the two cannot disagree about what counts as the same brand.
        let domain = BrandDiscovery.registrableDomain(of: base.host() ?? slug)
        let candidates = try await BrandModel.query(on: req.db).with(\.$sources).all()
        if let existing = candidates.first(where: { brand in
            guard let host = brand.website.flatMap({ URL(string: $0)?.host() }) ?? Optional(brand.slug)
            else { return false }
            return BrandDiscovery.registrableDomain(of: host) == domain
        }) {
            return BrandDTO(existing, sources: existing.sources)
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
        // Collected as they are written rather than re-queried: these are the rows this
        // request just created, and the response is about to name them.
        var created: [SourceModel] = []
        for source in found.sources where source.kind.isAutomatic {
            let model = SourceModel(brandID: brandID, kind: source.kind, url: source.url.absoluteString)
            try await model.save(on: req.db)
            created.append(model)
        }
        return BrandDTO(brand, sources: created)
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
            // Nested, because the brand's sources are what tell the phone how each brand
            // is being watched — the client cannot know that on its own in server mode,
            // since it does no polling and never discovered these itself.
            .with(\.$brand) { $0.with(\.$sources) }
            .all()
        return follows.map { BrandDTO($0.brand, sources: $0.brand.sources) }
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

    /// One brand's recent history, independent of the cursor.
    ///
    /// **What a newly followed brand is worth showing, and why `/v1/feed` cannot answer it.**
    /// That route is a *cursor* over everything a device follows: the client sends the
    /// timestamp of the last event it merged and gets what has happened since. Following a
    /// brand the poller has been watching for months therefore delivers nothing at all — the
    /// cursor is already past its whole history — so the brand's page sat empty, its counts
    /// read zero, and there was no sign anything was being watched until it next dropped,
    /// which for a two-collections-a-year label is months away.
    ///
    /// Widening the cursor instead would be wrong twice over: it would re-fetch every other
    /// followed brand's back catalogue at the same time, and everything it returned would
    /// arrive as unread — a feed full of drops that sold out in spring.
    ///
    /// So: one brand, a bounded window, and the client stores it pre-marked seen. It is a
    /// *baseline*, the same idea `sources.baselined_at` encodes for the poller and
    /// `Brand.lastSyncedAt == nil` encodes in the app — a brand's first sight of a catalogue
    /// is context, not news.
    ///
    /// Authenticated but deliberately not gated on following: the client calls this in the
    /// same breath as `POST /v1/follows` and the two are separate round trips, so requiring
    /// the follow to have landed first would make the order of two requests load-bearing.
    authed.get("brands", ":brandID", "feed") { req async throws -> FeedResponse in
        let device = try await req.authenticatedDevice()
        let user = try await device.$user.get(on: req.db)
        guard let brandID = req.parameters.get("brandID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 60, 200)
        let since = (try? req.query.get(Date.self, at: "since"))
            ?? Date().addingTimeInterval(-catchUpWindow)

        let events = try await EventModel.query(on: req.db)
            .filter(\.$brand.$id == brandID)
            .filter(\.$createdAt > since)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .with(\.$brand)
            .with(\.$product) { $0.with(\.$variants) }
            .all()

        let profile = user.sizeProfile
        let items = events.compactMap { FeedItem(event: $0, profile: profile) }
        // No cursor. This is a side query about one brand and must never be mistaken for
        // progress through the device's own feed — advancing the cursor from here would skip
        // every other brand's events in the same window.
        return FeedResponse(items: items, nextCursor: nil)
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

    /// Walk a UCP handshake against one storefront and say what happened at each step.
    ///
    /// The same argument as `push-test`, and for a pipeline that is even harder to see into.
    /// A UCP source has four ways to be silently useless — the storefront publishes no
    /// profile, the profile advertises no catalogue capability, the business cannot fetch
    /// *our* agent profile, or it can and refuses the version — and every one of them
    /// surfaces as the same thing on a brand page: a source that never produces a drop.
    /// Worse, three of the four are fixed on our side, and none of them can be reproduced
    /// locally: the merchant has to be able to reach `PUBLIC_BASE_URL` from its own network,
    /// which is exactly the condition a laptop cannot test.
    ///
    /// So this reports per stage rather than as a verdict. "0 products" is equally true when
    /// a store has no UCP, when our profile 404s, and when the season is simply over, and
    /// those have three different fixes.
    ///
    /// Reads only. It calls `search_catalog` and stores nothing.
    app.post("admin", "ucp-test") { req async throws -> String in
        guard let raw = try? req.query.get(String.self, at: "url"),
              let base = BrandDiscovery.normalizedURL(raw)
        else { throw Abort(.badRequest, reason: "pass ?url=") }

        var lines = ["agent profile: \(UCPAgent.profileURL.absoluteString)"]

        // Stage one: does the storefront advertise a machine interface at all?
        let http = req.application.fetcher
        guard let origin = await UCPSource.detect(at: base, http: http) else {
            lines.append("discovery: no usable profile at \(base.host() ?? raw)\(UCPSource.discoveryPath)")
            lines.append("  → this storefront is not watchable this way; nothing to fix here")
            return lines.joined(separator: "\n")
        }
        lines.append("discovery: ok")

        // Stage two: will the business talk to *us*? This is where a profile the merchant
        // cannot reach shows up, and it is the only stage whose fix is on our side.
        do {
            let result = try await UCPSource(http: http).fetch(BrandSource(kind: .ucp, url: origin), since: nil)
            lines.append("catalog: \(result.items.count) product(s)")
            for item in result.items.prefix(3) {
                let sizes = item.variants.compactMap(\.size).joined(separator: "/")
                lines.append("  \(item.title) — \(item.priceText ?? "no price") — \(sizes.isEmpty ? "no sizes" : sizes)")
            }
            if result.items.isEmpty {
                lines.append("  → answered, but empty. Between seasons, or the filter matched nothing.")
            }
        } catch let error as SourceError {
            lines.append("catalog: refused — \(error.errorDescription ?? "unknown")")
            if case .ucp = error {
                lines.append("  → the business could not use our agent profile. Check that")
                lines.append("    \(UCPAgent.profileURL.absoluteString) is reachable from the public internet.")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One line per brand: what it is watched with, how much it has, and what is failing.
    ///
    /// `/status` says the catalogue holds 22,000 products, which is true and answers nothing
    /// useful — a brand that discovered a source and stores nothing from it looks exactly
    /// like a brand that is working, and the totals hide it completely. That is the shape of
    /// failure this project keeps rediscovering: a page watch on a client-rendered
    /// storefront, a sitemap with no `lastmod`, a source erroring quietly behind a backoff.
    ///
    /// Sorted with the emptiest first, because the list is read to find what is broken.
    app.get("admin", "catalog") { req async throws -> String in
        let brands = try await BrandModel.query(on: req.db).with(\.$sources).sort(\.$name).all()

        // Counted in one grouped pass rather than a query per brand: this is 50+ brands and
        // growing, and a route that gets slower with the catalogue is a route nobody runs.
        struct Row: Decodable { var brand_id: UUID; var n: Int }
        func tally(_ table: String) async throws -> [UUID: Int] {
            guard let sql = req.db as? any SQLDatabase else { return [:] }
            let rows = try await sql.raw("SELECT brand_id, COUNT(*)::int AS n FROM \(unsafeRaw: table) GROUP BY brand_id")
                .all(decoding: Row.self)
            return Dictionary(rows.map { ($0.brand_id, $0.n) }, uniquingKeysWith: { a, _ in a })
        }
        let counts = try await tally("products")
        // Followers, because the other thing this list is read for is deciding which of two
        // rows for the same brand can be removed — and a row somebody follows cannot.
        let followers = try await tally("follows")

        // A brand is not one hostname, so two rows can be the same shop under different
        // hosts. Marked rather than merged: merging is destructive and this is a report.
        var byDomain: [String: Int] = [:]
        for brand in brands {
            let host = brand.website.flatMap { URL(string: $0)?.host() } ?? brand.slug
            byDomain[BrandDiscovery.registrableDomain(of: host), default: 0] += 1
        }

        let lines = brands.compactMap { brand -> (Int, String)? in
            guard let id = brand.id else { return nil }
            let products = counts[id] ?? 0
            let host = brand.website.flatMap { URL(string: $0)?.host() } ?? brand.slug
            let kinds = brand.sources.map(\.kind).joined(separator: "+")
            let failing = brand.sources.compactMap(\.lastError).first
            let note = failing.map { " ⚠ \($0.prefix(50))" } ?? ""
            let never = brand.sources.allSatisfy { $0.lastCheckedAt == nil } ? " (not checked yet)" : ""
            let dupe = (byDomain[BrandDiscovery.registrableDomain(of: host)] ?? 0) > 1 ? " ‼ DUPLICATE" : ""
            let cells = [
                String(products).padding(toLength: 7, withPad: " ", startingAt: 0),
                String(followers[id] ?? 0).padding(toLength: 5, withPad: " ", startingAt: 0),
                brand.name.padding(toLength: 26, withPad: " ", startingAt: 0),
                host.padding(toLength: 30, withPad: " ", startingAt: 0)
            ].joined()
            return (products, cells + kinds + never + dupe + note)
        }

        return (["products followers brand                 host                          sources"]
            + lines.sorted { $0.0 < $1.0 }.map(\.1)).joined(separator: "\n")
    }

    /// Remove a brand — **refusing by default if anybody follows it.**
    ///
    /// `follows.brand_id` is `ON DELETE CASCADE`, so deleting a brand does not fail when it
    /// has followers: it silently unfollows them, and they find out by noticing something
    /// missing. That is the whole reason this guard exists rather than a bare delete, and
    /// why the refusal names the count instead of just saying no.
    ///
    /// Exists because the catalogue is global and duplicates are therefore everybody's
    /// problem: two rows for one shop, both polling, and a follower getting half the drops.
    /// `admin/catalog` flags them; this is how the loser goes.
    app.post("admin", "brands", ":brandID", "delete") { req async throws -> String in
        guard let brandID = req.parameters.get("brandID", as: UUID.self),
              let brand = try await BrandModel.find(brandID, on: req.db)
        else { throw Abort(.notFound) }

        let followers = try await FollowModel.query(on: req.db).filter(\.$brand.$id == brandID).count()
        let force = (try? req.query.get(Bool.self, at: "force")) ?? false
        guard followers == 0 || force else {
            return "refused: \(brand.name) has \(followers) follower(s). "
                + "Deleting cascades their follows away. Re-run with &force=true if that is intended."
        }

        let products = try await ProductModel.query(on: req.db).filter(\.$brand.$id == brandID).count()
        try await brand.delete(on: req.db)
        return "deleted \(brand.name) (\(brand.slug)) — \(products) product(s), \(followers) follower(s)"
    }

    /// Point a brand at a different host and rebuild what watches it.
    ///
    /// **For the case a delete cannot fix: the followed row is on the wrong host.** Palace
    /// answers on the apex, `www.`, `usa.` and `eu.`, and only `www.` serves the Shopify
    /// catalogue — so the row two people were following sat on `usa.` with a sitemap, which
    /// carries a name and a date and no price, no sizes and no stock. Deleting it to keep
    /// the better duplicate would take those two follows with it; keeping it leaves them on
    /// the thin source. Neither is acceptable, so the row moves instead.
    ///
    /// The old products go with the old sources, deliberately. A sitemap product and a
    /// Shopify product for the same garment carry different external ids, so leaving them
    /// would put every item in that brand on screen twice — the duplicate problem again, one
    /// level down. Clearing them also leaves every new source un-baselined, so the first
    /// poll after this is context rather than a few hundred notifications.
    app.post("admin", "brands", ":brandID", "repoint") { req async throws -> String in
        guard let brandID = req.parameters.get("brandID", as: UUID.self),
              let brand = try await BrandModel.find(brandID, on: req.db),
              let raw = try? req.query.get(String.self, at: "url"),
              let base = BrandDiscovery.normalizedURL(raw)
        else { throw Abort(.badRequest, reason: "pass ?url=") }

        let found = await BrandDiscovery.discover(website: raw, instagramHandle: nil, http: req.application.fetcher)
        let usable = found.sources.filter { $0.kind.isAutomatic }
        guard !usable.isEmpty else { return "refused: nothing watchable at \(raw), leaving \(brand.name) as it was" }

        let before = try await ProductModel.query(on: req.db).filter(\.$brand.$id == brandID).count()
        try await ProductModel.query(on: req.db).filter(\.$brand.$id == brandID).delete()
        try await SourceModel.query(on: req.db).filter(\.$brand.$id == brandID).delete()

        brand.website = base.absoluteString
        brand.slug = base.host() ?? brand.slug
        if let logo = found.logoURL { brand.logoURL = logo.absoluteString }
        try await brand.save(on: req.db)

        for source in usable {
            try await SourceModel(brandID: brandID, kind: source.kind, url: source.url.absoluteString)
                .save(on: req.db)
        }
        return "repointed \(brand.name) to \(brand.slug) — cleared \(before) product(s), "
            + "now watched by \(usable.map(\.kind.rawValue).joined(separator: "+"))"
    }

    app.post("admin", "sweep") { req async throws -> String in
        guard let reaper = req.application.reaper else { throw Abort(.serviceUnavailable) }
        let result = await reaper.sweep()
        return "pruned \(result.events) events, \(result.products) products"
    }
}
