import Crypto
import Fluent
import FluentPostgresDriver
import Foundation
import StreetwCore
import Synchronization
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

// MARK: - Doubles

/// Replays recorded Messages API answers in order and keeps every request body it was sent.
final class ReplayTransport: AnthropicTransport {
    private let state: Mutex<(replies: [(UInt, String)], sent: [Data])>

    init(_ replies: [(UInt, String)]) {
        state = Mutex((replies, []))
    }

    func post(_ body: Data, timeout: Duration) async throws -> (status: UInt, body: Data) {
        try state.withLock { state in
            state.sent.append(body)
            guard !state.replies.isEmpty else { throw URLError(.timedOut) }
            let (status, text) = state.replies.removeFirst()
            return (status, Data(text.utf8))
        }
    }

    var sent: [JSONValue] {
        state.withLock { $0.sent.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
    }

    var raw: [String] {
        state.withLock { $0.sent.map { String(decoding: $0, as: UTF8.self) } }
    }
}

/// The fake, counting how often each action reached it — so a cache hit can be shown to
/// cost no call.
final class CountingProvider: AIProvider {
    let inner = FakeAIProvider()
    private let counts = Mutex<[String: Int]>([:])

    func count(_ name: String) -> Int { counts.withLock { $0[name] ?? 0 } }
    private func tick(_ name: String) { counts.withLock { $0[name, default: 0] += 1 } }

