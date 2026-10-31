// ProductReading.swift
// Which of a product's photographs is the clean product shot, and a few style words — read once
// per product, on the server, and sent on the wire (Phase 5).
//
// The phone has always picked the photograph it measures and the wall's cover with Vision's
// person detector (`ProductShot`), one save at a time, after somebody kept it. That works where
// Vision runs and costs a fetch of a 2000–3000 px original per photograph tried. The server
// already turns every product's lead photograph into a FashionSigLIP vector for search, and the
// same model can be asked, zero-shot, whether a photograph looks more like "a product photo of a
// garment on a plain background" or "a person wearing clothes" — so it answers once per product,
// for every phone, before anybody saves it. Vision stays as the phone's fallback.
//
// **SigLIP is the method; a model is the switch.** The owner's rule: implement it with the
// embeddings, and use Claude only if it clearly reads the photographs better. `PRODUCT_READING=
// haiku` sends the same photographs to the fast model instead, owner-paid and under
// `AI_BACKGROUND_DAILY_CAP_MICROS`; it is off by default. `Server/ReadingEval` compares them on
// 203 labelled products — see `docs/server.md` (*The product photograph and style words*).
//
// What is careful here, and why:
//
// - **The other photographs are embedded only when the first looks like a person.** Most shops
//   lead with a packshot (170 of the 203), and for those the lead's vector — already stored by
//   `EmbeddingBackfill` — answers alone, at no request. Otherwise up to `extraPhotographs` more
//   are asked, a few at a time with a pause between, because every request holds the sidecar's
//   model lock and a search waiting on it has 1.5 s.
// - **Small renditions** (`ImageRendition`, 400 px): the model reads 224 px, and fetching
//   storefront originals is most of what makes a photograph slow.
// - **A photograph the sidecar cannot read** follows `EmbeddingBackfill`'s rules: `.gone` is
//   written off for this reading (`product_readings.gone`) and never asked again; `.unavailable`
//   leaves the reading unsettled, asked again further apart, and settled as it is on the fifth.
// - **Style words are calibrated against the catalogue.** A prompt's raw similarity says as much
//   about the prompt as the photograph ("streetwear" is near everything), so each word's mean over
//   the catalogue is taken off first — measured, per model, from the average of the stored
//   vectors (`calibration`), which pgvector computes in one query. Until there are
//   `minimumCalibration` photographs to average, nothing is read.
// - **Resumable, and keyed on what was read.** `product_readings` holds the method (with its
//   version and the model), a digest of the photographs read, the attempts and the retry time,
//   so a restart resumes, a new gallery is read again, and a new model or version reads
//   everything again in its own time.

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

/// Which reader this deployment uses.
enum ProductReadingMethod: String, Sendable, Equatable {
    /// FashionSigLIP zero-shot through the embedding sidecar. The default.
    case siglip
    /// The fast model (`AnthropicProvider.Models.fast`), owner-paid.
    case haiku

    /// `PRODUCT_READING`, read once at boot. Anything but `haiku` is SigLIP.
    static func from(environment: [String: String]) -> ProductReadingMethod {
        environment["PRODUCT_READING"]?.trimmingCharacters(in: .whitespaces).lowercased() == "haiku" ? .haiku : .siglip
    }

    /// Stored beside every reading, so a change of method, version or model reads again.
    func key(model: String) -> String {
        switch self {
        case .siglip: "siglip.\(ZeroShot.version):\(model)"
        case .haiku: "haiku.\(ZeroShot.version):\(model)"
        }
    }
}

/// One product's answer.
struct ProductPhotoVerdict: Sendable, Equatable {
    /// Zero-based into the product's photographs; nil when none is a clean product shot.
    var shotIndex: Int?
    var styleWords: [String]
}

// MARK: - The zero-shot reader

/// The embedding model asked about a photograph by comparing it with sentences.
///
/// Every number here was measured on `Server/ReadingEval` (203 products from seven shops,
/// labelled by hand). The prompts and the weights are the idea's; the two bars are the
/// model's, because each model puts the same photograph and sentence at its own distance —
/// so they are kept per model id (`measuredBars`), and **a model with none is not read**
/// rather than read against another model's bars.
enum ZeroShot {
    /// Bump when the prompts, the bars or the rules change: every product is read again.
    static let version = 1

