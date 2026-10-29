// configure.swift

import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import StreetwCore
import Vapor

func configure(_ app: Application) async throws {
    // Hosting platforms assign the port at runtime and expect the app to bind 0.0.0.0.
    // Without this the container listens on 8080/127.0.0.1 and the health check never
    // passes, which looks exactly like a crashed deploy.
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "0.0.0.0"
    if let port = Environment.get("PORT").flatMap(Int.init) {
        app.http.server.configuration.port = port
    }

    // Postgres in production (the host injects DATABASE_URL); SQLite locally so the
    // server runs without Docker. Every array column is `.json`, so both work.
    if let url = Environment.get("DATABASE_URL") {
        var config = try SQLPostgresConfiguration(url: url)
        let host = URLComponents(string: url)?.host ?? ""
        let mode = Application.tlsMode(host: host)

        // `.prefer` only falls back when the server *refuses* TLS. Managed Postgres
        // offers TLS with a certificate the system trust store can't verify (private
        // hostname, internal CA), so verification has to be addressed explicitly or the
        // handshake fails outright.
        switch mode {
        case .disable:
            config.coreConfiguration.tls = .disable
        case .verify:
            config.coreConfiguration.tls = .require(try .init(configuration: .clientDefault))
        case .noVerify:
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .none
            config.coreConfiguration.tls = .prefer(try .init(configuration: tls))
        }

        app.databases.use(.postgres(configuration: config), as: .psql)
        app.storage[DatabaseKindKey.self] = "postgres"
        app.logger.notice("database: postgres (DATABASE_URL), host=\(host), tls=\(mode.rawValue)")
    } else {
        // Refuse to start rather than quietly write to a disk that vanishes on the next
        // deploy. Silent ephemeral SQLite in production would look perfectly healthy
        // while losing every poll baseline — which then re-notifies the whole catalog.
        guard app.environment != .production || Environment.get("ALLOW_SQLITE") == "true" else {
            app.logger.critical("""
            DATABASE_URL is not set in a production environment. Refusing to start on \
            ephemeral SQLite. On Railway, add a Postgres service and reference it from \
            this service's variables as DATABASE_URL=${{Postgres.DATABASE_URL}}. \
            Set ALLOW_SQLITE=true only if you genuinely want throwaway storage.
            """)
            throw Abort(.internalServerError, reason: "DATABASE_URL missing in production")
        }
        let path = Environment.get("SQLITE_PATH") ?? "streetw.sqlite"
        app.databases.use(.sqlite(path == ":memory:" ? .memory : .file(path)), as: .sqlite)
        app.storage[DatabaseKindKey.self] = "sqlite"
        app.logger.notice("database: sqlite at \(path)")
    }

    addMigrations(to: app)
    if Environment.get("AUTO_MIGRATE") != "false" {
        try await app.autoMigrate()
    }

    app.routes.defaultMaxBodySize = "1mb"

    // Pin date encoding on both sides. The feed's `since` cursor is a timestamp, so a
    // mismatch here wouldn't error — it would silently return the wrong window.
    ContentConfiguration.global.use(encoder: APICoding.encoder, for: .json)
    ContentConfiguration.global.use(decoder: APICoding.decoder, for: .json)

    // **And the query string, which is where the cursor actually travels.**
    //
    // The two lines above pin the JSON *body* coder, and `since` is not in a body — it is
    // `?since=` on `GET /v1/feed`. Vapor decodes query values with a separate
    // `URLEncodedFormDecoder` whose default date strategy is `.secondsSince1970`, i.e. a
    // plain `Double(_:)` parse. The client sends ISO-8601 (`StreetwAPI.feed(_:)`), so
    // `Double("2026-09-16T22:00:00Z")` was nil, the decode threw, the `try?` at the call
    // site swallowed it, and **every request silently fell back to the seven-day default**.
    //
    // The comment above describes exactly this failure and was attached to the wrong coder.
    // What it cost: a device away for more than a week could never reach anything older
    // than seven days — retention holds thirty, and the query is `.descending.limit(200)`,
    // so the rows existed and were simply unreachable, and the client then advanced its
    // cursor past them. And in the ordinary case every foreground refresh re-pulled up to
    // 200 fully hydrated events with their whole variant arrays instead of a delta, at a
    // sixty-second throttle, which is the precise cost this server exists to avoid.
    //
    // The encoder is pinned too, so anything this service sends as a query round-trips.
    ContentConfiguration.global.use(
        urlDecoder: URLEncodedFormDecoder(configuration: .init(dateDecodingStrategy: .iso8601))
    )
    ContentConfiguration.global.use(
        urlEncoder: URLEncodedFormEncoder(configuration: .init(dateEncodingStrategy: .iso8601))
    )

    // Every outbound request goes through the politeness budget: robots.txt obeyed,
    // and at most one request per host per interval no matter how many sources are due.
    let interval = Environment.get("POLITE_INTERVAL").flatMap(Double.init) ?? 2.0
    // One fetcher, stored, so anything else reaching a storefront queues behind the poller
    // instead of alongside it. A second `PoliteFetcher` would keep a second per-host clock
    // and the budget would quietly be twice what it says it is.
    let fetcher = PoliteFetcher(minInterval: interval)
    app.storage[FetcherKey.self] = fetcher
    let poller = Poller(app: app, http: fetcher)
    app.storage[PollerKey.self] = poller

    // Push is optional: with no key the notifier still runs and still walks its ledger
    // forward, it just doesn't deliver. That keeps the "first deploy with credentials"
    // case from firing every event ever recorded.
    // Said at boot, the same way APNs says it, because the alternative is inferring it from
    // a 503 on a route you were trying to use for something else. A variable set on the
    // wrong service, or saved without a redeploy, looks identical from outside — this is the
    // line that tells the two apart.
    if Environment.get("ADMIN_TOKEN")?.isEmpty == false {
        app.logger.notice("admin: ADMIN_TOKEN configured")
    } else {
        app.logger.warning("admin: ADMIN_TOKEN not set — every /admin route will refuse")
    }

    app.appleSignIn = AppleSignInConfiguration.make(for: app)
    // Read once, here, like the admin key — a country multiplies the polling of every brand
    // followed there, so which ones are on is a deployment decision and the boot log says it.
    let countries = Storefronts.countries(from: Environment.get("STOREFRONT_COUNTRIES"))
    app.storage[StorefrontCountriesKey.self] = countries
    app.logger.notice("storefronts: \(countries.isEmpty ? "no countries switched on" : countries.sorted().joined(separator: ","))")

    let sender = app.configureAPNS()
    app.storage[APNSConfiguredKey.self] = sender != nil
    let notifier = Notifier(app: app, sender: sender)
    app.storage[NotifierKey.self] = notifier

    let reaper = Reaper(app: app)
    app.storage[ReaperKey.self] = reaper

    let checks = BrandChecks(app: app)
    app.storage[BrandChecksKey.self] = checks

    // Built lazily on first use and cached — nothing here needs it at boot, and doing the
    // pass during startup would delay the health check for a value no request has asked
    // for yet.
    app.similarity = BrandSimilarity(app: app)

    // Product search is full-text everywhere; semantic retrieval needs pgvector *and* a
    // provider, and both are said here, because the alternative is inferring it from results
    // that are merely less good. `prepare` runs at every boot, not only in its migration —
    // see `SemanticIndex.prepare` for the restore that needs it.
    app.semanticStatus = await SemanticIndex.prepare(on: app.db, logger: app.logger)
    app.embeddingProvider = SidecarEmbeddingProvider.make(for: app)
    switch app.semanticStatus {
    case .installed(let version):
        let state = app.embeddingProvider == nil ? "off until EMBEDDING_URL and EMBEDDING_TOKEN are set" : "on"
        app.logger.notice("search: full-text; pgvector \(version) installed — semantic search \(state)")
    case .unavailable(let why):
        app.logger.notice("search: full-text; semantic search unavailable (\(why))")
    }

    // On with a key or with the fake, off otherwise, and said here either way — the embedding
    // provider's rule. See `docs/ai.md`.
    app.ai = AIService.make(
        environment: ProcessInfo.processInfo.environment,
        isProduction: app.environment == .production,
        client: app.client,
        logger: app.logger
    )

    // Which reader turns a product's photographs into its product shot and style words: the
    // embeddings by default, the fast model only when the owner switches it on. Said here.
    let readingMethod = ProductReadingMethod.from(environment: ProcessInfo.processInfo.environment)
    app.productReadingMethod = readingMethod
    switch readingMethod {
    case .siglip:
        app.logger.notice("readings: FashionSigLIP zero-shot — \(app.semanticSearch == nil ? "idle until embeddings are on" : "on")")
    case .haiku:
        app.logger.notice("readings: PRODUCT_READING=haiku — the fast model, owner-paid under the daily cap — \(app.ai == nil ? "idle until AI is on" : "on")")
    }

    if Environment.get("DISABLE_POLLER") != "true" {
        let loop = PollLoop(poller: poller, notifier: notifier, reaper: reaper)
        app.storage[PollLoopKey.self] = loop
        await loop.start(logger: app.logger)
        // The daily full scan, on a loop of its own so it never holds up a poll. Its own
        // switch, because it is the one piece of background work whose cost is mostly
        // storage: on a volume near its cap it can be stopped without stopping the poll.
        if Environment.get("DISABLE_CATALOGUE_SCAN") != "true" {
            let scans = ScanLoop(poller: poller)
            app.storage[ScanLoopKey.self] = scans
            await scans.start()
        } else {
            app.logger.notice("scan: DISABLE_CATALOGUE_SCAN set — catalogues are not scanned")
        }
        // Background work, so it runs where the poller does — never in a test app.
        Task { await checks.resumeOrphans() }
        // Only where there is a provider and a pgvector to write to. `POST /admin/embed` runs
        // a batch by hand, which is how a server with the poller off embeds anything.
        if app.semanticSearch != nil {
            let backfill = EmbeddingBackfill(app: app)
            app.storage[EmbeddingBackfillKey.self] = backfill
            await backfill.start()
        }
        // Behind the embedding backfill, which it reads from; or, by the model, wherever AI is
        // on. `POST /admin/readings` runs a batch by hand.
        let canRead = readingMethod == .siglip ? app.semanticSearch != nil : app.ai != nil
        if canRead, (app.db as? any SQLDatabase)?.dialect.name == "postgresql" {
            let readings = ProductReadingBackfill(app: app, method: readingMethod)
            app.storage[ProductReadingBackfillKey.self] = readings
            await readings.start()
        }
    }

    try routes(app)
}

