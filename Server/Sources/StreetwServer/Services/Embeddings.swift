import Foundation
import Vapor

// The embedding sidecar: what turns a search query or a product photograph into a vector.
//
// The model runs in its own service (`Embeddings/` at the repo root, Python) beside this one
// on Railway's private network — see "Embeddings" in docs/server.md. This file is the
// server's half of that wire and nothing else: it does not decide what gets embedded or
// when, and it never stores a vector.

/// Text and photographs in, unit vectors out.
///
/// **Integration:** the search work defines its own `EmbeddingProvider`, and this one is
/// shaped as that work was told to expect — `embed(texts:)`, `embed(imageURLs:)`, a
/// `dimension` and a `modelID`. Whichever lands second reconciles the two into one
/// protocol and keeps `SidecarEmbeddingProvider` conforming to it.
protocol EmbeddingProvider: Sendable {
    /// Stored beside every vector. Two models, or two revisions of one, do not share an
    /// embedding space, so a vector may only be compared with vectors carrying the same id.
    var modelID: String { get async throws }
    /// The vector width, as the running model reports it — never assumed.
    var dimension: Int { get async throws }
    func embed(texts: [String]) async throws -> [[Float]]
    func embed(imageURLs: [URL]) async throws -> [[Float]]
}

/// Every way embedding can fail, so search can say which before falling back to full-text.
enum EmbeddingError: Error, Equatable, CustomStringConvertible {
    /// Not reachable, timed out, or answered 5xx. Transient; full-text in the meantime.
    case unavailable(String)
    /// A 4xx: the request or the configuration is wrong on our side, and retrying will not help.
    case refused(status: UInt, reason: String)
    /// The answer did not have the shape the wire promises.
    case malformedResponse(String)
    /// The sidecar now runs a different model from the one `modelID` last reported. Nothing
    /// is returned, because returning those vectors under the old id would store vectors
    /// from one space labelled as the other. Read `modelID` again and re-embed.
    case modelChanged(from: String, to: String)
    /// Photographs that could not be fetched or decoded, by position in the request, with
    /// the sidecar's reason. Thrown rather than skipped: `[[Float]]` lines up with its input.
    case unreadableImages([Int: String])

    var description: String {
        switch self {
        case .unavailable(let reason): "embedding service unavailable: \(reason)"
        case .refused(let status, let reason): "embedding service refused (\(status)): \(reason)"
        case .malformedResponse(let reason): "embedding service answered badly: \(reason)"
        case .modelChanged(let from, let to): "embedding model changed from \(from) to \(to)"
        case .unreadableImages(let failures):
            "unreadable images: " + failures.sorted { $0.key < $1.key }
                .map { "#\($0.key) \($0.value)" }.joined(separator: ", ")
        }
    }
}

