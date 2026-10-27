import Foundation
import Synchronization
import Testing
import Vapor

@testable import StreetwServer

// `SidecarEmbeddingProvider` against a real HTTP server standing in for the sidecar, so the
// timeouts, status codes and bodies all cross an actual socket.

private let sidecarToken = "sidecar-secret"

/// A stand-in sidecar on an ephemeral port. Each route answers with whatever the test set.
private final class StubSidecar: Sendable {
    struct Reply: Sendable {
        var status: HTTPStatus = .ok
        var json: String
        var delay: Duration = .zero
    }

    let app: Application
    let port: Int
    private let replies = Mutex<[String: [Reply]]>([:])
    private let seen = Mutex<[Seen]>([])

    struct Seen: Sendable {
        let path: String
        let auth: String?
        let body: String
    }

    var requests: [Seen] { seen.withLock { $0 } }

    /// Queue replies for a path; the last one repeats.
    func reply(_ path: String, _ queue: Reply...) {
        replies.withLock { $0[path] = queue }
    }

    private init(app: Application, port: Int) {
        self.app = app
        self.port = port
    }

    static func start() async throws -> StubSidecar {
        let app = try await Application.make(.testing)
        let box = Mutex<StubSidecar?>(nil)
        let responder: @Sendable (Request) async throws -> Response = { req in
            let stub = box.withLock { $0! }
            let path = req.url.path
            stub.seen.withLock {
                $0.append(Seen(path: path, auth: req.headers.first(name: .authorization),
                               body: req.body.string ?? ""))
            }
            let reply = stub.replies.withLock { queues -> Reply? in
                guard var queue = queues[path], let first = queue.first else { return nil }
                if queue.count > 1 { queue.removeFirst(); queues[path] = queue }
                return first
            }
            guard let reply else { return Response(status: .notFound) }
            if reply.delay > .zero { try await Task.sleep(for: reply.delay) }
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: reply.status, headers: headers, body: .init(string: reply.json))
        }
        app.get("health", use: responder)
        app.post("embed", "text", use: responder)
        app.post("embed", "image", use: responder)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        let port = try #require(app.http.server.shared.localAddress?.port)
        let stub = StubSidecar(app: app, port: port)
        box.withLock { $0 = stub }
        return stub
    }

    func stop() async throws {
        await app.server.shutdown()
        try await app.asyncShutdown()
    }

    func provider(
        token: String = sidecarToken, batchSize: Int = 32, imageBatchSize: Int = 8,
        timeout: Duration = .seconds(2)
    ) -> SidecarEmbeddingProvider {
        var configuration = SidecarEmbeddingProvider.Configuration(
            baseURL: "http://127.0.0.1:\(port)", token: token)
        configuration.batchSize = batchSize
        configuration.imageBatchSize = imageBatchSize
        configuration.healthTimeout = timeout
        configuration.textTimeout = timeout
        configuration.imageTimeout = timeout
        return SidecarEmbeddingProvider(configuration: configuration, client: app.client)
    }
}

private func withSidecar(_ body: (StubSidecar) async throws -> Void) async throws {
    let stub = try await StubSidecar.start()
    do {
        try await body(stub)
    } catch {
        try await stub.stop()
        throw error
    }
    try await stub.stop()
}

private func healthJSON(model: String = "Marqo/marqo-fashionSigLIP@c56244cc94f9", dimension: Int = 3) -> String {
    #"{"model":"\#(model)","dimension":\#(dimension),"ready":true}"#
}

