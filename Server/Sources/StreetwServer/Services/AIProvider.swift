// AIProvider.swift
// The server's only view of a language model — the six reader actions and the two background
// readings Phase 4 asks of one, and what each cost.
//
// **One protocol, per action rather than per prompt.** A generic "send these messages" seam
// would leave every route writing its own prompt and parsing its own answer, and the fake
// would have to answer prompts it cannot read. Here each action is one method with typed
// input and typed output, so `AnthropicProvider` owns the prompts and the parsing, and
// `FakeAIProvider` can answer every action deterministically from its input — which is what
// lets the whole flow run in a simulator against a local server with no key.
//
// **Every answer carries its bill**, and so does every failure that was billed (`AIFailure`):
// a reply whose tool input would not decode cost exactly as much as one that did, and the
// meter is a fact about the provider bill (`docs/credits.md`). A call the API refused before
// doing any work — a 429, a 529, a timeout — reports no usage, costs nothing and records
// nothing.
//
// See `docs/ai.md`.

import Crypto
import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

/// An answer, and what producing it cost — one entry per provider call it took.
struct AIAnswer<Value: Sendable>: Sendable {
    var value: Value
    var costs: [MeteredCost]
}

/// Every way a model call fails, said without the model's words: an error description ends
/// up in a log line, and a log line must never hold what anybody typed or what came back.
enum AIError: Error, Equatable, CustomStringConvertible {
    /// Not reachable, timed out, rate limited, overloaded or a 5xx. Worth asking again later.
    case unavailable(String)
    /// A 4xx other than 429: our request or our key is wrong, and asking again will not help.
    case refused(status: UInt, type: String)
    /// The answer did not have the shape the tool promised.
    case malformed(String)
    /// The model declined (`stop_reason: refusal`) or answered without calling the tool.
    case declined

    var description: String {
        switch self {
        case .unavailable(let why): "model unavailable: \(why)"
        case .refused(let status, let type): "model refused the request (\(status) \(type))"
        case .malformed(let why): "model answered badly: \(why)"
        case .declined: "model declined to answer"
        }
    }
}

/// A failed action, with whatever it was billed before it failed.
struct AIFailure: Error, CustomStringConvertible {
    var error: AIError
    var costs: [MeteredCost]

    init(_ error: AIError, costs: [MeteredCost] = []) {
        self.error = error
        self.costs = costs
    }

    var description: String { error.description }
}

/// One daily pick, as the model is told about it: the product in a few words, the wardrobe
/// partner as a description, and the rule. Never a photograph, a brand id or a save.
struct AIPickPrompt: Sendable, Hashable {
    /// The cache key and the answer's key.
    var key: String
    /// "Chore Jacket · Outerwear · Carhartt WIP".
    var product: String
    var anchor: String?
    var basis: String
}

/// What a sale banner's words say beyond the pattern's percentage and code.
struct AISaleReading: Sendable, Equatable {
    var endsAt: Date?
    var code: String?
    /// The fine print, in one line — "Excludes new arrivals and gift cards."
    var terms: String?
}

/// What a product page with no structured data says, read from its visible text.
struct AIPageReading: Sendable, Equatable {
    struct Size: Sendable, Equatable {
        var size: String
        var available: Bool?
    }
    var title: String
    var price: Double?
    var currency: String?
    var available: Bool?
    var sizes: [Size]
}

/// What a model read off one product's photographs — the alternative to the zero-shot reader
/// (`ProductReading`), off unless `PRODUCT_READING=haiku`.
struct AIPhotoReading: Sendable, Equatable {
    /// Zero-based, into the photographs sent; nil when none is a clean product shot.
    var productShot: Int?
    /// Already held to `StyleWords.vocabulary` and `StyleWords.maximum`.
    var styleWords: [String]
}

protocol AIProvider: Sendable {
    /// Whether "Show me more" can be offered.
    var supportsWebSearch: Bool { get }

    /// The thread rewritten in the `ShopQuery` grammar, with a line back and follow-ups.
    func readSearch(text: String, thread: [AISearchTurn]) async throws -> AIAnswer<AISearchReading>
    /// Product pages from the open web for a grammar text. `brandID` is always nil here;
    /// the route resolves it.
    func searchWeb(query: String, country: String?) async throws -> AIAnswer<[AIWebItem]>
    /// One line per pick, by `AIPickPrompt.key`. A pick missing from the answer keeps the
    /// phone's own reason.
    func wordPickReasons(_ picks: [AIPickPrompt]) async throws -> AIAnswer<[String: String]>
    /// One photograph of one garment, JPEG.
    func readScan(image: Data) async throws -> AIAnswer<AIScanReading>
    func judgeFit(pieces: [AIFitPiece]) async throws -> AIAnswer<AIFitVerdict>
    /// Candidates the model would keep, best first, as indexes into `candidates`. The route
    /// validates every index.
    func suggestForFit(fit: [AIFitPiece], candidates: [AIFitPiece]) async throws -> AIAnswer<[AIFitSuggestion]>
    func readSaleBanner(message: String, brand: String, today: Date) async throws -> AIAnswer<AISaleReading>
    /// Nil when the page is not one product.
    func readProductPage(text: String, url: URL) async throws -> AIAnswer<AIPageReading?>
    /// Which of a product's photographs (small renditions, in the shop's order) is the clean
    /// product shot, and its style words. Owner-paid background work.
    func readProductPhotos(imageURLs: [URL], title: String) async throws -> AIAnswer<AIPhotoReading>
}