    /// The two numbers that belong to a model: how far the product side must lead for a
    /// photograph to be a product shot, and how far above its catalogue mean a style word must
    /// score to be given.
    struct Bars: Sendable, Equatable {
        var shotMargin: Double
        var styleBar: Double
    }

    /// Per model id, as the sidecar reports it — the same key as
    /// `ProductSearch.measuredThresholds`. Measured by running `ReadingEvalTests` against the
    /// model with no entry here, which sweeps both bars and prints the table to choose from
    /// (`docs/server.md`, *The reading eval*). `ProductReadingBackfill` waits, and says so, for
    /// a model that is missing — the backfill would otherwise read ten thousand products
    /// against bars that were never measured for them, and nothing on the wire would show it.
    static let measuredBars: [String: Bars] = [
        // 99.5 % of the labelled product shots clear 0.02, and it is what turned STAUD's
        // on-model lead shots (0.01–0.016) from "product shot" into "look further".
        "Marqo/marqo-fashionSigLIP@c56244cc94f9": Bars(shotMargin: 0.02, styleBar: 0.01),
        // Swept on 2026-10-30: 0.03 reads 186 of the 203 shots right (0.916 — five points under
        // SigLIP, which reads photographs better than it reads text); 0.035 gives words at
        // SigLIP's precision (0.654 against 0.648) on a few fewer products (147 against 158).
        "Marqo/marqo-fashionCLIP@44f4c655124e": Bars(shotMargin: 0.03, styleBar: 0.035),
    ]

    /// Said when a model has no bars.
    struct Unmeasured: Error, CustomStringConvertible {
        var model: String
        var description: String {
            "no measured bars for \(model) — the reading waits until ZeroShot.measuredBars has them (Server/ReadingEval)"
        }
    }

    /// What a clean product shot looks like. The best of these is compared with the best of
    /// `otherPrompts`, so a shoe or a bag on a plain ground is not mistaken for nothing.
    static let productPrompts = [
        "a product photo of a garment on a plain background",
        "a flat lay photo of clothing",
        "a packshot of a product on a white background",
        "a photo of shoes on a plain background",
        "a photo of a bag on a plain background",
    ]
    /// What it is not: somebody wearing it, and a close-up of the cloth — without the last, a
    /// gallery that leads with a model would hand the cover to its swatch.
    static let otherPrompts = [
        "a person wearing clothes",
        "a model wearing an outfit",
        "a photo of a person",
        "a woman wearing a dress",
        "a fashion model posing",
        "a close-up photo of fabric texture",
    ]
    /// Each style word as a few phrases, averaged into one vector. Richer phrases than the bare
    /// word measured better (top-two precision 0.61 → 0.64).
    static let styleDescriptions: [String: [String]] = [
        "workwear": ["workwear", "utility work wear", "rugged canvas work jacket", "chore coat and carpenter pants"],
        "minimal": ["minimalist", "plain simple basic", "clean understated essentials"],
        "preppy": ["preppy", "ivy league collegiate", "rugby shirt, oxford shirt and cable knit"],
        "streetwear": ["streetwear", "urban hype streetwear", "oversized hoodie and graphic tee"],
        "tailoring": ["tailored formal", "smart tailoring", "suit, blazer, tie and dress shoes"],
        "y2k": ["y2k", "2000s style", "early 2000s pop"],
        "sporty": ["sporty", "athletic sportswear", "sweatpants and sneakers"],
        "outdoor": ["outdoor technical", "gorpcore hiking", "waterproof shell and fleece"],
        "romantic": ["romantic feminine", "delicate romantic", "silk and lace dress"],
        "vintage": ["vintage", "retro"],
        "skate": ["skate", "skateboarding"],
        "western": ["western", "cowboy", "cowboy boots and suede"],
        "boho": ["boho", "bohemian", "earthy free-spirited"],
        "grunge": ["grunge", "distressed grunge"],
        "graphic": ["graphic print", "bold logo graphic"],
    ]
    static func stylePrompt(_ phrase: String) -> String { "a photo of \(phrase) clothing" }

