// AIRoutes.swift
// `/v1/ai/…` — the model-backed actions. In their own file so `routes.swift` gains one line.
//
// Every route is in the device-authenticated group, acts for `actingUserID()` (so
// `X-Profile-ID` chooses the profile), and spends from the account's one ledger through
// `AIAction.run`. **Nothing a reader typed or sent is logged or stored**: request bodies are
// never logged by Vapor (its route log line is the method and the path), errors name statuses
// and never the model's words, and the only text written down is a daily pick's sentence,
// keyed by a hash and naming nobody. See `docs/ai.md`.

import Crypto
import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

extension AIStatus: @retroactive Content {}
extension AISearchResponse: @retroactive Content {}
extension AIWebSearchResponse: @retroactive Content {}
extension AIPickReasonsResponse: @retroactive Content {}
extension AIScanResponse: @retroactive Content {}
extension AIFitJudgeResponse: @retroactive Content {}
extension AIFitSuggestResponse: @retroactive Content {}

/// What the routes accept, in one place so the limits can be read against each other.
enum AILimits {
    static let searchText = 200
    static let threadQuery = 300
    static let suggestions = 4
    static let suggestion = 40
    static let reply = 240
    static let webItems = 8
    static let pickExternalID = 200
    static let pickAnchor = 80
    static let pickBasis = 40
    static let pickReason = 120
    /// How long a cached pick sentence is believed.
    static let pickReasonLifetime: TimeInterval = 30 * 86_400
    static let pieceSlot = 24
    static let pieceTitle = 120
    static let pieceColour = 32
    static let notes = 4
    static let note = 200
    static let similar = 8

    /// One JPEG under `AIScan.maxBytes`, base64 in JSON: four thirds of it and a little.
    static let scanBody: ByteCount = "2100kb"
    /// A fit of `AIFits.maxPieces`, every one the reader's own photograph. Catalogue pieces
    /// travel as URLs, so a real request is a small fraction of this.
    static let judgeBody: ByteCount = "17mb"
    /// A fit and its candidates, of which the reader's own photographs are at most
    /// `maxOwnPhotographs` — a suggestion is about catalogue pieces, by URL.
    static let suggestBody: ByteCount = "17mb"
    static let maxOwnPhotographs = 8
}

extension Request {
    /// The deployment's AI, or 503 — the phone only asks after `GET /v1/ai` said it exists,
    /// so this is a deploy that turned it off in between.
    func aiService() throws -> AIService {
        guard let service = application.ai else {
            throw Abort(.serviceUnavailable, reason: "AI isn't available on this server.")
        }
        return service
    }

    /// Checked as well as the route's `maxSize`, for the reason `POST /v1/usage` gives: a body
    /// that arrives in one read is never measured against the route's limit.
    func requireBody(atMost limit: ByteCount) throws {
        guard (body.data?.readableBytes ?? 0) <= limit.value else { throw Abort(.payloadTooLarge) }
    }
}

