// FakeAIProvider.swift
// Every action answered deterministically from its input, at no cost — behind `AI_FAKE=true`,
// so the whole Phase 4 flow runs in a simulator against a local server with no key.
//
// **Refused on a production environment** (`AIService.make`). Its answers are plausible
// rather than right: a search reading that is the thread's words in order, a scan that always
// sees a black chore jacket, a fit judged by how many pieces it has. What it proves is the
// plumbing — charges, threads, validation, caching, the screens — and the screens need
// something believable to lay out.
//
// Metered like the real one, under the model id `fake` and at zero cost, so `ai_costs` and
// `GET /admin/costs` can be read end to end too.

import Foundation
import StreetwCore

struct FakeAIProvider: AIProvider {
    static let model = "fake"

    /// The host "Show me more" answers on, so a test can watch a brand there and see its
    /// `brandID` come back.
    static let webHost = "example.com"

    var supportsWebSearch: Bool { true }

    private func cost(_ action: CreditAction) -> [MeteredCost] {
        [MeteredCost(action: action, model: Self.model, inputTokens: 0, outputTokens: 0, costMicros: 0)]
    }

    /// The thread's words, oldest first and the turn's last, lowercased and collapsed.
    func readSearch(text: String, thread: [AISearchTurn]) async throws -> AIAnswer<AISearchReading> {
        let words = ((thread.last.map { [$0.query] } ?? []) + [text])
            .joined(separator: " ")
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
        var seen = Set<Substring>()
        let query = words.filter { seen.insert($0).inserted }.prefix(12).joined(separator: " ")
        return AIAnswer(
            value: AISearchReading(
                query: query,
                reply: thread.isEmpty ? nil : "Narrowed, keeping what you asked for before.",
                suggestions: ["cheaper", "no wool", "in black"]
            ),
            costs: cost(.search)
        )
    }

    /// Two pages: one on `webHost`, and one on a shop nobody watches.
    func searchWeb(query: String, country: String?) async throws -> AIAnswer<[AIWebItem]> {
        let slug = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        let handle = slug.isEmpty ? "item" : slug
        return AIAnswer(value: [
            AIWebItem(
                title: "\(query.capitalized) (example)",
                shop: "Example",
                url: URL(string: "https://\(Self.webHost)/products/\(handle)")!,
                price: 120,
                currency: "USD"
            ),
            AIWebItem(
                title: "\(query.capitalized), another",
                shop: "Elsewhere",
                url: URL(string: "https://shop.example.org/products/\(handle)")!
            ),
        ], costs: cost(.webSearch))
    }

    func wordPickReasons(_ picks: [AIPickPrompt]) async throws -> AIAnswer<[String: String]> {
        var out: [String: String] = [:]
        for pick in picks {
            out[pick.key] = pick.anchor.map { "Goes with your \($0)" } ?? "Fills a gap in your wardrobe"
        }
        return AIAnswer(value: out, costs: cost(.pickReason))
    }

    func readScan(image: Data) async throws -> AIAnswer<AIScanReading> {
        AIAnswer(value: AIScanReading(
            slot: GarmentSlot.outerwear.rawValue,
            type: "chore jacket",
            colours: ["Black"],
            material: "canvas",
            pattern: nil,
            style: ["workwear"],
            name: "Black chore jacket",
            description: "Black canvas chore jacket with patch pockets",
            searchText: "black chore jacket canvas",
            isGarment: true
        ), costs: cost(.scan))
    }

    /// Two or three pieces work; more is risky, with the last one the swap.
    func judgeFit(pieces: [AIFitPiece]) async throws -> AIAnswer<AIFitVerdict> {
        let works = (2...3).contains(pieces.count)
        return AIAnswer(value: AIFitVerdict(
            verdict: works ? "works" : "risky",
            summary: works ? "Balanced and easy to wear." : "A lot going on at once.",
            notes: pieces.prefix(2).map { "The \($0.title) carries the outfit." },
            swap: works ? nil : pieces.count - 1
        ), costs: cost(.fitJudge))
    }

    /// Every candidate in reverse order, except one whose title says it clashes — and one
    /// index that does not exist, so the route's validation has something to drop.
    func suggestForFit(fit: [AIFitPiece], candidates: [AIFitPiece]) async throws -> AIAnswer<[AIFitSuggestion]> {
        let anchor = fit.first?.title ?? "the outfit"
        var out = candidates.indices.reversed()
            .filter { !candidates[$0].title.lowercased().contains("clash") }
            .map { AIFitSuggestion(candidate: $0, reason: "Goes with the \(anchor).") }
        out.append(AIFitSuggestion(candidate: candidates.count, reason: "Not a candidate."))
        return AIAnswer(value: out, costs: cost(.fitSuggest))
    }

    /// The pattern's code, and a week from today as the end.
    func readSaleBanner(message: String, brand: String, today: Date) async throws -> AIAnswer<AISaleReading> {
        AIAnswer(value: AISaleReading(
            endsAt: today.addingTimeInterval(7 * 86_400),
            code: SaleBanner.read(html: "<div class=\"announcement\">\(message)</div>")?.code,
            terms: "Fake reading: excludes gift cards."
        ), costs: cost(.saleReading))
    }

    /// A product only when the page says `fake-product`, so a test can choose either answer.
    func readProductPage(text: String, url: URL) async throws -> AIAnswer<AIPageReading?> {
        guard text.contains("fake-product") else { return AIAnswer(value: nil, costs: cost(.pageReading)) }
        return AIAnswer(value: AIPageReading(
            title: "Fake Product",
            price: 42,
            currency: "USD",
            available: true,
            sizes: [.init(size: "S", available: false), .init(size: "M", available: true)]
        ), costs: cost(.pageReading))
    }
}
