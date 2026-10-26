// Embeddings.swift
// Vectors of each product's text and photograph, in pgvector, from the embedding sidecar.
//
// Three things have to be true before a single vector exists:
//
// 1. **A Postgres with pgvector.** Railway's default Postgres has none and will not get one;
//    the move is a dump and restore onto the pgvector template (`docs/pgvector-migration.md`).
//    Until then `SemanticIndex.status` is `.unavailable`, said once at boot, and everything
//    else — full-text search, "more like this" by text — works exactly as it would anyway.
// 2. **A provider** (`EmbeddingProvider`). The one there is, `SidecarEmbeddingProvider`, is
//    the client for `Embeddings/` at the repo root — a Python service running FashionSigLIP
//    beside this one on Railway's private network (see "Embeddings" in docs/server.md).
//    Configured by `EMBEDDING_URL` and `EMBEDDING_TOKEN`; either unset is off, said at boot.
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
import Synchronization
import Vapor

/// Which model made a vector, and how long it is. Two models, or two revisions of one, do
/// not share a space, so a vector may only be compared with vectors from the same one.
struct EmbeddingSpace: Sendable, Hashable {
    /// Stored beside every vector — for the sidecar, the repository *and* the revision.
    var model: String
    /// The length of every vector. Checked on every answer: a vector of another length is
    /// refused rather than stored, because the index is built for exactly this.
    var dimension: Int
}

/// What became of one photograph sent to be embedded.
enum ImageEmbedding: Sendable, Equatable {
    case vector([Float])
    /// Asking again gets the same answer: a 4xx, a 200 that will not decode, a URL the
    /// sidecar refuses to fetch. Written off for this URL.
    case gone(String)
    /// Might answer later: a timeout, a 429 or 5xx, a host that did not resolve. Asked again,
    /// a few times, further apart each time (`EmbeddingBackfill.retryDelay`).
    case unavailable(String)
}

/// Text and photographs in, one vector each out.
///
/// The server's only view of an embedding model. Nothing here knows what is behind it, so the
/// whole of search, the backfill and "more like this" are tested with a fake
/// (`FakeEmbeddingProvider` in the tests) and no network.
protocol EmbeddingProvider: Sendable {
    /// The model and dimension, as the provider reports them — never assumed. Asynchronous
    /// because the sidecar learns them from its own `/health`, and may not be up yet.
    var space: EmbeddingSpace { get async throws }
    /// Whether `embed(imageURLs:)` answers. A text-only model leaves the image column empty.
    var embedsImages: Bool { get }

    /// One vector per text, in order, all in `space`.
    func embed(texts: [String]) async throws -> [[Float]]
    /// One answer per photograph, in order. A photograph that could not be read is an answer,
    /// not a failure of the whole batch.
    func embed(imageURLs: [URL]) async throws -> [ImageEmbedding]
}

/// Every way embedding can fail, so search can say which before falling back to full-text.
enum EmbeddingError: Error, Equatable, CustomStringConvertible {
    /// Not reachable, timed out, or answered 5xx. Transient; full-text in the meantime.
    case unavailable(String)
    /// A 4xx: the request or the configuration is wrong on our side, and retrying will not help.
    case refused(status: UInt, reason: String)
    /// The answer did not have the shape the wire promises.
    case malformedResponse(String)
    /// The sidecar now runs a different model from the one `space` last reported. Nothing
    /// is returned, because returning those vectors under the old id would store vectors
    /// from one space labelled as the other. Read `space` again and re-embed.
    case modelChanged(from: String, to: String)
    case wrongCount(expected: Int, got: Int)
    case wrongDimension(expected: Int, got: Int)
    /// `withTimeout` gave up waiting.
    case timedOut