func aiRoutes(_ app: Application, authed: any RoutesBuilder) {
    /// Each AI request is an outbound call that costs real money and seconds; this is the
    /// budget that stops a script, whatever its credits. Thirty in a burst, four a minute —
    /// far above anybody refining a search by hand.
    let ai = authed.grouped(RateLimit(store: app.rateLimits.ai, identity: .device, name: "ai"))

    // MARK: Status

    authed.get("ai") { req async throws -> AIStatus in
        let user = try await req.actingUser()
        guard let service = req.application.ai else {
            return AIStatus(available: false, webSearch: false, credits: [:], signedIn: user.$account.id != nil)
        }
        var credits: [String: Int] = [:]
        for action in CreditPolicy.paidAIActions { credits[action.rawValue] = CreditPolicy.credits(for: action) }
        return AIStatus(
            available: true,
            webSearch: service.provider.supportsWebSearch,
            credits: credits,
            signedIn: user.$account.id != nil
        )
    }

    // MARK: Search

    /// One turn of a search thread: the model reads the thread into the grammar, and the
    /// server's own search answers that text exactly as `GET /v1/products/search` would. A
    /// turn carrying a valid thread token is not charged.
    ai.post("ai", "search") { req async throws -> AISearchResponse in
        let service = try req.aiService()
        let body = try req.content.decode(AISearchRequest.self)
        let text = AIText.clean(body.text, AILimits.searchText + 1)
        guard !text.isEmpty, text.count <= AILimits.searchText else {
            throw Abort(.badRequest, reason: "A search is 1 to \(AILimits.searchText) characters.")
        }
        guard body.thread.count < AIThreadToken.maxTurns,
              body.thread.allSatisfy({ $0.text.count <= AILimits.searchText && $0.query.count <= AILimits.threadQuery })
        else { throw Abort(.badRequest, reason: "That thread is too long; start a new search.") }

        let user = try await req.actingUser()
        let accountID = try CreditLedger.accountID(of: user)
        let profileID = try user.requireID()
        let now = Date()
        let continuing: AIThreadToken? = body.threadToken.flatMap { token in
            try? AIThreadToken.verify(token, key: service.threadKey, account: accountID, profile: profileID, now: now).get()
        }

        let (answer, charge) = try await AIAction.run(
            .search, charge: continuing == nil, for: user, on: req.db, logger: req.logger, now: now
        ) { meter in
            let reading = AIText.reading(meter.take(try await service.provider.readSearch(text: text, thread: body.thread)))
            guard !reading.query.isEmpty else { throw AIFailure(.malformed("an empty query")) }
            let results = try await ProductSearch.run(
                ProductSearch.Ask(text: reading.query, scope: body.scope, inMySize: body.inMySize),
                for: user, app: req.application, on: req.db
            )
            return (reading, results)
        }

        var thread = continuing ?? AIThreadToken(account: accountID, profile: profileID, issuedAt: now, turns: 0)
        thread.turns += 1
        return AISearchResponse(
            reading: answer.0,
            results: answer.1,
            threadToken: try thread.signed(with: service.threadKey),
            turnsLeft: thread.turnsLeft,
            charge: charge
        )
    }

    /// "Show me more": the reading asked of the open web. A shop the server already watches
    /// comes back with its brand; anything else is an ordinary site check away. Nothing found
    /// is not charged.
    ai.post("ai", "search", "web") { req async throws -> AIWebSearchResponse in
        let service = try req.aiService()
        guard service.provider.supportsWebSearch else {
            throw Abort(.serviceUnavailable, reason: "Web search isn't available on this server.")
        }
        let body = try req.content.decode(AIWebSearchRequest.self)
        let query = AIText.clean(body.query, AILimits.searchText + 1)
        guard !query.isEmpty, query.count <= AILimits.searchText else {
            throw Abort(.badRequest, reason: "A search is 1 to \(AILimits.searchText) characters.")
        }
        let user = try await req.actingUser()
        let country = CountryCode.normalized(body.country) ?? CountryCode.normalized(user.country)

        let (items, charge) = try await AIAction.run(
            .webSearch, for: user, on: req.db, logger: req.logger, producedNothing: { $0.isEmpty }
        ) { meter in
            let found = meter.take(try await service.provider.searchWeb(query: query, country: country))
            return try await AIWeb.resolve(AIWeb.cleaned(found), on: req.db)
        }
        return AIWebSearchResponse(items: items, charge: charge)
    }

    // MARK: Daily picks

    /// A sentence for each of the top few picks. Free, cached by what it was written from with
    /// no user or device on the row, and paid by the owner under the daily background cap. A
    /// pick with no sentence here keeps the phone's own reason, so every failure is silent.
    ai.post("ai", "picks", "reasons") { req async throws -> AIPickReasonsResponse in
        let service = try req.aiService()
        let body = try req.content.decode(AIPickReasons.self)
        guard body.picks.count <= AIPicks.maxReasons else {
            throw Abort(.badRequest, reason: "At most \(AIPicks.maxReasons) picks a request.")
        }
        let picks = body.picks.compactMap(AIPickCache.Pick.init)
        let device = try await req.authenticatedDevice()
        let reasons = await AIPickCache.reasons(
            for: picks, service: service, device: try device.requireID(), app: req.application, on: req.db
        )
        return AIPickReasonsResponse(reasons: reasons)
    }

    // MARK: Scan

    /// One photograph of one garment, read. Never stored and never logged; it goes to the
    /// provider for this one reading. A photograph that is not of a garment is not charged.
    ai.on(.POST, "ai", "scan", body: .collect(maxSize: AILimits.scanBody)) { req async throws -> AIScanResponse in
        try req.requireBody(atMost: AILimits.scanBody)
        let service = try req.aiService()
        let body = try req.content.decode(AIScanRequest.self)
        try AIImages.check(body.image)
        let user = try await req.actingUser()

        let (reading, charge) = try await AIAction.run(
            .scan, for: user, on: req.db, logger: req.logger, producedNothing: { !$0.isGarment }
        ) { meter in
            AIText.scan(meter.take(try await service.provider.readScan(image: body.image)))
        }
        let similar = reading.isGarment
            ? await AIScanSimilar.cards(for: reading, user: user, app: req.application, on: req.db)
            : nil
        return AIScanResponse(reading: reading, similar: similar, charge: charge)
    }

    // MARK: Fits

    ai.on(.POST, "ai", "fits", "judge", body: .collect(maxSize: AILimits.judgeBody)) { req async throws -> AIFitJudgeResponse in
        try req.requireBody(atMost: AILimits.judgeBody)
        let service = try req.aiService()
        let body = try req.content.decode(AIFitJudgeRequest.self)
        guard (2...AIFits.maxPieces).contains(body.pieces.count) else {
            throw Abort(.badRequest, reason: "A fit to judge has 2 to \(AIFits.maxPieces) pieces.")
        }
        let pieces = try AIImages.pieces(body.pieces)
        let user = try await req.actingUser()

        let (verdict, charge) = try await AIAction.run(.fitJudge, for: user, on: req.db, logger: req.logger) { meter in
            let raw = meter.take(try await service.provider.judgeFit(pieces: pieces))
            guard let verdict = AIText.verdict(raw, pieces: pieces.count) else {
                throw AIFailure(.malformed("a verdict outside the three"))
            }
            return verdict
        }
        return AIFitJudgeResponse(verdict: verdict, charge: charge)
    }

    ai.on(.POST, "ai", "fits", "suggest", body: .collect(maxSize: AILimits.suggestBody)) { req async throws -> AIFitSuggestResponse in
        try req.requireBody(atMost: AILimits.suggestBody)
        let service = try req.aiService()
        let body = try req.content.decode(AIFitSuggestRequest.self)
        guard (1...AIFits.maxPieces).contains(body.fit.count),
              (1...AIFits.maxCandidates).contains(body.candidates.count)
        else {
            throw Abort(.badRequest, reason: "Send 1 to \(AIFits.maxPieces) pieces and 1 to \(AIFits.maxCandidates) candidates.")
        }
        let fit = try AIImages.pieces(body.fit)
        let candidates = try AIImages.pieces(body.candidates)
        guard (fit + candidates).count(where: { $0.image != nil }) <= AILimits.maxOwnPhotographs else {
            throw Abort(.payloadTooLarge, reason: "At most \(AILimits.maxOwnPhotographs) of your own photographs at once.")
        }
        let user = try await req.actingUser()

        let (suggestions, charge) = try await AIAction.run(.fitSuggest, for: user, on: req.db, logger: req.logger) { meter in
            AIText.suggestions(
                meter.take(try await service.provider.suggestForFit(fit: fit, candidates: candidates)),
                candidates: candidates.count
            )
        }
        return AIFitSuggestResponse(suggestions: suggestions, charge: charge)
    }
}