    var supportsWebSearch: Bool { true }
    func readSearch(text: String, thread: [AISearchTurn]) async throws -> AIAnswer<AISearchReading> {
        tick("search"); return try await inner.readSearch(text: text, thread: thread)
    }
    func searchWeb(query: String, country: String?) async throws -> AIAnswer<[AIWebItem]> {
        tick("web"); return try await inner.searchWeb(query: query, country: country)
    }
    func wordPickReasons(_ picks: [AIPickPrompt]) async throws -> AIAnswer<[String: String]> {
        tick("picks"); return try await inner.wordPickReasons(picks)
    }
    func readScan(image: Data) async throws -> AIAnswer<AIScanReading> {
        tick("scan"); return try await inner.readScan(image: image)
    }
    func judgeFit(pieces: [AIFitPiece]) async throws -> AIAnswer<AIFitVerdict> {
        tick("judge"); return try await inner.judgeFit(pieces: pieces)
    }
    func suggestForFit(fit: [AIFitPiece], candidates: [AIFitPiece]) async throws -> AIAnswer<[AIFitSuggestion]> {
        tick("suggest"); return try await inner.suggestForFit(fit: fit, candidates: candidates)
    }
    func readSaleBanner(message: String, brand: String, today: Date) async throws -> AIAnswer<AISaleReading> {
        tick("sale"); return try await inner.readSaleBanner(message: message, brand: brand, today: today)
    }
    func readProductPage(text: String, url: URL) async throws -> AIAnswer<AIPageReading?> {
        tick("page"); return try await inner.readProductPage(text: text, url: url)
    }
}

/// Fails every action after being billed for it, as a reply whose tool input would not decode is.
struct BilledFailureProvider: AIProvider {
    static let cost = MeteredCost(action: .scan, model: "claude-sonnet-5-5", inputTokens: 900, outputTokens: 40, costMicros: 2_200)
    var supportsWebSearch: Bool { true }
    private func fail<T>() throws -> T { throw AIFailure(.malformed("test"), costs: [Self.cost]) }
    func readSearch(text: String, thread: [AISearchTurn]) async throws -> AIAnswer<AISearchReading> { try fail() }
    func searchWeb(query: String, country: String?) async throws -> AIAnswer<[AIWebItem]> { try fail() }
    func wordPickReasons(_ picks: [AIPickPrompt]) async throws -> AIAnswer<[String: String]> { try fail() }
    func readScan(image: Data) async throws -> AIAnswer<AIScanReading> { try fail() }
    func judgeFit(pieces: [AIFitPiece]) async throws -> AIAnswer<AIFitVerdict> { try fail() }
    func suggestForFit(fit: [AIFitPiece], candidates: [AIFitPiece]) async throws -> AIAnswer<[AIFitSuggestion]> { try fail() }
    func readSaleBanner(message: String, brand: String, today: Date) async throws -> AIAnswer<AISaleReading> { try fail() }
    func readProductPage(text: String, url: URL) async throws -> AIAnswer<AIPageReading?> { try fail() }
}

// MARK: - Recorded answers

/// A Messages API reply carrying one tool call, shaped as the API sends it.
private func toolReply(
    _ name: String,
    input: String,
    model: String = "claude-sonnet-5-5",
    input inputTokens: Int = 1200,
    output: Int = 300,
    stop: String = "tool_use",
    extraBlocks: String = "",
    searches: Int? = nil
) -> String {
    let serverTool = searches.map { #","server_tool_use":{"web_search_requests":\#($0)}"# } ?? ""
    return """
    {"id":"msg_01","type":"message","role":"assistant","model":"\(model)",
     "content":[\(extraBlocks){"type":"thinking","thinking":"","signature":"sig"},
       {"type":"tool_use","id":"toolu_01","name":"\(name)","input":\(input)}],
     "stop_reason":"\(stop)","stop_sequence":null,
     "usage":{"input_tokens":\(inputTokens),"output_tokens":\(output),
       "cache_creation_input_tokens":0,"cache_read_input_tokens":0\(serverTool)}}
    """
}

private func errorReply(_ type: String) -> String {
    #"{"type":"error","error":{"type":"\#(type)","message":"Overloaded"}}"#
}

private func provider(_ replies: [(UInt, String)], main: String = "claude-sonnet-5-5") -> (AnthropicProvider, ReplayTransport) {
    let transport = ReplayTransport(replies)
    return (AnthropicProvider(transport: transport, models: .init(main: main, fast: "claude-haiku-4-5-20251001")), transport)
}

/// The failure an action threw, or nil when it did not throw one.
private func failure<T>(_ work: () async throws -> T) async -> AIFailure? {
    do { _ = try await work(); return nil } catch { return error as? AIFailure }
}

// MARK: - The provider

@Suite("AI: the Anthropic provider")
struct AnthropicProviderTests {
    @Test("A search reading comes from the tool's input, priced from the reported usage")
    func searchReading() async throws {
        let (provider, transport) = provider([(200, toolReply(
            "read_search",
            input: #"{"query":"black suit under 400 no wool formal","suggestions":["cheaper","in navy"]}"#
        ))])
        let answer = try await provider.readSearch(text: "black suit under 400, not wool", thread: [])
        #expect(answer.value.query == "black suit under 400 no wool formal")
        #expect(answer.value.suggestions == ["cheaper", "in navy"])
        #expect(answer.value.reply == nil)
        // 1,200 in at $2/MTok and 300 out at $10/MTok: 2,400 + 3,000 millionths.
        #expect(answer.costs == [MeteredCost(action: .search, model: "claude-sonnet-5-5", inputTokens: 1200, outputTokens: 300, costMicros: 5_400)])

        // Sonnet 5.5 refuses a forced tool, so it is asked for, strictly.
        let body = try #require(transport.sent.first)
        #expect(body["tool_choice"] == ["type": "auto"])
        #expect(body["tools"]?.array?.first?["strict"] == true)
        #expect(body["output_config"]?["effort"] == "low")
        #expect(body["temperature"] == nil)
        // Whole numbers go out as integers: the API types `max_tokens` as one.
        #expect(transport.raw.first?.contains(#""max_tokens":2048"#) == true)
    }

    @Test("Haiku is forced onto the tool and sent no effort")
    func haikuForced() async throws {
        let (provider, transport) = provider([(200, toolReply(
            "word_reasons", input: #"{"reasons":[{"key":"k1","reason":"Goes with your black chore jacket"},{"key":"zz","reason":"x"}]}"#,
            model: "claude-haiku-4-5-20251001", input: 400, output: 30
        ))])
        let answer = try await provider.wordPickReasons([
            AIPickPrompt(key: "k1", product: "Loafer · Shoes · Example", anchor: "black chore jacket", basis: "colour")
        ])
        // A key nobody asked about is dropped.
        #expect(answer.value == ["k1": "Goes with your black chore jacket"])
        #expect(answer.costs.first?.costMicros == Int64(400 * 1 + 30 * 5))
        let body = try #require(transport.sent.first)
        #expect(body["tool_choice"] == ["type": "tool", "name": "word_reasons"])
        #expect(body["output_config"] == nil)
        #expect(body["tools"]?.array?.first?["strict"] == nil)
    }

    @Test("Web results are held to the URLs the search returned, and searches are priced")
    func webSearch() async throws {
        let results = """
        {"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"black suit"}},
        {"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[
          {"type":"web_search_result","url":"https://www.shop.example/products/suit","title":"Suit","encrypted_content":"x","page_age":null}]},
        """
        let (provider, transport) = provider([(200, toolReply(
            "report_products",
            input: #"{"items":[{"title":"Black Suit","shop":"Shop","url":"https://shop.example/products/suit/","price":380,"currency":"eur"},{"title":"Made up","shop":"Nowhere","url":"https://invented.example/p/1"}]}"#,
            input: 20_000, output: 800, extraBlocks: results, searches: 2
        ))])
        let answer = try await provider.searchWeb(query: "black suit under 400", country: "DE")
        #expect(answer.value.map(\.title) == ["Black Suit"])
        #expect(answer.value.first?.currency == "EUR")
        // 20,000 × 2 + 800 × 10 + two searches at a cent each.
        #expect(answer.costs.first?.costMicros == Int64(40_000 + 8_000 + 20_000))

        let body = try #require(transport.sent.first)
        let tools = try #require(body["tools"]?.array)
        #expect(tools.first?["type"] == "web_search_20260209")
        #expect(tools.first?["user_location"]?["country"] == "DE")
        #expect(body["tool_choice"] == ["type": "auto"])
    }

    @Test("A paused turn is resumed with its own content, and both calls are metered")
    func pauseTurn() async throws {
        let paused = """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5",
         "content":[{"type":"server_tool_use","id":"s1","name":"web_search","input":{"query":"q"}}],
         "stop_reason":"pause_turn","usage":{"input_tokens":100,"output_tokens":10,"server_tool_use":{"web_search_requests":1}}}
        """
        let (provider, transport) = provider([
            (200, paused),
            (200, toolReply("report_products", input: #"{"items":[]}"#, input: 200, output: 20)),
        ])
        let answer = try await provider.searchWeb(query: "q", country: nil)
        #expect(answer.value.isEmpty)
        let expected: [Int64] = [200 + 100 + 10_000, 400 + 200]
        #expect(answer.costs.map(\.costMicros) == expected)
        let second = try #require(transport.sent.last)
        #expect(second["messages"]?.array?.count == 2)
        #expect(second["messages"]?.array?.last?["role"] == "assistant")
    }

    @Test("A 429 is unavailable at no cost, and is not retried")
    func rateLimited() async {
        let (provider, transport) = provider([(429, errorReply("rate_limit_error")), (200, "{}")])
        let failed = await failure { try await provider.readSearch(text: "x", thread: []) }
        #expect(failed?.error == .unavailable("429 rate_limit_error"))
        #expect(failed?.costs.isEmpty == true)
        #expect(transport.sent.count == 1)
    }

    @Test("A 529 is retried once; a second is unavailable")
    func overloaded() async throws {
        let (once, _) = provider([
            (529, errorReply("overloaded_error")),
            (200, toolReply("read_search", input: #"{"query":"tee","suggestions":[]}"#)),
        ])
        #expect(try await once.readSearch(text: "tee", thread: []).value.query == "tee")

        let (twice, transport) = provider([(529, errorReply("overloaded_error")), (529, errorReply("overloaded_error"))])
        let failed = await failure { try await twice.readSearch(text: "tee", thread: []) }
        #expect(failed?.error == .unavailable("529 overloaded_error"))
        #expect(transport.sent.count == 2)
    }

    @Test("A 400 is refused, with the error type and none of the message")
    func refused() async {
        let (provider, _) = provider([(400, errorReply("invalid_request_error"))])
        let failed = await failure { try await provider.readSearch(text: "x", thread: []) }
        #expect(failed?.error == .refused(status: 400, type: "invalid_request_error"))
    }

    @Test("Tool input that does not decode is malformed, and still billed")
    func malformedInput() async {
        let (provider, _) = provider([(200, toolReply("read_search", input: #"{"reply":"no query here"}"#))])
        let failed = await failure { try await provider.readSearch(text: "x", thread: []) }
        #expect(failed?.error == .malformed("read_search input did not decode"))
        #expect(failed?.costs.first?.costMicros == 5_400)
    }

    @Test("A refusal, or an answer with no tool call, is declined and billed")
    func declined() async {
        let refusal = """
        {"type":"message","model":"claude-sonnet-5-5","content":[],"stop_reason":"refusal",
         "stop_details":{"type":"refusal","category":null},"usage":{"input_tokens":50,"output_tokens":0}}
        """
        let prose = """
        {"type":"message","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Here you go"}],
         "stop_reason":"end_turn","usage":{"input_tokens":50,"output_tokens":5}}
        """
        for reply in [refusal, prose] {
            let (provider, _) = provider([(200, reply)])
            let failed = await failure { try await provider.readScan(image: Data([0xFF, 0xD8, 0xFF])) }
            #expect(failed?.error == .declined)
            #expect(failed?.costs.count == 1)
        }
    }

    @Test("A scan sends its photograph as base64 JPEG; a fit piece by URL as a URL source")
    func images() async throws {
        let (scanner, scanned) = provider([(200, toolReply("read_garment", input: """
            {"slot":"outerwear","type":"chore jacket","colours":["Black"],"description":"d","search_text":"black chore jacket","is_garment":true}
            """))])
        _ = try await scanner.readScan(image: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let image = try #require(scanned.sent.first?["messages"]?.array?.first?["content"]?.array?.first)
        #expect(image["source"]?["type"] == "base64")
        #expect(image["source"]?["media_type"] == "image/jpeg")
        #expect(image["source"]?["data"] == .string(Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()))

        let (judge, judged) = provider([(200, toolReply("judge_fit", input: #"{"verdict":"works","summary":"s"}"#))])
        _ = try await judge.judgeFit(pieces: [
            AIFitPiece(slot: "top", title: "Tee", imageURL: URL(string: "https://cdn.example/tee.jpg")),
            AIFitPiece(slot: "bottom", title: "Jeans", image: Data([0xFF, 0xD8, 0xFF])),
        ])
        let content = try #require(judged.sent.first?["messages"]?.array?.first?["content"]?.array)
        let sources = content.compactMap { $0["source"]?["type"]?.string }
        #expect(sources == ["url", "base64"])
    }

    @Test("A sale reading's day is the end of that day, UTC")
    func saleDay() async throws {
        let (provider, _) = provider([(200, toolReply(
            "read_sale", input: #"{"ends_on":"2026-11-01","terms":"Excludes gift cards"}"#, model: "claude-haiku-4-5-20251001"
        ))])
        let answer = try await provider.readSaleBanner(message: "30% off ends Sunday", brand: "Shop", today: Date(timeIntervalSince1970: 1_792_843_200))
        #expect(answer.value.endsAt == Date(timeIntervalSince1970: 1_793_577_599))
        #expect(answer.value.terms == "Excludes gift cards")
        #expect(answer.value.code == nil)
    }
}

@Suite("AI: prices and models")
struct AIPricingTests {
    @Test("Cache tokens are priced as reads and writes; a model nobody priced is priced dearest")
    func arithmetic() {
        let usage = AIPricing.Usage(inputTokens: 1000, outputTokens: 100, cacheCreationTokens: 1000, cacheReadTokens: 10_000)
        let cost = AIPricing.cost(usage, model: "claude-haiku-4-5-20251001", action: .pickReason)
        // 1,000 + 1,250 + 1,000 in, 500 out.
        #expect(cost.costMicros == 3_750)
        #expect(cost.inputTokens == 12_000)

        let unknown = AIPricing.cost(AIPricing.Usage(inputTokens: 1, outputTokens: 1), model: "claude-unknown-9", action: .search)
        #expect(unknown.costMicros == 60)
        // The longest prefix wins.
        #expect(AIPricing.row(for: "claude-sonnet-5-5")?.input == 2)
        #expect(AIPricing.row(for: "claude-opus-5-5")?.input == 4)
        #expect(AIPricing.row(for: "claude-opus-5")?.input == 5)
    }

    @Test("Which models take a forced tool, which search tool, and effort")
    func traits() {
        #expect(AnthropicProvider.ModelTraits.of("claude-haiku-4-5-20251001")
            == .init(forcesToolChoice: true, webSearchTool: "web_search_20250305", takesEffort: false))
        #expect(AnthropicProvider.ModelTraits.of("claude-sonnet-5-5")
            == .init(forcesToolChoice: false, webSearchTool: "web_search_20260209", takesEffort: true))
        #expect(AnthropicProvider.ModelTraits.of("claude-sonnet-5").forcesToolChoice)
        #expect(!AnthropicProvider.ModelTraits.of("claude-opus-5-5").forcesToolChoice)
    }

    @Test("AI_FAKE is refused on production; no key is off")
    func configuration() {
        let app = Application(.testing)
        defer { app.shutdown() }
        #expect(AIService.make(environment: ["AI_FAKE": "true"], isProduction: true, client: app.client, logger: app.logger) == nil)
        #expect(AIService.make(environment: [:], isProduction: false, client: app.client, logger: app.logger) == nil)
        let fake = AIService.make(environment: ["AI_FAKE": "true", "AI_BACKGROUND_DAILY_CAP_MICROS": "250"],
                                  isProduction: false, client: app.client, logger: app.logger)
        #expect(fake?.provider is FakeAIProvider)
        #expect(fake?.backgroundDailyCapMicros == 250)
        let real = AIService.make(environment: ["ANTHROPIC_API_KEY": "test"], isProduction: true, client: app.client, logger: app.logger)
        #expect(real?.provider is AnthropicProvider)
    }
}

// MARK: - Threads

@Suite("AI: thread tokens")
struct AIThreadTokenTests {
    let key = SymmetricKey(size: .bits256)
    let account = UUID()
    let profile = UUID()
    let start = Date(timeIntervalSince1970: 1_792_843_200)

    private func token(turns: Int = 1) throws -> String {
        try AIThreadToken(account: account, profile: profile, issuedAt: start, turns: turns).signed(with: key)
    }

    @Test("A token round-trips inside its thirty minutes")
    func roundTrip() throws {
        let verified = AIThreadToken.verify(try token(), key: key, account: account, profile: profile, now: start.addingTimeInterval(29 * 60))
        #expect(try verified.get().turns == 1)
        #expect(try verified.get().turnsLeft == 5)
    }

    @Test("Expired, tampered, spent, another account's or another profile's — each is refused")
    func refusals() throws {
        let good = try token()
        #expect(AIThreadToken.verify(good, key: key, account: account, profile: profile, now: start.addingTimeInterval(30 * 60))
            == .failure(.expired))
        #expect(AIThreadToken.verify(good, key: SymmetricKey(size: .bits256), account: account, profile: profile, now: start)
            == .failure(.forged))
        #expect(AIThreadToken.verify(good, key: key, account: UUID(), profile: profile, now: start) == .failure(.otherAccount))
        #expect(AIThreadToken.verify(good, key: key, account: account, profile: UUID(), now: start) == .failure(.otherProfile))
        #expect(AIThreadToken.verify(try token(turns: 6), key: key, account: account, profile: profile, now: start) == .failure(.spent))
        #expect(AIThreadToken.verify("nonsense", key: key, account: account, profile: profile, now: start) == .failure(.malformed))

        // A payload edited to buy more turns no longer matches its signature.
        let parts = good.split(separator: ".").map(String.init)
        var payload = try #require(Data(base64URL: parts[0]))
        payload = Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\"t\":1", with: "\"t\":0").utf8)
        let edited = payload.base64URLEncodedString() + "." + parts[1]
        #expect(AIThreadToken.verify(edited, key: key, account: account, profile: profile, now: start) == .failure(.forged))
    }
}

// MARK: - Routes

private func withAI(
    _ provider: any AIProvider = FakeAIProvider(),
    cap: Int64 = AIService.defaultBackgroundCapMicros,
    _ body: (Application) async throws -> Void
) async throws {
    try await withServer { app in
        app.ai = AIService(provider: provider, threadKey: SymmetricKey(size: .bits256), backgroundDailyCapMicros: cap)
        try await body(app)
    }
}

/// A registered device whose user is on a new account, following `brands`.
private func member(_ app: Application, follows brands: [UUID] = [], unlimited: Bool = false) async throws -> (headers: HTTPHeaders, account: UUID, user: UserModel) {
    let headers = try await deviceAuth(app)
    let token = headers.bearerAuthorization!.token
    let device = try #require(try await DeviceModel.query(on: app.db).filter(\.$authToken == token).first())
    let user = try await device.$user.get(on: app.db)
    let account = AccountModel(appleSubject: "subject-\(UUID().uuidString)")
    account.unlimitedCredits = unlimited
    try await account.save(on: app.db)
    user.$account.id = try account.requireID()
    try await user.save(on: app.db)
    for brand in brands {
        try await app.testing().test(.POST, "v1/follows", headers: headers, beforeRequest: { req in
            try req.content.encode(FollowBrand(brandID: brand))
        })
    }
    return (headers, try account.requireID(), user)
}

/// A followed shop with one product in it.
private func shopWithJacket(_ app: Application, slug: String = "shop.example") async throws -> UUID {
    let brand = BrandModel(name: "Shop", slug: slug, website: "https://\(slug)", instagramHandle: nil, usesGeneratedName: false)
    brand.currency = "USD"
    try await brand.save(on: app.db)
    let brandID = try brand.requireID()
    let source = SourceModel(brandID: brandID, kind: .shopify, url: "https://\(slug)")
    try await source.save(on: app.db)
    let product = ProductModel(brandID: brandID, sourceID: try source.requireID(), item: FetchedItem(
        externalID: "shopify:7001",
        title: "Black Chore Jacket",
        linkURL: URL(string: "https://\(slug)/products/chore"),
        imageURLStrings: ["https://cdn.example.com/chore.jpg"],
        publishedAt: Date().addingTimeInterval(-86_400),
        kind: .product,
        priceText: "$180",
        priceAmount: 180,
        productType: "Jackets"
    ))
    try await product.save(on: app.db)
    try await VariantModel(productID: try product.requireID(), info: VariantInfo(id: "v1", title: "M", available: true, size: "M")).save(on: app.db)
    return brandID
}

private func call<Body: Content, Answer: Decodable>(
    _ app: Application,
    _ path: String,
    method: HTTPMethod = .POST,
    headers: HTTPHeaders,
    body: Body? = Optional<String>.none,
    as: Answer.Type
) async throws -> (HTTPStatus, Answer?, String) {
    var out: (HTTPStatus, Answer?, String) = (.internalServerError, nil, "")
    try await app.testing().test(method, path, headers: headers, beforeRequest: { req in
        if let body { try req.content.encode(body) }
    }, afterResponse: { res async throws in
        out = (res.status, res.status == .ok ? try res.content.decode(Answer.self) : nil, res.body.string)
    })
    return out
}

extension AISearchRequest: @retroactive Content {}
extension AIWebSearchRequest: @retroactive Content {}
extension AIPickReasons: @retroactive Content {}
extension AIScanRequest: @retroactive Content {}
extension AIFitJudgeRequest: @retroactive Content {}
extension AIFitSuggestRequest: @retroactive Content {}

private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x11, count: 64))

@Suite("AI: routes")
struct AIRouteTests {
    @Test("GET /v1/ai says off when there is no provider, and the prices when there is")
    func status() async throws {
        try await withServer { app in
            let headers = try await deviceAuth(app)
            let (_, off, _) = try await call(app, "v1/ai", method: .GET, headers: headers, as: AIStatus.self)
            #expect(off?.available == false)
            #expect(off?.signedIn == false)

            app.ai = AIService(provider: FakeAIProvider(), threadKey: SymmetricKey(size: .bits256), backgroundDailyCapMicros: 0)
            let signedIn = try await member(app)
            let (_, on, _) = try await call(app, "v1/ai", method: .GET, headers: signedIn.headers, as: AIStatus.self)
            #expect(on?.available == true)
            #expect(on?.webSearch == true)
            #expect(on?.signedIn == true)
            #expect(on?.credits == ["search": 1, "web_search": 3, "scan": 2, "fit_judge": 1, "fit_suggest": 1])

            // Off, every action says so rather than failing some other way.
            app.ai = nil
            let (status, _, _) = try await call(app, "v1/ai/search", headers: signedIn.headers,
                                                body: AISearchRequest(text: "tee"), as: AISearchResponse.self)
            #expect(status == .serviceUnavailable)
        }
    }

    @Test("Search needs an account: 403 signed out")
    func signedOut() async throws {
        try await withAI { app in
            let headers = try await deviceAuth(app)
            let (status, _, body) = try await call(app, "v1/ai/search", headers: headers,
                                                   body: AISearchRequest(text: "black chore jacket"), as: AISearchResponse.self)
            #expect(status == .forbidden)
            #expect(body.contains("Sign in to use credits"))
        }
    }

    @Test("Search costs one credit, runs the server's own search, and a follow-up is free")
    func searchThread() async throws {
        try await withAI { app in
            let brand = try await shopWithJacket(app)
            let reader = try await member(app, follows: [brand])

            let (status, first, text) = try await call(app, "v1/ai/search", headers: reader.headers,
                                                       body: AISearchRequest(text: "Black chore jacket"), as: AISearchResponse.self)
            #expect(status == .ok, "\(text)")
            let answer = try #require(first)
            #expect(answer.reading.query == "black chore jacket")
            #expect(answer.results.exact.map(\.card.title) == ["Black Chore Jacket"])
            #expect(answer.charge == AICharge(credits: 1, balance: 49))
            #expect(answer.turnsLeft == 5)

            let (_, second, _) = try await call(app, "v1/ai/search", headers: reader.headers, body: AISearchRequest(
                text: "in canvas",
                thread: [AISearchTurn(text: "Black chore jacket", query: answer.reading.query)],
                threadToken: answer.threadToken
            ), as: AISearchResponse.self)
            #expect(second?.charge == AICharge(credits: 0, balance: 49))
            #expect(second?.turnsLeft == 4)
            #expect(second?.reading.query == "black chore jacket in canvas")

            // A token from somewhere else starts a new, paid thread.
            let (_, forged, _) = try await call(app, "v1/ai/search", headers: reader.headers, body: AISearchRequest(
                text: "tee", threadToken: answer.threadToken + "x"
            ), as: AISearchResponse.self)
            #expect(forged?.charge == AICharge(credits: 1, balance: 48))

            // The meter saw three calls; usage counts two searches, because the follow-up was not one.
            #expect(try await CostRecordModel.query(on: app.db).count() == 3)
            let usage = try await CreditLedger.usage(of: reader.account, now: Date(), on: app.db)
            #expect(usage == [CreditUsage(action: "search", count: 2)])
        }
    }

    @Test("402 when the balance cannot pay, and the provider is never asked")
    func insufficient() async throws {
        let counting = CountingProvider()
        try await withAI(counting) { app in
            let reader = try await member(app)
            try await CreditLedger.grant(credits: -CreditPolicy.monthlyAllowance, account: reader.account, on: app.db)
            let (status, _, _) = try await call(app, "v1/ai/search", headers: reader.headers,
                                                body: AISearchRequest(text: "tee"), as: AISearchResponse.self)
            #expect(status == .paymentRequired)
            #expect(counting.count("search") == 0)
        }
    }

    @Test("A failed action is undone and still metered")
    func failureUndone() async throws {
        try await withAI(BilledFailureProvider()) { app in
            let reader = try await member(app)
            let (status, _, body) = try await call(app, "v1/ai/scan", headers: reader.headers,
                                                   body: AIScanRequest(image: jpeg), as: AIScanResponse.self)
            #expect(status == .badGateway)
            #expect(body.contains("credits were not used"))
            #expect(!body.contains("test"))
            // The allowance, the spend, and its reversal: the balance is whole again.
            #expect(try await CreditLedger.balance(of: reader.account, on: app.db) == CreditPolicy.monthlyAllowance)
            let reasons = try await CreditEntryModel.query(on: app.db).all().map(\.reason).sorted()
            #expect(reasons == ["allowance", "reversal", "spend"])
            let costs = try await CostRecordModel.query(on: app.db).all()
            #expect(costs.map(\.costMicros) == [BilledFailureProvider.cost.costMicros])
            #expect(costs.first?.$account.id == reader.account)
            #expect(try await CreditLedger.usage(of: reader.account, now: Date(), on: app.db).isEmpty)
        }
    }

    @Test("Show me more costs three, and a watched shop comes back with its brand")
    func web() async throws {
        try await withAI { app in
            let watched = try await shopWithJacket(app, slug: "www.\(FakeAIProvider.webHost)")
            let reader = try await member(app)
            let (status, answer, text) = try await call(app, "v1/ai/search/web", headers: reader.headers,
                                                        body: AIWebSearchRequest(query: "black chore jacket", country: "gb"),
                                                        as: AIWebSearchResponse.self)
            #expect(status == .ok, "\(text)")
            #expect(answer?.items.count == 2)
            #expect(answer?.items.first?.brandID == watched)
            #expect(answer?.items.last?.brandID == nil)
            #expect(answer?.charge == AICharge(credits: 3, balance: 47))
        }
    }

    @Test("Pick reasons are free, cached with no user on the row, and a cache hit costs no call")
    func picks() async throws {
        let counting = CountingProvider()
        try await withAI(counting) { app in
            _ = try await shopWithJacket(app)
            let headers = try await deviceAuth(app)
            let ask = AIPickReasons(picks: [
                AIPickReasonRequest(productExternalID: "shopify:7001", anchor: "black loafers", basis: "colour"),
                AIPickReasonRequest(productExternalID: "shopify:404", anchor: nil, basis: "missing"),
            ])
            let (status, first, _) = try await call(app, "v1/ai/picks/reasons", headers: headers, body: ask, as: AIPickReasonsResponse.self)
            #expect(status == .ok)
            // The product the server does not hold keeps the phone's reason.
            #expect(first?.reasons == ["shopify:7001": "Goes with your black loafers"])
            #expect(counting.count("picks") == 1)
            #expect(try await AIPickReasonModel.query(on: app.db).count() == 1)
            let costs = try await CostRecordModel.query(on: app.db).all()
            #expect(costs.count == 1)
            #expect(costs.first?.$account.id == nil && costs.first?.$user.id == nil)

            // Another device, the same description in other capitals: the cache answers.
            let other = try await deviceAuth(app)
            let again = AIPickReasons(picks: [AIPickReasonRequest(productExternalID: "shopify:7001", anchor: "Black Loafers", basis: "colour")])
            let (_, second, _) = try await call(app, "v1/ai/picks/reasons", headers: other, body: again, as: AIPickReasonsResponse.self)
            #expect(second?.reasons == ["shopify:7001": "Goes with your black loafers"])
            #expect(counting.count("picks") == 1)

            let tooMany = AIPickReasons(picks: Array(repeating: ask.picks[0], count: AIPicks.maxReasons + 1))
            let (refused, _, _) = try await call(app, "v1/ai/picks/reasons", headers: headers, body: tooMany, as: AIPickReasonsResponse.self)
            #expect(refused == .badRequest)
        }
    }

    @Test("Owner-paid work stops at the day's cap")
    func backgroundCap() async throws {
        let counting = CountingProvider()
        try await withAI(counting, cap: 1_000) { app in
            _ = try await shopWithJacket(app)
            let service = try #require(app.ai)
            #expect(await AIBackground.allows(service, on: app.db))
            // Yesterday's spending does not count; today's does, and a reader's never does.
            let yesterday = AIBackground.dayStart(of: Date()).addingTimeInterval(-60)
            let cost = MeteredCost(action: .saleReading, model: "claude-haiku-4-5-20251001", inputTokens: 1, outputTokens: 1, costMicros: 1_000)
            try await CostMeter.record(cost, account: nil, user: nil, at: yesterday, on: app.db)
            let reader = try await member(app)
            try await CostMeter.record(cost, account: reader.account, user: reader.user.id, on: app.db)
            #expect(await AIBackground.allows(service, on: app.db))
            try await CostMeter.record(cost, account: nil, user: nil, on: app.db)
            #expect(!(await AIBackground.allows(service, on: app.db)))

            let headers = try await deviceAuth(app)
            let ask = AIPickReasons(picks: [AIPickReasonRequest(productExternalID: "shopify:7001", anchor: nil, basis: "missing")])
            let (status, answer, _) = try await call(app, "v1/ai/picks/reasons", headers: headers, body: ask, as: AIPickReasonsResponse.self)
            #expect(status == .ok)
            #expect(answer?.reasons.isEmpty == true)
            #expect(counting.count("picks") == 0)
        }
    }

    @Test("A scan costs two; a non-JPEG and an oversized photograph are refused before any call")
    func scan() async throws {
        let counting = CountingProvider()
        try await withAI(counting) { app in
            let reader = try await member(app)
            let (status, answer, _) = try await call(app, "v1/ai/scan", headers: reader.headers,
                                                     body: AIScanRequest(image: jpeg), as: AIScanResponse.self)
            #expect(status == .ok)
            #expect(answer?.reading.slot == "outerwear")
            #expect(answer?.reading.searchText == "black chore jacket canvas")
            // No embedding service here, so the phone searches the text instead.
            #expect(answer?.similar == nil)
            #expect(answer?.charge == AICharge(credits: 2, balance: 48))

            let (png, _, _) = try await call(app, "v1/ai/scan", headers: reader.headers,
                                             body: AIScanRequest(image: Data([0x89, 0x50, 0x4E, 0x47])), as: AIScanResponse.self)
            #expect(png == .unsupportedMediaType)
            let huge = Data([0xFF, 0xD8, 0xFF]) + Data(count: AIScan.maxBytes)
            let (large, _, _) = try await call(app, "v1/ai/scan", headers: reader.headers,
                                               body: AIScanRequest(image: huge), as: AIScanResponse.self)
            #expect(large == .payloadTooLarge)
            #expect(counting.count("scan") == 1)
        }
    }

    @Test("Judging a fit costs one; a piece with two photographs, or none, is refused")
    func judge() async throws {
        try await withAI { app in
            let reader = try await member(app)
            let pieces = [
                AIFitPiece(slot: "top", title: "White tee", imageURL: URL(string: "https://cdn.example/tee.jpg")),
                AIFitPiece(slot: "bottom", title: "Black trousers", image: jpeg),
            ]
            let (status, answer, _) = try await call(app, "v1/ai/fits/judge", headers: reader.headers,
                                                     body: AIFitJudgeRequest(pieces: pieces), as: AIFitJudgeResponse.self)
            #expect(status == .ok)
            #expect(answer?.verdict.verdict == "works")
            #expect(answer?.charge == AICharge(credits: 1, balance: 49))

            let both = AIFitPiece(slot: "top", title: "x", imageURL: URL(string: "https://cdn.example/a.jpg"), image: jpeg)
            let (refused, _, _) = try await call(app, "v1/ai/fits/judge", headers: reader.headers,
                                                 body: AIFitJudgeRequest(pieces: [pieces[0], both]), as: AIFitJudgeResponse.self)
            #expect(refused == .badRequest)
            let none = AIFitPiece(slot: "top", title: "x")
            let (empty, _, _) = try await call(app, "v1/ai/fits/judge", headers: reader.headers,
                                               body: AIFitJudgeRequest(pieces: [pieces[0], none]), as: AIFitJudgeResponse.self)
            #expect(empty == .badRequest)
        }
    }

    @Test("Suggestions drop indexes the request did not offer")
    func suggest() async throws {
        try await withAI { app in
            let reader = try await member(app, unlimited: true)
            let url = URL(string: "https://cdn.example/p.jpg")
            let request = AIFitSuggestRequest(
                fit: [AIFitPiece(slot: "top", title: "Navy overshirt", imageURL: url)],
                candidates: [
                    AIFitPiece(slot: "bottom", title: "Grey trousers", imageURL: url),
                    AIFitPiece(slot: "bottom", title: "Clash shorts", imageURL: url),
                    AIFitPiece(slot: "footwear", title: "Loafers", imageURL: url),
                ]
            )
            let (status, answer, _) = try await call(app, "v1/ai/fits/suggest", headers: reader.headers,
                                                     body: request, as: AIFitSuggestResponse.self)
            #expect(status == .ok)
            #expect(answer?.suggestions.map(\.candidate) == [2, 0])
            // Unlimited: nothing taken, no balance printed, and still metered.
            #expect(answer?.charge == AICharge(credits: 0, balance: nil))
            #expect(try await CostRecordModel.query(on: app.db).count() == 1)
        }
    }

    @Test("A suggestion's validation in isolation: out of range, negative and repeated indexes go")
    func suggestionValidation() {
        let raw = [
            AIFitSuggestion(candidate: 1, reason: "a"), AIFitSuggestion(candidate: -1, reason: "b"),
            AIFitSuggestion(candidate: 1, reason: "c"), AIFitSuggestion(candidate: 3, reason: "d"),
            AIFitSuggestion(candidate: 0, reason: "  e  "),
        ]
        #expect(AIText.suggestions(raw, candidates: 3) == [
            AIFitSuggestion(candidate: 1, reason: "a"), AIFitSuggestion(candidate: 0, reason: "e"),
        ])
        #expect(AIText.verdict(AIFitVerdict(verdict: "great", summary: "s"), pieces: 2) == nil)
        #expect(AIText.verdict(AIFitVerdict(verdict: "Clashes", summary: "s", swap: 5), pieces: 2)?.swap == nil)
    }
}

// MARK: - Background reading

@Suite("AI: background reading")
struct AIBackgroundReadingTests {
    private let shipping = #"<html><body><div class="announcement-bar"><p>Free shipping over $100</p></div></body></html>"#
    private let sale = #"<html><body><div class="announcement-bar"><p>30% off everything, ends Sunday</p></div></body></html>"#

    /// A followed brand whose bar has had its baseline read, now due again with a sale up.
    private func brandWithNewSale(_ app: Application) async throws -> SaleBanners {
        let brand = BrandModel(name: "Shop", slug: "shop.example", website: "https://shop.example", instagramHandle: nil, usesGeneratedName: false)
        try await brand.save(on: app.db)
        let user = UserModel()
        try await user.save(on: app.db)
        try await FollowModel(userID: try user.requireID(), brandID: try brand.requireID(), mode: .everything).save(on: app.db)
        let http = StubHTTP()
        http.stub("/", body: shipping)
        let banners = SaleBanners(app: app, http: http)
        await banners.checkDue()
        http.stub("/", body: sale)
        brand.bannerCheckAt = Date().addingTimeInterval(-1)
        try await brand.save(on: app.db)
        return banners
    }

    private func saleEvent(_ app: Application) async throws -> EventModel? {
        try await EventModel.query(on: app.db).filter(\.$kind == UpdateKind.sale.rawValue).first()
    }

    @Test("A new sale's banner is read once, onto its event, and metered as nobody's")
    func saleRead() async throws {
        let counting = CountingProvider()
        try await withAI(counting) { app in
            let banners = try await brandWithNewSale(app)
            await banners.checkDue()
            let event = try #require(try await saleEvent(app))
            let ends = try #require(event.saleEndsAt)
            #expect(ends > Date().addingTimeInterval(6 * 86_400))
            #expect(event.saleTerms == "Fake reading: excludes gift cards.")
            #expect(counting.count("sale") == 1)
            let costs = try await CostRecordModel.query(on: app.db).all()
            #expect(costs.map(\.action) == ["sale_reading"])
            #expect(costs.first?.$account.id == nil && costs.first?.$user.id == nil)

            // The same bar next time is the same sale: not announced, not read.
            let brand = try #require(try await BrandModel.query(on: app.db).first())
            brand.bannerCheckAt = Date().addingTimeInterval(-1)
            try await brand.save(on: app.db)
            await banners.checkDue()
            #expect(counting.count("sale") == 1)
        }
    }

    @Test("With AI off, or the day's cap spent, the sale is announced without a reading")
    func saleUnread() async throws {
        try await withServer { app in
            let banners = try await brandWithNewSale(app)
            await banners.checkDue()
            let event = try #require(try await saleEvent(app))
            #expect(event.saleEndsAt == nil && event.saleTerms == nil)
        }
        let counting = CountingProvider()
        try await withAI(counting, cap: 0) { app in
            let banners = try await brandWithNewSale(app)
            await banners.checkDue()
            #expect(try await saleEvent(app) != nil)
            #expect(counting.count("sale") == 0)
        }
    }

    @Test("A reading is held to a plausible window, and a code only of code characters")
    func saleChecked() {
        let now = Date(timeIntervalSince1970: 1_792_843_200)
        #expect(AIBackgroundReading.checked(AISaleReading(endsAt: now.addingTimeInterval(400 * 86_400)), now: now) == nil)
        let read = AIBackgroundReading.checked(
            AISaleReading(endsAt: now.addingTimeInterval(86_400), code: " autumn25 ", terms: "  Excludes\n gift cards "), now: now
        )
        #expect(read == AISaleReading(endsAt: now.addingTimeInterval(86_400), code: "AUTUMN25", terms: "Excludes gift cards"))
        #expect(AIBackgroundReading.checked(AISaleReading(code: "use code at checkout"), now: now) == nil)
    }

    private func sitemap(_ slugs: [String]) -> String {
        let urls = slugs.map { "<url><loc>https://shop.example/products/\($0)</loc></url>" }.joined()
        return "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\(urls)</urlset>"
    }

    /// A page drawn by script with no structured data, whose words still say what it sells.
    private let plainPage = """
        <html><head><title>Plain Tee</title><script>window.x = 1</script></head>
        <body><h1>Plain Tee</h1><p>fake-product · Heavyweight cotton tee in white. $42. Sizes S M L. Add to bag.</p></body></html>
        """

    @Test("A new product's page with no structured data is read once, and announced with what it said")
    func pageRead() async throws {
        let counting = CountingProvider()
        try await withAI(counting) { app in
            let brand = BrandModel(name: "Shop", slug: "shop.example", website: "https://shop.example", instagramHandle: nil, usesGeneratedName: false)
            try await brand.save(on: app.db)
            try await SourceModel(brandID: try brand.requireID(), kind: .sitemap, url: "https://shop.example/sitemap.xml").save(on: app.db)
            let http = StubHTTP()
            http.stub("/sitemap.xml", body: sitemap(["hoodie"]))
            http.stub("/products/hoodie", body: plainPage)
            let poller = Poller(app: app, http: http)
            await poller.tick()
            // The baseline's rows are read for their pages, never by the model.
            #expect(counting.count("page") == 0)

            http.stub("/sitemap.xml", body: sitemap(["hoodie", "plain-tee"]))
            http.stub("/products/plain-tee", body: plainPage)
            let source = try #require(try await SourceModel.query(on: app.db).first())
            source.nextCheckAt = Date().addingTimeInterval(-1)
            try await source.save(on: app.db)
            await poller.tick()

            #expect(counting.count("page") == 1)
            let events = try await EventModel.query(on: app.db).with(\.$product).all()
            #expect(events.count == 1)
            let product = try #require(events.first?.product)
            #expect(product.title == "Fake Product")
            #expect(product.priceAmount == 42)
            let variants = try await VariantModel.query(on: app.db).filter(\.$product.$id == product.requireID()).all()
            #expect(Set(variants.compactMap(\.size)) == ["S", "M"])
            #expect(try await CostRecordModel.query(on: app.db).all().map(\.action) == ["page_reading"])
        }
    }

    @Test("Visible text leaves out scripts, styles and markup")
    func visibleText() {
        let text = AIBackgroundReading.visibleText(of: "<style>p{}</style><p>Tee &amp; shorts</p><script>var a='<p>no</p>'</script>  <b>£40</b>")
        #expect(text == "Tee & shorts £40")
        #expect(AIBackgroundReading.visibleText(of: String(repeating: "word ", count: 10_000)).count == AIBackgroundReading.pageTextLimit)
    }
}

// MARK: - On Postgres

/// The sums and the cache on the database production runs: a `BIGINT` sum comes back as a
/// `NUMERIC` there and must be cast, which SQLite never shows, and the search a thread runs is
/// the full-text index. Runs only when `STREETW_TEST_POSTGRES_URL` names a scratch database.
@Suite(
    "AI on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct AIPostgresTests {
    private func withPostgres(_ body: (Application) async throws -> Void) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"])
        setenv("ADMIN_TOKEN", testAdminToken, 1)
        let app = try await Application.make(.testing)
        var config = try SQLPostgresConfiguration(url: url)
        config.coreConfiguration.tls = .disable
        app.databases.use(.postgres(configuration: config, maxConnectionsPerEventLoop: 4), as: .psql)
        addMigrations(to: app)
        do {
            try await app.autoMigrate()
            app.ai = AIService(provider: CountingProvider(), threadKey: SymmetricKey(size: .bits256), backgroundDailyCapMicros: 5_000)
            try routes(app)
            try await app.asyncBoot()
            try await body(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("A thread is paid once and searched by the index; owner spending is summed by day")
    func threadAndCap() async throws {
        try await withPostgres { app in
            let brand = try await shopWithJacket(app)
            let reader = try await member(app, follows: [brand])
            let (status, first, text) = try await call(app, "v1/ai/search", headers: reader.headers,
                                                       body: AISearchRequest(text: "black jacket"), as: AISearchResponse.self)
            #expect(status == .ok, "\(text)")
            #expect(first?.results.exact.map(\.card.title) == ["Black Chore Jacket"])
            #expect(first?.charge == AICharge(credits: 1, balance: 49))
            let (_, second, _) = try await call(app, "v1/ai/search", headers: reader.headers, body: AISearchRequest(
                text: "chore", thread: [AISearchTurn(text: "black jacket", query: "black jacket")], threadToken: first?.threadToken
            ), as: AISearchResponse.self)
            #expect(second?.charge == AICharge(credits: 0, balance: 49))

            let service = try #require(app.ai)
            let cost = MeteredCost(action: .pageReading, model: "claude-haiku-4-5-20251001", inputTokens: 10, outputTokens: 1, costMicros: 4_000)
            try await CostMeter.record(cost, account: nil, user: nil, on: app.db)
            #expect(try await AIBackground.spentToday(on: app.db) == 4_000)
            #expect(await AIBackground.allows(service, on: app.db))
            try await CostMeter.record(cost, account: nil, user: nil, on: app.db)
            #expect(!(await AIBackground.allows(service, on: app.db)))
        }
    }

    @Test("A pick sentence is cached once under its unique key")
    func pickCache() async throws {
        try await withPostgres { app in
            _ = try await shopWithJacket(app)
            let headers = try await deviceAuth(app)
            let ask = AIPickReasons(picks: [AIPickReasonRequest(productExternalID: "shopify:7001", anchor: "grey trousers", basis: "colour")])
            for _ in 0..<2 {
                let (_, answer, _) = try await call(app, "v1/ai/picks/reasons", headers: headers, body: ask, as: AIPickReasonsResponse.self)
                #expect(answer?.reasons == ["shopify:7001": "Goes with your grey trousers"])
            }
            #expect(try await AIPickReasonModel.query(on: app.db).count() == 1)
        }
    }
}
