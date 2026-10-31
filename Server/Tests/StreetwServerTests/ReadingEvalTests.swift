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
            /// Every clean product shot; nil when none is.
            var shots: [Int]?
            /// Every close-up, crop, swatch or label.
            var details: [Int]?
            var words: [String]
            /// "close-ups" for the products added for the close-up rule, nil for the original set.
            var group: String?

            var leadIsAShot: Bool { shots?.contains(0) ?? false }
            var isDetail: (Int) -> Bool { { details?.contains($0) ?? false } }
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

    /// The stand-in rule's numbers. **Precision first**: a stand-in is an override of the shop's
    /// own choice, and a wrong one is worse than none.
    struct Summary: Codable, CustomStringConvertible {
        var method: String
        var model: String
        var products = 0
        /// Products given a stand-in.
        var overrides = 0
        /// …that is a labelled product shot.
        var overridesRight = 0
        /// …that is a labelled close-up, crop, swatch or label.
        var overridesToACloseUp = 0
        /// …where the lead was a product shot already: not wrong, not needed.
        var overridesOfAFineLead = 0
        /// Products whose lead is not a product shot.
        var leadIsNotAShot = 0
        /// …and a later photograph is one: the stand-ins there were to find.
        var standInsToFind = 0
        /// …found, and right.
        var standInsFound = 0
        /// The answer as a whole: a right stand-in, or none where the lead is a shot or nothing is.
        var right = 0
        /// The first rule, run on the same photographs: stand-ins, right ones, close-ups.
        var beforeOverrides = 0
        var beforeOverridesRight = 0
        var beforeOverridesToACloseUp = 0
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
                  override precision           \(share(overridesRight, overrides)) (a stand-in that is a product shot)
                  override rate                \(share(overrides, products))
                  overrides to a close-up      \(overridesToACloseUp) (the first rule chose \(beforeOverridesToACloseUp) of \(beforeOverrides), precision \(share(beforeOverridesRight, beforeOverrides)))
                  overrides of a fine lead     \(overridesOfAFineLead)
                  stand-ins found              \(share(standInsFound, standInsToFind)) (lead on a person, a product shot later)
                  lead is not a product shot   \(leadIsNotAShot)
                  answer right                 \(share(right, products))
                  style words right            \(share(wordsRight, wordsGiven)) (precision)
                  products with a right word   \(share(productsWithARightWord, labelledForWords))
                  products given any word      \(share(productsWithWords, products))
                  style recall                 \(String(format: "%.3f", labelledForWords == 0 ? 0 : recall / Double(labelledForWords)))
                  photographs beyond the lead  \(photographsBeyondTheLead)
                  cost                         $\(String(format: "%.4f", Double(costMicros) / 1_000_000))
                """
        }

        static func isRight(_ product: Labelled.Product, shot: Int?) -> Bool {
            if let shot { return product.shots?.contains(shot) ?? false }
            return product.leadIsAShot || product.shots == nil
        }

        mutating func add(_ product: Labelled.Product, shot: Int?, words: [String], asked: Int, before: Int?) -> Bool {
            products += 1
            let isRight = Self.isRight(product, shot: shot)
            if isRight { right += 1 }
            if let shot {
                overrides += 1
                if product.shots?.contains(shot) ?? false { overridesRight += 1 }
                if product.isDetail(shot) { overridesToACloseUp += 1 }
                if product.leadIsAShot { overridesOfAFineLead += 1 }
            }
            if !product.leadIsAShot {
                leadIsNotAShot += 1
                if product.shots != nil {
                    standInsToFind += 1
                    if let shot, product.shots?.contains(shot) ?? false { standInsFound += 1 }
                }
            }
            if let before {
                beforeOverrides += 1
                if product.shots?.contains(before) ?? false { beforeOverridesRight += 1 }
                if product.isDetail(before) { beforeOverridesToACloseUp += 1 }
            }
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
            return isRight
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

    /// One photograph's raw scores, for the sweep and for the first rule.
    private struct Scored {
        var index: Int
        var scores: ZeroShot.Scores
        /// The first rule's score: product over its one "other" class.
        var v1: Double
        /// Calibrated style scores, every word.
        var styles: [(word: String, score: Double)]
    }

    /// The first rule, exactly as it shipped, for the "before" column: five product prompts
    /// against six others with the fabric close-up among them, a product shot where product
    /// led by the margin, the lead first and then the gallery in chunks.
    private enum V1 {
        static let productPrompts = [
            "a product photo of a garment on a plain background",
            "a flat lay photo of clothing",
            "a packshot of a product on a white background",
            "a photo of shoes on a plain background",
            "a photo of a bag on a plain background",
        ]
        static let otherPrompts = [
            "a person wearing clothes",
            "a model wearing an outfit",
            "a photo of a person",
            "a woman wearing a dress",
            "a fashion model posing",
            "a close-up photo of fabric texture",
        ]
        static let margins: [String: Double] = [
            "Marqo/marqo-fashionSigLIP@c56244cc94f9": 0.02,
            "Marqo/marqo-fashionCLIP@44f4c655124e": 0.03,
        ]

        static func score(_ photo: [Float], product: [[Float]], other: [[Float]]) -> Double {
            (product.map { ZeroShot.dot($0, photo) }.max() ?? 0) - (other.map { ZeroShot.dot($0, photo) }.max() ?? 0)
        }

        /// The shot the first rule chose, as a stand-in: nil when it chose the lead or nothing.
        static func standIn(_ scores: [Scored], margin: Double) -> Int? {
            guard let lead = scores.first, lead.index == 0 else { return nil }
            if lead.v1 > margin { return nil }
            let others = Array(scores.dropFirst().prefix(ZeroShot.extraPhotographs))
            var seen: [Scored] = []
            for start in stride(from: 0, to: others.count, by: ZeroShot.extraChunk) {
                seen += others[start..<min(start + ZeroShot.extraChunk, others.count)]
                if let best = seen.filter({ $0.v1 > margin }).max(by: { $0.v1 < $1.v1 }) { return best.index }
            }
            return nil
        }
    }

    /// Zero-shot through the sidecar. Every photograph is embedded, the shipped reader is run
    /// over them as the backfill would run it, and the margins are swept from the same scores
    /// so a new model's bars can be chosen from the table (`ZeroShot.measuredBars`). **A model
    /// with measured bars is scored and written; one without is only measured**, because a run
    /// against unchosen bars is not a result.
    @Test("Zero-shot through the embedding model, via the sidecar")
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
            let model = try await provider.space.model
            let calibrating = ZeroShot.measuredBars[model] == nil
            let prompts = try await ZeroShot.prompts(
                using: provider, bars: calibrating ? ZeroShot.Bars(personMargin: .infinity, shotMargin: .infinity, styleBar: .infinity) : nil
            )
            if calibrating { print("\(model) has no measured bars: measuring, not scoring") }
            let v1Product = try await provider.embed(texts: V1.productPrompts)
            let v1Other = try await provider.embed(texts: V1.otherPrompts)
            // What the backfill finds stored: the text vector, and the lead photograph's.
            let texts = try await provider.embed(texts: products.map {
                SemanticIndex.text(title: $0.title, productType: $0.productType, tags: $0.tags, brand: $0.brand, colours: [])
            })
            // Every photograph, up front, in the sidecar's batches: the reader is then answered
            // from this cache, so what it *asks* is still what the backfill would ask.
            var cache: [URL: ImageEmbedding] = [:]
            let urls = products.flatMap { $0.photos.prefix(1 + ZeroShot.extraPhotographs) }
                .compactMap { URL(string: $0).map(ZeroShot.rendition) }
            for start in stride(from: 0, to: urls.count, by: 64) {
                let batch = Array(urls[start..<min(start + 64, urls.count)])
                for (url, answer) in zip(batch, try await provider.embed(imageURLs: batch)) { cache[url] = answer }
            }
            let firsts: [[Float]?] = products.map { product in
                guard let url = URL(string: product.photos[0]), case .vector(let v)? = cache[ZeroShot.rendition(url)] else { return nil }
                return v
            }
            // The catalogue's mean is this set's: no label is read for it.
            let calibration = ZeroShot.calibration(
                meanImage: ZeroShot.mean(firsts.compactMap { $0 }), meanText: ZeroShot.mean(texts), prompts: prompts
            )
            var summary = Summary(method: "siglip", model: prompts.model)
            var closeUps = Summary(method: "siglip (close-up group)", model: prompts.model)
            var answers: [Answer] = []
            var scored: [[Scored]] = []
            for (index, product) in products.enumerated() {
                let others = product.photos.enumerated().dropFirst().map { (index: $0.offset, url: $0.element) }
                var asked = 0
                let outcome = try await ZeroShot.read(
                    first: firsts[index], text: texts[index], others: others, prompts: prompts, calibration: calibration
                ) { urls in
                    asked += urls.count
                    return urls.map { cache[$0] ?? .unavailable("not embedded") }
                }
                func score(_ photo: Int, _ vector: [Float]) -> Scored {
                    Scored(index: photo, scores: ZeroShot.scores(vector, prompts),
                           v1: V1.score(vector, product: v1Product, other: v1Other),
                           styles: ZeroShot.styleScores(photo: vector, text: texts[index], prompts: prompts, calibration: calibration))
                }
                let all = (firsts[index].map { [score(0, $0)] } ?? [])
                    + others.compactMap { entry -> Scored? in
                        guard let url = URL(string: entry.url), case .vector(let v)? = cache[ZeroShot.rendition(url)] else { return nil }
                        return score(entry.index, v)
                    }
                scored.append(all)
                let before = V1.margins[prompts.model].flatMap { V1.standIn(all, margin: $0) }
                let right = summary.add(product, shot: outcome.verdict.shotIndex, words: outcome.verdict.styleWords, asked: asked, before: before)
                if product.group == "close-ups" {
                    _ = closeUps.add(product, shot: outcome.verdict.shotIndex, words: outcome.verdict.styleWords, asked: asked, before: before)
                }
                answers.append(Answer(externalID: product.externalID, shot: outcome.verdict.shotIndex,
                                      words: outcome.verdict.styleWords, right: right, asked: asked))
            }
            summary.seconds = Date().timeIntervalSince(started)
            if calibrating {
                print(summary)
            } else {
                try write(summary, answers)
            }
            print("\(closeUps)")
            sweep(products, scored)
        }
    }

    /// The reader run again at every pair of margins, from the scores — exact, because every
    /// photograph was looked at. Then the style bar at the shipped margins.
    private func sweep(_ products: [Labelled.Product], _ scored: [[Scored]]) {
        func standIn(_ scores: [Scored], person: Double, shot: Double) -> Int? {
            let bars = ZeroShot.Bars(personMargin: person, shotMargin: shot, styleBar: 0)
            guard let lead = scores.first, lead.index == 0, ZeroShot.isOnAPerson(lead.scores, bars) else { return nil }
            // As `ZeroShot.read` walks the gallery: a chunk at a time, stopping at the first with one.
            let others = Array(scores.dropFirst().prefix(ZeroShot.extraPhotographs))
            var seen: [(index: Int, scores: ZeroShot.Scores)] = []
            for start in stride(from: 0, to: others.count, by: ZeroShot.extraChunk) {
                seen += others[start..<min(start + ZeroShot.extraChunk, others.count)].map { ($0.index, $0.scores) }
                if let best = ZeroShot.best(seen, bars) { return best }
            }
            return nil
        }

        print("person margin / shot margin → overrides right/made (precision) · to a close-up · of a fine lead · stand-ins found/to find · answer right · the wrong ones (#product→photograph)")
        for personStep in 0...8 {
            for shotStep in 0...8 {
                let person = Double(personStep) * 0.01, shot = Double(shotStep) * 0.01
                var made = 0, right = 0, closeUp = 0, fine = 0, toFind = 0, found = 0, answers = 0
                var wrong: [String] = []
                for (index, (product, scores)) in zip(products, scored).enumerated() {
                    let answer = standIn(scores, person: person, shot: shot)
                    if Summary.isRight(product, shot: answer) { answers += 1 }
                    if let answer {
                        made += 1
                        if product.shots?.contains(answer) ?? false { right += 1 } else { wrong.append("#\(index)→\(answer)") }
                        if product.isDetail(answer) { closeUp += 1 }
                        if product.leadIsAShot { fine += 1 }
                    }
                    if !product.leadIsAShot, product.shots != nil {
                        toFind += 1
                        if let answer, product.shots?.contains(answer) ?? false { found += 1 }
                    }
                }
                print(String(format: "  %.2f / %.2f  %3d/%3d = %.3f   %2d   %2d   %2d/%d   %3d/%d   ",
                             person, shot, right, made, made == 0 ? 0 : Double(right) / Double(made), closeUp, fine, found, toFind, answers, products.count)
                      + wrong.joined(separator: " "))
            }
        }

        print("style bar → words right (precision) / products with a right word / products given any word (on the lead)")
        for step in -4...16 {
            let bar = Double(step) * 0.005
            var given = 0, right = 0, labelled = 0, withRight = 0, withAny = 0
            for (product, scores) in zip(products, scored) {
                guard let measured = scores.first(where: { $0.index == 0 }) else { continue }
                let words = measured.styles.filter { $0.score >= bar }.prefix(StyleWords.maximum).map(\.word)
                if !words.isEmpty { withAny += 1 }
                guard !product.words.isEmpty else { continue }
                labelled += 1
                let hits = words.filter(product.words.contains).count
                given += words.count
                right += hits
                if hits > 0 { withRight += 1 }
            }
            print(String(format: "  %+.3f  %3d/%3d = %.3f   %3d/%d   %3d/%d", bar, right, given, given == 0 ? 0 : Double(right) / Double(given), withRight, labelled, withAny, products.count))
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
                let right = summary.add(product, shot: shot, words: words, asked: 0, before: nil)
                answers.append(Answer(externalID: product.externalID, shot: shot, words: words, right: right, asked: 0))
            }
            summary.seconds = Date().timeIntervalSince(started)
            try write(summary, answers)
        }
    }
}