// MARK: - Cleaning what comes back

/// The model's words, held to the shapes the wire promises. A field too long is cut rather
/// than refused — the reader paid for the answer — and an answer that cannot be held to its
/// shape at all is a failed call.
enum AIText {
    /// Whitespace collapsed to single spaces, at most `limit` characters.
    static func clean(_ text: String, _ limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    static func reading(_ raw: AISearchReading) -> AISearchReading {
        var seen = Set<String>()
        let suggestions = raw.suggestions
            .map { clean($0, AILimits.suggestion) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return AISearchReading(
            query: clean(raw.query, AILimits.searchText),
            reply: raw.reply.map { clean($0, AILimits.reply) }.flatMap { $0.isEmpty ? nil : $0 },
            suggestions: Array(suggestions.prefix(AILimits.suggestions))
        )
    }

    static func scan(_ raw: AIScanReading) -> AIScanReading {
        let slot = GarmentSlot(rawValue: raw.slot) ?? .unknown
        var reading = raw
        reading.slot = slot.rawValue
        reading.type = clean(raw.type, 60)
        reading.colours = Array(raw.colours.map { clean($0, AILimits.pieceColour) }.filter { !$0.isEmpty }.prefix(4))
        reading.material = raw.material.map { clean($0, 60) }.flatMap { $0.isEmpty ? nil : $0 }
        reading.pattern = raw.pattern.map { clean($0, 60) }.flatMap { $0.isEmpty ? nil : $0 }
        reading.style = Array(raw.style.map { clean($0, 30) }.filter { !$0.isEmpty }.prefix(5))
        reading.description = clean(raw.description, AILimits.reply)
        reading.searchText = clean(raw.searchText, AILimits.searchText)
        // A reading with nothing to search for is not a garment the phone can do anything with.
        reading.isGarment = raw.isGarment && !reading.searchText.isEmpty
        return reading
    }

    static let verdicts: Set<String> = ["works", "risky", "clashes"]

    static func verdict(_ raw: AIFitVerdict, pieces: Int) -> AIFitVerdict? {
        let verdict = raw.verdict.lowercased()
        guard verdicts.contains(verdict) else { return nil }
        return AIFitVerdict(
            verdict: verdict,
            summary: clean(raw.summary, AILimits.reply),
            notes: Array(raw.notes.map { clean($0, AILimits.note) }.filter { !$0.isEmpty }.prefix(AILimits.notes)),
            swap: raw.swap.flatMap { (0..<pieces).contains($0) ? $0 : nil }
        )
    }

    /// Indexes the request did not offer, and repeats, are dropped; the order is the model's.
    static func suggestions(_ raw: [AIFitSuggestion], candidates: Int) -> [AIFitSuggestion] {
        var seen = Set<Int>()
        return raw.compactMap { suggestion in
            guard (0..<candidates).contains(suggestion.candidate), seen.insert(suggestion.candidate).inserted else { return nil }
            return AIFitSuggestion(candidate: suggestion.candidate, reason: clean(suggestion.reason, AILimits.note))
        }
    }
}

// MARK: - Photographs

enum AIImages {
    /// JPEG's start-of-image marker. The phone encodes JPEG; anything else is refused rather
    /// than sent to the provider under the wrong media type.
    static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])
    }

    static func check(_ data: Data) throws {
        guard !data.isEmpty else { throw Abort(.badRequest, reason: "Send a photograph.") }
        guard data.count <= AIScan.maxBytes else {
            throw Abort(.payloadTooLarge, reason: "That photograph is too large; send one under \(AIScan.maxBytes / 1000) KB.")
        }
        guard isJPEG(data) else { throw Abort(.unsupportedMediaType, reason: "Send the photograph as a JPEG.") }
    }

    /// Each piece with exactly one photograph — a web URL or a JPEG — and its words held short.
    static func pieces(_ pieces: [AIFitPiece]) throws -> [AIFitPiece] {
        try pieces.map { piece in
            switch (piece.imageURL, piece.image) {
            case (let url?, nil):
                guard AnthropicProvider.isWebPage(url) else { throw Abort(.badRequest, reason: "A piece's photograph must be a web address.") }
            case (nil, let data?):
                try check(data)
            default:
                throw Abort(.badRequest, reason: "Each piece needs exactly one photograph.")
            }
            var piece = piece
            piece.slot = AIText.clean(piece.slot, AILimits.pieceSlot)
            piece.title = AIText.clean(piece.title, AILimits.pieceTitle)
            piece.colour = piece.colour.map { AIText.clean($0, AILimits.pieceColour) }
            return piece
        }
    }
}

