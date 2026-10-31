// BrandSearch.swift
// Finding a brand in the catalogue by what somebody typed: a name, or a link.
//
// **Accents and case do not count.** A name is matched on `brands.search_name`, the name
// folded by `BrandNaming.searchKey`, against the query folded the same way — so "stussy",
// "STUSSY" and "Stüssy" are one search. A plain `LIKE` over two lowercase strings, which needs
// no extension and no collation and so behaves the same on Postgres and SQLite.

import Fluent
import SQLKit
import StreetwCore

enum BrandSearch {
    static let limit = 25

    /// One field for both because a person adding a brand has one of two things in hand —
    /// its name, or a link they copied. A pasted URL is reduced to its host and matched
    /// against `slug`, which is exactly what discovery keys on, so
    /// "https://www.kith.com/products/foo" finds the Kith that is already here rather than
    /// proposing to create a second one.
    static func find(_ raw: String, on db: any Database) async throws -> [BrandModel] {
        var builder = BrandModel.query(on: db)
        if !raw.isEmpty {
            // `ILIKE` is Postgres-only; SQLite's LIKE is already case-insensitive for
            // ASCII, so the local test database needs the plain operator.
            let insensitive: DatabaseQuery.Filter.Method =
                (db as? any SQLDatabase)?.dialect.name == "postgresql"
                    ? .custom("ILIKE")
                    : .custom("LIKE")
            let key = BrandNaming.searchKey(raw)
            let host = raw.contains(".")
                ? BrandDiscovery.normalizedURL(raw)?.host()?.replacingOccurrences(of: "www.", with: "")
                : nil

            builder = builder.group(.or) { group in
                group.filter(\.$searchName, .custom("LIKE"), "%\(key)%")
                // A row the column has not reached yet still answers to its name as written.
                group.filter(\.$name, insensitive, "%\(raw)%")
                if let host { group.filter(\.$slug, insensitive, "%\(host)%") }
            }
        }
        return try await builder
            .sort(\.$name)
            .limit(limit)
            .with(\.$sources)
            .all()
    }
}

/// Keeps `brands.search_name` in step with `brands.name`, wherever the name was written —
/// discovery, a check, the poller's improved name, the admin override.
///
/// In the database's middleware rather than at each call site, because a fourth place that
/// names a brand would otherwise make that brand unsearchable by its new name with nothing
/// to say so. Written only when it would change, so an update that leaves the name alone
/// rewrites nothing it did not already (`docs/server.md`, *What fills the volume*).
struct BrandSearchName: AsyncModelMiddleware {
    func create(model: BrandModel, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        refresh(model)
        try await next.create(model, on: db)
    }

    func update(model: BrandModel, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        refresh(model)
        try await next.update(model, on: db)
    }

    /// Through the property wrappers' optional values: a model fetched with only some of its
    /// fields would trap on `model.name`.
    private func refresh(_ model: BrandModel) {
        guard let name = model.$name.value else { return }
        let key = BrandNaming.searchKey(name)
        if (model.$searchName.value ?? nil) != key { model.searchName = key }
    }
}
