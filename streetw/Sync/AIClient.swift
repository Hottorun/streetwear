// AIClient.swift
// Whether the model-backed actions exist here, what each costs, and asking for one — with
// every way it can fail said in words.
//
// **Nothing AI is drawn unless the server says it can answer** (`AIStatus.available`), and
// never in standalone mode, which has no server to ask: a button that can only fail is a
// placeholder, and `CLAUDE.md` draws none. Signed out is not unavailable — the actions are
// offered and say "sign in", because the server's answer for that case is a 403 with a reason,
// not a missing feature. See `docs/ai.md`.

import Foundation
import Observation
import StreetwCore

/// What the phone knows about the AI actions on this deployment.
///
/// **One small seam, on purpose.** Shop's search reads the same `GET /v1/ai`, and the two halves
/// of Phase 4 were built side by side; whichever store ends up holding the answer, the scan and
/// the fit canvas only ever ask `isOffered`, `isSignedIn` and `credits(for:)`.
@MainActor
@Observable
final class AIAvailability {
    private(set) var status: AIStatus?
    private let settings: ServerSettings

    init(settings: ServerSettings) {
        self.settings = settings
    }

    /// Whether to draw any AI affordance at all.
    var isOffered: Bool { settings.isConfigured && status?.available == true }

    var isSignedIn: Bool { status?.signedIn == true }

    /// What an action costs, as the server's table says — so a price change needs no app
    /// update. The placeholders from `docs/ai.md` stand in only for a server that sent none.
    func credits(for action: CreditAction) -> Int {
        if let price = status?.credits[action.rawValue] { return price }
        switch action {
        case .scan: return 2
        default: return 1
        }
    }

    /// Asks the server. Keyed by its callers on the token, for the first-launch rule in
    /// `CLAUDE.md`: a view appears before registration finishes, and a 401 swallowed here
    /// would hide the feature for the whole session.
    func refresh() async {
        guard let api = AIClient.api(settings: settings, profile: nil) else {
            status = nil
            return
        }
        // Kept on failure: an answer from a minute ago beats every AI button vanishing because
        // the network blinked. A first ask that fails draws nothing, which is the safe side.
        if let answer = try? await api.aiStatus() { status = answer }
    }
}

/// A request that did not produce an answer, as somebody should be told it.
///
/// **A failure is never an empty answer.** "Nothing goes with it" and "it could not be asked"
/// are different sentences with different next steps, and printing the first for the second
/// is the failed-lookup rule in `CLAUDE.md`.
enum AIFailure: Error, Equatable {
    /// 402 — the server's reason names the balance.
    case notEnoughCredits(String?)
    /// 403 — credits need an account.
    case signIn
    /// 429 — the cost cap, or too many at once.
    case limit(String?)
    /// The request never reached the server, or its answer never came back.
    case offline
    /// The server answered and the action produced nothing; the charge is undone server-side.
    case failed(String?)

    var message: String {
        switch self {
        case .notEnoughCredits(let reason):
            return reason.map { "Not enough credits. \($0)" } ?? "Not enough credits for this."
        case .signIn:
            return "Sign in on the You page to use credits."
        case .limit(let reason):
            return reason ?? "That's the limit for now. Try again later."
        case .offline:
            return "Couldn't reach Dropwall. Check the connection and try again."
        case .failed:
            return "That didn't work, and nothing was charged for it. Try again in a moment."
        }
    }

    /// Worth offering "try again" for: the network, or a failure the server undid. The others
    /// have an answer that asking again will not change.
    var isRetryable: Bool {
        switch self {
        case .offline, .failed: true
        case .notEnoughCredits, .signIn, .limit: false
        }
    }

    init(_ error: any Error) {
        switch error {
        case APIError.server(402, let reason): self = .notEnoughCredits(reason)
        case APIError.forbidden: self = .signIn
        case APIError.server(429, let reason): self = .limit(reason)
        case APIError.transport, APIError.notConfigured, APIError.unauthorized: self = .offline
        case APIError.server(_, let reason): self = .failed(reason)
        default: self = .failed(nil)
        }
    }
}

/// The three calls the scan and the fit canvas make.
@MainActor
struct AIClient {
    let api: StreetwAPI

    static func api(settings: ServerSettings, profile: UUID?) -> StreetwAPI? {
        guard let baseURL = settings.baseURL, settings.token != nil else { return nil }
        return StreetwAPI(baseURL: baseURL, token: settings.token, profileID: profile)
    }

    init?(settings: ServerSettings, profile: UUID?) {
        guard let api = Self.api(settings: settings, profile: profile) else { return nil }
        self.api = api
    }

    func scan(_ jpeg: Data) async -> Result<AIScanResponse, AIFailure> {
        await run { try await api.aiScan(AIScanRequest(image: jpeg)) }
    }

    func judge(_ pieces: [AIFitPiece]) async -> Result<AIFitJudgeResponse, AIFailure> {
        await run { try await api.aiJudgeFit(AIFitJudgeRequest(pieces: Array(pieces.prefix(AIFits.maxPieces)))) }
    }

    func suggest(fit: [AIFitPiece], candidates: [AIFitPiece]) async -> Result<AIFitSuggestResponse, AIFailure> {
        await run {
            try await api.aiSuggestForFit(AIFitSuggestRequest(
                fit: Array(fit.prefix(AIFits.maxPieces)),
                candidates: Array(candidates.prefix(AIFits.maxCandidates))
            ))
        }
    }

    private func run<T>(_ body: () async throws -> T) async -> Result<T, AIFailure> {
        do {
            return .success(try await body())
        } catch {
            return .failure(AIFailure(error))
        }
    }
}

extension AICharge {
    /// "2 CREDITS USED · 14 LEFT", for the line under an answer. Nil when nothing was taken.
    var line: String? {
        guard credits > 0 else { return nil }
        let used = credits == 1 ? "1 CREDIT USED" : "\(credits) CREDITS USED"
        return balance.map { "\(used) · \($0) LEFT" } ?? used
    }
}

extension CreditAction {
    /// "2 CREDITS", said before anything is sent.
    static func price(_ credits: Int) -> String {
        credits == 1 ? "1 CREDIT" : "\(credits) CREDITS"
    }
}
