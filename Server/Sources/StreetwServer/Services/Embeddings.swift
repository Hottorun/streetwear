// Embeddings.swift
// Vectors of each product's text and photograph, in pgvector — designed, not yet switched on.
//
// Three things have to be true before a single vector exists, and today only the first is:
//
// 1. **A Postgres with pgvector.** Railway's default Postgres has none and will not get one;
//    the move is a dump and restore onto the pgvector template (`docs/pgvector-migration.md`).
//    Until then `SemanticIndex.status` is `.unavailable`, said once at boot, and everything
//    else — full-text search, "more like this" by text — works exactly as it would anyway.
// 2. **A provider** (`EmbeddingProvider`), named by `EMBEDDING_URL`. The owner chose Marqo
//    FashionSigLIP 2, self-hosted as a small service beside this one; the client for it is
//    built with that service, so `EmbeddingConfiguration` reads the variable and, until then,
//    says at boot that nothing answers it. Unset is off, which is today.
// 3. **The backfill** (`EmbeddingBackfill`), which embeds each product once per model. Idle
//    without both of the above.
//
// **The model id is stored beside every vector**, and that is the whole of the migration
// story: a new model is a new id, every product's row is stale against it, and the backfill
// re-embeds them in its own time. Vectors from two models are never compared — a nearest
// neighbour query names the model in its `WHERE` — so a half-finished re-embed answers from
// fewer products rather than from nonsense.
//
// **The dimension is the provider's, never this file's.** The column is a bare `vector`, which
// takes any length, and the approximate index is built per model, on `embedding::vector(n)`
// with `n` read from the provider (`SemanticIndex.ensureIndex`). A fixed `vector(768)` column
// would make choosing a different model a schema migration; this makes it a new index.
//
// **Separate table, not a column on `products`.** `products` is rewritten by the poller and
// the scan; a few kilobytes of floats per row would ride along on every one of those rewrites,
// which is the volume problem `docs/server.md` spends a page on. Written once per product per
// model here, and cascaded away with the product.

import Fluent
import Foundation
import SQLKit
import Vapor

/// Text and photographs in, one vector each out.
///
/// The server's only view of an embedding model. Nothing here knows what is behind it, so the
/// whole of search, the backfill and "more like this" are tested with a fake
/// (`FakeEmbeddingProvider` in the tests) and no network.
protocol EmbeddingProvider: Sendable {
    /// Stored beside every vector this produces. Two providers that would give different
    /// vectors for the same input must not share one.
    var model: String { get }
    /// The length of every vector, read once. Checked on every answer: a vector of another
    /// length is refused rather than stored, because the index is built for exactly this.
    var dimension: Int { get }
    /// Whether `embed(imageURLs:)` answers. A text-only model leaves the image column empty.
    var embedsImages: Bool { get }

    /// One vector per text, in order.
    func embed(texts: [String]) async throws -> [[Float]]
    /// One vector per photograph, in order — nil for one that could not be read, which is
    /// not a failure of the whole batch.
    func embed(imageURLs: [URL]) async throws -> [[Float]?]
}

enum EmbeddingError: Error, CustomStringConvertible {
    case wrongCount(expected: Int, got: Int)
    case wrongDimension(expected: Int, got: Int)
    case timedOut

    var description: String {
        switch self {
        case .wrongCount(let expected, let got): "provider answered \(got) vectors for \(expected) inputs"
        case .wrongDimension(let expected, let got): "provider answered a \(got)-long vector, not \(expected)"
        case .timedOut: "provider did not answer in time"
        }
    }
}

/// Reads which provider, if any, this deployment has.
enum EmbeddingConfiguration {
    /// The provider for `EMBEDDING_URL`, or nil.
    ///
    /// Nil today whatever the variable says: the client for the chosen service is built with
    /// the service. Set without one, it is logged rather than ignored, because a variable that
    /// silently does nothing is how push stayed off for months.
    static func make(for app: Application, environment: [String: String] = ProcessInfo.processInfo.environment) -> (any EmbeddingProvider)? {
        guard let raw = environment["EMBEDDING_URL"], !raw.isEmpty else {
            app.logger.notice("embeddings: EMBEDDING_URL not set — no provider, semantic search off")
            return nil
        }
        app.logger.warning("embeddings: EMBEDDING_URL is set but this build has no client for it — semantic search off")
        return nil
    }
}

