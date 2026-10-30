import Foundation
import StreetwCore
import Testing
import Vapor

@testable import StreetwServer

/// The photograph reading's eval: `Server/ReadingEval/labelled.json` read by the shipped code,
/// scored against the labels, the answers written beside it.
///
/// Off unless `STREETW_READING_EVAL` names a method, because it talks to the network: the
/// sidecar for `siglip` (`EMBEDDING_URL`, `EMBEDDING_TOKEN`), Anthropic for `haiku`
/// (`ANTHROPIC_API_KEY`, and `AI_MODEL_FAST` to try another model). One command each — see
/// `docs/server.md` (*The product photograph and style words*):
///
///     STREETW_READING_EVAL=haiku ANTHROPIC_API_KEY=… swift test --filter ReadingEval
///
/// Nothing is stored and nothing is metered: it reads photographs and prints a table.
@Suite(
    "The photograph reading's eval",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_READING_EVAL"] != nil),
    .serialized
)
struct ReadingEvalTests {
    struct Labelled: Decodable {
        struct Product: Decodable {
            var externalID: String
            var brand: String
            var title: String
            var productType: String?
            var tags: [String]
            var photos: [String]
            var shots: [Int]?
            var words: [String]
        }
        var products: [Product]
    }

    struct Answer: Codable {
        var externalID: String
        var shot: Int?
        var words: [String]
        var right: Bool
        var asked: Int
    }

    struct Summary: Codable, CustomStringConvertible {
        var method: String
        var model: String
        var products = 0
        var shotsRight = 0
        var leadIsNotAShot = 0
        var leadIsNotAShotRight = 0
        var leadVerdictRight = 0
        var wordsGiven = 0
        var wordsRight = 0
        var productsWithWords = 0
        var productsWithARightWord = 0
        var labelledForWords = 0
        var recall = 0.0
        var photographsBeyondTheLead = 0
        var costMicros: Int64 = 0
        var seconds = 0.0

        var description: String {
            func share(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%d/%d = %.3f", a, b, Double(a) / Double(b)) }
            return """
                \(method) (\(model)), \(products) products, \(String(format: "%.0f", seconds)) s
                  product shot right           \(share(shotsRight, products))
                  …where the lead is not one   \(share(leadIsNotAShotRight, leadIsNotAShot))
                  lead photograph judged right \(share(leadVerdictRight, products))
                  style words right            \(share(wordsRight, wordsGiven)) (precision)
                  products with a right word   \(share(productsWithARightWord, labelledForWords))
                  products given any word      \(share(productsWithWords, products))
                  style recall                 \(String(format: "%.3f", labelledForWords == 0 ? 0 : recall / Double(labelledForWords)))
                  photographs beyond the lead  \(photographsBeyondTheLead)
                  cost                         $\(String(format: "%.4f", Double(costMicros) / 1_000_000))
                """
        }

        mutating func add(_ product: Labelled.Product, shot: Int?, words: [String], asked: Int) -> Bool {
            products += 1
            let right = product.shots.map { shot.map($0.contains) ?? false } ?? (shot == nil)
            if right { shotsRight += 1 }
            let leadIsAShot = product.shots?.contains(0) ?? false
            if !leadIsAShot {
                leadIsNotAShot += 1
                if right { leadIsNotAShotRight += 1 }
            }
            if leadIsAShot == (shot == 0) { leadVerdictRight += 1 }
            photographsBeyondTheLead += asked
            if !words.isEmpty { productsWithWords += 1 }
            if !product.words.isEmpty {
                labelledForWords += 1
                let hits = words.filter(product.words.contains).count
                wordsGiven += words.count
                wordsRight += hits
                if hits > 0 { productsWithARightWord += 1 }
                recall += Double(hits) / Double(product.words.count)
            }
            return right
        }
    }

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ReadingEval")
    }