enum DatabaseTLSMode: String {
    /// Plaintext. Correct on a provider's private network, where traffic never leaves it.
    case disable
    /// Encrypted, certificate not checked. What managed Postgres normally needs: the
    /// certificate is issued by the provider's own CA for an internal hostname, so a
    /// public trust store can never validate it.
    case noVerify = "no-verify"
    /// Encrypted and verified. Use when connecting over the public internet.
    case verify
}

extension Application {
    /// Chosen automatically from the host, overridable with `DATABASE_TLS`.
    ///
    /// The override is a parameter rather than an environment read inside the function:
    /// env vars are process-global, and tests run in parallel, so reading it here made
    /// one test's `setenv` leak into another's expectations.
    static func tlsMode(
        host: String,
        override: String? = Environment.get("DATABASE_TLS")
    ) -> DatabaseTLSMode {
        if let override, let mode = DatabaseTLSMode(rawValue: override.lowercased()) {
            return mode
        }
        // Provider-internal hostnames aren't reachable from outside and aren't in any
        // public DNS, so plaintext there is a private-network hop, not the internet.
        if host.hasSuffix(".internal") || host == "localhost" || host == "127.0.0.1" {
            return .disable
        }
        return .noVerify
    }
}

struct DatabaseKindKey: StorageKey {
    typealias Value = String
}