    /// The photograph's share of a style score; the product's text vector has the rest. Words
    /// alone and the picture alone both measured worse than the blend.
    static let imageWeight = 0.7

    /// Photographs past the first worth embedding — the phone's `ProductShot.extraCandidates`.
    static let extraPhotographs = 5
    /// Photographs per request when looking past the first, and the pause after each: the
    /// sidecar takes requests one at a time, and a search's query waits behind whichever is in.
    static let extraChunk = 4
    static let extraPause: Duration = .milliseconds(250)

    /// Vectors averaged for the calibration, and the fewest it is believed on.
    static let calibrationSample = 2_000
    static let minimumCalibration = 200

    /// The prompts as vectors, for one model, with that model's bars.
    struct Prompts: Sendable {
        var model: String
        var bars: Bars
        var product: [[Float]]
        var other: [[Float]]
        /// In `StyleWords.vocabulary` order.
        var styles: [(word: String, vector: [Float])]
    }

    /// Each style word's catalogue mean, taken off before a word is given.
    struct Calibration: Sendable, Equatable {
        var offsets: [String: Double]
    }

    /// The model's bars unless given others — the tests', or the eval's sweep. Throws
    /// `Unmeasured` for a model with none, so nothing reads against another model's.
    static func prompts(using provider: any EmbeddingProvider, bars: Bars? = nil) async throws -> Prompts {
        let model = try await provider.space.model
        guard let bars = bars ?? measuredBars[model] else { throw Unmeasured(model: model) }
        let product = try await provider.embed(texts: productPrompts)
        let other = try await provider.embed(texts: otherPrompts)
        var styles: [(String, [Float])] = []
        for word in StyleWords.vocabulary {
            let phrases = (styleDescriptions[word] ?? [word]).map(stylePrompt)
            styles.append((word, normalised(mean(try await provider.embed(texts: phrases)))))
        }
        return Prompts(model: model, bars: bars, product: product, other: other, styles: styles)
    }

    /// Offsets from the mean photograph and the mean text: the mean of a dot product is the dot
    /// product with the mean, so two averages stand for the whole catalogue.
    static func calibration(meanImage: [Float], meanText: [Float], prompts: Prompts) -> Calibration {
        var offsets: [String: Double] = [:]
        for (word, vector) in prompts.styles {
            offsets[word] = imageWeight * dot(vector, meanImage) + (1 - imageWeight) * dot(vector, meanText)
        }
        return Calibration(offsets: offsets)
    }

    /// How much more a photograph looks like a product shot than like anything else.
    static func shotScore(_ photo: [Float], _ prompts: Prompts) -> Double {
        let product = prompts.product.map { dot($0, photo) }.max() ?? 0
        let other = prompts.other.map { dot($0, photo) }.max() ?? 0
        return product - other
    }

    static func isProductShot(_ score: Double, _ bars: Bars) -> Bool { score > bars.shotMargin }

    /// The best-scoring photograph that clears the bar, or nil.
    static func best(_ scores: [(index: Int, score: Double)], _ bars: Bars) -> Int? {
        scores.filter { isProductShot($0.score, bars) }.max { $0.score < $1.score }?.index
    }

    /// Every style word's score for one photograph, its catalogue mean taken off, best first.
    static func styleScores(photo: [Float], text: [Float]?, prompts: Prompts, calibration: Calibration) -> [(word: String, score: Double)] {
        prompts.styles.map { word, vector -> (word: String, score: Double) in
            let image = dot(vector, photo)
            let words = text.map { dot(vector, $0) } ?? image
            return (word, imageWeight * image + (1 - imageWeight) * words - (calibration.offsets[word] ?? 0))
        }
        .sorted { $0.score > $1.score }
    }

    /// At most `StyleWords.maximum` words, best first, each clearing the bar.
    static func styleWords(photo: [Float], text: [Float]?, prompts: Prompts, calibration: Calibration) -> [String] {
        styleScores(photo: photo, text: text, prompts: prompts, calibration: calibration)
            .filter { $0.score >= prompts.bars.styleBar }
            .prefix(StyleWords.maximum)
            .map(\.word)
    }

