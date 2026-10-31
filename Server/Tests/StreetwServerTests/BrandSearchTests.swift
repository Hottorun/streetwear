import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

/// "stussy" did not find "Stüssy", so Add a brand said the shop was not in the catalogue and
/// offered to add it a second time. A name is matched accents and case aside, on a column the
/// server fills itself (`brands.search_name`), so it means the same on SQLite and Postgres.
@Suite("Brand search ignores accents and case")
struct BrandSearchTests {
    private func brand(_ db: any Database, name: String, slug: String) async throws -> BrandModel {
        let brand = BrandModel(
            name: name, slug: slug, website: "https://\(slug)",
            instagramHandle: nil, usesGeneratedName: false
        )
        try await brand.save(on: db)
        return brand
    }

    private func search(_ app: Application, _ query: String) async throws -> [String] {
        var names: [String] = []
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        try await app.testing().test(.GET, "v1/brands?q=\(q)", headers: try await deviceAuth(app)) { res async throws in
            #expect(res.status == .ok)
            names = try res.content.decode([BrandDTO].self).map(\.name)
        }
        return names
    }

    @Test("The key folds accents, case, letters of their own and spacing", arguments: [
        ("Stüssy", "stussy"), ("STÜSSY", "stussy"), ("Aimé Leon Dore", "aime leon dore"),
        ("Acne  Studios", "acne studios"), ("Wood Wood Ø", "wood wood o"), ("Straße", "strasse"),
        ("Kith", "kith")
    ])
    func key(name: String, expected: String) {
        #expect(BrandNaming.searchKey(name) == expected)
    }

    @Test("A name is found however its accents and case are typed", arguments: [
        "stussy", "STUSSY", "Stüssy", "stüssy", "tüss", "uss"
    ])
    func findsAcrossAccents(query: String) async throws {
        try await withServer { app in
            _ = try await brand(app.db, name: "Stüssy", slug: "stussy.com")
            _ = try await brand(app.db, name: "Kith", slug: "kith.com")
            #expect(try await search(app, query) == ["Stüssy"], "\(query) should find Stüssy and only Stüssy")
        }
    }

    @Test("An accent in the query finds a name stored without one")
    func accentInTheQuery() async throws {
        try await withServer { app in
            _ = try await brand(app.db, name: "Aime Leon Dore", slug: "aimeleondore.com")
            #expect(try await search(app, "aimé leon") == ["Aime Leon Dore"])
        }
    }

    /// The poller improves a generated name, and the admin route overrides one; either way
    /// the brand must answer to the name it has now, not the one it was created with.
    @Test("A renamed brand is found by its new name")
    func renamed() async throws {
        try await withServer { app in
            let row = try await brand(app.db, name: "Stussy", slug: "stussy.com")
            row.name = "Stüssy Chapter"
            try await row.save(on: app.db)
            let stored = try #require(try await BrandModel.find(row.requireID(), on: app.db))
            #expect(stored.searchName == "stussy chapter")
            #expect(try await search(app, "stussy chapter") == ["Stüssy Chapter"])
        }
    }

    /// Rows written before the column existed get their key from the migration.
    @Test("The migration fills the key in on rows that predate it")
    func backfill() async throws {
        try await withServer { app in
            let row = try await brand(app.db, name: "Stüssy", slug: "stussy.com")
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.update(BrandModel.schema).set("search_name", to: SQLLiteral.null).run()
            try await AddBrandSearchName.backfill(sql)
            let stored = try #require(try await BrandModel.find(row.requireID(), on: app.db))
            #expect(stored.searchName == "stussy")
        }
    }

    /// Postgres's `LIKE` is case-sensitive where SQLite's is not, which is the half of this
    /// that SQLite cannot show. Runs only when `STREETW_TEST_POSTGRES_URL` names a scratch
    /// database.
    @Test(
        "On Postgres too, an unaccented query finds an accented name",
        .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil)
    )
    func postgres() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"])
        let app = try await Application.make(.testing)
        var config = try SQLPostgresConfiguration(url: url)
        config.coreConfiguration.tls = .disable
        app.databases.use(.postgres(configuration: config), as: .psql)
        addMigrations(to: app)
        app.databases.middleware.use(BrandSearchName(), on: nil)
        do {
            try await app.autoMigrate()
            _ = try await brand(app.db, name: "Stüssy", slug: "stussy.com")
            _ = try await brand(app.db, name: "Kith", slug: "kith.com")
            for query in ["stussy", "STUSSY", "Stüssy"] {
                #expect(try await BrandSearch.find(query, on: app.db).map(\.name) == ["Stüssy"], "\(query)")
            }
            #expect(try await BrandSearch.find("https://www.kith.com/products/tee", on: app.db).map(\.name) == ["Kith"])
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