struct PollerKey: StorageKey {
    typealias Value = Poller
}

struct FetcherKey: StorageKey {
    typealias Value = any HTTPFetching
}

struct PollLoopKey: StorageKey {
    typealias Value = PollLoop
}

struct ScanLoopKey: StorageKey {
    typealias Value = ScanLoop
}

struct NotifierKey: StorageKey {
    typealias Value = Notifier
}

struct ReaperKey: StorageKey {
    typealias Value = Reaper
}

struct APNSConfiguredKey: StorageKey {
    typealias Value = Bool
}

extension Application {
    var poller: Poller? { storage[PollerKey.self] }
    /// Falls back to the bare client so a test app that never called `configure` still
    /// works — the politeness budget is about production, and a stub never reaches a host.
    var fetcher: any HTTPFetching { storage[FetcherKey.self] ?? Net.live }
    var notifier: Notifier? { storage[NotifierKey.self] }
    var reaper: Reaper? { storage[ReaperKey.self] }
}

/// Every migration, in the order they were applied in production. One list, so a test that runs
/// against a real Postgres migrates exactly the schema the deployment has rather than a hand-picked
/// subset that drifts from it.
func addMigrations(to app: Application) {
    app.migrations.add(CreateSchema())
    app.migrations.add(AddIndexes())
    app.migrations.add(FixPostgresArrayColumns())
    app.migrations.add(AddPushLedger())
    app.migrations.add(AddSourceBaseline())
    app.migrations.add(AddBrandLogo())
    app.migrations.add(AddProductPriceAmount())
    app.migrations.add(AddUserGender())
    app.migrations.add(CreateWatches())
    app.migrations.add(AddSourceLock())
    app.migrations.add(AddVariantImageIndex())
    app.migrations.add(AddUserWaistSizes())
    app.migrations.add(AddEventPrice())
    app.migrations.add(AddProductBrandIndex())
    app.migrations.add(AddBrandNotifyLedger())
    app.migrations.add(CreatePollHints())
    app.migrations.add(AddProductMembers())
    app.migrations.add(CreateBrandChecks())
    app.migrations.add(CreateUsageCounts())
    app.migrations.add(AddDeviceActiveDay())
    app.migrations.add(AddUserDressAndSuitSizes())
    app.migrations.add(AddFollowMode())
    app.migrations.add(AddProductEnrichment())
    app.migrations.add(AddProductOriginalPrice())
    app.migrations.add(AddSaleLedgers())
    app.migrations.add(CreateAccounts())
    app.migrations.add(CreateCreditLedger())
    app.migrations.add(CreateCostRecords())
    app.migrations.add(CreateStorefronts())
    app.migrations.add(AddStorefrontColumns())
    app.migrations.add(AddUserProfiles())
    app.migrations.add(CreateStorefrontCountries())
    app.migrations.add(CreateCatalogueScans())
    app.migrations.add(AddProductSearch())
    app.migrations.add(AddProductEmbeddings())
    app.migrations.add(CreateAIPickReasons())
    app.migrations.add(AddSaleReading())
    app.migrations.add(AddProductReading())
}