private func answerJSON(
    _ vectors: [[Float]?], model: String = "Marqo/marqo-fashionSigLIP@c56244cc94f9",
    dimension: Int = 3, errors: String? = nil
) -> String {
    let encoded = vectors.map { v in v.map { "[" + $0.map { "\($0)" }.joined(separator: ",") + "]" } ?? "null" }
    let errorPart = errors.map { #","errors":\#($0)"# } ?? ""
    return #"{"model":"\#(model)","dimension":\#(dimension),"vectors":[\#(encoded.joined(separator: ","))]\#(errorPart)}"#
}

@Suite("Embedding sidecar provider")
struct EmbeddingsTests {
    /// Alo Yoga's 40 tags made a text the sidecar refused (413), and the backfill stalled on
    /// that batch in production.
    @Test func aProductsTextStaysUnderTheSidecarsLimit() {
        let tags = (1...60).map { "Alo Yoga Legging Tag Number \($0)" }
        let text = SemanticIndex.text(
            title: "7/8 High-Waist Airlift Legging", productType: "Leggings",
            tags: tags, brand: "Alo Yoga", colours: ["Burgundy"]
        )
        #expect(text.unicodeScalars.count <= SemanticIndex.maxTextLength)
        #expect(text.hasPrefix("7/8 High-Waist Airlift Legging · Leggings · Alo Yoga · Burgundy · "))
        #expect(!text.hasSuffix(" · "))
        // Whole tags only: whatever was cut, every tag left is complete.
        #expect(text.components(separatedBy: " · ").dropFirst(4).allSatisfy(tags.contains))

        let long = String(repeating: "é", count: 800)
        #expect(SemanticIndex.text(title: long, productType: nil, tags: [], brand: "B", colours: [])
            .unicodeScalars.count == SemanticIndex.maxTextLength)
        #expect(SemanticIndex.text(title: "Tee", productType: nil, tags: ["a"], brand: "B", colours: []) == "Tee · B · a")
    }

    @Test func offUnlessBothVariablesAreSet() {
        typealias C = SidecarEmbeddingProvider.Configuration
        #expect(C.from(environment: [:]) == nil)
        #expect(C.from(environment: ["EMBEDDING_URL": "http://embeddings.railway.internal:8080"]) == nil)
        #expect(C.from(environment: ["EMBEDDING_TOKEN": "t"]) == nil)
        #expect(C.from(environment: ["EMBEDDING_URL": "  ", "EMBEDDING_TOKEN": "t"]) == nil)
        #expect(C.from(environment: ["EMBEDDING_URL": "http://x", "EMBEDDING_TOKEN": " "]) == nil)
        #expect(C.from(environment: ["EMBEDDING_URL": "embeddings:8080", "EMBEDDING_TOKEN": "t"]) == nil)
        let on = C.from(environment: ["EMBEDDING_URL": "http://embeddings.railway.internal:8080/",
                                      "EMBEDDING_TOKEN": " secret "])
        #expect(on?.baseURL == "http://embeddings.railway.internal:8080")
        #expect(on?.token == "secret")
    }

    @Test func dimensionAndModelComeFromHealthAndAreAskedOnce() async throws {
        try await withSidecar { stub in
            stub.reply("/health", .init(json: healthJSON(dimension: 768)))
            let provider = stub.provider()
            let space = try await provider.space
            _ = try await provider.space
            #expect(space == EmbeddingSpace(model: "Marqo/marqo-fashionSigLIP@c56244cc94f9", dimension: 768))
            #expect(stub.requests.filter { $0.path == "/health" }.count == 1)
        }
    }

    @Test func notReadyIsUnavailable() async throws {
        try await withSidecar { stub in
            stub.reply("/health", .init(status: .serviceUnavailable,
                                        json: #"{"model":null,"dimension":null,"ready":false}"#))
            await #expect(throws: EmbeddingError.unavailable("the service is up but not ready")) {
                try await stub.provider().space
            }
        }
    }

    @Test func textsAreSentWithTheTokenAndSplitIntoBatchesInOrder() async throws {
        try await withSidecar { stub in
            stub.reply("/embed/text",
                       .init(json: answerJSON([[1, 0, 0], [0, 1, 0]])),
                       .init(json: answerJSON([[0, 0, 1]])))
            let vectors = try await stub.provider(batchSize: 2).embed(texts: ["olive chore coat", "black beanie", "navy blazer"])
            #expect(vectors == [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
            let sent = stub.requests.filter { $0.path == "/embed/text" }
            #expect(sent.count == 2)
            #expect(sent.allSatisfy { $0.auth == "Bearer \(sidecarToken)" })
            #expect(sent[0].body.contains("olive chore coat") && sent[0].body.contains("black beanie"))
            #expect(sent[1].body.contains("navy blazer"))
        }
    }

    @Test func imageURLsGoAsURLs() async throws {
        try await withSidecar { stub in
            stub.reply("/embed/image", .init(json: answerJSON([[1, 0, 0]])))
            let url = try #require(URL(string: "https://cdn.shopify.com/s/files/a.jpg?v=1"))
            #expect(try await stub.provider().embed(imageURLs: [url]) == [.vector([1, 0, 0])])
            let body = try #require(stub.requests.first?.body)
            #expect(body.contains(#""urls""#) && body.contains("cdn.shopify.com"))
        }
    }

    /// One unreadable photograph is an answer in its place, not a failure of the batch — and
    /// the sidecar's `transient` says whether asking again could help.
    @Test func unreadableImagesAreAnsweredInPlaceAcrossBatches() async throws {
        try await withSidecar { stub in
            stub.reply("/embed/image",
                       .init(json: answerJSON([[1, 0, 0], nil],
                                              errors: #"[{"index":1,"error":"timed out","transient":true}]"#)),
                       .init(json: answerJSON([nil, nil],
                                              errors: #"[{"index":0,"error":"HTTP 404","transient":false},{"index":1,"error":"could not be read"}]"#)))
            let urls = (0..<4).compactMap { URL(string: "https://cdn.example/\($0).jpg") }
            let answers = try await stub.provider(imageBatchSize: 2).embed(imageURLs: urls)
            #expect(answers == [
                .vector([1, 0, 0]),
                .unavailable("timed out"),
                .gone("HTTP 404"),
                // An older sidecar names no permanence; the safe reading is to ask again.
                .unavailable("could not be read"),
            ])
            #expect(stub.requests.filter { $0.path == "/embed/image" }.count == 2)
        }
    }

    @Test func aNullVectorWithNoErrorIsRefused() async throws {
        try await withSidecar { stub in
            stub.reply("/embed/image", .init(json: answerJSON([nil])))
            let url = try #require(URL(string: "https://cdn.example/a.jpg"))
            await #expect(throws: EmbeddingError.malformedResponse("a null vector with no error for it")) {
                try await stub.provider().embed(imageURLs: [url])
            }
        }
    }

    @Test func anAnswerOfTheWrongLengthIsRefused() async throws {
        try await withSidecar { stub in
            stub.reply("/embed/text", .init(json: answerJSON([[1, 0, 0]])))
            await #expect(throws: EmbeddingError.wrongCount(expected: 2, got: 1)) {
                try await stub.provider().embed(texts: ["a", "b"])
            }
        }
    }

    @Test func aDifferentModelInAnAnswerIsNeverReturnedUnderTheOldID() async throws {
        try await withSidecar { stub in
            stub.reply("/health", .init(json: healthJSON(model: "old@1")))
            stub.reply("/embed/text", .init(json: answerJSON([[1, 0, 0]], model: "new@2")))
            let provider = stub.provider()
            let before = try await provider.space.model
            #expect(before == "old@1")
            await #expect(throws: EmbeddingError.modelChanged(from: "old@1", to: "new@2")) {
                try await provider.embed(texts: ["x"])
            }
            let after = try await provider.space.model
            let vectors = try await provider.embed(texts: ["x"])
            #expect(after == "new@2")
            #expect(vectors == [[1, 0, 0]])
        }
    }

    @Test func malformedAnswersAreRefused() async throws {
        try await withSidecar { stub in
            stub.reply("/embed/text", .init(json: answerJSON([[1, 0]], dimension: 3)))
            await #expect(throws: EmbeddingError.malformedResponse("a vector is not 3 wide")) {
                try await stub.provider().embed(texts: ["x"])
            }
        }
    }

    @Test func statusCodesSayWhichFailure() async throws {
        try await withSidecar { stub in
            stub.reply("/embed/text",
                       .init(status: .unauthorized, json: #"{"error":"missing or wrong token"}"#),
                       .init(status: .internalServerError, json: #"{"error":"boom"}"#))
            let provider = stub.provider(token: "wrong")
            await #expect(throws: EmbeddingError.refused(status: 401, reason: "missing or wrong token")) {
                try await provider.embed(texts: ["x"])
            }
            await #expect(throws: EmbeddingError.unavailable("embed/text answered 500: boom")) {
                try await provider.embed(texts: ["x"])
            }
        }
    }

    @Test func aSlowSidecarTimesOutQuickly() async throws {
        try await withSidecar { stub in
            stub.reply("/embed/text", .init(json: answerJSON([[1, 0, 0]]), delay: .seconds(3)))
            let started = ContinuousClock.now
            do {
                _ = try await stub.provider(timeout: .milliseconds(300)).embed(texts: ["x"])
                Issue.record("expected a timeout")
            } catch let error as EmbeddingError {
                guard case .unavailable = error else { Issue.record("wrong error \(error)"); return }
            }
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }

    @Test func nothingListeningIsUnavailable() async throws {
        let app = try await Application.make(.testing)
        let provider = SidecarEmbeddingProvider(
            configuration: .init(baseURL: "http://127.0.0.1:9", token: sidecarToken), client: app.client)
        do {
            _ = try await provider.embed(texts: ["x"])
            Issue.record("expected a failure")
        } catch let error as EmbeddingError {
            if case .unavailable = error {} else { Issue.record("wrong error \(error)") }
        }
        try await app.asyncShutdown()
    }
}