struct EmbeddingProviderKey: StorageKey {
    typealias Value = any EmbeddingProvider
}

struct SemanticStatusKey: StorageKey {
    typealias Value = SemanticIndex.Status
}

extension Application {
    var embeddingProvider: (any EmbeddingProvider)? {
        get { storage[EmbeddingProviderKey.self] }
        set { storage[EmbeddingProviderKey.self] = newValue }
    }

    /// What `SemanticIndex.prepare` found at boot. `.unavailable` until it has run.
    var semanticStatus: SemanticIndex.Status {
        get { storage[SemanticStatusKey.self] ?? .unavailable("not checked") }
        set { storage[SemanticStatusKey.self] = newValue }
    }

    /// The provider, but only where its vectors have somewhere to go. Every semantic path asks
    /// this one question, so none of them can run half switched on.
    var semanticSearch: (any EmbeddingProvider)? {
        guard case .installed = semanticStatus else { return nil }
        return embeddingProvider
    }
}

enum SemanticIndex {
    enum Status: Sendable, Equatable {
        /// pgvector is installed and `product_embeddings` exists.
        case installed(version: String)
        /// No pgvector to be had — SQLite, or a Postgres without the extension — with why.
        case unavailable(String)
    }

    /// Installs pgvector and the vectors table where the database can have them, and says what
    /// it found. Idempotent, and run twice on purpose: by `AddProductEmbeddings` and again at
    /// every boot.
    ///
    /// **The second run is the one the migration needs.** The move to a pgvector Postgres is a
    /// dump and restore, and the dump carries `_fluent_migrations` with it — so on the new
    /// database the migration is already "done", having run on the old one where there was no
    /// extension to install. Without this, the restored database would never get its table.
    @discardableResult
    static func prepare(on database: any Database, logger: Logger) async -> Status {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return .unavailable("not Postgres")
        }
        do {
            let available = try await sql.raw("""
                SELECT default_version FROM pg_available_extensions WHERE name = 'vector'
                """).first()
            guard available != nil else {
                return .unavailable("this Postgres has no pgvector")
            }
            try await sql.raw("CREATE EXTENSION IF NOT EXISTS vector").run()
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS product_embeddings (
                  product_id UUID PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
                  model TEXT NOT NULL,
                  text_embedding vector NOT NULL,
                  image_embedding vector,
                  embedded_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """).run()
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS idx_product_embeddings_model ON product_embeddings (model)
                """).run()
            let version = try await sql.raw("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
                .first()?.decode(column: "extversion", as: String.self) ?? "?"
            return .installed(version: version)
        } catch {
            // A database user without the right to create an extension is the likely one. Said,
            // and the rest of the server carries on: nothing else depends on this.
            logger.error("embeddings: could not install pgvector: \(String(reflecting: error))")
            return .unavailable("pgvector could not be installed")
        }
    }

