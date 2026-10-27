// AIWire.swift
// The wire contract for Phase 4's model-backed actions: what the phone sends to `/v1/ai/…`
// and what comes back. Shared by both ends for the reason every DTO in `API.swift` is.
//
// The rules the shapes encode — see `docs/ai.md`:
//
// - **The model never answers with products.** It reads the text into the same `ShopQuery`
//   grammar the field already prints (`AISearchReading.query`), and the server's own search
//   finds the products. A model that named products could name ones that do not exist.
// - **A thread is held by the phone, not the server.** Each turn sends the previous ones back
//   with a signed `threadToken`, so nothing anybody typed is stored, and a follow-up inside a
//   paid thread is not charged again.
// - **Every optional field is optional** so a server that learns a field does not fail an
//   older phone's decode, and every enum-like value is a string for the same reason.

import Foundation

// MARK: - Availability

/// `GET /v1/ai` — whether the model-backed actions exist on this deployment, and what each
/// costs. The phone draws no AI affordance at all when `available` is false: a button that
/// can only fail is the placeholder rule (`CLAUDE.md`) broken.
public struct AIStatus: Codable, Sendable, Hashable {
    /// The deployment holds a provider key.
    public var available: Bool
    /// Whether "Show me more" (the open web) is offered.
    public var webSearch: Bool
    /// Credits per action, keyed by `CreditAction` raw value — the server's table
    /// (`CreditPolicy`), so a price change needs no app update.
    public var credits: [String: Int]
    /// The caller can spend: signed in. False is "Sign in to use", not "unavailable".
    public var signedIn: Bool

    public init(available: Bool, webSearch: Bool, credits: [String: Int], signedIn: Bool) {
        self.available = available
        self.webSearch = webSearch
        self.credits = credits
        self.signedIn = signedIn
    }
}

/// What an action cost, returned beside its answer so the phone can update the balance
/// without asking `/v1/credits` again.
public struct AICharge: Codable, Sendable, Hashable {
    /// Taken by this request: zero on an unlimited account and on a follow-up inside a thread
    /// that was already paid for.
    public var credits: Int
    /// The balance after it. Nil on an unlimited account.
    public var balance: Int?

    public init(credits: Int, balance: Int?) {
        self.credits = credits
        self.balance = balance
    }
}

// MARK: - Search

/// One earlier turn of a search thread, as the phone holds it.
public struct AISearchTurn: Codable, Sendable, Hashable {
    /// What was typed: the first description, or a short reply ("no wool", "more formal").
    public var text: String
    /// What the model read it as, in the grammar — sent back so the next turn refines that
    /// reading rather than re-deriving it from scratch.
    public var query: String

    public init(text: String, query: String) {
        self.text = text
        self.query = query
    }
}

/// `POST /v1/ai/search`.
public struct AISearchRequest: Codable, Sendable {
    /// This turn's text.
    public var text: String
    /// Earlier turns, oldest first. Empty on a thread's first turn.
    public var thread: [AISearchTurn]
    /// From the previous answer; nil on the first turn. A turn with a valid token is not
    /// charged; one without starts — and pays for — a new thread.
    public var threadToken: String?
    /// Passed through to the search, as on `GET /v1/products/search`.
    public var scope: ProductSearchScope
    public var inMySize: Bool

    public init(
        text: String,
        thread: [AISearchTurn] = [],
        threadToken: String? = nil,
        scope: ProductSearchScope = .followed,
        inMySize: Bool = false
    ) {
        self.text = text
        self.thread = thread
        self.threadToken = threadToken
        self.scope = scope
        self.inMySize = inMySize
    }
}

/// What the model understood, in words the field can print.
public struct AISearchReading: Codable, Sendable, Hashable {
    /// The whole thread so far, rewritten in the `ShopQuery` grammar — "black suit under 400
    /// no wool formal". The server searched exactly this, and the phone prints its own
    /// `ShopQuery` reading of it, so the two cannot disagree about what was searched.
    public var query: String
    /// One short sentence back, when there is something worth saying — "Looking for summer
    /// weight: linen and cotton." Nil when the reading says it all.
    public var reply: String?
    /// Two to four short follow-ups worth offering as chips — "cheaper", "no wool",
    /// "in navy". Each is sent back as a turn's `text`.
    public var suggestions: [String]

    public init(query: String, reply: String? = nil, suggestions: [String] = []) {
        self.query = query
        self.reply = reply
        self.suggestions = suggestions
    }
}

/// The answer to one turn.
public struct AISearchResponse: Codable, Sendable {
    public var reading: AISearchReading
    /// The products, found by the server's own search over `reading.query` — exactly what
    /// `GET /v1/products/search` would answer for that text.
    public var results: ProductSearchResponse
    /// Pass back on the next turn. Expires; an expired one starts a new, paid thread.
    public var threadToken: String
    /// How many more turns this thread takes before a new one is needed.
    public var turnsLeft: Int
    public var charge: AICharge