    /// What the sidecar is sent for a photograph — the embedding backfill's small rendition.
    static func rendition(_ url: URL) -> URL { SemanticIndex.rendition(url) }

    /// What became of reading one product.
    struct Outcome: Sendable {
        var verdict: ProductPhotoVerdict
        /// The shot's own vector when it is not the first photograph — what photo search compares.
        var shotVector: [Float]?
        /// Photographs written off in this reading, as stored.
        var gone: [String] = []
        /// Photographs that may answer later. Non-zero leaves the reading unsettled.
        var unavailable = 0
        /// Photographs embedded for it.
        var asked = 0
    }

    /// One product's reading.
    ///
    /// - Parameters:
    ///   - first: the lead photograph's stored vector, or nil when it was written off.
    ///   - text: the product's stored text vector.
    ///   - others: the photographs after the first that may still be asked, as stored, with their
    ///     positions — those already written off left out by the caller.
    ///   - embed: asks for some of them; the caller paces it. Run in the caller's isolation, so
    ///     it may be a closure over the caller's state.
    static func read(
        isolation: isolated (any Actor)? = #isolation,
        first: [Float]?,
        text: [Float]?,
        others: [(index: Int, url: String)],
        prompts: Prompts,
        calibration: Calibration,
        embed: ([URL]) async throws -> [ImageEmbedding]
    ) async throws -> Outcome {
        if let first, isProductShot(shotScore(first, prompts), prompts.bars) {
            return Outcome(verdict: ProductPhotoVerdict(
                shotIndex: 0,
                styleWords: styleWords(photo: first, text: text, prompts: prompts, calibration: calibration)
            ))
        }
        var outcome = Outcome(verdict: ProductPhotoVerdict(shotIndex: nil, styleWords: []))
        var scored: [(index: Int, score: Double)] = []
        var vectors: [Int: [Float]] = [:]
        let candidates = others.prefix(extraPhotographs).compactMap { entry -> (index: Int, url: String, asked: URL)? in
            guard let url = URL(string: entry.url), url.scheme == "http" || url.scheme == "https" else {
                outcome.gone.append(entry.url)
                return nil
            }
            return (entry.index, entry.url, rendition(url))
        }
        for chunk in stride(from: 0, to: candidates.count, by: extraChunk).map({ Array(candidates[$0..<min($0 + extraChunk, candidates.count)]) }) {
            let answers = try await embed(chunk.map(\.asked))
            guard answers.count == chunk.count else {
                throw EmbeddingError.wrongCount(expected: chunk.count, got: answers.count)
            }
            outcome.asked += chunk.count
            for (entry, answer) in zip(chunk, answers) {
                switch answer {
                case .vector(let vector):
                    vectors[entry.index] = vector
                    scored.append((entry.index, shotScore(vector, prompts)))
                case .gone:
                    outcome.gone.append(entry.url)
                case .unavailable:
                    outcome.unavailable += 1
                }
            }
            // Found one: the rest of the gallery is not worth a request.
            if best(scored, prompts.bars) != nil { break }
        }
        let shot = best(scored, prompts.bars)
        let measured = shot.flatMap { vectors[$0] } ?? first
        outcome.verdict = ProductPhotoVerdict(
            shotIndex: shot,
            styleWords: measured.map { styleWords(photo: $0, text: text, prompts: prompts, calibration: calibration) } ?? []
        )
        outcome.shotVector = shot.flatMap { vectors[$0] }
        // A shot found settles it whatever else did not answer.
        if shot != nil { outcome.unavailable = 0 }
        return outcome
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return Double(sum)
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let width = vectors.first?.count else { return [] }
        var out = [Float](repeating: 0, count: width)
        for vector in vectors where vector.count == width {
            for index in 0..<width { out[index] += vector[index] }
        }
        return out.map { $0 / Float(vectors.count) }
    }

    static func normalised(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return norm == 0 ? vector : vector.map { $0 / norm }
    }
}

// MARK: - The backfill