    /// The approximate nearest-neighbour index for one model, built the first time the model
    /// is used. Partial on the model and cast to its dimension, which is how a bare `vector`
    /// column can carry an index at all — and how two models' vectors stay apart.
    static func ensureIndex(for provider: any EmbeddingProvider, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS \(ident: indexName(for: provider)) ON product_embeddings \
            USING hnsw ((text_embedding::vector(\(literal: provider.dimension))) vector_cosine_ops) \
            WHERE model = \(literal: provider.model)
            """).run()
    }

    /// One name per model and dimension, stable across restarts: FNV-1a, since `Hasher` is
    /// seeded per process.
    static func indexName(for provider: any EmbeddingProvider) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(provider.model)#\(provider.dimension)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "idx_product_embeddings_" + String(hash, radix: 16)
    }

    /// pgvector's text form, `[0.1,0.2,…]` — bound as a string and cast in the query, which is
    /// the one encoding both the driver and the extension agree on without a custom type.
    static func literal(_ vector: [Float]) -> String {
        "[" + vector.map { String($0) }.joined(separator: ",") + "]"
    }

    /// The products nearest `vector` among those `allowed` says, closest first, with the
    /// cosine similarity — the model's vectors only.
    static func nearest(
        to vector: [Float],
        provider: any EmbeddingProvider,
        scope: SQLQueryString,
        excluding product: UUID? = nil,
        limit: Int,
        on sql: any SQLDatabase
    ) async throws -> [(id: UUID, similarity: Double)] {
        let cast = SQLQueryString("::vector(\(literal: provider.dimension))")
        let exclusion: SQLQueryString = product.map { "AND p.id <> \(bind: $0)" } ?? ""
        let rows = try await sql.raw("""
            SELECT p.id AS id, 1 - ((e.text_embedding\(cast)) <=> (\(bind: literal(vector))\(cast))) AS similarity
            FROM product_embeddings e JOIN products p ON p.id = e.product_id
            WHERE e.model = \(bind: provider.model) AND \(scope) \(exclusion)
            ORDER BY (e.text_embedding\(cast)) <=> (\(bind: literal(vector))\(cast))
            LIMIT \(literal: limit)
            """).all()
        return try rows.map { (try $0.decode(column: "id", as: UUID.self), try $0.decode(column: "similarity", as: Double.self)) }
    }

    /// A product's own text vector under this model, when it has one.
    static func vector(of product: UUID, provider: any EmbeddingProvider, on sql: any SQLDatabase) async throws -> [Float]? {
        guard let row = try await sql.raw("""
            SELECT text_embedding::text AS v FROM product_embeddings
            WHERE product_id = \(bind: product) AND model = \(bind: provider.model)
            """).first() else { return nil }
        return parse(try row.decode(column: "v", as: String.self))
    }

    static func parse(_ text: String) -> [Float]? {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !body.isEmpty else { return nil }
        let values = body.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        return values.isEmpty ? nil : values
    }

    /// The text a product is embedded from: what it is called, what it is filed as, how it is
    /// tagged, who makes it and what colours it comes in — the fields the grammar reads, so
    /// the two indexes describe the same thing.
    static func text(title: String, productType: String?, tags: [String], brand: String, colours: [String]) -> String {
        ([title, productType ?? "", brand] + colours + tags)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Runs `work`, or gives up after `seconds` — for the one embedding made while somebody waits.
///
/// A query is embedded per search, so semantic search needs the provider up at that moment.
/// When it is down or slow the answer is the full-text one, which is a complete answer on its
/// own, rather than a spinner: a search that waited thirty seconds for a provider to time out
/// is worse than one that never asked.
func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw EmbeddingError.timedOut
        }
        guard let first = try await group.next() else { throw EmbeddingError.timedOut }
        group.cancelAll()
        return first
    }
}

/// Embeds every product once per model, a batch at a time.
///
/// Keyed by model: a product is due when it has no row, or a row from another model — which
/// is how a model change re-embeds the catalogue without a migration. Products with no
/// photograph are embedded from their text alone. Runs only where `Application.semanticSearch`
/// says vectors have somewhere to go; with no provider configured, which is today, it is idle.
actor EmbeddingBackfill {
    private let app: Application
    private let batch: Int
    private var task: Task<Void, Never>?

    init(app: Application, batch: Int = 32) {
        self.app = app
        self.batch = batch
    }

    /// One batch. Returns how many products were embedded; zero means nothing is due, or there
    /// is nothing to embed with.
    @discardableResult
    func runOnce() async throws -> Int {
        guard let provider = app.semanticSearch, let sql = app.db as? any SQLDatabase else { return 0 }
        try await SemanticIndex.ensureIndex(for: provider, on: sql)

        let due = try await sql.raw("""
            SELECT p.id AS id, p.title AS title, p.product_type AS product_type, p.tags AS tags,
                   p.image_urls AS image_urls, b.name AS brand
            FROM products p
            JOIN brands b ON b.id = p.brand_id
            LEFT JOIN product_embeddings e ON e.product_id = p.id
            WHERE p.kind = 'product' AND (e.product_id IS NULL OR e.model <> \(bind: provider.model))
            ORDER BY p.published_at DESC, p.id
            LIMIT \(literal: batch)
            """).all()
        guard !due.isEmpty else { return 0 }

        struct Due {
            var id: UUID
            var text: String
            var image: URL?
        }
        let ids = try due.map { try $0.decode(column: "id", as: UUID.self) }
        let colours = try await Self.colours(of: ids, on: sql)
        let items: [Due] = try due.map { row in
            let id = try row.decode(column: "id", as: UUID.self)
            let images = try row.decode(column: "image_urls", as: [String].self)
            return Due(
                id: id,
                text: SemanticIndex.text(
                    title: try row.decode(column: "title", as: String.self),
                    productType: try row.decode(column: "product_type", as: String?.self),
                    tags: try row.decode(column: "tags", as: [String].self),
                    brand: try row.decode(column: "brand", as: String.self),
                    colours: colours[id] ?? []
                ),
                image: images.first.flatMap(URL.init(string:))
            )
        }

        let texts = try await provider.embed(texts: items.map(\.text))
        guard texts.count == items.count else { throw EmbeddingError.wrongCount(expected: items.count, got: texts.count) }
        var images: [[Float]?] = Array(repeating: nil, count: items.count)
        if provider.embedsImages {
            let withImage = items.indices.filter { items[$0].image != nil }
            let answered = try await provider.embed(imageURLs: withImage.compactMap { items[$0].image })
            guard answered.count == withImage.count else {
                throw EmbeddingError.wrongCount(expected: withImage.count, got: answered.count)
            }
            for (position, index) in withImage.enumerated() { images[index] = answered[position] }
        }

        for (index, item) in items.enumerated() {
            let text = texts[index]
            guard text.count == provider.dimension else {
                throw EmbeddingError.wrongDimension(expected: provider.dimension, got: text.count)
            }
            // A photograph of the wrong length is dropped rather than failing the product:
            // the text vector is the one every query reads.
            let image = images[index].flatMap { $0.count == provider.dimension ? SemanticIndex.literal($0) : nil }
            try await sql.raw("""
                INSERT INTO product_embeddings (product_id, model, text_embedding, image_embedding, embedded_at)
                VALUES (\(bind: item.id), \(bind: provider.model), \(bind: SemanticIndex.literal(text))::vector,
                        \(bind: image)::vector, now())
                ON CONFLICT (product_id) DO UPDATE SET
                  model = EXCLUDED.model, text_embedding = EXCLUDED.text_embedding,
                  image_embedding = EXCLUDED.image_embedding, embedded_at = EXCLUDED.embedded_at
                """).run()
        }
        return items.count
    }

    /// Batches until nothing is due, then waits and looks again — new products arrive with
    /// every poll and every scan.
    func start(interval: Duration = .seconds(60)) {
        guard task == nil else { return }
        let logger = app.logger
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    let done = try await self.runOnce()
                    if done > 0 { continue }
                } catch {
                    logger.error("embeddings: backfill failed: \(String(describing: error))")
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The colourway names per product, for the text a product is embedded from.
    static func colours(of products: [UUID], on sql: any SQLDatabase) async throws -> [UUID: [String]] {
        guard !products.isEmpty else { return [:] }
        let rows = try await sql.raw("""
            SELECT product_id, color FROM variants
            WHERE product_id IN (\(binds: products)) AND color IS NOT NULL
            """).all()
        var out: [UUID: [String]] = [:]
        for row in rows {
            let id = try row.decode(column: "product_id", as: UUID.self)
            let colour = try row.decode(column: "color", as: String.self)
            guard !colour.isEmpty, colour != "Default Title", out[id]?.contains(colour) != true else { continue }
            out[id, default: []].append(colour)
        }
        return out
    }
}

struct EmbeddingBackfillKey: StorageKey {
    typealias Value = EmbeddingBackfill
}