    var description: String {
        switch self {
        case .unavailable(let reason): "embedding service unavailable: \(reason)"
        case .refused(let status, let reason): "embedding service refused (\(status)): \(reason)"
        case .malformedResponse(let reason): "embedding service answered badly: \(reason)"
        case .modelChanged(let from, let to): "embedding model changed from \(from) to \(to)"
        case .wrongCount(let expected, let got): "provider answered \(got) vectors for \(expected) inputs"
        case .wrongDimension(let expected, let got): "provider answered a \(got)-long vector, not \(expected)"
        case .timedOut: "provider did not answer in time"
        }
    }
}

// MARK: - The sidecar

/// `EmbeddingProvider` over the sidecar's HTTP API.
///
/// Configured by `EMBEDDING_URL` and `EMBEDDING_TOKEN`; with either unset there is no
/// provider at all, and search runs on full-text alone — the sidecar refuses every
/// request without a token anyway, so a URL with no token is not "on". The query path does
/// not lean on these timeouts: a search gives its embedding `ProductSearch.embeddingTimeout`
/// whatever they say. They bound the backfill, and the request a search walked away from.
actor SidecarEmbeddingProvider: EmbeddingProvider {
    struct Configuration: Equatable, Sendable {
        var baseURL: String
        var token: String
        var healthTimeout: Duration = .seconds(2)
        /// A batch of 32 texts took 3s on 2 vCPU, measured; one query takes about 0.1s.
        var textTimeout: Duration = .seconds(10)
        /// Images are fetched by the sidecar before they are embedded, so a batch is
        /// bounded by the slowest storefront CDN in it as well as by the CPU.
        var imageTimeout: Duration = .seconds(60)
        /// Inputs per request. The sidecar refuses more than its own `EMBEDDING_MAX_ITEMS`
        /// (64 by default); larger calls are split and the answers concatenated in order.
        var batchSize = 32
        /// Photographs per request, fewer than texts: sixteen took 12.8s to fetch and embed
        /// on 2 vCPU with FashionSigLIP, and the SigLIP2 alternative is four times slower.
        var imageBatchSize = 8

        /// Nil — embeddings off — unless both variables are set to something.
        static func from(environment: [String: String]) -> Configuration? {
            let url = environment["EMBEDDING_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let token = environment["EMBEDDING_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty, !token.isEmpty,
                  let parsed = URL(string: url), parsed.scheme == "http" || parsed.scheme == "https",
                  parsed.host?.isEmpty == false
            else { return nil }
            return Configuration(baseURL: url.hasSuffix("/") ? String(url.dropLast()) : url, token: token)
        }
    }

    /// The provider this deployment is configured for, or nil, logging which — a variable
    /// that silently does nothing is how push stayed off for months.
    static func make(
        for app: Application,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SidecarEmbeddingProvider? {
        guard let configuration = Configuration.from(environment: environment) else {
            let half = [environment["EMBEDDING_URL"], environment["EMBEDDING_TOKEN"]]
                .contains { $0?.trimmingCharacters(in: .whitespaces).isEmpty == false }
            if half {
                app.logger.warning("embeddings: off — EMBEDDING_URL and EMBEDDING_TOKEN must both be set, and the URL be http(s)")
            } else {
                app.logger.notice("embeddings: off — EMBEDDING_URL and EMBEDDING_TOKEN are not set")
            }
            return nil
        }
        app.logger.notice("embeddings: sidecar at \(configuration.baseURL)")
        return SidecarEmbeddingProvider(configuration: configuration, client: app.client)
    }

    nonisolated let embedsImages = true
    private let configuration: Configuration
    private let client: any Client
    private var model: EmbeddingSpace?

    init(configuration: Configuration, client: any Client) {
        self.configuration = configuration
        self.client = client
    }

    var space: EmbeddingSpace {
        get async throws { try await described() }
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for chunk in Self.chunks(of: texts, size: configuration.batchSize) {
            let answer = try await post("embed/text", body: TextRequest(texts: chunk),
                                        count: chunk.count, timeout: configuration.textTimeout)
            let vectors = answer.vectors.compactMap { $0 }
            guard vectors.count == chunk.count else {
                throw EmbeddingError.malformedResponse("a text with no vector")
            }
            out += vectors
        }
        return out
    }

    func embed(imageURLs: [URL]) async throws -> [ImageEmbedding] {
        var out: [ImageEmbedding] = []
        out.reserveCapacity(imageURLs.count)
        for chunk in Self.chunks(of: imageURLs.map(\.absoluteString), size: configuration.imageBatchSize) {
            let answer = try await post("embed/image", body: ImageRequest(urls: chunk),
                                        count: chunk.count, timeout: configuration.imageTimeout)
            let failures = Dictionary((answer.errors ?? []).map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
            for (index, vector) in answer.vectors.enumerated() {
                if let vector {
                    out.append(.vector(vector))
                } else if let failure = failures[index] {
                    // An older sidecar says nothing about permanence; asking again is the
                    // safe reading, and the backfill's attempts are bounded either way.
                    out.append(failure.transient == false ? .gone(failure.error) : .unavailable(failure.error))
                } else {
                    throw EmbeddingError.malformedResponse("a null vector with no error for it")
                }
            }
        }
        return out
    }

    // MARK: Wire

    private struct TextRequest: Content { let texts: [String] }
    private struct ImageRequest: Content { let urls: [String] }

    private struct Health: Decodable {
        let model: String?
        let dimension: Int?
        let ready: Bool
    }

    private struct Answer: Decodable {
        struct ItemError: Decodable {
            let index: Int
            let error: String
            let transient: Bool?
        }
        let model: String
        let dimension: Int
        let vectors: [[Float]?]
        let errors: [ItemError]?
    }

    private struct Refusal: Decodable { let error: String }

    private static func chunks<T>(of items: [T], size: Int) -> [[T]] {
        let size = max(size, 1)
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    private func described() async throws -> EmbeddingSpace {
        if let model { return model }
        let response = try await send(.GET, "health", timeout: configuration.healthTimeout) { _ in }
        // /health answers 503 with a body while it is not ready, which is worth reading.
        let health = try decode(Health.self, from: response, path: "health", allowing: [200, 503])
        guard health.ready, let id = health.model, let dimension = health.dimension, dimension > 0 else {
            throw EmbeddingError.unavailable("the service is up but not ready")
        }
        if let model { return model }
        let space = EmbeddingSpace(model: id, dimension: dimension)
        model = space
        return space
    }

    private func post(_ path: String, body: some Content, count: Int, timeout: Duration) async throws -> Answer {
        let response = try await send(.POST, path, timeout: timeout) { try $0.content.encode(body) }
        let answer = try decode(Answer.self, from: response, path: path, allowing: [200])
        try adopt(EmbeddingSpace(model: answer.model, dimension: answer.dimension))
        guard answer.vectors.count == count else {
            throw EmbeddingError.wrongCount(expected: count, got: answer.vectors.count)
        }
        guard answer.vectors.allSatisfy({ $0 == nil || $0?.count == answer.dimension }) else {
            throw EmbeddingError.malformedResponse("a vector is not \(answer.dimension) wide")
        }
        return answer
    }

    /// Every answer names the model that produced it. The first one seen is believed; a
    /// different one later means the sidecar was redeployed with another model under us.
    private func adopt(_ answered: EmbeddingSpace) throws {
        guard let model else {
            model = answered
            return
        }
        guard model == answered else {
            self.model = answered
            throw EmbeddingError.modelChanged(from: model.model, to: answered.model)
        }
    }

    private func send(
        _ method: HTTPMethod, _ path: String, timeout: Duration,
        _ prepare: (inout ClientRequest) throws -> Void
    ) async throws -> ClientResponse {
        var request = ClientRequest(method: method, url: URI(string: "\(configuration.baseURL)/\(path)"))
        let (seconds, attoseconds) = timeout.components
        request.timeout = .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        request.headers.bearerAuthorization = BearerAuthorization(token: configuration.token)
        try prepare(&request)
        do {
            return try await client.send(request).get()
        } catch {
            throw EmbeddingError.unavailable(String(describing: error))
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type, from response: ClientResponse, path: String, allowing ok: Set<UInt>
    ) throws -> T {
        let status = response.status.code
        guard ok.contains(status) else {
            let reason = (try? response.content.decode(Refusal.self).error) ?? response.status.reasonPhrase
            if status >= 500 { throw EmbeddingError.unavailable("\(path) answered \(status): \(reason)") }
            throw EmbeddingError.refused(status: status, reason: reason)
        }
        do {
            return try response.content.decode(T.self, using: JSONDecoder())
        } catch {
            throw EmbeddingError.malformedResponse("\(path): \(error)")
        }
    }
}

// MARK: - Where the provider lives

struct EmbeddingProviderKey: StorageKey {
    typealias Value = any EmbeddingProvider
}

struct SemanticStatusKey: StorageKey {
    typealias Value = SemanticIndex.Status
}

struct SemanticRestKey: StorageKey {
    typealias Value = SemanticRest
}

/// A short pause on asking the provider, after it failed a search.
///
/// The deadline bounds one search, not an outage: with the sidecar down, every search would
/// still wait out its full 1.5 s — the HTTP client keeps retrying a refused connection until
/// the deadline — and a box that is a second and a half slower for as long as the sidecar is
/// redeploying reads as a broken search. So one failure makes the next `interval` of searches
/// full-text without asking. In memory and per process: a pause, not a verdict, like
/// `ImageTagger.resting` on the phone. The backfill does not consult it; it has its own sleep.
final class SemanticRest: Sendable {
    static let interval: TimeInterval = 30
    private let until = Mutex<Date?>(nil)

    func isResting(now: Date = Date()) -> Bool {
        until.withLock { $0.map { $0 > now } ?? false }
    }

    func rest(now: Date = Date()) {
        until.withLock { $0 = now.addingTimeInterval(Self.interval) }
    }
}

extension Application {
    /// Setting a provider starts it with no pause.
    var embeddingProvider: (any EmbeddingProvider)? {
        get { storage[EmbeddingProviderKey.self] }
        set {
            storage[EmbeddingProviderKey.self] = newValue
            storage[SemanticRestKey.self] = SemanticRest()
        }
    }

    var semanticRest: SemanticRest? { storage[SemanticRestKey.self] }

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

// MARK: - pgvector

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
    /// It is also why a column added to the table is added here, with `IF NOT EXISTS`, rather
    /// than in a migration of its own.
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
            // What the image column is about, and what became of it — see `EmbeddingBackfill`.
            for column in [
                "image_url TEXT",
                "image_failure TEXT",
                "image_attempts INTEGER NOT NULL DEFAULT 0",
                "image_retry_at TIMESTAMPTZ",
            ] {
                try await sql.raw("ALTER TABLE product_embeddings ADD COLUMN IF NOT EXISTS \(unsafeRaw: column)").run()
            }
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
    static func ensureIndex(for space: EmbeddingSpace, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS \(ident: indexName(for: space)) ON product_embeddings \
            USING hnsw ((text_embedding::vector(\(literal: space.dimension))) vector_cosine_ops) \
            WHERE model = \(literal: space.model)
            """).run()
    }

    /// One name per model and dimension, stable across restarts: FNV-1a, since `Hasher` is
    /// seeded per process.
    static func indexName(for space: EmbeddingSpace) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(space.model)#\(space.dimension)".utf8 {
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
        in space: EmbeddingSpace,
        scope: SQLQueryString,
        excluding product: UUID? = nil,
        limit: Int,
        on sql: any SQLDatabase
    ) async throws -> [(id: UUID, similarity: Double)] {
        let cast = SQLQueryString("::vector(\(literal: space.dimension))")
        let exclusion: SQLQueryString = product.map { "AND p.id <> \(bind: $0)" } ?? ""
        let rows = try await sql.raw("""
            SELECT p.id AS id, 1 - ((e.text_embedding\(cast)) <=> (\(bind: literal(vector))\(cast))) AS similarity
            FROM product_embeddings e JOIN products p ON p.id = e.product_id
            WHERE e.model = \(bind: space.model) AND \(scope) \(exclusion)
            ORDER BY (e.text_embedding\(cast)) <=> (\(bind: literal(vector))\(cast))
            LIMIT \(literal: limit)
            """).all()
        return try rows.map { (try $0.decode(column: "id", as: UUID.self), try $0.decode(column: "similarity", as: Double.self)) }
    }

    /// A product's own text vector under this model, when it has one.
    static func vector(of product: UUID, in space: EmbeddingSpace, on sql: any SQLDatabase) async throws -> [Float]? {
        guard let row = try await sql.raw("""
            SELECT text_embedding::text AS v FROM product_embeddings
            WHERE product_id = \(bind: product) AND model = \(bind: space.model)
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

// MARK: - Waiting on it

/// Runs `work`, or gives up after `seconds` — for the one embedding made while somebody waits.
///
/// A query is embedded per search, so semantic search needs the provider up at that moment.
/// When it is down or slow the answer is the full-text one, which is a complete answer on its
/// own, rather than a spinner: a search that waited thirty seconds for a provider to time out
/// is worse than one that never asked.
///
/// **It returns at the deadline whether or not `work` listens.** A task group cancels its
/// children and then waits for them, and an HTTP request in flight on an event loop does not
/// hear cancellation — so a group-based timeout over the sidecar returned when the *request's*
/// timeout fired, not this one. The work runs unstructured instead; on the deadline it is
/// cancelled and left to end by its own timeout.
func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let answer = FirstAnswer<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            answer.wait(continuation)
            let worker = Task {
                do { answer.give(.success(try await work())) } catch { answer.give(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                answer.give(.failure(EmbeddingError.timedOut))
                worker.cancel()
            }
        }
    } onCancel: {
        answer.give(.failure(CancellationError()))
    }
}

/// A continuation resumed by whichever answer comes first; the rest are dropped.
private final class FirstAnswer<T: Sendable>: Sendable {
    private enum State {
        case empty
        case waiting(CheckedContinuation<T, any Error>)
        /// Cancellation can land before the continuation exists; it is held until it does.
        case answered(Result<T, any Error>)
        case done
    }

    private let state = Mutex<State>(.empty)

    func wait(_ continuation: CheckedContinuation<T, any Error>) {
        let early: Result<T, any Error>? = state.withLock { state in
            switch state {
            case .answered(let result):
                state = .done
                return result
            case .empty:
                state = .waiting(continuation)
                return nil
            case .waiting, .done:
                return nil
            }
        }
        if let early { continuation.resume(with: early) }
    }

    func give(_ result: Result<T, any Error>) {
        let waiting: CheckedContinuation<T, any Error>? = state.withLock { state in
            switch state {
            case .waiting(let continuation):
                state = .done
                return continuation
            case .empty:
                state = .answered(result)
                return nil
            case .answered, .done:
                return nil
            }
        }
        waiting?.resume(with: result)
    }
}

// MARK: - The backfill

/// Embeds every listed product once per model, a batch at a time.
///
/// A product is due when it has no row, a row from another model — which is how a model change
/// re-embeds the catalogue without a migration — or a photograph the row does not describe.
/// Products with no photograph are embedded from their text alone. Runs only where
/// `Application.semanticSearch` says vectors have somewhere to go.
///
/// **A photograph that cannot be read costs the product only its image vector**, and is
/// remembered so that it is not asked about again on every pass. The sidecar says which kind
/// of failure it was, and they are treated as `docs/collection.md` treats them on the phone:
///
/// - **`.gone`** (a 4xx, something that will not decode, a URL refused): written off, with
///   the URL and the reason, so `image_url` matches the product's photograph and the row
///   leaves the backlog. A *different* photograph later makes it due again.
/// - **`.unavailable`** (a timeout, 429, 5xx, no DNS answer): asked again after
///   `retryDelay`, which grows fourfold from an hour. The fifth such answer for one URL writes
///   it off as gone — four days of a CDN refusing the sidecar is not a blip, and a backlog
///   that never drains re-fetches the same photographs forever.
///
/// The text vector is written either way; it is the one every query reads.
actor EmbeddingBackfill {
    /// Unavailable answers for one photograph before it is written off.
    static let maxImageAttempts = 5

    /// How long after the `attempt`th unavailable answer the photograph is asked about again.
    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        3_600 * pow(4, Double(max(attempt, 1) - 1))
    }

    /// What one batch did, for the log and `POST /admin/embed`.
    struct Pass: Sendable, Equatable, CustomStringConvertible {
        var embedded = 0
        var images = 0
        var gone = 0
        var unavailable = 0
        var model: String?

        var description: String {
            "embedded \(embedded) (\(images) with a photograph, \(gone) written off, \(unavailable) to ask again)"
                + (model.map { " under \($0)" } ?? "")
        }
    }

    private let app: Application
    private let batch: Int
    private var task: Task<Void, Never>?

    init(app: Application, batch: Int = 32) {
        self.app = app
        self.batch = batch
    }

    /// One batch. `embedded` is how many products were written; zero means nothing is due, or
    /// there is nothing to embed with. Every product written leaves the backlog — a photograph
    /// to ask about again is due only at its `image_retry_at` — so a drain loop cannot spin.
    @discardableResult
    func runOnce(now: Date = Date()) async throws -> Pass {
        guard let provider = app.semanticSearch, let sql = app.db as? any SQLDatabase else { return Pass() }
        let space = try await provider.space
        try await SemanticIndex.ensureIndex(for: space, on: sql)

        // Postgres arrays count from one: `image_urls[1]` is the lead photograph.
        let photographChanged: SQLQueryString = provider.embedsImages
            ? "OR e.image_url IS DISTINCT FROM p.image_urls[1]"
            : ""
        let due = try await sql.raw("""
            SELECT p.id AS id, p.title AS title, p.product_type AS product_type, p.tags AS tags,
                   p.image_urls[1] AS image, b.name AS brand,
                   e.model AS was_model, e.image_url AS was_image, e.image_attempts AS was_attempts
            FROM products p
            JOIN brands b ON b.id = p.brand_id
            LEFT JOIN product_embeddings e ON e.product_id = p.id
            WHERE p.kind = 'product' AND p.unlisted_at IS NULL
              AND (e.product_id IS NULL OR e.model <> \(bind: space.model)
                   \(photographChanged)
                   OR e.image_retry_at <= \(bind: now))
            ORDER BY p.published_at DESC, p.id
            LIMIT \(literal: batch)
            """).all()
        guard !due.isEmpty else { return Pass(model: space.model) }

        struct Due {
            var id: UUID
            var text: String
            /// As stored, so the write-off records exactly the string it is compared with.
            var image: String?
            /// Unavailable answers already had for this same photograph under this model.
            var attempts: Int
        }
        let ids = try due.map { try $0.decode(column: "id", as: UUID.self) }
        let colours = try await Self.colours(of: ids, on: sql)
        let items: [Due] = try due.map { row in
            let id = try row.decode(column: "id", as: UUID.self)
            let image = try row.decode(column: "image", as: String?.self).flatMap { $0.isEmpty ? nil : $0 }
            let wasModel = try row.decode(column: "was_model", as: String?.self)
            let wasImage = try row.decode(column: "was_image", as: String?.self)
            let sameSubject = wasModel == space.model && wasImage == image
            return Due(
                id: id,
                text: SemanticIndex.text(
                    title: try row.decode(column: "title", as: String.self),
                    productType: try row.decode(column: "product_type", as: String?.self),
                    tags: try row.decode(column: "tags", as: [String].self),
                    brand: try row.decode(column: "brand", as: String.self),
                    colours: colours[id] ?? []
                ),
                image: provider.embedsImages ? image : nil,
                attempts: sameSubject ? (try row.decode(column: "was_attempts", as: Int?.self) ?? 0) : 0
            )
        }

        let texts = try await provider.embed(texts: items.map(\.text))
        guard texts.count == items.count else { throw EmbeddingError.wrongCount(expected: items.count, got: texts.count) }

        var images: [ImageEmbedding?] = Array(repeating: nil, count: items.count)
        var asked: [(index: Int, url: URL)] = []
        for (index, item) in items.enumerated() {
            guard let image = item.image else { continue }
            if let url = URL(string: image), url.scheme == "http" || url.scheme == "https" {
                asked.append((index, url))
            } else {
                // Not a URL at all: no sidecar is needed to know asking again gets nowhere.
                images[index] = .gone("not an http(s) URL")
            }
        }
        if !asked.isEmpty {
            let answered = try await provider.embed(imageURLs: asked.map(\.url))
            guard answered.count == asked.count else {
                throw EmbeddingError.wrongCount(expected: asked.count, got: answered.count)
            }
            for (position, entry) in asked.enumerated() { images[entry.index] = answered[position] }
        }

        var pass = Pass(model: space.model)
        for (index, item) in items.enumerated() {
            let text = texts[index]
            guard text.count == space.dimension else {
                throw EmbeddingError.wrongDimension(expected: space.dimension, got: text.count)
            }
            var vector: String?
            var failure: String?
            var attempts = 0
            var retryAt: Date?
            switch images[index] {
            case nil:
                break
            case .vector(let image) where image.count == space.dimension:
                vector = SemanticIndex.literal(image)
                pass.images += 1
            case .vector(let image):
                failure = "a \(image.count)-long vector, not \(space.dimension)"
            case .gone(let reason):
                failure = reason
            case .unavailable(let reason):
                attempts = item.attempts + 1
                if attempts >= Self.maxImageAttempts {
                    failure = "unavailable \(attempts) times, last: \(reason)"
                } else {
                    failure = reason
                    retryAt = now.addingTimeInterval(Self.retryDelay(afterAttempt: attempts))
                }
            }
            if failure != nil {
                if retryAt == nil {
                    pass.gone += 1
                    // Said with the address, because nothing else connects a product with no
                    // image vector to the URL that would not answer.
                    app.logger.notice("embeddings: photograph written off: \(item.image ?? "?") — \(failure ?? "")")
                } else {
                    pass.unavailable += 1
                }
            }
            try await sql.raw("""
                INSERT INTO product_embeddings
                  (product_id, model, text_embedding, image_embedding, embedded_at,
                   image_url, image_failure, image_attempts, image_retry_at)
                VALUES (\(bind: item.id), \(bind: space.model), \(bind: SemanticIndex.literal(text))::vector,
                        \(bind: vector)::vector, \(bind: now),
                        \(bind: item.image), \(bind: failure), \(bind: attempts), \(bind: retryAt))
                ON CONFLICT (product_id) DO UPDATE SET
                  model = EXCLUDED.model, text_embedding = EXCLUDED.text_embedding,
                  image_embedding = EXCLUDED.image_embedding, embedded_at = EXCLUDED.embedded_at,
                  image_url = EXCLUDED.image_url, image_failure = EXCLUDED.image_failure,
                  image_attempts = EXCLUDED.image_attempts, image_retry_at = EXCLUDED.image_retry_at
                """).run()
            pass.embedded += 1
        }
        return pass
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
                    let pass = try await self.runOnce()
                    if pass.embedded > 0 {
                        logger.info("embeddings: \(pass)")
                        continue
                    }
                } catch EmbeddingError.modelChanged(let from, let to) {
                    // Not a failure: the next batch reads the new model and starts re-embedding.
                    logger.notice("embeddings: the sidecar now runs \(to), not \(from) — re-embedding")
                    continue
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