// MARK: - Show me more

enum AIWeb {
    /// At most `webItems`, one per page, each named.
    static func cleaned(_ items: [AIWebItem]) -> [AIWebItem] {
        var seen = Set<String>()
        var out: [AIWebItem] = []
        for item in items where out.count < AILimits.webItems {
            guard AnthropicProvider.isWebPage(item.url), seen.insert(AnthropicProvider.key(item.url)).inserted else { continue }
            var item = item
            item.title = AIText.clean(item.title, AILimits.pieceTitle)
            item.shop = AIText.clean(item.shop, 60)
            guard !item.title.isEmpty else { continue }
            if let price = item.price, !(price > 0 && price.isFinite) { item.price = nil }
            if item.price == nil { item.currency = nil }
            item.brandID = nil
            out.append(item)
        }
        return out
    }

    /// Each item's shop, when the server already watches it: by host first — the slug is the
    /// host a brand was added with — then by registrable domain, so `eu.kith.com` and
    /// `www.kith.com` find Kith. A country shop's own host finds its brand too.
    static func resolve(_ items: [AIWebItem], on db: any Database) async throws -> [AIWebItem] {
        let hosts = Set(items.compactMap { $0.url.host()?.lowercased() })
        guard !hosts.isEmpty else { return items }
        let bare = Set(hosts.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 })
        let variants = Array(bare.union(bare.map { "www." + $0 }))
        let domains = Set(bare.map(BrandDiscovery.registrableDomain(of:)))