// MARK: - Prices

/// What the provider charges, per model. **The one table**: every `MeteredCost` is computed
/// here from the usage the API reported, never estimated.
///
/// **Check every row against https://www.anthropic.com/pricing before launch, and whenever a
/// model is changed.** A wrong row is a wrong measurement, and credit prices are set from the
/// measurement (`GET /admin/costs`). Rows checked 2026-10-27 against the API reference.
enum AIPricing {
    struct Row: Sendable, Equatable {
        /// Dollars per million tokens — which is also millionths of a dollar per token.
        var input: Double
        var output: Double
    }

    /// Longest prefix first, so `claude-sonnet-5-5` is not priced as `claude-sonnet-5`.
    static let rows: [(prefix: String, row: Row)] = [
        ("claude-fable-5", Row(input: 10, output: 50)),
        ("claude-opus-5-5", Row(input: 4, output: 20)),
        ("claude-opus-5", Row(input: 5, output: 25)),
        ("claude-opus-4", Row(input: 5, output: 25)),
        ("claude-sonnet-5-5", Row(input: 2, output: 10)),
        ("claude-sonnet-5", Row(input: 2, output: 10)),
        ("claude-sonnet-4", Row(input: 3, output: 15)),
        ("claude-haiku-4-5", Row(input: 1, output: 5)),
    ]

    /// A model the table does not know is priced at the dearest row rather than at zero:
    /// an unknown cost recorded as nothing would read as a free action in the summary the
    /// prices are set from. Said in the log by the caller.
    static let fallback = Row(input: 10, output: 50)

    /// Ten dollars per thousand searches: ten thousand millionths each.
    static let webSearchMicros: Int64 = 10_000
    /// Cache reads are a tenth of input, cache writes (five-minute) one and a quarter. Nothing
    /// here asks for caching; they are priced in case a reply reports them anyway.
    static let cacheReadFactor = 0.1
    static let cacheWriteFactor = 1.25

    static func row(for model: String) -> Row? {
        rows.first { model.hasPrefix($0.prefix) }?.row
    }

    /// The API's `usage` object, as read.
    struct Usage: Sendable, Equatable {
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var webSearches = 0
    }

    static func cost(_ usage: Usage, model: String, action: CreditAction) -> MeteredCost {
        let row = row(for: model) ?? fallback
        let input = Double(usage.inputTokens) * row.input
            + Double(usage.cacheCreationTokens) * row.input * cacheWriteFactor
            + Double(usage.cacheReadTokens) * row.input * cacheReadFactor
        let output = Double(usage.outputTokens) * row.output
        // Rounded up, so a call is never recorded as cheaper than it was.
        let micros = Int64((input + output).rounded(.up)) + Int64(usage.webSearches) * webSearchMicros
        return MeteredCost(
            action: action,
            model: model,
            inputTokens: usage.inputTokens + usage.cacheCreationTokens + usage.cacheReadTokens,
            outputTokens: usage.outputTokens,
            costMicros: micros
        )
    }
}

// MARK: - Configuration

/// Everything AI on this deployment: the provider, the thread key and the owner's daily cap.
/// Nil on `Application` means AI is off, and `GET /v1/ai` says so.
struct AIService: Sendable {
    var provider: any AIProvider
    /// The key's bytes, not the key. swift-crypto's `SymmetricKey` is `Sendable` on Apple
    /// platforms (it is CryptoKit's there) and not on Linux, so holding one here compiles on
    /// the Mac and fails the deploy's build — the trap `AppleClientSecret.keyData` documents.
    private var threadSecret: Data
    /// What the owner pays per UTC day, at most, for work nobody asked for: background
    /// reading and daily-pick sentences.
    var backgroundDailyCapMicros: Int64

    /// Signs `AIThreadToken`s.
    var threadKey: SymmetricKey { SymmetricKey(data: threadSecret) }

    init(provider: any AIProvider, threadKey: SymmetricKey, backgroundDailyCapMicros: Int64) {
        self.provider = provider
        self.threadSecret = threadKey.withUnsafeBytes { Data($0) }
        self.backgroundDailyCapMicros = backgroundDailyCapMicros
    }