/// Reads every listed product's photographs once per method, a batch at a time, behind the
/// embedding backfill. Postgres only — its due query compares slices of `image_urls`.
actor ProductReadingBackfill {
    /// Unavailable answers before a reading is settled as it stands — `EmbeddingBackfill`'s rule.
    static let maxAttempts = EmbeddingBackfill.maxImageAttempts

    struct Pass: Sendable, Equatable, CustomStringConvertible {
        var read = 0
        /// A shot past the first photograph.
        var movedShots = 0
        var noShot = 0
        var withWords = 0
        /// Photographs embedded beyond the first.
        var asked = 0
        var gone = 0
        var unsettled = 0
        var method: String?
        /// Why nothing was read, when that is the answer.
        var waiting: String?

        var description: String {
            if let waiting, read == 0 { return "readings: \(waiting)" }
            return "read \(read) (\(movedShots) shots past the first photograph, \(noShot) with none, \(withWords) with style words; "
                + "\(asked) more photographs embedded, \(gone) written off, \(unsettled) to ask again)"
                + (method.map { " by \($0)" } ?? "")
        }
    }

    private let app: Application
    private let batch: Int
    private let method: ProductReadingMethod
    private let minimumCalibration: Int
    private let pause: Duration
    /// Bars in place of the model's measured ones — for tests, whose provider is a fake.
    private let bars: ZeroShot.Bars?
    private var task: Task<Void, Never>?
    private var prompts: ZeroShot.Prompts?
    private var calibration: (model: String, value: ZeroShot.Calibration, at: Date)?
    /// Why the last pass read nothing, so the loop says it once rather than every minute.
    private var saidWaiting: String?

    init(
        app: Application,
        method: ProductReadingMethod,
        batch: Int = 16,
        minimumCalibration: Int = ZeroShot.minimumCalibration,
        pause: Duration = ZeroShot.extraPause,
        bars: ZeroShot.Bars? = nil
    ) {
        self.app = app
        self.method = method
        self.batch = batch
        self.minimumCalibration = minimumCalibration
        self.pause = pause
        self.bars = bars
    }

    /// One batch. `read == 0` means nothing is due, or there is nothing to read with — `waiting`
    /// says which.
    @discardableResult
    func runOnce(now: Date = Date()) async throws -> Pass {
        guard let sql = app.db as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return Pass(waiting: "not Postgres")
        }
        switch method {
        case .siglip: return try await readBySigLIP(sql: sql, now: now)
        case .haiku: return try await readByModel(sql: sql, now: now)
        }
    }

    // MARK: SigLIP

    private func readBySigLIP(sql: any SQLDatabase, now: Date) async throws -> Pass {
        guard let provider = app.semanticSearch else { return Pass(waiting: "embeddings are off") }
        let space = try await provider.space
        let prompts: ZeroShot.Prompts
        do {
            prompts = try await self.prompts(for: space, provider: provider)
        } catch let unmeasured as ZeroShot.Unmeasured {
            // Waiting, not failing: the sidecar was switched to a model nobody has measured the
            // bars for, and reading against another model's would be wrong on every product.
            return Pass(waiting: unmeasured.description)
        }
        guard let calibration = try await calibration(for: space, prompts: prompts, sql: sql, now: now) else {
            return Pass(waiting: "fewer than \(minimumCalibration) photographs embedded under \(space.model) to calibrate on")
        }
        let key = method.key(model: space.model)

        // Due: a listed product whose lead photograph's embedding is settled under this model —
        // a vector, or written off — and whose reading is missing, by another method, model or
        // version, of other photographs, or waiting for a retry that has come.
        let rows = try await sql.raw("""
            SELECT p.id AS id, p.image_urls[1:\(literal: 1 + ZeroShot.extraPhotographs)] AS photos,
                   md5(array_to_string(p.image_urls[1:\(literal: 1 + ZeroShot.extraPhotographs)], ' ')) AS digest,
                   e.image_embedding::text AS first, e.text_embedding::text AS text,
                   r.method AS was_method, r.photographs AS was_photographs, r.attempts AS was_attempts, r.gone AS was_gone
            FROM products p
            JOIN product_embeddings e ON e.product_id = p.id AND e.model = \(bind: space.model)
            LEFT JOIN product_readings r ON r.product_id = p.id
            WHERE p.kind = 'product' AND p.unlisted_at IS NULL AND cardinality(p.image_urls) > 0
              AND e.image_url IS NOT DISTINCT FROM p.image_urls[1] AND e.image_retry_at IS NULL
              AND (r.product_id IS NULL OR r.method <> \(bind: key)
                   OR r.photographs <> md5(array_to_string(p.image_urls[1:\(literal: 1 + ZeroShot.extraPhotographs)], ' '))
                   OR r.retry_at <= \(bind: now))
            ORDER BY p.published_at DESC, p.id
            LIMIT \(literal: batch)
            """).all()
        var pass = Pass(method: key)
        guard !rows.isEmpty else { return pass }

        for row in rows {
            let due = try Due(row: row, key: key)
            let first = try row.decode(column: "first", as: String?.self).flatMap(SemanticIndex.parse)
            let text = try row.decode(column: "text", as: String?.self).flatMap(SemanticIndex.parse)
            let others = due.photos.enumerated().dropFirst()
                .filter { !due.gone.contains($0.element) }
                .map { (index: $0.offset, url: $0.element) }
            let outcome = try await ZeroShot.read(
                first: first, text: text, others: others, prompts: prompts, calibration: calibration
            ) { urls in
                let answers = try await provider.embed(imageURLs: urls)
                try? await Task.sleep(for: pause)
                return answers
            }
            try await write(outcome.verdict, for: due, gone: outcome.gone, unavailable: outcome.unavailable, now: now, sql: sql)
            // The product shot's own vector, for photo search (`SemanticIndex.Column.image`).
            // Only past the first photograph: there the lead's vector already is the shot's.
            try await sql.raw("""
                UPDATE product_embeddings SET shot_embedding = \(bind: outcome.shotVector.map(SemanticIndex.literal))::vector
                WHERE product_id = \(bind: due.id) AND model = \(bind: space.model)
                  AND (shot_embedding IS NOT NULL OR \(bind: outcome.shotVector != nil))
                """).run()
            pass.note(outcome.verdict, asked: outcome.asked, gone: outcome.gone.count, unsettled: outcome.unavailable > 0)
        }
        return pass
    }

    private func prompts(for space: EmbeddingSpace, provider: any EmbeddingProvider) async throws -> ZeroShot.Prompts {
        if let prompts, prompts.model == space.model { return prompts }
        let made = try await ZeroShot.prompts(using: provider, bars: bars)
        prompts = made
        return made
    }

    /// The catalogue's mean photograph and mean text, refreshed daily; nil until there are enough.
    private func calibration(
        for space: EmbeddingSpace, prompts: ZeroShot.Prompts, sql: any SQLDatabase, now: Date
    ) async throws -> ZeroShot.Calibration? {
        if let calibration, calibration.model == space.model, now.timeIntervalSince(calibration.at) < 86_400 {
            return calibration.value
        }
        if let override = app.styleCalibration { return override }
        let cast = SQLQueryString("::vector(\(literal: space.dimension))")
        guard let row = try await sql.raw("""
            SELECT avg(i\(cast))::text AS image, avg(t\(cast))::text AS text, count(*) AS n FROM (
              SELECT image_embedding AS i, text_embedding AS t FROM product_embeddings
              WHERE model = \(bind: space.model) AND image_embedding IS NOT NULL
              LIMIT \(literal: ZeroShot.calibrationSample)
            ) s
            """).first() else { return nil }
        let count = try row.decode(column: "n", as: Int.self)
        guard count >= minimumCalibration,
              let image = try row.decode(column: "image", as: String?.self).flatMap(SemanticIndex.parse),
              let text = try row.decode(column: "text", as: String?.self).flatMap(SemanticIndex.parse)
        else { return nil }
        let value = ZeroShot.calibration(meanImage: image, meanText: text, prompts: prompts)
        calibration = (space.model, value, now)
        return value
    }

    // MARK: The model

    private func readByModel(sql: any SQLDatabase, now: Date) async throws -> Pass {
        guard let service = app.ai else { return Pass(waiting: "AI is off") }
        let key = method.key(model: "fast")
        guard await AIBackground.allows(service, now: now, on: app.db) else {
            return Pass(method: key, waiting: "today's owner-paid allowance is spent")
        }
        let rows = try await sql.raw("""
            SELECT p.id AS id, p.title AS title, p.image_urls[1:\(literal: 1 + ZeroShot.extraPhotographs)] AS photos,
                   md5(array_to_string(p.image_urls[1:\(literal: 1 + ZeroShot.extraPhotographs)], ' ')) AS digest,
                   r.method AS was_method, r.photographs AS was_photographs, r.attempts AS was_attempts, r.gone AS was_gone
            FROM products p
            LEFT JOIN product_readings r ON r.product_id = p.id
            WHERE p.kind = 'product' AND p.unlisted_at IS NULL AND cardinality(p.image_urls) > 0
              AND (r.product_id IS NULL OR r.method <> \(bind: key)
                   OR r.photographs <> md5(array_to_string(p.image_urls[1:\(literal: 1 + ZeroShot.extraPhotographs)], ' '))
                   OR r.retry_at <= \(bind: now))
            ORDER BY p.published_at DESC, p.id
            LIMIT \(literal: batch)
            """).all()
        var pass = Pass(method: key)
        for row in rows {
            // Asked before every product: one call may take the day past the cap, the next is refused.
            guard await AIBackground.allows(service, now: now, on: app.db) else {
                pass.waiting = "today's owner-paid allowance is spent"
                break
            }
            let due = try Due(row: row, key: key)
            let urls = due.photos.compactMap(URL.init(string:)).map(ZeroShot.rendition)
            do {
                let answer = try await service.provider.readProductPhotos(
                    imageURLs: urls, title: try row.decode(column: "title", as: String.self)
                )
                await AIBackground.record(answer.costs, now: now, on: app.db)
                var verdict = answer.value
                if let shot = verdict.productShot, !due.photos.indices.contains(shot) { verdict.productShot = nil }
                let read = ProductPhotoVerdict(shotIndex: verdict.productShot, styleWords: StyleWords.clean(verdict.styleWords))
                try await write(read, for: due, gone: [], unavailable: 0, now: now, sql: sql)
                pass.note(read, asked: urls.count, gone: 0, unsettled: false)
            } catch {
                if let failure = error as? AIFailure { await AIBackground.record(failure.costs, now: now, on: app.db) }
                app.logger.info("readings: photographs of \(due.id) not read: \(String(describing: error))")
                // Not written as read: asked again later, and settled empty after the last try.
                try await write(nil, for: due, gone: [], unavailable: 1, now: now, sql: sql)
                pass.unsettled += 1
            }
        }
        return pass
    }

    // MARK: Writing

    /// What the due query said about one product.
    private struct Due {
        var id: UUID
        /// The method key this reading is written under.
        var key: String
        var photos: [String]
        var digest: String
        /// Unavailable answers already had for this same reading.
        var attempts: Int
        /// Photographs written off for this same reading.
        var gone: [String]

        init(row: any SQLRow, key: String) throws {
            id = try row.decode(column: "id", as: UUID.self)
            self.key = key
            photos = try row.decode(column: "photos", as: [String]?.self) ?? []
            digest = try row.decode(column: "digest", as: String.self)
            let same = try row.decode(column: "was_method", as: String?.self) == key
                && row.decode(column: "was_photographs", as: String?.self) == digest
            attempts = same ? (try row.decode(column: "was_attempts", as: Int?.self) ?? 0) : 0
            gone = same ? (try row.decode(column: "was_gone", as: [String]?.self) ?? []) : []
        }
    }

    /// The answer onto the product — only when it changes, because a write to `products` is a
    /// rewrite of the row — and the ledger beside it. A nil verdict is a reading that failed
    /// outright: the product keeps what it had until the last attempt settles it empty.
    private func write(
        _ verdict: ProductPhotoVerdict?, for due: Due, gone: [String], unavailable: Int, now: Date, sql: any SQLDatabase
    ) async throws {
        let attempts = unavailable > 0 ? due.attempts + 1 : 0
        let settled = unavailable == 0 || attempts >= Self.maxAttempts
        let retryAt = settled ? nil : now.addingTimeInterval(EmbeddingBackfill.retryDelay(afterAttempt: attempts))
        let answer = verdict ?? (settled ? ProductPhotoVerdict(shotIndex: nil, styleWords: []) : nil)
        if let answer {
            try await sql.raw("""
                UPDATE products SET shot_index = \(bind: answer.shotIndex), style_words = \(bind: answer.styleWords)
                WHERE id = \(bind: due.id)
                  AND (shot_index IS DISTINCT FROM \(bind: answer.shotIndex) OR style_words IS DISTINCT FROM \(bind: answer.styleWords)::text[])
                """).run()
        }
        let written = Array(Set(due.gone + gone)).sorted()
        if settled, attempts >= Self.maxAttempts {
            app.logger.notice("readings: \(due.id) settled after \(attempts) unanswered tries")
        }
        try await sql.raw("""
            INSERT INTO product_readings (product_id, method, photographs, read_at, attempts, retry_at, gone)
            VALUES (\(bind: due.id), \(bind: due.key), \(bind: due.digest), \(bind: now),
                    \(bind: settled ? 0 : attempts), \(bind: retryAt), \(bind: written)::text[])
            ON CONFLICT (product_id) DO UPDATE SET
              method = EXCLUDED.method, photographs = EXCLUDED.photographs, read_at = EXCLUDED.read_at,
              attempts = EXCLUDED.attempts, retry_at = EXCLUDED.retry_at, gone = EXCLUDED.gone
            """).run()
    }

    // MARK: Running

    /// Batches until nothing is due, then waits and looks again — the embedding backfill keeps
    /// making products due as it reaches them.
    func start(interval: Duration = .seconds(60)) {
        guard task == nil else { return }
        let logger = app.logger
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    let pass = try await self.runOnce()
                    if pass.read > 0 {
                        logger.info("\(pass)")
                        continue
                    }
                    // Why nothing is read, once per reason — a model with no bars, above all.
                    if let waiting = pass.waiting, await self.isNews(waiting) {
                        logger.notice("\(pass)")
                    }
                } catch EmbeddingError.modelChanged {
                    continue
                } catch {
                    logger.error("readings: backfill failed: \(String(describing: error))")
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// True the first time a reason for waiting is seen, so the loop says it once.
    private func isNews(_ waiting: String) -> Bool {
        guard waiting != saidWaiting else { return false }
        saidWaiting = waiting
        return true
    }
}

