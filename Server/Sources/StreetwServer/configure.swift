// configure.swift

import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import StreetwCore
import Vapor

func configure(_ app: Application) async throws {
    // Postgres in production (Railway injects DATABASE_URL); SQLite locally so the
    // server runs without Docker. Every array column is `.json`, so both work.
    if let url = Environment.get("DATABASE_URL") {
        var config = try SQLPostgresConfiguration(url: url)
        // Managed Postgres terminates TLS at the proxy with its own certificate.
        config.coreConfiguration.tls = .prefer(try .init(configuration: .clientDefault))
        app.databases.use(.postgres(configuration: config), as: .psql)
    } else {
        let path = Environment.get("SQLITE_PATH") ?? "streetw.sqlite"
        app.databases.use(.sqlite(path == ":memory:" ? .memory : .file(path)), as: .sqlite)
        app.logger.notice("no DATABASE_URL — using SQLite at \(path)")
    }

    app.migrations.add(CreateSchema())
    app.migrations.add(AddIndexes())
    if Environment.get("AUTO_MIGRATE") != "false" {
        try await app.autoMigrate()
    }

    app.routes.defaultMaxBodySize = "1mb"

    let poller = Poller(app: app)
    app.storage[PollerKey.self] = poller

    if Environment.get("DISABLE_POLLER") != "true" {
        let loop = PollLoop(poller: poller)
        app.storage[PollLoopKey.self] = loop
        await loop.start(logger: app.logger)
    }

    try routes(app)
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