    static let defaultBackgroundCapMicros: Int64 = 1_000_000

    /// The service this environment describes, or nil — logged either way, because a variable
    /// that silently does nothing is how push stayed off for months.
    ///
    /// `AI_FAKE=true` is refused on a production environment, like `SIWA_TEST_TOKENS`: the fake
    /// answers anything for nothing, and a production server answering searches with it would
    /// look like a working feature.
    static func make(
        environment: [String: String],
        isProduction: Bool,
        client: any Client,
        logger: Logger
    ) -> AIService? {
        func value(_ key: String) -> String? {
            let trimmed = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        var provider: (any AIProvider)?
        if value("AI_FAKE") == "true" {
            if isProduction {
                logger.critical("ai: AI_FAKE is set on a production environment — ignored")
            } else {
                logger.warning("ai: on — FAKE provider (AI_FAKE), deterministic answers at no cost; local development only")
                provider = FakeAIProvider()
            }
        }
        if provider == nil {
            if let key = value("ANTHROPIC_API_KEY") {
                let models = AnthropicProvider.Models(
                    main: value("AI_MODEL") ?? AnthropicProvider.Models.defaultMain,
                    fast: value("AI_MODEL_FAST") ?? AnthropicProvider.Models.defaultFast
                )
                for model in [models.main, models.fast] where AIPricing.row(for: model) == nil {
                    logger.warning("ai: no price for \(model) — metered at the dearest row until AIPricing has one")
                }
                logger.notice("ai: on — Anthropic, \(models.main) for readers, \(models.fast) for background work")
                provider = AnthropicProvider(
                    transport: VaporAnthropicTransport(client: client, apiKey: key),
                    models: models
                )
            } else {
                logger.notice("ai: off — ANTHROPIC_API_KEY is not set")
                return nil
            }
        }
        guard let provider else { return nil }

        let threadKey: SymmetricKey
        if let secret = value("AI_THREAD_SECRET") {
            threadKey = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        } else {
            // Only costs a paid thread its follow-ups across a deploy or between instances.
            logger.notice("ai: AI_THREAD_SECRET not set — search threads are signed with a key made at boot")
            threadKey = SymmetricKey(size: .bits256)
        }

        var cap = defaultBackgroundCapMicros
        if let raw = value("AI_BACKGROUND_DAILY_CAP_MICROS") {
            if let parsed = Int64(raw), parsed >= 0 {
                cap = parsed
            } else {
                logger.warning("ai: AI_BACKGROUND_DAILY_CAP_MICROS is not a whole number — using \(cap)")
            }
        }
        logger.notice("ai: background reading capped at \(cap) micro-dollars a day")
        return AIService(provider: provider, threadKey: threadKey, backgroundDailyCapMicros: cap)
    }
}

struct AIServiceKey: StorageKey {
    typealias Value = AIService
}

extension Application {
    /// Settable so the suite can put the fake in after `configure`.
    var ai: AIService? {
        get { storage[AIServiceKey.self] }
        set { storage[AIServiceKey.self] = newValue }
    }
}

// MARK: - The owner's daily cap

/// Work nobody asked for — a sale banner's fine print, a page with no structured data, a
/// daily pick's sentence — is paid by the owner, metered with no account and no user, and
/// stops for the rest of the UTC day once it has cost `backgroundDailyCapMicros`. A reader's
/// own actions are never counted against it: they are paid in credits.
enum AIBackground {
    static func dayStart(of date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: date)
    }

    /// What owner-paid work has cost since midnight UTC.
    static func spentToday(now: Date = Date(), on db: any Database) async throws -> Int64 {
        guard let sql = db as? any SQLDatabase else { return 0 }
        let row = try await sql.raw("""
            SELECT CAST(COALESCE(SUM(cost_micros), 0) AS BIGINT) AS total FROM ai_costs \
            WHERE account_id IS NULL AND user_id IS NULL AND created_at >= \(bind: dayStart(of: now))
            """).first()
        return try row?.decode(column: "total", as: Int64.self) ?? 0
    }

    /// Whether there is any of today's allowance left. A call already started may take the
    /// day a little past the cap; the next one is refused.
    static func allows(_ service: AIService, now: Date = Date(), on db: any Database) async -> Bool {
        do {
            return try await spentToday(now: now, on: db) < service.backgroundDailyCapMicros
        } catch {
            return false
        }
    }

    /// Records every cost as nobody's.
    static func record(_ costs: [MeteredCost], now: Date = Date(), on db: any Database) async {
        for cost in costs {
            try? await CostMeter.record(cost, account: nil, user: nil, at: now, on: db)
        }
    }
}