        var byHost: [String: UUID] = [:]
        var byDomain: [String: UUID] = [:]
        let exact = try await BrandModel.query(on: db).filter(\.$slug ~~ variants).all()
        for brand in exact {
            guard let id = brand.id else { continue }
            byHost[brand.slug.lowercased().replacingOccurrences(of: "www.", with: ""), default: id] = id
        }
        // A brand whose slug shares a registrable domain: asked per domain, matched in Swift,
        // because "contains" in SQL would also find `notkith.com`.
        for domain in domains {
            let near = try await BrandModel.query(on: db).filter(\.$slug ~~ domain).limit(20).all()
            for brand in near where BrandDiscovery.registrableDomain(of: brand.slug.lowercased()) == domain {
                if let id = brand.id, byDomain[domain] == nil { byDomain[domain] = id }
            }
            let shops = try await StorefrontModel.query(on: db).filter(\.$url ~~ domain).limit(20).all()
            for shop in shops {
                guard let host = URL(string: shop.url)?.host()?.lowercased(),
                      BrandDiscovery.registrableDomain(of: host) == domain else { continue }
                byHost[host.replacingOccurrences(of: "www.", with: ""), default: shop.$brand.id] = shop.$brand.id
            }
        }

        return items.map { item in
            var item = item
            if let host = item.url.host()?.lowercased() {
                let key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                item.brandID = byHost[key] ?? byDomain[BrandDiscovery.registrableDomain(of: key)]
            }
            return item
        }
    }
}

// MARK: - Daily picks

enum AIPickCache {
    struct Pick: Sendable {
        var externalID: String
        var anchor: String?
        var basis: String

        init?(_ request: AIPickReasonRequest) {
            let id = request.productExternalID.trimmingCharacters(in: .whitespacesAndNewlines)
            let basis = AIText.clean(request.basis, AILimits.pickBasis)
            guard !id.isEmpty, id.count <= AILimits.pickExternalID, !basis.isEmpty else { return nil }
            externalID = id
            anchor = request.anchor.map { AIText.clean($0, AILimits.pickAnchor) }.flatMap { $0.isEmpty ? nil : $0 }
            self.basis = basis
        }

