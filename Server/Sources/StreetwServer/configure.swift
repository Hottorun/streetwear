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

    app.migrations.add(CreateSchema())
    app.migrations.add(AddIndexes())
    app.migrations.add(FixPostgresArrayColumns())
    app.migrations.add(AddPushLedger())
    app.migrations.add(AddSourceBaseline())
    app.migrations.add(AddBrandLogo())
    app.migrations.add(AddProductPriceAmount())
    app.migrations.add(AddUserGender())
    app.migrations.add(CreateWatches())
    if Environment.get("AUTO_MIGRATE") != "false" {
        try await app.autoMigrate()
    }

    app.routes.defaultMaxBodySize = "1mb"

    // Pin date encoding on both sides. The feed's `since` cursor is a timestamp, so a
    // mismatch here wouldn't error — it would silently return the wrong window.
    ContentConfiguration.global.use(encoder: APICoding.encoder, for: .json)
    ContentConfiguration.global.use(decoder: APICoding.decoder, for: .json)

    // Every outbound request goes through the politeness budget: robots.txt obeyed,
    // and at most one request per host per interval no matter how many sources are due.
    let interval = Environment.get("POLITE_INTERVAL").flatMap(Double.init) ?? 2.0
    let poller = Poller(app: app, http: PoliteFetcher(minInterval: interval))
    app.storage[PollerKey.self] = poller

    // Push is optional: with no key the notifier still runs and still walks its ledger
    // forward, it just doesn't deliver. That keeps the "first deploy with credentials"
    // case from firing every event ever recorded.
    let sender = app.configureAPNS()
    app.storage[APNSConfiguredKey.self] = sender != nil
    let notifier = Notifier(app: app, sender: sender)
    app.storage[NotifierKey.self] = notifier

    let reaper = Reaper(app: app)
    app.storage[ReaperKey.self] = reaper

    // Built lazily on first use and cached — nothing here needs it at boot, and doing the
    // pass during startup would delay the health check for a value no request has asked
    // for yet.
    app.similarity = BrandSimilarity(app: app)

    if Environment.get("DISABLE_POLLER") != "true" {
        let loop = PollLoop(poller: poller, notifier: notifier, reaper: reaper)
        app.storage[PollLoopKey.self] = loop
        await loop.start(logger: app.logger)
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

struct PollLoopKey: StorageKey {
    typealias Value = PollLoop
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
    var notifier: Notifier? { storage[NotifierKey.self] }
    var reaper: Reaper? { storage[ReaperKey.self] }
}
