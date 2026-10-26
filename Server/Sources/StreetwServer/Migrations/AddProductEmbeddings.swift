// AddProductEmbeddings.swift
// pgvector and `product_embeddings`, where the database has pgvector — and nothing where not.
//
// `CREATE EXTENSION IF NOT EXISTS vector` runs **only when `pg_available_extensions` lists
// it**. Railway's default Postgres does not, so on production today this records itself as
// applied having done nothing, and the server boots exactly as before with semantic search
// reported unavailable. That is also why the same work runs again at every boot
// (`SemanticIndex.prepare`): the move to a pgvector Postgres is a dump and restore, and the
// restored `_fluent_migrations` says this already ran.

import Fluent
import SQLKit

struct AddProductEmbeddings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        _ = await SemanticIndex.prepare(on: database, logger: database.logger)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        // The extension is left installed: other databases on the server may use it, and
        // dropping it would take their columns with it.
        try await sql.raw("DROP TABLE IF EXISTS product_embeddings").run()
    }
}