        /// `sha256(productExternalID|anchor|basis)`, hex. Lowercased words, so "Black chore
        /// jacket" and "black chore jacket" are one row.
        var key: String {
            let text = [externalID, anchor?.lowercased() ?? "", basis.lowercased()].joined(separator: "|")
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The cached sentences, and new ones for the rest when the owner's day allows and this
    /// device has not asked too often. Never throws: a pick with no sentence keeps its own.
    static func reasons(
        for picks: [Pick],
        service: AIService,
        device: UUID,
        app: Application,
        on db: any Database,
        now: Date = Date()
    ) async -> [String: String] {
        guard !picks.isEmpty else { return [:] }
        var out: [String: String] = [:]
        let keys = Dictionary(picks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let cached = (try? await AIPickReasonModel.query(on: db)
            .filter(\.$key ~~ Array(keys.keys))
            .filter(\.$createdAt > now.addingTimeInterval(-AILimits.pickReasonLifetime))
            .all()) ?? []
        var answered = Set<String>()
        for row in cached {
            guard let pick = keys[row.key] else { continue }
            out[pick.externalID] = row.reason
            answered.insert(row.key)
        }

        let misses = keys.filter { !answered.contains($0.key) }
        guard !misses.isEmpty,
              await AIBackground.allows(service, now: now, on: db),
              await app.rateLimits.pickReasons.take(device.uuidString, now: now) == nil
        else { return out }

        let prompts = (try? await prompts(for: Array(misses.values), on: db)) ?? []
        guard !prompts.isEmpty else { return out }
        do {
            let answer = try await service.provider.wordPickReasons(prompts)
            await AIBackground.record(answer.costs, now: now, on: db)
            let model = answer.costs.last?.model ?? "unknown"
            for prompt in prompts {
                guard let pick = misses[prompt.key], let raw = answer.value[prompt.key] else { continue }
                let reason = AIText.clean(raw, AILimits.pickReason)
                guard !reason.isEmpty else { continue }
                out[pick.externalID] = reason
                // Replaces a stale row; two devices asking at once is a unique-key conflict
                // that loses nothing — the other row says the same.
                try? await AIPickReasonModel.query(on: db).filter(\.$key == prompt.key).delete()
                try? await AIPickReasonModel(key: prompt.key, reason: reason, model: model, createdAt: now).save(on: db)
            }
        } catch {
            if let failure = error as? AIFailure { await AIBackground.record(failure.costs, now: now, on: db) }
            app.logger.info("ai: pick reasons skipped: \(String(describing: error))")
        }
        return out
    }

    /// Each pick's product in a few words, keyed by its cache key. A pick whose product the
    /// server does not hold is left to the phone's own reason.
    static func prompts(for picks: [Pick], on db: any Database) async throws -> [AIPickPrompt] {
        let ids = Array(Set(picks.map(\.externalID)))
        let products = try await ProductModel.query(on: db).filter(\.$externalID ~~ ids).all()
        // The main shop's row first: a country shop's copy of a product is the same garment.
        var byID: [String: ProductModel] = [:]
        for product in products.sorted(by: { ($0.storefrontID == nil ? 0 : 1) < ($1.storefrontID == nil ? 0 : 1) }) {
            if byID[product.externalID] == nil { byID[product.externalID] = product }
        }
        let brandIDs = Array(Set(byID.values.map(\.$brand.id)))
        let brands = Dictionary(
            try await BrandModel.query(on: db).filter(\.$id ~~ brandIDs).all().compactMap { brand in brand.id.map { ($0, brand.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        return picks.compactMap { pick in
            guard let product = byID[pick.externalID] else { return nil }
            let words = [product.title, product.productType ?? "", brands[product.$brand.id] ?? ""]
                .map { AIText.clean($0, 80) }
                .filter { !$0.isEmpty }
            return AIPickPrompt(key: pick.key, product: words.joined(separator: " · "), anchor: pick.anchor, basis: pick.basis)
        }
    }
}

// MARK: - The scan's "find this"

enum AIScanSimilar {
    /// Products near the reading, from every shop the server holds, by the vector index.
    ///
    /// **The reading's words, not the photograph's pixels.** The embedding sidecar only fetches
    /// photographs by URL — it never accepts bytes — and the reader's photograph has no URL,
    /// by design. So the reading's search text is embedded with the same model the catalogue
    /// was, and the nearest products by text vector answer. Nil whenever semantic search is
    /// off, resting, slow or empty; the phone then searches `searchText` instead.
    static func cards(for reading: AIScanReading, user: UserModel, app: Application, on db: any Database) async -> [DiscoverCard]? {
        guard let provider = app.semanticSearch, app.semanticRest?.isResting() != true,
              let sql = db as? any SQLDatabase
        else { return nil }
        do {
            let (space, vectors) = try await withTimeout(ProductSearch.embeddingTimeout) {
                (try await provider.space, try await provider.embed(texts: [reading.searchText]))
            }
            guard let vector = vectors.first, vector.count == space.dimension else { return nil }
            let scope = try await ProductSearch.scope(.all, for: user, app: app, on: db)
            guard !scope.brands.isEmpty else { return nil }
            let near = try await SemanticIndex.nearest(to: vector, in: space, scope: scope.predicate, limit: 40, on: sql)
            let loaded = try await ProductSearch.load(
                near.map { IndexCandidate(id: $0.id, relevance: $0.similarity) }, scope: scope, profile: user.sizeProfile, on: sql
            )
            .filter(\.listing.isShown)
            .sorted { a, b in
                a.listing.relevance != b.listing.relevance ? a.listing.relevance > b.listing.relevance : a.listing.id < b.listing.id
            }
            let page = Array(loaded.prefix(AILimits.similar))
            guard !page.isEmpty else { return nil }
            let cards = try await ProductSearch.cards(for: page, scope: scope, on: db)
            return page.compactMap { cards[$0.listing.id] }
        } catch {
            app.semanticRest?.rest()
            app.logger.warning("ai: scan similar skipped: \(String(describing: error))")
            return nil
        }
    }
}