    public init(
        reading: AISearchReading,
        results: ProductSearchResponse,
        threadToken: String,
        turnsLeft: Int,
        charge: AICharge
    ) {
        self.reading = reading
        self.results = results
        self.threadToken = threadToken
        self.turnsLeft = turnsLeft
        self.charge = charge
    }
}

/// `POST /v1/ai/search/web` — "Show me more": the same reading, asked of the open web.
public struct AIWebSearchRequest: Codable, Sendable {
    /// The grammar text to look for — the latest `AISearchReading.query`.
    public var query: String
    /// The reader's country (ISO 3166 alpha-2), so the shops found sell there.
    public var country: String?

    public init(query: String, country: String? = nil) {
        self.query = query
        self.country = country
    }
}

/// One product found on the open web. Nothing here is from our catalogue, so nothing is
/// claimed that the page did not say: price and photograph are optional.
public struct AIWebItem: Codable, Sendable, Hashable, Identifiable {
    public var title: String
    /// The shop's name as the page gave it.
    public var shop: String
    /// The product page — always the shop's own, never a search or aggregator page.
    public var url: URL
    public var price: Double?
    /// ISO 4217, beside `price`.
    public var currency: String?
    public var imageURL: URL?
    /// Set when the server already watches this shop: the brand to open rather than offer
    /// to follow. Nil means "Follow this shop" starts the ordinary site check on `url`'s host.
    public var brandID: UUID?

    public var id: URL { url }

    public init(
        title: String,
        shop: String,
        url: URL,
        price: Double? = nil,
        currency: String? = nil,
        imageURL: URL? = nil,
        brandID: UUID? = nil
    ) {
        self.title = title
        self.shop = shop
        self.url = url
        self.price = price
        self.currency = currency
        self.imageURL = imageURL
        self.brandID = brandID
    }
}

public struct AIWebSearchResponse: Codable, Sendable {
    public var items: [AIWebItem]
    public var charge: AICharge

    public init(items: [AIWebItem], charge: AICharge) {
        self.items = items
        self.charge = charge
    }
}

// MARK: - Daily picks

/// One pick the phone wants a sentence for. The phone chose it (`DailyPicks`); the model only
/// words why, from what the phone already knows is true.
public struct AIPickReasonRequest: Codable, Sendable, Hashable {
    public var productExternalID: String
    /// The garment from the reader's wardrobe it goes with, **as a short description only** —
    /// "black chore jacket" — never a photograph, a brand or an id. Nil when the pick is
    /// chosen for filling a gap rather than for a partner.
    public var anchor: String?
    /// The rule that chose it, as `Pairing` names it — "colour", "missing", "style". A string
    /// so a new rule does not break an older server.
    public var basis: String

    public init(productExternalID: String, anchor: String?, basis: String) {
        self.productExternalID = productExternalID
        self.anchor = anchor
        self.basis = basis
    }
}

/// `POST /v1/ai/picks/reasons` — free; at most `AIPicks.maxReasons` a request.
public struct AIPickReasons: Codable, Sendable {
    public var picks: [AIPickReasonRequest]

    public init(picks: [AIPickReasonRequest]) {
        self.picks = picks
    }
}

public struct AIPickReasonsResponse: Codable, Sendable {
    /// By `productExternalID`. A pick missing here keeps the phone's own reason.
    public var reasons: [String: String]

    public init(reasons: [String: String]) {
        self.reasons = reasons
    }
}

public enum AIPicks {
    /// The top few only — the roadmap's "a short reason for the top few".
    public static let maxReasons = 3
}

// MARK: - Clothes scan

/// `POST /v1/ai/scan` — one photograph of one garment.
public struct AIScanRequest: Codable, Sendable {
    /// JPEG, at most `AIScan.maxBytes`, already cut out on the phone where the cutout
    /// succeeded. Base64 in JSON rather than multipart so it travels like every other body.
    public var image: Data

    public init(image: Data) {
        self.image = image
    }
}

public enum AIScan {
    /// What the phone may send: a 1024px JPEG at 0.8 is well under this, and a garment needs
    /// no more to be read.
    public static let maxBytes = 1_500_000
    /// The longest edge the phone scales to before encoding.
    public static let maxEdge = 1024
}