    private func load() throws -> [Labelled.Product] {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent("labelled.json"))
        return try JSONDecoder().decode(Labelled.self, from: data).products
    }

    private func write(_ summary: Summary, _ answers: [Answer]) throws {
        struct File: Encodable { var summary: Summary; var answers: [Answer] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Self.directory.appendingPathComponent("results-\(summary.method).json")
        try encoder.encode(File(summary: summary, answers: answers)).write(to: url)
        print("\(summary)\n  written to \(url.path)")
        // The other method's last run, for the comparison the owner asked for.
        for other in ["siglip", "haiku"] where other != summary.method {
            struct Previous: Decodable { var summary: Summary }
            let previous = Self.directory.appendingPathComponent("results-\(other).json")
            if let data = try? Data(contentsOf: previous), let file = try? JSONDecoder().decode(Previous.self, from: data) {
                print("…against the last \(other) run:\n\(file.summary)")
            }
        }
    }

    private func withClient(_ body: (any Client) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await body(app.client)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("SigLIP zero-shot, through the sidecar")
    func siglip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STREETW_READING_EVAL"] == "siglip" else { return }
        var configuration = try #require(SidecarEmbeddingProvider.Configuration.from(environment: environment),
                                         "EMBEDDING_URL and EMBEDDING_TOKEN")
        configuration.imageTimeout = .seconds(120)
        configuration.textTimeout = .seconds(60)
        let products = try load()
        try await withClient { client in
            let provider = SidecarEmbeddingProvider(configuration: configuration, client: client)
            let started = Date()
            let prompts = try await ZeroShot.prompts(using: provider)
            // What the backfill finds stored: the text vector, and the lead photograph's.
            let texts = try await provider.embed(texts: products.map {
                SemanticIndex.text(title: $0.title, productType: $0.productType, tags: $0.tags, brand: $0.brand, colours: [])
            })
            let leads = try await provider.embed(imageURLs: products.map { URL(string: $0.photos[0]).map(ZeroShot.rendition)! })
            let firsts: [[Float]?] = leads.map { if case .vector(let v) = $0 { v } else { nil } }
            // The catalogue's mean is this set's: no label is read for it.
            let calibration = ZeroShot.calibration(
                meanImage: ZeroShot.mean(firsts.compactMap { $0 }), meanText: ZeroShot.mean(texts), prompts: prompts
            )
            var summary = Summary(method: "siglip", model: prompts.model)
            var answers: [Answer] = []
            for (index, product) in products.enumerated() {
                let outcome = try await ZeroShot.read(
                    first: firsts[index], text: texts[index],
                    others: product.photos.enumerated().dropFirst().map { (index: $0.offset, url: $0.element) },
                    prompts: prompts, calibration: calibration
                ) { try await provider.embed(imageURLs: $0) }
                let right = summary.add(product, shot: outcome.verdict.shotIndex, words: outcome.verdict.styleWords, asked: outcome.asked)
                answers.append(Answer(externalID: product.externalID, shot: outcome.verdict.shotIndex,
                                      words: outcome.verdict.styleWords, right: right, asked: outcome.asked))
            }
            summary.seconds = Date().timeIntervalSince(started)
            try write(summary, answers)
        }
    }

    @Test("The fast model, given the same photographs")
    func haiku() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STREETW_READING_EVAL"] == "haiku" else { return }
        let key = try #require(environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }, "ANTHROPIC_API_KEY")
        let model = environment["AI_MODEL_FAST"] ?? AnthropicProvider.Models.defaultFast
        let products = try load()
        try await withClient { client in
            let provider = AnthropicProvider(
                transport: VaporAnthropicTransport(client: client, apiKey: key),
                models: AnthropicProvider.Models(main: AnthropicProvider.Models.defaultMain, fast: model)
            )
            let started = Date()
            var summary = Summary(method: "haiku", model: model)
            var answers: [Answer] = []
            for product in products {
                let urls = product.photos.compactMap(URL.init(string:)).map(ZeroShot.rendition)
                var shot: Int?
                var words: [String] = []
                do {
                    let answer = try await provider.readProductPhotos(imageURLs: urls, title: product.title)
                    shot = answer.value.productShot
                    words = answer.value.styleWords
                    summary.costMicros += answer.costs.reduce(0) { $0 + $1.costMicros }
                } catch {
                    // Scored as a wrong answer, and said: a run that fails silently reads as a bad model.
                    if let failure = error as? AIFailure { summary.costMicros += failure.costs.reduce(0) { $0 + $1.costMicros } }
                    print("\(product.externalID): \(error)")
                }
                let right = summary.add(product, shot: shot, words: words, asked: 0)
                answers.append(Answer(externalID: product.externalID, shot: shot, words: words, right: right, asked: 0))
            }
            summary.seconds = Date().timeIntervalSince(started)
            try write(summary, answers)
        }
    }
}
