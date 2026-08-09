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
        // Managed Postgres terminates TLS at the proxy with its own certificate.
        config.coreConfiguration.tls = .prefer(try .init(configuration: .clientDefault))
        app.databases.use(.postgres(configuration: config), as: .psql)
        app.storage[DatabaseKindKey.self] = "postgres"
        app.logger.notice("database: postgres (DATABASE_URL)")
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

    if Environment.get("DISABLE_POLLER") != "true" {
        let loop = PollLoop(poller: poller)
        app.storage[PollLoopKey.self] = loop
        await loop.start(logger: app.logger)
    }

    try routes(app)
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

extension Application {
    var poller: Poller? { storage[PollerKey.self] }
}