/// What the photograph showed.
public struct AIScanReading: Codable, Sendable, Hashable {
    /// `GarmentSlot` raw value; `unknown` when the photograph is not one garment.
    public var slot: String
    /// What it is, in a shop's words — "chore jacket", "loafers".
    public var type: String
    /// Colour names, main first, in `ColorHarmony`'s canonical vocabulary where one fits.
    public var colours: [String]
    public var material: String?
    public var pattern: String?
    /// A few words of style — "workwear", "minimal".
    public var style: [String]
    /// One line to print under the photograph.
    public var description: String
    /// The grammar text to search for this or something like it — "black chore jacket canvas".
    public var searchText: String
    /// False when the model saw no garment; the phone says so and offers nothing.
    public var isGarment: Bool

    public init(
        slot: String,
        type: String,
        colours: [String],
        material: String? = nil,
        pattern: String? = nil,
        style: [String] = [],
        description: String,
        searchText: String,
        isGarment: Bool = true
    ) {
        self.slot = slot
        self.type = type
        self.colours = colours
        self.material = material
        self.pattern = pattern
        self.style = style
        self.description = description
        self.searchText = searchText
        self.isGarment = isGarment
    }
}

public struct AIScanResponse: Codable, Sendable {
    public var reading: AIScanReading
    /// Products that look like it, when the embedding service is on and could read the
    /// photograph; nil otherwise, and the phone searches `reading.searchText` instead.
    public var similar: [DiscoverCard]?
    public var charge: AICharge

    public init(reading: AIScanReading, similar: [DiscoverCard]? = nil, charge: AICharge) {
        self.reading = reading
        self.similar = similar
        self.charge = charge
    }
}

// MARK: - Fits

/// One garment in a fit, as the model is shown it.
public struct AIFitPiece: Codable, Sendable, Hashable {
    /// `GarmentSlot` raw value.
    public var slot: String
    /// Title or the scan's description — "black chore jacket".
    public var title: String
    /// The measured colour, when the phone has one.
    public var colour: String?
    /// A catalogue photograph the server may fetch. Exactly one of `imageURL` and `image`.
    public var imageURL: URL?
    /// The reader's own photograph (a scanned save), JPEG under `AIScan.maxBytes`.
    public var image: Data?

    public init(slot: String, title: String, colour: String? = nil, imageURL: URL? = nil, image: Data? = nil) {
        self.slot = slot
        self.title = title
        self.colour = colour
        self.imageURL = imageURL
        self.image = image
    }
}

public enum AIFits {
    /// A fit is a handful of garments; more is somebody's whole wardrobe.
    public static let maxPieces = 8
    /// Candidates offered to `/v1/ai/fits/suggest` per request.
    public static let maxCandidates = 12
}

/// `POST /v1/ai/fits/judge`.
public struct AIFitJudgeRequest: Codable, Sendable {
    public var pieces: [AIFitPiece]

    public init(pieces: [AIFitPiece]) {
        self.pieces = pieces
    }
}

public struct AIFitVerdict: Codable, Sendable, Hashable {
    /// "works", "risky" or "clashes" — the same three `Outfit` prints, as strings.
    public var verdict: String
    /// One line, said about the whole fit.
    public var summary: String
    /// A few specific observations, each about the photographs.
    public var notes: [String]
    /// Index into the request's `pieces` of the one to change, when there is one.
    public var swap: Int?

    public init(verdict: String, summary: String, notes: [String] = [], swap: Int? = nil) {
        self.verdict = verdict
        self.summary = summary
        self.notes = notes
        self.swap = swap
    }
}

public struct AIFitJudgeResponse: Codable, Sendable {
    public var verdict: AIFitVerdict
    public var charge: AICharge

    public init(verdict: AIFitVerdict, charge: AICharge) {
        self.verdict = verdict
        self.charge = charge
    }
}

/// `POST /v1/ai/fits/suggest` — which of these candidates go with what is already in the fit,
/// judged from the photographs. The phone chose the candidates (`FitSuggestions`); the model
/// only orders them and refuses the ones that clash.
public struct AIFitSuggestRequest: Codable, Sendable {
    public var fit: [AIFitPiece]
    public var candidates: [AIFitPiece]

    public init(fit: [AIFitPiece], candidates: [AIFitPiece]) {
        self.fit = fit
        self.candidates = candidates
    }
}

public struct AIFitSuggestion: Codable, Sendable, Hashable {
    /// Index into the request's `candidates`.
    public var candidate: Int
    public var reason: String

    public init(candidate: Int, reason: String) {
        self.candidate = candidate
        self.reason = reason
    }
}

public struct AIFitSuggestResponse: Codable, Sendable {
    /// Best first. A candidate missing from here was refused.
    public var suggestions: [AIFitSuggestion]
    public var charge: AICharge

    public init(suggestions: [AIFitSuggestion], charge: AICharge) {
        self.suggestions = suggestions
        self.charge = charge
    }
}