extension ProductReadingBackfill.Pass {
    mutating func note(_ verdict: ProductPhotoVerdict, asked: Int, gone: Int, unsettled: Bool) {
        read += 1
        if let shot = verdict.shotIndex { if shot > 0 { movedShots += 1 } } else { noShot += 1 }
        if !verdict.styleWords.isEmpty { withWords += 1 }
        self.asked += asked
        self.gone += gone
        if unsettled { self.unsettled += 1 }
    }
}

struct ProductReadingBackfillKey: StorageKey {
    typealias Value = ProductReadingBackfill
}

struct ProductReadingMethodKey: StorageKey {
    typealias Value = ProductReadingMethod
}

struct StyleCalibrationKey: StorageKey {
    typealias Value = ZeroShot.Calibration
}

extension Application {
    /// A fixed calibration in place of the catalogue's mean — for tests, whose catalogues are a
    /// handful of products. Nil in production.
    var styleCalibration: ZeroShot.Calibration? {
        get { storage[StyleCalibrationKey.self] }
        set { storage[StyleCalibrationKey.self] = newValue }
    }

    var productReading: ProductReadingBackfill? { storage[ProductReadingBackfillKey.self] }

    /// `PRODUCT_READING`, as read at boot; SigLIP where nothing set it.
    var productReadingMethod: ProductReadingMethod {
        get { storage[ProductReadingMethodKey.self] ?? .siglip }
        set { storage[ProductReadingMethodKey.self] = newValue }
    }
}