/// `EmbeddingProvider` over the sidecar's HTTP API.
///
/// Configured by `EMBEDDING_URL` and `EMBEDDING_TOKEN`; with either unset there is no
/// provider at all, and search runs on full-text alone — the sidecar refuses every
/// request without a token anyway, so a URL with no token is not "on". Timeouts are short
/// on purpose: a query waiting on the model is a person waiting on a search box, and
/// full-text is a better answer than a spinner.
actor SidecarEmbeddingProvider: EmbeddingProvider {
    struct Configuration: Equatable, Sendable {
        var baseURL: String
        var token: String
        var healthTimeout: Duration = .seconds(2)
        var textTimeout: Duration = .seconds(3)
        /// Images are fetched by the sidecar before they are embedded, so a batch is
        /// bounded by the slowest storefront CDN in it as well as by the CPU.
        var imageTimeout: Duration = .seconds(30)
        /// Inputs per request. The sidecar refuses more than its own `EMBEDDING_MAX_ITEMS`
        /// (64 by default); larger calls are split and the answers concatenated in order.
        var batchSize = 32

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

    /// The provider this deployment is configured for, or nil, logging which.
    static func make(for app: Application) -> SidecarEmbeddingProvider? {
        guard let configuration = Configuration.from(environment: ProcessInfo.processInfo.environment) else {
            app.logger.notice("Embeddings off: EMBEDDING_URL and EMBEDDING_TOKEN are not both set")
            return nil
        }
        app.logger.notice("Embeddings via \(configuration.baseURL)")
        return SidecarEmbeddingProvider(configuration: configuration, client: app.client)
    }

    private let configuration: Configuration
    private let client: any Client
    private var model: (id: String, dimension: Int)?

    init(configuration: Configuration, client: any Client) {
        self.configuration = configuration
        self.client = client
    }

    var modelID: String {
        get async throws { try await described().id }
    }

    var dimension: Int {
        get async throws { try await described().dimension }
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        try await chunked(texts) { chunk in
            try await self.post("embed/text", body: TextRequest(texts: chunk),
                                timeout: self.configuration.textTimeout)
        }
    }

    func embed(imageURLs: [URL]) async throws -> [[Float]] {
        try await chunked(imageURLs.map(\.absoluteString)) { chunk in
            try await self.post("embed/image", body: ImageRequest(urls: chunk),
                                timeout: self.configuration.imageTimeout)
        }
    }

    // MARK: - Wire

    private struct TextRequest: Content { let texts: [String] }
    private struct ImageRequest: Content { let urls: [String] }

    private struct Health: Decodable {
        let model: String?
        let dimension: Int?
        let ready: Bool
    }

    private struct Answer: Decodable {
        struct ItemError: Decodable { let index: Int; let error: String }
        let model: String
        let dimension: Int
        let vectors: [[Float]?]
        let errors: [ItemError]?
    }

    private struct Refusal: Decodable { let error: String }

    private func described() async throws -> (id: String, dimension: Int) {
        if let model { return model }
        let response = try await send(.GET, "health", timeout: configuration.healthTimeout) { _ in }
        // /health answers 503 with a body while it is not ready, which is worth reading.
        let health = try decode(Health.self, from: response, path: "health", allowing: [200, 503])
        guard health.ready, let id = health.model, let dimension = health.dimension, dimension > 0 else {
            throw EmbeddingError.unavailable("the service is up but not ready")
        }
        if let model { return model }
        model = (id, dimension)
        return (id, dimension)
    }

    private func chunked(_ inputs: [String], _ run: ([String]) async throws -> [[Float]]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(inputs.count)
        var start = 0
        while start < inputs.count {
            let end = min(start + max(configuration.batchSize, 1), inputs.count)
            do {
                out += try await run(Array(inputs[start..<end]))
            } catch EmbeddingError.unreadableImages(let failures) {
                // Positions are within the chunk; the caller needs them within its input.
                throw EmbeddingError.unreadableImages(
                    Dictionary(uniqueKeysWithValues: failures.map { ($0.key + start, $0.value) }))
            }
            start = end
        }
        return out
    }

    private func post(_ path: String, body: some Content, timeout: Duration) async throws -> [[Float]] {
        let response = try await send(.POST, path, timeout: timeout) { try $0.content.encode(body) }
        let answer = try decode(Answer.self, from: response, path: path, allowing: [200])
        try adopt(model: answer.model, dimension: answer.dimension)

        if let errors = answer.errors, !errors.isEmpty {
            throw EmbeddingError.unreadableImages(
                Dictionary(errors.map { ($0.index, $0.error) }, uniquingKeysWith: { first, _ in first }))
        }
        let vectors = answer.vectors.compactMap { $0 }
        guard vectors.count == answer.vectors.count else {
            throw EmbeddingError.malformedResponse("a null vector with no error for it")
        }
        guard vectors.allSatisfy({ $0.count == answer.dimension }) else {
            throw EmbeddingError.malformedResponse("a vector is not \(answer.dimension) wide")
        }
        return vectors
    }

    /// Every answer names the model that produced it. The first one seen is believed; a
    /// different one later means the sidecar was redeployed with another model under us.
    private func adopt(model id: String, dimension: Int) throws {
        guard let model else {
            model = (id, dimension)
            return
        }
        guard model.id == id, model.dimension == dimension else {
            let previous = model.id
            self.model = (id, dimension)
            throw EmbeddingError.modelChanged(from: previous, to: id)
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
