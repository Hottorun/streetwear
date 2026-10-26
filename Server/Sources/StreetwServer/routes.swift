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

/// Makes this device the only holder of an APNs token.
///
/// **A token identifies a phone, and a phone must not appear twice.** `apns_token` carries
/// no uniqueness constraint, and nothing used to clear it from an older row — while the
/// client has a documented path that mints a *new* device for the same phone: a 401 on the
/// sizes push spends the credential and re-registers. The old row keeps its live token and
/// its own follows, so `Notifier` finds both and the same phone receives every alert twice,
/// for as long as both rows exist. Apple will not tell us: the token is valid on both.
///
/// So the newest registration takes the token and any older holder loses it. The old device
/// row is left in place rather than deleted — it may still be the row somebody's follows
/// hang off, and losing those is a worse failure than a stale row that can no longer be
/// pushed to.
private func claimAPNsToken(_ token: String, for deviceID: UUID, on db: any Database) async throws {
    try await DeviceModel.query(on: db)
        .filter(\.$apnsToken == token)
        .filter(\.$id != deviceID)
        .set(\.$apnsToken, to: nil)
        .update()
}

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

    /// Everything an operator can do, behind one key. See `AdminAuthenticator` — it refuses
    /// outright when `ADMIN_TOKEN` is unset, rather than falling open.
    ///
    /// `/status` lives here too. It is a diagnostic, not a health check: it counts users and
    /// devices, says whether push is configured, and reports the database error verbatim
    /// when something is wrong — which is a description of the deployment's internals handed
    /// to anybody who asks. `/health` stays public and is what an uptime monitor wants.
    let admin = app.grouped("admin").grouped(AdminAuthenticator())

    /// The one to look at by eye. Actually queries the database, so a 200 here means
    /// the connection and the migrated schema are both real.
    admin.get("status") { req async -> StatusResponse in
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
            status.accounts = try await AccountModel.query(on: req.db).count()
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
    ///
    /// **Rate limited per address, and it is the most important one.** This route has to be
    /// open — a phone cannot authenticate before it has registered — and it hands out a
    /// working credential, so without a limit here the device tier is decorative: anyone
    /// can mint as many identities as they like and spend every other budget in parallel.
    v1.grouped(RateLimit(store: app.rateLimits.registration, identity: .address, name: "register"))
        .post("devices") { req async throws -> DeviceResponse in
        let body = try req.content.decode(RegisterDevice.self)

        let user = UserModel()
        if let sizes = body.sizes { user.sizeProfile = sizes.asProfile }
        user.country = CountryCode.normalized(body.country)
        try await user.save(on: req.db)

        guard let userID = user.id else { throw Abort(.internalServerError) }
        let device = DeviceModel(
            userID: userID,
            apnsToken: body.apnsToken,
            environment: body.environment ?? "production",
            locale: body.locale
        )
        try await device.save(on: req.db)
        if let token = body.apnsToken {
            try await claimAPNsToken(token, for: try device.requireID(), on: req.db)
        }
        return DeviceResponse(deviceID: try device.requireID(), token: device.authToken)
    }

    // Both, and the order matters: find the device, then insist there was one. See
    // `RequireDevice` — the authenticator alone never refused anybody.
    //
    // The standard budget sits on the group rather than on each route, for the same reason
    // `RequireDevice` does: membership should be the guarantee, so a route added later
    // cannot be unlimited by having forgotten a line. It is set far above what the app does
    // — see `RateLimits` — so the only caller it can refuse is one that is not the app.
    let authed = v1
        .grouped(DeviceAuthenticator())
        .grouped(RequireDevice())
        .grouped(RateLimit(store: app.rateLimits.standard, identity: .device, name: "standard"))

    /// The two routes that spend *outbound* budget: they make this server fetch a storefront
    /// somebody named, and one of them writes a row the poller revisits every twenty minutes
    /// from then on. They also share the poller's `PoliteFetcher`, so hammering them delays
    /// real polling for the host in question — see `RateLimit.swift`.
    let outbound = authed
        .grouped(RateLimit(store: app.rateLimits.outbound, identity: .device, name: "outbound"))

    authed.patch("devices", "me") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        let body = try req.content.decode(UpdateDevice.self)

        if let token = body.apnsToken { device.apnsToken = token }
        if let environment = body.environment { device.environment = environment }
        try await device.save(on: req.db)
        // The commoner of the two paths: a phone that reinstalls registers afresh and then
        // hands over the same APNs token here.
        if let token = body.apnsToken {
            try await claimAPNsToken(token, for: try device.requireID(), on: req.db)
        }

        if body.sizes != nil || body.country != nil {
            let user = try await device.$user.get(on: req.db)
            var changed = false
            if let sizes = body.sizes {
                user.sizeProfile = sizes.asProfile
                changed = true
            }
            // Absent says nothing, empty clears, a code sets — and a code that is not one is
            // ignored rather than refused: this body is the first authenticated call of every
            // launch, and a 400 here would fail the whole sync over a setting. See
            // `UpdateDevice.country`.
            if let raw = body.country {
                let country = raw.isEmpty ? nil : CountryCode.normalized(raw)
                if raw.isEmpty || country != nil, user.country != country {
                    user.country = country
                    changed = true
                }
            }
            if changed { try await user.save(on: req.db) }
        }
        return .noContent
    }

    /// Whether a push could reach *this* device — the one question Settings asks.
    ///
    /// The app used to read `/status` for this, which answers about everybody and also
    /// reports the environment, the user count and the database error. Two booleans about
    /// the caller is the whole of what the screen needs.
    authed.get("devices", "me", "delivery") { req async throws -> DeliveryStatus in
        let device = try await req.authenticatedDevice()
        return DeliveryStatus(
            apnsConfigured: req.application.storage[APNSConfiguredKey.self] ?? false,
            hasToken: device.apnsToken?.isEmpty == false
        )
    }

    // MARK: Accounts

    accountRoutes(authed: authed, admin: admin)

    // MARK: Brands

    /// Search the shared catalog by name *or* address.
    ///
    /// One field for both because a person adding a brand has one of two things in hand —
    /// its name, or a link they copied — and making them say which is a question with no
    /// interesting answer. A pasted URL is reduced to its host and matched against `slug`,
    /// which is exactly what discovery keys on, so "https://www.kith.com/products/foo"
    /// finds the Kith that is already here rather than proposing to create a second one.
    authed.get("brands") { req async throws -> [BrandDTO] in
        let device = try await req.authenticatedDevice()
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
        let brands = try await builder
            .sort(\.$name)
            .limit(25)
            .with(\.$sources)
            .all()
        // The caller's shop for each, as on every route that hands over a brand: the phone
        // stores one row per brand whichever route it arrived on.
        let serving = try await Storefronts.serving(req, device: device, brandIDs: brands.compactMap(\.id))
        return brands.map { BrandDTO($0, sources: $0.sources, storefront: $0.id.flatMap { serving[$0] }) }
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
        let serving = try await Storefronts.serving(req, device: device, brandIDs: ranked.map(\.key))

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
                // The shop the caller would be following: its photographs, not another's.
                .filter(\.$storefrontID == serving[id]?.id)
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
                brand: BrandDTO(brand, sources: brand.sources, storefront: serving[entry.key]),
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
    ///
    /// Kept for 1.0, like `POST /v1/brands/discover` below; newer clients start a check.
    outbound.get("brands", "probe") { req async throws -> BrandProbe in
        guard let raw = try? req.query.get(String.self, at: "url"),
              BrandDiscovery.normalizedURL(raw) != nil else {
            throw Abort(.badRequest, reason: "Not a usable URL")
        }
        // Through the shared fetcher, so a dry run obeys robots.txt and queues behind the
        // poller like everything else. Discovery was reaching storefronts with `Net.live`,
        // which is the one thing BACKEND.md says outbound fetching must not do.
        let found = await BrandDiscovery.discover(
            website: raw, instagramHandle: nil, http: req.application.fetcher
        )
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
    ///
    /// **Kept for 1.0, which calls it and waits.** Newer clients start a check instead
    /// (`POST /v1/brands/checks`), because this says nothing until discovery has finished and
    /// a site that is not on Shopify can take longer than the app's thirty-second timeout.
    outbound.post("brands", "discover") { req async throws -> BrandDTO in
        let body = try req.content.decode(DiscoverBrand.self)
        guard let base = BrandDiscovery.normalizedURL(body.url) else {
            throw Abort(.badRequest, reason: "Not a usable URL")
        }
        let domain = BrandDiscovery.registrableDomain(of: base.host() ?? body.url)
        if let existing = try await BrandCatalog.existing(domain: domain, on: req.db) {
            let serving = try await Storefronts.serving(
                req, device: try await req.authenticatedDevice(), brandIDs: existing.id.map { [$0] } ?? []
            )
            return BrandDTO(existing, sources: existing.sources, storefront: existing.id.flatMap { serving[$0] })
        }

        let found = await BrandDiscovery.discover(
            website: body.url, instagramHandle: body.instagram, http: req.application.fetcher
        )

        // **A site nothing could read is not added.**
        //
        // Narrow on purpose. This briefly refused anything whose only source was a page
        // watch, on the theory that "something changed" is not worth having — and that was
        // wrong in the way that matters: a page watch on Supreme reached its follower before
        // the brand's own drop email. Being early is the product. It is also the only source
        // that detects a storefront locking down, which is the strongest signal here.
        //
        // What is refused is a site where *nothing answered at all* — no catalogue, no feed,
        // no sitemap, and not even a readable page. Adding one of those creates a brand row
        // that reports no error and delivers nothing forever, in a catalogue everybody
        // shares.
        guard found.canMonitor else {
            throw Abort(
                .unprocessableEntity,
                reason: "streetw couldn't read anything from \(base.host() ?? body.url) — "
                    + "no catalogue, feed, sitemap or readable page. It may be down or blocking us."
            )
        }

        // `body.name` is ignored — see `BrandCatalog.create`.
        let created = try await BrandCatalog.create(
            base: base,
            suggestedName: found.suggestedName,
            logoURL: found.logoURL?.absoluteString,
            instagram: body.instagram,
            sources: found.sources.map { ($0.kind, $0.url.absoluteString) },
            on: req.db
        )
        return BrandDTO(created.brand, sources: created.sources)
    }

    /// Starts looking at a site and answers at once — or joins the look somebody already
    /// started at the same shop. See `BrandChecks`.
    outbound.post("brands", "checks") { req async throws -> BrandCheck in
        let device = try await req.authenticatedDevice()
        let body = try req.content.decode(StartBrandCheck.self)
        guard let checks = req.application.brandChecks else { throw Abort(.serviceUnavailable) }
        let check = try await checks.start(url: body.url)
        return try await checks.response(for: check, userID: device.$user.id)
    }

    /// Asked every couple of seconds while a check runs, so it is on the standard budget
    /// rather than the outbound one: it fetches nothing.
    authed.get("brands", "checks", ":checkID") { req async throws -> BrandCheck in
        let device = try await req.authenticatedDevice()
        guard let id = req.parameters.get("checkID", as: UUID.self) else { throw Abort(.badRequest) }
        guard let checks = req.application.brandChecks else { throw Abort(.serviceUnavailable) }
        guard let check = try await BrandCheckModel.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "No check with that id.")
        }
        return try await checks.response(for: check, userID: device.$user.id)
    }

    /// Follow this shop now if the check found something to watch, or as soon as it does.
    /// Outbound, because it is the call that can create a brand the poller then visits
    /// every twenty minutes.
    outbound.post("brands", "checks", ":checkID", "watch") { req async throws -> BrandCheck in
        let device = try await req.authenticatedDevice()
        guard let id = req.parameters.get("checkID", as: UUID.self) else { throw Abort(.badRequest) }
        guard let checks = req.application.brandChecks else { throw Abort(.serviceUnavailable) }
        let body = try req.content.decode(WatchBrandCheck.self)
        let check = try await checks.watch(checkID: id, userID: device.$user.id, instagram: body.instagram)
        return try await checks.response(for: check, userID: device.$user.id)
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
            // **Checked rather than left to the foreign key.** `follows.brand_id` is a real
            // FK, so an id the catalogue no longer holds raised a constraint violation —
            // which is not an `AbortError` and surfaced as a generic 500 "Something went
            // wrong." A client holding a stale id could do nothing with that; a 404 it can
            // act on by searching again. `POST /v1/watches` already answers this way.
            guard try await BrandModel.find(body.brandID, on: req.db) != nil else {
                throw Abort(.notFound, reason: "No brand with that id.")
            }
            try await FollowModel(
                userID: device.$user.id,
                brandID: body.brandID,
                mode: body.mode ?? .everything
            ).save(on: req.db)
        } else if let existing, let mode = body.mode, existing.mode != mode {
            // Only when a mode was *sent*. Following a brand you already follow — from a
            // search result, a saved item, a recommendation — posts again with no mode, and
            // reading a missing one as `.everything` would undo a choice made on the brand's
            // page by tapping a button somewhere else.
            existing.mode = mode
            try await existing.save(on: req.db)
        }
        return .created
    }

    /// How much of a followed brand reaches the caller. See `FollowMode`.
    ///
    /// A route of its own rather than a field on `POST /v1/follows`, because changing how you
    /// hear from a brand is not following it again: this refuses a brand you do not follow
    /// rather than quietly starting to, which is the difference between a setting and a
    /// side effect.
    authed.patch("follows", ":brandID") { req async throws -> HTTPStatus in
        let device = try await req.authenticatedDevice()
        guard let brandID = req.parameters.get("brandID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let body = try req.content.decode(UpdateFollow.self)
        guard let follow = try await FollowModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .filter(\.$brand.$id == brandID)
            .first()
        else { throw Abort(.notFound, reason: "You don't follow that brand.") }

        // Guarded, like every write here that can change nothing.
        if follow.mode != body.mode {
            follow.mode = body.mode
            try await follow.save(on: req.db)
        }
        return .noContent
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
        // A poll hint requires a follow, so unfollowing must take it — enforced here rather
        // than trusted to the client, because "follow, hint, unfollow" is otherwise a way to
        // hold a window on a brand you have no relationship with, which is the exact thing
        // the check on `PUT /v1/poll-hints` exists to refuse. The app re-sends its whole set
        // on the next foreground anyway; this closes the gap in between and the case where
        // it never comes back.
        try await PollHintModel.query(on: req.db)
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
        let serving = try await Storefronts.serving(req, device: device, brandIDs: follows.map(\.$brand.id))
        // With the mode, because this is the only list that is about the caller's follows
        // and the phone decides the feed with it — see `FollowMode.admits`. And with the shop
        // serving the caller, whose sources and currency are the brand page's.
        return follows.map {
            BrandDTO(
                $0.brand,
                sources: $0.brand.sources,
                followMode: $0.mode,
                storefront: serving[$0.$brand.id]
            )
        }
    }

    // MARK: Discover

    /// How many brands one page samples, and how deep it reaches into each.
    ///
    /// `discoverPerBrand` is the number of *cards* a brand contributes per page;
    /// `discoverFetchPerBrand` is how many rows are read to find them, because the garment
    /// filter and the has-a-photograph rule both reject rows and a brand whose two newest
    /// products are a gift card and a size guide would otherwise contribute nothing.
    ///
    /// The fetch window is also where the spread comes from, which is why it is wider than
    /// the filtering alone needs. **It is still not what the offset advances by** — the cards
    /// are exactly the rows `[offset, offset + discoverPerBrand)`, and reading the window as
    /// the stride would silently skip most of every catalogue.
    let discoverPerBrand = 2
    let discoverFetchPerBrand = 24
    let discoverBrandsPerPage = 20
    /// How many of a brand's garments travel as the spread.
    ///
    /// **Eighteen, not eight, and the difference is what the card is able to claim.** A brand
    /// card is headlined with a wordmark and its whole job is *what does this label make* —
    /// and eight photographs, drawn as a grid insisting on whole rows of three, arrived on
    /// screen as six. Six garments is a shelf, not a catalogue, on a card standing in for a
    /// shop holding hundreds. It is the one number here where the payload buys something the
    /// reader can see: a second round trip per card is not available in a scrolling feed, so
    /// what the card can say is exactly what was sent with it.
    let discoverSpread = 18
    /// A backstop on how far a single request will walk looking for a non-empty page. Never
    /// the reason a page ends in practice — the barren-cycle test below is — but a loop that
    /// queries the database has to have a bound that does not depend on the data being sane.
    let discoverMaxWalk = 200

    /// How many of a brand's recent products are scanned to find a release's contents, and
    /// how many of their photographs a release card carries.
    ///
    /// Scanned in Swift rather than narrowed in SQL because the match is on the product's
    /// *tags* as well as its title, and a portable `LIKE` across an array column is not
    /// something Fluent expresses the same way on Postgres and SQLite — which is exactly the
    /// class of difference that passes locally and fails on the deployment. One bounded query
    /// per brand, only at depth zero.
    let releaseScan = 120
    let releaseMembers = 12

    /// The newest collection row for a brand that is actually a release.
    ///
    /// Recency is checked in the query and the judgement in Swift, because `Release.isRelease`
    /// is a vocabulary rather than anything SQL can express.
    @Sendable func newestRelease(_ brandID: UUID, storefrontID: UUID?, on db: any Database) async throws -> ProductModel? {
        let collections = try await ProductModel.query(on: db)
            .filter(\.$brand.$id == brandID)
            .filter(\.$storefrontID == storefrontID)
            .filter(\.$kind == UpdateKind.collection.rawValue)
            .sort(\.$publishedAt, .descending)
            .limit(40)
            .all()
        return collections.first { Release.isRelease(title: $0.title) }
    }

    /// The garments in a release, found by the distinctive words in its name.
    ///
    /// `/collections.json` announces a release and does not list it, so there is no link
    /// between the two rows — brands tag their seasons, and that tag is the only thread.
    /// Deliberately a heuristic, exactly as `Brand.members(of:)` is on the client: the
    /// alternative is a network call per card in a scrolling feed, and being wrong costs a
    /// card with a few extra garments on it rather than a missed drop.
    ///
    /// **Products only.** A release lands in the middle of ordinary trading, so admitting
    /// every kind would sweep up restocks of last season's stock and price drops off the sale
    /// rail and print them as the contents of something only just announced.
    @Sendable func members(
        of release: ProductModel,
        brandID: UUID,
        on db: any Database
    ) async throws -> (images: [String], count: Int) {
        let matched: [ProductModel]

        if !release.memberExternalIDs.isEmpty {
            // **What the storefront listed.** `CollectionsSource` reads
            // `/collections/<handle>/products.json` once, at the poll that first sees a
            // collection, so the membership is a stored fact rather than a guess for
            // anything polled since. Bounded by the id list, which is a release's worth.
            let wanted = release.memberExternalIDs
            matched = try await ProductModel.query(on: db)
                .filter(\.$brand.$id == brandID)
                .filter(\.$storefrontID == release.storefrontID)
                .filter(\.$externalID ~~ wanted)
                .sort(\.$publishedAt, .descending)
                .limit(releaseScan)
                .all()
                .filter { !$0.imageURLs.isEmpty }
        } else {
            // Collections stored before that shipped. The word match is what this route
            // always did, and it is wrong often enough that it is now the fallback rather
            // than the answer — see `Brand.members(of:)` for what it printed.
            let words = Release.distinctiveWords(in: release.title)
            guard !words.isEmpty else { return ([], 0) }

            let recent = try await ProductModel.query(on: db)
                .filter(\.$brand.$id == brandID)
                .filter(\.$storefrontID == release.storefrontID)
                .filter(\.$kind == UpdateKind.product.rawValue)
                .sort(\.$publishedAt, .descending)
                .limit(releaseScan)
                .all()

            matched = recent.filter { product in
                guard !product.imageURLs.isEmpty else { return false }
                let tokens = Set(
                    ([product.title, product.productType ?? ""] + product.tags)
                        .joined(separator: " ")
                        .lowercased()
                        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                        .map(String.init)
                )
                return words.contains { tokens.contains($0) }
            }
        }

        // **Spread across the body, not taken in catalogue order.**
        //
        // A mosaic is the only thing standing in for a whole collection, so it has to look
        // like one. Catalogue order does not: Icecream's Fall 2026 lists its socks together,
        // so the first nine matches were six pairs of socks, a banana pouch and a jacket —
        // a card whose job is "here is a season" showing an accessories drawer. The same
        // round-robin the route uses to stop one brand owning a page, keyed on the garment
        // slot instead of the brand.
        let spread = Discovery.interleave(matched) {
            GarmentClassifier.classify(
                title: $0.title,
                productType: $0.productType,
                tags: $0.tags
            )
        }
        let images = PreviewImages.pick(
            from: spread.map { (title: $0.title, imageURL: $0.imageURLs.first) },
            limit: releaseMembers
        )
        return (images, matched.count)
    }

    /// Garments from brands the caller does not follow — the discovery feed's supply.
    ///
    /// **The shape of the query is the diversity, and that is deliberate.** The obvious
    /// implementation is one date-sorted query over every unfollowed brand with a `LIMIT`,
    /// and it does not work: a storefront that publishes 250 products in one re-merchandising
    /// sweep owns the entire window, so the first several pages are one shop. That is not a
    /// hypothetical — it is the bug `/v1/brands/popular` shipped with, where a global cut
    /// dressed as a per-brand budget left fourteen of thirty-five recommendations with no
    /// photographs at all. A cut made in SQL across all brands at once can never be a
    /// per-brand budget.
    ///
    /// So the page is assembled the other way round: every eligible brand is asked for its
    /// own newest few, and the cursor walks *depth* rather than time. Page zero is each
    /// brand's two newest; page one is their next two. Diversity is then a property of the
    /// query rather than of a filter applied afterwards, and it cannot be lost by tuning.
    ///
    /// The client does the real ordering — it holds the taste profile, the wardrobe and the
    /// saturation history, none of which are or should be here. This only has to hand over a
    /// page that isn't one storefront.
    authed.get("discover") { req async throws -> DiscoverResponse in
        let device = try await req.authenticatedDevice()

        let mine = Set(
            try await FollowModel.query(on: req.db)
                .filter(\.$user.$id == device.$user.id)
                .all()
                .map(\.$brand.id)
        )

        // Sorted by id rather than by name or date: the enumeration a cursor walks has to be
        // stable between two requests, and a brand renaming itself must not shuffle the
        // pages under somebody mid-scroll.
        let allBrands: [BrandModel] = try await BrandModel.query(on: req.db)
            .with(\.$sources)
            .all()
        let unfollowed: [BrandModel] = allBrands.filter { brand in
            guard let id = brand.id else { return false }
            return !mine.contains(id)
        }
        let brands: [BrandModel] = unfollowed.sorted { first, second in
            (first.id?.uuidString ?? "") < (second.id?.uuidString ?? "")
        }
        guard !brands.isEmpty else { return DiscoverResponse(cards: [], nextCursor: nil) }

        // The cursor is a page index and nothing else. It is opaque on the wire so no client
        // is tempted to do arithmetic on it, but there is deliberately no timestamp in it:
        // this pages a *catalogue* by depth, not a timeline by date, and a date cursor over
        // ties — storefronts stamp a whole drop with one second — would either re-serve a
        // page or skip one.
        let page = max(0, (try? req.query.get(Int.self, at: "cursor")) ?? 0)

        // Brands are covered in groups when there are more of them than a page samples, so
        // every brand is reached rather than only the first twenty forever.
        let groups = max(1, (brands.count + discoverBrandsPerPage - 1) / discoverBrandsPerPage)
        let vectors = await req.application.similarity?.all() ?? [:]
        // The caller's country shop for each brand that has one being read, and the main shop
        // for the rest. Every brand rather than the page's slice: one query either way, and
        // none at all while no country is switched on.
        let serving = try await Storefronts.serving(req, device: device)

        /// One page's worth, or nil when this group is exhausted at this depth.
        func build(page: Int) async throws -> (cards: [DiscoverCard], sawRows: Bool) {
            let group = page % groups
            let depth = page / groups
            let slice = brands
                .dropFirst(group * discoverBrandsPerPage)
                .prefix(discoverBrandsPerPage)

            var cards: [DiscoverCard] = []
            /// Whether any brand had *rows* at this depth, regardless of whether any
            /// survived filtering. This is the exhaustion test, and it has to be this rather
            /// than "were there cards": a brand whose newest two products are a gift card and
            /// a size guide yields a page with nothing on it while its whole catalogue sits
            /// one depth further down, and reading that as "the catalogue is spent" ended the
            /// feed permanently at the first promotional window.
            var sawRows = false
            for brand in slice {
                guard let brandID = brand.id else { continue }
                // **The offset advances by `discoverPerBrand`, not by the size of the
                // window.** The window is wider only so the spread has something to draw
                // from; the *cards* come from exactly the rows `[offset, offset + perBrand)`,
                // because that is what makes the enumeration a partition. Written the other
                // way round — offset by the fetch size while consuming two — every page
                // silently skipped ten of each brand's products, and nothing anywhere would
                // ever have reported them missing.
                let offset = depth * discoverPerBrand
                let shop = serving[brandID]
                // **No `.with(\.$variants)` here, and that is most of the payload.** The
                // window is 24 rows wide only so the spread has photographs to draw from,
                // and a spread entry is a *URL* — but eager loading joined every variant of
                // all 24, at eight or so apiece, to send two cards' worth. Measured at
                // 133,937 bytes for one screenful. The two rows that actually become cards
                // ask for their variants below, in one query, once the filters have decided
                // which they are.
                let rows = try await ProductModel.query(on: req.db)
                    .filter(\.$brand.$id == brandID)
                    // One shop per brand: the caller's country's where it is served, the
                    // main shop otherwise — never both, or a jacket would be dealt twice in
                    // two currencies.
                    .filter(\.$storefrontID == shop?.id)
                    .sort(\.$publishedAt, .descending)
                    .offset(offset)
                    .limit(discoverFetchPerBrand)
                    .all()
                guard !rows.isEmpty else { continue }
                sawRows = true

                // Both filters matter and neither is optional. A photograph *is* the feature
                // on this screen — the same rule the fit tray and `FitSuggestions` apply —
                // and `PreviewImages` is the shared vocabulary that keeps a delivery banner
                // or a gift card from being somebody's first impression of a label. A brand
                // whose turn falls on two gift cards contributes nothing this page rather
                // than reaching forward for replacements, which would double-serve them at
                // the next depth.
                let garments = rows.prefix(discoverPerBrand).filter {
                    // **A collection is not a garment, and this is where one got in.**
                    // A release has its own path a few lines below, which loads its members
                    // and refuses to emit a card without them. Reaching the feed through
                    // *this* loop instead skipped all of that: `DiscoverCard`'s product
                    // initialiser takes no `members`, so the row arrived with an empty
                    // array — and the client draws a release as a mosaic of its members, so
                    // the card rendered as a blank page with a lone wordmark on it.
                    //
                    // Seen live on Cap City's "09.16 - Wednesdays Drop": one image, a title
                    // that reads like a product, `memberCount: 0`, and it was the first card
                    // on the Discover tab.
                    $0.kind != UpdateKind.collection.rawValue
                        && !$0.imageURLs.isEmpty
                        && PreviewImages.isGarment(title: $0.title, imageURL: $0.imageURLs.first)
                }
                guard !garments.isEmpty else { continue }

                // The size run, the colourways and the "in your size" rule are the whole
                // reason a card is worth tapping, so these do travel — for the cards, and
                // only for the cards. One query for both rather than one each: the loop is
                // already `discoverBrandsPerPage` round trips deep and this is the cheap
                // shape of the same information.
                let garmentIDs = garments.compactMap(\.id)
                let variantsByProduct = Dictionary(
                    grouping: try await VariantModel.query(on: req.db)
                        .filter(\.$product.$id ~~ garmentIDs)
                        .all(),
                    by: { $0.$product.id }
                )

                let dto = BrandDTO(brand, sources: brand.sources, storefront: shop)
                let spread = PreviewImages.pick(
                    from: rows.map { (title: $0.title, imageURL: $0.imageURLs.first) },
                    limit: discoverSpread
                )

                // **A release, once, the first time a brand comes round.**
                //
                // It is the strongest card the feed has — a named season is more interesting
                // than any single garment inside it — and also the rarest: of 759 collection
                // rows in a real six-brand poll, `Release.isRelease` admits 55, because
                // `/collections.json` is mostly shop furniture (shoe sizes, sale rails, the
                // designers a multi-brand shop stocks). So it gets its own path rather than
                // competing in the product enumeration, and only at depth zero: a brand has
                // one current season, not one per page.
                if depth == 0, let release = try await newestRelease(brandID, storefrontID: shop?.id, on: req.db) {
                    let contents = try await members(of: release, brandID: brandID, on: req.db)
                    // A release with nothing found in it is not shown. The card is drawn out
                    // of its members' photographs — the release row itself carries none — so
                    // without them there is literally nothing to put on screen.
                    if !contents.images.isEmpty {
                        cards.append(
                            DiscoverCard(
                                release,
                                brand: dto,
                                mainCurrency: brand.currency,
                                // A release has none, and the query deliberately does not
                                // load them.
                                variants: [],
                                spread: spread,
                                vector: vectors[brandID],
                                members: contents.images,
                                memberCount: contents.count
                            )
                        )
                    }
                }

                for product in garments {
                    cards.append(
                        DiscoverCard(
                            product,
                            brand: dto,
                            mainCurrency: brand.currency,
                            // Never `product.variants`: the query above deliberately does
                            // not eager load them, and Fluent's `@Children` accessor traps
                            // rather than returning empty when it was not asked to.
                            variants: product.id.flatMap { variantsByProduct[$0] } ?? [],
                            spread: spread,
                            vector: vectors[brandID]
                        )
                    )
                }
            }
            return (cards, sawRows)
        }

        // An empty page walks forward rather than ending the feed, because empty has two
        // very different causes. A group can be exhausted while another still has rows — a
        // brand with three products runs out at depth two while its neighbour has two
        // hundred and fifty — and a depth window can be entirely promotional. Neither means
        // the catalogue is spent, and treating them as if they did is how a feed ends at the
        // first gift card.
        //
        // The stopping condition is therefore a full cycle of groups in which **no brand had
        // a row at all**. `discoverMaxWalk` is a backstop and nothing more: it should never
        // be the thing that ends a page, and if it ever is, something above is wrong.
        var current = page
        var cards: [DiscoverCard] = []
        var barrenCycle = 0
        for _ in 0..<discoverMaxWalk {
            let (built, sawRows) = try await build(page: current)
            cards = built
            if !cards.isEmpty { break }
            barrenCycle = sawRows ? 0 : barrenCycle + 1
            if barrenCycle >= groups { break }
            current += 1
        }
        guard !cards.isEmpty else { return DiscoverResponse(cards: [], nextCursor: nil) }

        return DiscoverResponse(
            cards: Discovery.interleave(cards, by: { $0.brand.id ?? UUID() }),
            nextCursor: String(current + 1)
        )
    }

    // MARK: Feed

    /// Events since a cursor, hydrated with their product, a page at a time and fairly
    /// between brands — see `FeedPaging` for the order and why it is the one it is.
    ///
    /// `?since=` begins a read: the window is everything after the cursor up to the newest
    /// event visible now, which comes back as `nextCursor`. When the window does not fit in
    /// one page the response also carries a `continuation`, and `?continuation=` carries the
    /// read on from exactly there — same window, same order — until it comes back nil.
    ///
    /// The 1.0 app sends `since` and never `continuation`, and moves its cursor to
    /// `nextCursor` exactly as it always has; the only thing that changed for it is *which*
    /// 200 events the one page holds. See `FeedPaging`.
    ///
    /// `?kinds=` names the kinds the client can draw, and only those are in the window —
    /// 1.0 names none and gets the seven it shipped with (`FeedKinds`). A continued read
    /// keeps the kinds its first page was asked for, carried in the token, so a read is one
    /// window from its first page to its last even across an app update.
    authed.get("feed") { req async throws -> FeedResponse in
        let device = try await req.authenticatedDevice()
        let user = try await device.$user.get(on: req.db)
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 100, 200)

        var resumed: FeedContinuation?
        if let token = try? req.query.get(String.self, at: "continuation") {
            guard let decoded = FeedContinuation(token: token) else {
                throw Abort(.badRequest, reason: "Not a continuation this server wrote.")
            }
            resumed = decoded
        }
        let since = resumed?.since
            ?? (try? req.query.get(Date.self, at: "since"))
            ?? Date().addingTimeInterval(-7 * 86_400)
        let kinds = resumed.map { $0.kinds ?? FeedKinds.legacy.map(\.rawValue) }
            ?? FeedKinds.accepted(try? req.query.get(String.self, at: FeedKinds.parameter))

        let followed = try await FollowModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .all()
            .map(\.$brand.id)
        guard !followed.isEmpty else { return FeedResponse(items: [], nextCursor: nil) }
        // Which shop each brand's events come from for this caller. Applied to the window
        // itself, below, so the paging ranks only what this person can be sent.
        let serving = try await Storefronts.serving(
            country: user.country,
            enabled: req.application.storefrontCountries,
            brandIDs: followed,
            on: req.db
        )

        // The whole window, three columns a row, so the ranking can see every brand's share
        // of it; products and variants are loaded for the one page afterwards.
        //
        // **Bounded above in Swift, not in SQL.** The upper bound is a timestamp read back out
        // of this database on the first page, and binding it again is not guaranteed to keep
        // its last microsecond — so `<= until` could drop the newest event, which re-ranks its
        // whole brand by one and slides rows past the reader. Comparing the decoded values
        // with each other is exact, because every page decodes the same rows the same way.
        let window = try await EventModel.query(on: req.db)
            .filter(\.$brand.$id ~~ followed)
            .filter(\.$createdAt > since)
            .filter(\.$kind ~~ kinds)
            .field(\.$id)
            .field(\.$brand.$id)
            .field(\.$createdAt)
            .field(\.$storefrontID)
            .all()
            .compactMap { event -> FeedPaging.Row? in
                guard let id = event.id, let createdAt = event.createdAt else { return nil }
                if let until = resumed?.until, createdAt > until { return nil }
                // One shop per brand. In Swift, for the reason the bound is: the choice is a
                // different shop per brand, and the window is three columns a row.
                guard event.storefrontID == serving[event.$brand.id]?.id else { return nil }
                return FeedPaging.Row(id: id, brandID: event.$brand.id, createdAt: createdAt)
            }
        guard let until = resumed?.until ?? window.map(\.createdAt).max() else {
            return FeedResponse(items: [], nextCursor: nil)
        }

        let page = FeedPaging.page(window, after: resumed?.after, limit: limit)
        let hydrated = page.ids.isEmpty ? [] : try await EventModel.query(on: req.db)
            .filter(\.$id ~~ page.ids)
            .with(\.$brand)
            .with(\.$product) { $0.with(\.$variants) }
            .all()
        let byID = Dictionary(
            hydrated.compactMap { event in event.id.map { ($0, event) } },
            uniquingKeysWith: { first, _ in first }
        )

        let profile = user.sizeProfile
        let items = page.ids
            .compactMap { byID[$0] }
            .compactMap { FeedItem(event: $0, profile: profile) }
        return FeedResponse(
            items: items,
            // The head of the read only. A continued page is not progress through the
            // device's own feed — the client keeps the cursor the first page gave it, which
            // is exactly what `brands/:id/feed` says for the same reason.
            nextCursor: resumed == nil ? until : nil,
            continuation: page.next.map {
                FeedContinuation(since: since, until: until, after: $0, kinds: kinds).token
            }
        )
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
        // The same contract as `/v1/feed`: nothing the client did not name.
        let kinds = FeedKinds.accepted(try? req.query.get(String.self, at: FeedKinds.parameter))

        // The shop this caller is served, and only its history — the same choice the feed
        // makes, or following a brand would hand over the other shop's back catalogue.
        let serving = try await Storefronts.serving(
            country: user.country,
            enabled: req.application.storefrontCountries,
            brandIDs: [brandID],
            on: req.db
        )
        let events = try await EventModel.query(on: req.db)
            .filter(\.$brand.$id == brandID)
            .filter(\.$storefrontID == serving[brandID]?.id)
            .filter(\.$createdAt > since)
            .filter(\.$kind ~~ kinds)
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

    // MARK: Poll hints

    /// Replace the caller's whole set of "this brand drops at this moment" hints.
    ///
    /// The one route where a client asks the server to *spend* something — requests against
    /// a storefront — so it is the one route written from the refusals outwards. Five of
    /// them, and the fifth is the one that actually matters:
    ///
    /// 1. **Device required**, like everything else under `/v1`. `RequireDevice` is in the
    ///    group, so this cannot be public by forgetting a line here.
    /// 2. **You must follow the brand.** Asking the server to fetch a storefront harder is
    ///    a reasonable request about something you watch and a resource-exhaustion primitive
    ///    about something you don't. Refused per brand rather than rejecting the request, so
    ///    a stale row for a brand somebody unfollowed does not throw away the rest of their
    ///    calendar.
    /// 3. **`PollHintPolicy` bounds the date** — nothing already over, nothing past
    ///    `maxLeadTime` — and **the count**, at `maxPerUser`. A longer list is refused whole
    ///    rather than truncated: silently keeping the first twenty of somebody's thirty is
    ///    the kind of quiet wrong answer this project keeps a list of.
    /// 4. **The window is not on the wire.** The client sends an instant; how wide a window
    ///    that buys is `PollHintPolicy`'s and is echoed back rather than accepted.
    /// 5. **A hint buys attention, not requests.** `Poller` claims hinted sources against a
    ///    separate fixed budget, so the extra load is the same whether one person hints one
    ///    brand or a thousand people hint a thousand — they divide it. That is what makes
    ///    the rest of this a tidiness exercise rather than the only thing standing between
    ///    the queue and a stranger.
    ///
    /// Nothing here is readable by anybody else, and no hint produces an event, a product or
    /// a notification. The most a hinted brand can do is get looked at sooner.
    authed.put("poll-hints") { req async throws -> PollHintsResponse in
        let device = try await req.authenticatedDevice()
        let userID = device.$user.id
        let body = try req.content.decode(PollHintSync.self)
        let now = Date()

        var rejected: [PollHintsResponse.Rejected] = []

        // Refused whole. Note this is checked before anything is read from the database,
        // so an oversized list costs one decode rather than a query per entry.
        guard body.hints.count <= PollHintPolicy.maxPerUser else {
            let seen = Set(body.hints.map(\.brandID))
            return PollHintsResponse(
                accepted: [],
                rejected: seen.map { .init(brandID: $0, reason: .tooMany) }
            )
        }

        // One per brand. A client sending two for the same brand has not been told which
        // one wins, so neither is a safe pick and both are refused — the unique index would
        // otherwise decide it by insertion order.
        var counts: [UUID: Int] = [:]
        for hint in body.hints { counts[hint.brandID, default: 0] += 1 }

        var candidates: [PollHint] = []
        for hint in body.hints {
            if counts[hint.brandID, default: 0] > 1 {
                if !rejected.contains(where: { $0.brandID == hint.brandID }) {
                    rejected.append(.init(brandID: hint.brandID, reason: .tooMany))
                }
                continue
            }
            guard PollHintPolicy.isAcceptable(releaseAt: hint.releaseAt, now: now) else {
                rejected.append(.init(brandID: hint.brandID, reason: .outOfRange))
                continue
            }
            candidates.append(hint)
        }

        // The follow check, in one query rather than one per hint — this runs on every
        // foreground of every install that keeps a calendar.
        var followed: Set<UUID> = []
        if !candidates.isEmpty {
            followed = Set(
                try await FollowModel.query(on: req.db)
                    .filter(\.$user.$id == userID)
                    .filter(\.$brand.$id ~~ candidates.map(\.brandID))
                    .all()
                    .map { $0.$brand.id }
            )
        }

        var accepted: [PollHint] = []
        for hint in candidates {
            if followed.contains(hint.brandID) {
                accepted.append(hint)
            } else {
                // A brand that exists but is not followed, and a brand id that is not in
                // the catalogue at all, are told apart because the two have different fixes
                // — and because "no such brand" is what a client holding a stale id needs
                // to hear before it keeps sending it every foreground.
                let exists = try await BrandModel.find(hint.brandID, on: req.db) != nil
                rejected.append(.init(brandID: hint.brandID, reason: exists ? .notFollowing : .unknownBrand))
            }
        }

        // Replace, not merge. Deleting the caller's rows first means an empty body is the
        // honest way to withdraw everything — which is what the app sends when the last
        // planned drop is deleted.
        try await PollHintModel.query(on: req.db)
            .filter(\.$user.$id == userID)
            .delete()
        for hint in accepted {
            try await PollHintModel(
                userID: userID,
                brandID: hint.brandID,
                releaseAt: hint.releaseAt
            ).save(on: req.db)
        }

        return PollHintsResponse(accepted: accepted, rejected: rejected)
    }

    /// What this device currently has standing. Its own rows and no one else's — there is
    /// deliberately no route that reads across users here, unlike `/v1/brands/popular`.
    authed.get("poll-hints") { req async throws -> [PollHint] in
        let device = try await req.authenticatedDevice()
        return try await PollHintModel.query(on: req.db)
            .filter(\.$user.$id == device.$user.id)
            .sort(\.$releaseAt)
            .all()
            .map(\.asPollHint)
    }

    // MARK: Usage

    /// Add this device's tallies to everybody's totals.
    ///
    /// Written from the refusals outwards, like `PUT /v1/poll-hints`, because a route that
    /// writes on every call is a way to make the database work on a stranger's say-so:
    ///
    /// 1. **Device required**, and its own budget on top of the standard one — see
    ///    `RateLimits.usage`.
    /// 2. **A small body.** 32KB, against the server's 1MB default: a full week of every
    ///    event is about six. Refused at the door, before anything is decoded.
    /// 3. **`UsagePolicy` decides every row** — a whitelisted name, a day in the last week,
    ///    a count a person could reach, no row twice — and refuses a long report whole.
    /// 4. **Nothing written names the device.** The tallies go into shared totals; the
    ///    device row keeps one overwritten day, which is how weekly actives are counted.
    ///    See `UsageLedger`.
    ///
    /// One transaction, so a report is added whole or not at all — the phone keeps what it
    /// sent until a reply arrives, and half a report followed by a retry would count twice.
    let usageBodyLimit: ByteCount = "32kb"
    authed.grouped(RateLimit(store: app.rateLimits.usage, identity: .device, name: "usage"))
        .on(.POST, "usage", body: .collect(maxSize: usageBodyLimit)) { req async throws -> UsageReceipt in
        // Checked again here because Vapor applies a route's limit only to a body that
        // streams in: one that arrives in a single read — which is most bodies under a
        // socket buffer — is handed over whole and never measured against it.
        guard (req.body.data?.readableBytes ?? 0) <= usageBodyLimit.value else {
            throw Abort(.payloadTooLarge)
        }
        let device = try await req.authenticatedDevice()
        let report = try req.content.decode(UsageReport.self)
        let now = Date()

        let (accepted, refused) = UsagePolicy.accepted(report, now: now)
        guard !accepted.isEmpty else { return UsageReceipt(accepted: 0, refused: refused) }

        try await req.db.transaction { db in
            try await UsageLedger.add(accepted, on: db)
            // Only a report that counted something makes the device active. Nothing else
            // stamps it — not the feed, not the size push — because a background refresh
            // makes both, and a phone in a drawer is not somebody using the app.
            try await UsageLedger.markActive(device, now: now, on: db)
        }
        return UsageReceipt(accepted: accepted.count, refused: refused)
    }

    /// The totals, for the operator. `?days=` how far back, default four weeks.
    admin.get("usage") { req async throws -> UsageSummary in
        let days = min(max((try? req.query.get(Int.self, at: "days")) ?? 28, 1), 366)
        return try await UsageLedger.summary(days: days, now: Date(), on: req.db)
    }

    // MARK: Ops

    /// Manual kick, for development and for verifying a new brand without waiting.
    admin.post("poll") { req async throws -> String in
        guard let poller = req.application.poller else { throw Abort(.serviceUnavailable) }
        let count = await poller.tick()
        return "checked \(count)"
    }

    /// Fan out anything pending without waiting for the loop. Reports what it did, so
    /// "did my push actually go anywhere" has an answer that isn't a log grep.
    admin.post("notify") { req async throws -> String in
        guard let notifier = req.application.notifier else { throw Abort(.serviceUnavailable) }
        let result = await notifier.dispatch()
        return "events \(result.events), sent \(result.sent), failed \(result.failed), pruned \(result.prunedTokens)"
    }

    /// Send a test push right now, to every registered device or to one named device.
    ///
    /// Answers "does APNs work" without waiting for a storefront to restock something.
    /// Writes nothing, so it can be run repeatedly and cannot swallow a real alert.
    admin.post("push-test") { req async throws -> String in
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
    admin.post("ucp-test") { req async throws -> String in
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
    admin.get("catalog") { req async throws -> String in
        let brands = try await BrandModel.query(on: req.db)
            .with(\.$sources)
            .with(\.$storefronts)
            .sort(\.$name)
            .all()

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
            let kinds = brand.sources.filter { $0.$storefront.id == nil }.map(\.kind).joined(separator: "+")
            // A country's shop, where one is attached, after the main shop's sources — with
            // the kinds it is read by, so a storefront that found nothing shows as one.
            let shops: String = brand.storefronts.sorted { $0.country < $1.country }.map { shop -> String in
                let read = brand.sources.filter { $0.$storefront.id == shop.id }.map(\.kind)
                let host = URL(string: shop.url)?.host() ?? shop.url
                return " · \(shop.country) \(host) \(read.joined(separator: "+"))"
            }.joined()
            let failing = brand.sources.compactMap(\.lastError).first
            let note = failing.map { " ⚠ \($0.prefix(50))" } ?? ""
            let never = brand.sources.allSatisfy { $0.lastCheckedAt == nil } ? " (not checked yet)" : ""
            let dupe = (byDomain[BrandDiscovery.registrableDomain(of: host)] ?? 0) > 1 ? " ‼ DUPLICATE" : ""
            let cells = [
                // **The id, because every route that acts on a brand needs one and this is
                // the only listing there is.** `POST /admin/brands/:id/name`,
                // `…/repoint`, `…/source` and `…/delete` all take a `:brandID`, and an
                // operator reading this report had no way to get one — the report named the
                // brand it was telling them to fix and withheld the one field required to
                // fix it. First, so the line can be cut at a space.
                id.uuidString + "  ",
                String(products).padding(toLength: 7, withPad: " ", startingAt: 0),
                String(followers[id] ?? 0).padding(toLength: 5, withPad: " ", startingAt: 0),
                brand.name.padding(toLength: 26, withPad: " ", startingAt: 0),
                host.padding(toLength: 30, withPad: " ", startingAt: 0)
            ].joined()
            let line: String = [cells, kinds, shops, never, dupe, note].joined()
            return (products, line)
        }

        return ([
            "id                                    products followers brand                 host                          sources"
        ] + lines.sorted { $0.0 < $1.0 }.map(\.1)).joined(separator: "\n")
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
    admin.post("brands", ":brandID", "delete") { req async throws -> String in
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
    admin.post("brands", ":brandID", "repoint") { req async throws -> String in
        guard let brandID = req.parameters.get("brandID", as: UUID.self),
              let brand = try await BrandModel.find(brandID, on: req.db),
              let raw = try? req.query.get(String.self, at: "url"),
              let base = BrandDiscovery.normalizedURL(raw)
        else { throw Abort(.badRequest, reason: "pass ?url=") }

        let found = await BrandDiscovery.discover(website: raw, instagramHandle: nil, http: req.application.fetcher)
        let usable = found.sources.filter { $0.kind.isAutomatic }
        guard !usable.isEmpty else { return "refused: nothing watchable at \(raw), leaving \(brand.name) as it was" }

        // The main shop only. A country's storefront has a URL of its own and is rebuilt by
        // attaching it again; repointing the brand must not take it down with the main shop.
        let before = try await ProductModel.query(on: req.db)
            .filter(\.$brand.$id == brandID).filter(\.$storefrontID == nil).count()
        try await ProductModel.query(on: req.db)
            .filter(\.$brand.$id == brandID).filter(\.$storefrontID == nil).delete()
        try await SourceModel.query(on: req.db)
            .filter(\.$brand.$id == brandID).filter(\.$storefront.$id == nil).delete()

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

    /// Point one of a brand's sources at a URL discovery could not have guessed.
    ///
    /// **Because some catalogues are real and simply not findable.** Carhartt WIP publishes
    /// a sitemap index wrapped in a `<urlset>`, whose 38 entries are locale sitemaps, each
    /// of which lists three more — the products are three hops down at
    /// `/en-gb/product/sitemap.xml`, and there are 930 of them with `lastmod` and `/p/`
    /// paths the adapter already reads perfectly. Teaching `SitemapSource` to walk that tree
    /// generically would mean following 38 locales × 3 children on *every* poll of *every*
    /// sitemap brand, to serve one shop. Naming the leaf costs one line and no requests.
    ///
    /// **Restricted to the brand's own domain**, which is what makes an unauthenticated
    /// route that adds a *recurring* fetch safe: the poller can only ever be pointed at the
    /// storefront it is already polling. Without that this would be a standing request to
    /// fetch anything, every twenty minutes, on somebody else's say-so.
    admin.post("brands", ":brandID", "source") { req async throws -> String in
        guard let brandID = req.parameters.get("brandID", as: UUID.self),
              let brand = try await BrandModel.find(brandID, on: req.db),
              let raw = try? req.query.get(String.self, at: "url"),
              let url = URL(string: raw), url.scheme == "https",
              let kindName = try? req.query.get(String.self, at: "kind"),
              let kind = BrandSource.Kind(rawValue: kindName), kind.isAutomatic
        else { throw Abort(.badRequest, reason: "pass ?kind=<sitemap|feed|shopify|collections|ucp>&url=https://…") }

        let mine = BrandDiscovery.registrableDomain(of: brand.website.flatMap { URL(string: $0)?.host() } ?? brand.slug)
        guard let host = url.host(), BrandDiscovery.registrableDomain(of: host) == mine else {
            return "refused: \(url.host() ?? raw) is not \(brand.name)'s own domain (\(mine))"
        }

        // The replaced source's products go with it. They were keyed on the old source, so
        // leaving them would put the same garment on screen twice once the new one fills.
        // The main shop's — a country storefront's sources are its own business.
        let replaced = try await SourceModel.query(on: req.db)
            .filter(\.$brand.$id == brandID).filter(\.$storefront.$id == nil)
            .filter(\.$kind == kind.rawValue).all()
        for old in replaced {
            try await ProductModel.query(on: req.db).filter(\.$source.$id == old.id!).delete()
            try await old.delete(on: req.db)
        }
        try await SourceModel(brandID: brandID, kind: kind, url: url.absoluteString).save(on: req.db)

        return "\(brand.name): \(kind.rawValue) now \(url.absoluteString)"
            + (replaced.isEmpty ? "" : " (replaced \(replaced.count))")
    }

    /// Attach a brand's shop for one country, by URL — `?country=GB&url=https://…`.
    ///
    /// **By hand, because nothing finds these on its own.** A shop per country is the norm for
    /// big retailers and the exception for streetwear labels, and where one exists it is
    /// usually a different host (`eu.kith.com`), a different company, or both. Guessing at
    /// them would mean probing every brand's every plausible host for every country, which is
    /// a crawl, not a poll. So an operator names the shop, and this runs ordinary discovery on
    /// it — through the poller's fetcher, robots.txt and spacing included.
    ///
    /// Refuses three mistakes rather than storing them:
    ///
    /// - **Nothing watchable there.** The same bar as adding a brand.
    /// - **A catalogue the brand already reads.** A Shopify Markets subfolder (`/en-gb/`) is
    ///   read off the host, so it would be the main shop again under another name, polled
    ///   twice; and one country shop serving several countries (`eu.kith.com` ships to 48)
    ///   can be attached for one of them, not read twice for two.
    /// - **A shop that says it does not ship there**, from its own `/meta.json`, unless
    ///   `&force=true`. Palace's `www.` ships to five countries; serving it to somebody in
    ///   Germany would be serving a shop they cannot buy from.
    ///
    /// Attaching a country that already has a shop replaces it, history and all. The new
    /// sources start un-baselined, so their first read is context rather than news — and
    /// nothing is read at all until the country is switched on and somebody there follows
    /// the brand.
    admin.post("brands", ":brandID", "storefronts") { req async throws -> String in
        guard let brandID = req.parameters.get("brandID", as: UUID.self),
              let brand = try await BrandModel.query(on: req.db)
                  .filter(\.$id == brandID).with(\.$sources).first(),
              let country = CountryCode.normalized(try? req.query.get(String.self, at: "country")),
              let raw = try? req.query.get(String.self, at: "url"),
              let base = BrandDiscovery.normalizedURL(raw)
        else { throw Abort(.badRequest, reason: "pass ?country=<ISO code>&url=https://…") }
        let force = (try? req.query.get(Bool.self, at: "force")) ?? false

        let found = await BrandDiscovery.discover(website: raw, instagramHandle: nil, http: req.application.fetcher)
        let usable = found.sources.filter { $0.kind.isAutomatic }
        guard !usable.isEmpty else {
            return "refused: nothing watchable at \(base.host() ?? raw); \(brand.name) is unchanged"
        }

        let replaced = try await StorefrontModel.query(on: req.db)
            .filter(\.$brand.$id == brandID).filter(\.$country == country).first()
        // Every catalogue the brand reads, less the one being replaced.
        let read = Set(
            brand.sources
                .filter { replaced == nil || $0.$storefront.id != replaced?.id }
                .map(\.url)
        )
        if let same = usable.first(where: { read.contains($0.url.absoluteString) }) {
            return "refused: \(same.url.absoluteString) is a catalogue \(brand.name) already reads — "
                + "the main shop, or another country's. One shop is read once."
        }
        if !found.shipsTo.isEmpty, !found.shipsTo.contains(country), !force {
            return "refused: \(base.host() ?? raw) says it ships to \(found.shipsTo.count) "
                + "countr\(found.shipsTo.count == 1 ? "y" : "ies") and not \(country) "
                + "(\(found.shipsTo.prefix(8).joined(separator: ","))\(found.shipsTo.count > 8 ? ",…" : "")). "
                + "Re-run with &force=true if that is wrong."
        }

        let storefront = StorefrontModel(
            brandID: brandID,
            country: country,
            url: base.absoluteString,
            currency: found.currency
        )
        let cleared = try await req.db.transaction { db -> Int in
            var cleared = 0
            if let replaced, let id = replaced.id {
                cleared = try await Storefronts.remove(id, on: db)
            }
            try await storefront.save(on: db)
            let storefrontID = try storefront.requireID()
            for source in usable {
                try await SourceModel(
                    brandID: brandID,
                    kind: source.kind,
                    url: source.url.absoluteString,
                    storefrontID: storefrontID
                ).save(on: db)
            }
            return cleared
        }
        let switchedOn = req.application.storefrontCountries.contains(country)
        return "\(brand.name): \(country) shop is \(base.host() ?? raw)"
            + (found.currency.map { " in \($0)" } ?? "")
            + ", watched by \(usable.map(\.kind.rawValue).joined(separator: "+"))"
            + (replaced == nil ? "" : " (replaced the last one, \(cleared) product(s) cleared)")
            + (switchedOn ? "" : ". \(country) is not in STOREFRONT_COUNTRIES, so nothing is read yet")
    }

    /// Remove a brand's shop for one country, with everything read from it. Its followers
    /// there are served the main shop from the next request.
    admin.post("brands", ":brandID", "storefronts", ":country", "delete") { req async throws -> String in
        guard let brandID = req.parameters.get("brandID", as: UUID.self),
              let country = CountryCode.normalized(req.parameters.get("country")),
              let storefront = try await StorefrontModel.query(on: req.db)
                  .filter(\.$brand.$id == brandID).filter(\.$country == country).first(),
              let id = storefront.id
        else { throw Abort(.notFound) }
        let cleared = try await req.db.transaction { db in
            try await Storefronts.remove(id, on: db)
        }
        return "removed the \(country) shop (\(storefront.url)) — \(cleared) product(s)"
    }

    /// Correct a brand's name — the one trusted path, since the public one no longer exists.
    ///
    /// Discovery reads the name off the storefront and nobody else may set it, which is
    /// right for a global catalogue and leaves exactly one gap: a shop whose own metadata is
    /// wrong or absent. "Official Carhartt WIP Store UK" is the merchant's own `<title>` and
    /// is nobody's idea of a brand name. This closes that gap without reopening it to
    /// everybody.
    ///
    /// Clears `usesGeneratedName`, so the next poll does not put the storefront's version
    /// back over the correction.
    admin.post("brands", ":brandID", "name") { req async throws -> String in
        guard let brandID = req.parameters.get("brandID", as: UUID.self),
              let brand = try await BrandModel.find(brandID, on: req.db),
              let value = try? req.query.get(String.self, at: "value"),
              let name = BrandNaming.tidy(value)
        else { throw Abort(.badRequest, reason: "pass ?value=") }

        let was = brand.name
        brand.name = name
        brand.usesGeneratedName = false
        try await brand.save(on: req.db)
        return "renamed \(was) → \(name)"
    }

    admin.post("sweep") { req async throws -> String in
        guard let reaper = req.application.reaper else { throw Abort(.serviceUnavailable) }
        let result = await reaper.sweep()
        return "pruned \(result.events) events, \(result.products) products"
    }

    try creditRoutes(app, v1: v1, authed: authed, admin: admin)
}
