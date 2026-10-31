// AIStore.swift
// Whether the model-backed actions exist here, what each costs, and the one way to call them.
//
// **Nothing AI is drawn unless the server said it exists** (`GET /v1/ai`, `AIStatus.available`)
// and never standalone. A button that can only fail is the placeholder rule broken, so every
// affordance asks `isAvailable` first — and a deployment that turned its key off answers
// `available: false` on the next launch, which takes every one of them away at once.
//
// **Signed out is not unavailable.** Credits need an account (`docs/credits.md`), so an
// anonymous device is told "Sign in to use" and taken to sign-in — never shown a dead button,
// and never shown nothing, which would read as the feature not existing for it.
//
// **A refusal is said in words** (`AIRefusal`): not enough credits, this month's cost cap,
// sign in. Each has a different fix, and none of them is "no results" — a search that was
// refused did not run, and an empty list would be a claim about the catalogue it never made.
//
// The account's, like `CreditStore`, so it is built once in `streetwApp.init` and survives a
// profile switch; each call carries the profile current *when it starts*, because a paid
// search thread is signed for the profile that opened it (`AIThreadToken`). Every answer's
// `AICharge` goes straight to `CreditStore.apply`, so the balance on You is right without
// asking `/v1/credits` again. See `docs/ai.md`.

import Foundation
import Observation
import StreetwCore

@MainActor
@Observable
final class AIStore {
    /// What the server last said. Nil until asked, or when it could not be — which draws
    /// nothing, the same as `available: false`.
    private(set) var status: AIStatus?

    private let settings: ServerSettings
    private let credits: CreditStore

    init(settings: ServerSettings, credits: CreditStore) {
        self.settings = settings
        self.credits = credits
    }

    // MARK: - What may be drawn

    /// The model-backed actions exist here: a server, and one that holds a provider key.
    var isAvailable: Bool {
        settings.isConfigured && status?.available == true
    }

    /// The caller can spend credits. False on an available deployment means "Sign in to use".
    var isSignedIn: Bool {
        isAvailable && status?.signedIn == true
    }

    /// "Show me more" — the open web — is offered.
    var offersWebSearch: Bool {
        isAvailable && status?.webSearch == true
    }

    /// What an action costs, from the server's table. Nil when the server named no price for
    /// it, which is not the same as free and is never printed as such.
    func credits(for action: CreditAction) -> Int? {
        status?.credits[action.rawValue]
    }

    /// "1 CREDIT", "3 CREDITS" — for the affordance that spends it.
    func costLabel(for action: CreditAction) -> String? {
        credits(for: action).map(Self.creditsLabel)
    }

    nonisolated static func creditsLabel(_ count: Int) -> String {
        count == 1 ? "1 credit" : "\(count) credits"
    }

    // MARK: - Reading

    /// Asks the server. Keyed by the caller on the token, the account and the profile — the
    /// token because the page appears before registration finishes (`CLAUDE.md`), the account
    /// because signing in is what turns "Sign in to use" into a price.
    func refresh() async {
        guard let api = api() else {
            status = nil
            return
        }
        do {
            status = try await api.aiStatus()
        } catch APIError.server(let code, _) where code == 404 {
            // A server from before Phase 4 has no such route: there is no AI there.
            status = nil
        } catch {
            // Kept rather than cleared, `CreditStore`'s reason: a blink in the network must not
            // take the field's affordance away mid-thought. A first read that fails draws nothing.
        }
    }

    // MARK: - Calling

    /// One turn of a search thread. See `ShopAsk`.
    func search(_ request: AISearchRequest) async -> Result<AISearchResponse, AIRefusal> {
        await call { api in
            let response = try await api.aiSearch(request)
            return (response, response.charge)
        }
    }

    /// "Show me more".
    func webSearch(_ request: AIWebSearchRequest) async -> Result<AIWebSearchResponse, AIRefusal> {
        await call { api in
            let response = try await api.aiWebSearch(request)
            return (response, response.charge)
        }
    }

    /// The sentence for a few of today's picks. Free and device-authenticated, so it needs no
    /// account — only a deployment that has a model.
    func pickReasons(_ request: AIPickReasons) async -> Result<AIPickReasonsResponse, AIRefusal> {
        await call { api in (try await api.aiPickReasons(request), nil) }
    }

    /// One photograph of one garment, read. Two credits by the server's table.
    func scan(_ request: AIScanRequest) async -> Result<AIScanResponse, AIRefusal> {
        await call { api in
            let response = try await api.aiScan(request)
            return (response, response.charge)
        }
    }

    /// A whole fit judged from its photographs.
    func judgeFit(_ request: AIFitJudgeRequest) async -> Result<AIFitJudgeResponse, AIRefusal> {
        await call { api in
            let response = try await api.aiJudgeFit(request)
            return (response, response.charge)
        }
    }

    /// The phone's candidates for a fit, ordered and vetted from their photographs.
    func suggestForFit(_ request: AIFitSuggestRequest) async -> Result<AIFitSuggestResponse, AIRefusal> {
        await call { api in
            let response = try await api.aiSuggestForFit(request)
            return (response, response.charge)
        }
    }

    // MARK: - Transport

    /// Built per call, carrying the profile current *now* — see the file header.
    private func api() -> StreetwAPI? {
        guard let baseURL = settings.baseURL, settings.token != nil else { return nil }
        return StreetwAPI(baseURL: baseURL, token: settings.token, profileID: ProfileScope.active.id)
    }

    private func call<Response>(
        _ work: (StreetwAPI) async throws -> (Response, AICharge?)
    ) async -> Result<Response, AIRefusal> {
        guard isAvailable, let api = api() else { return .failure(.unavailable) }
        do {
            let (response, charge) = try await work(api)
            if let charge { credits.apply(charge) }
            return .success(response)
        } catch {
            let refusal = AIRefusal(error)
            // The deployment lost its key since `GET /v1/ai` answered: ask again, so every
            // affordance goes away rather than each failing in turn.
            if refusal == .unavailable { await refresh() }
            // Signed out since — or never, on a status read before sign-in landed.
            if refusal == .signedOut, status?.signedIn == true { await refresh() }
            return .failure(refusal)
        }
    }
}

/// Why an AI action did not run, in words somebody can act on.
enum AIRefusal: Error, Equatable {
    /// 403 — credits need an account.
    case signedOut
    /// 402 — the balance does not cover it.
    case notEnoughCredits
    /// 429 — the account's monthly cost cap, a guard against a looping bug, not a price.
    case costCap
    /// 503, or a deployment with no model since the status was read.
    case unavailable
    /// Anything else: the network, the server, an answer that did not decode.
    case failed(String)

    init(_ error: Error) {
        switch error {
        case APIError.forbidden, APIError.profileRefused:
            self = .signedOut
        case APIError.server(402, _):
            self = .notEnoughCredits
        case APIError.server(429, _):
            self = .costCap
        case APIError.server(503, _), APIError.notConfigured:
            self = .unavailable
        default:
            self = .failed(error.localizedDescription)
        }
    }

    /// The serif line.
    var title: String {
        switch self {
        case .signedOut: "Sign in to use"
        case .notEnoughCredits: "Not enough credits"
        case .costCap: "This month's AI limit is reached"
        case .unavailable: "Dropwall's AI isn't available right now"
        case .failed: "That didn't run"
        }
    }

    /// The sentence under it: what happened, and what fixes it.
    var detail: String {
        switch self {
        case .signedOut:
            "Credits need an account. Nothing was charged."
        case .notEnoughCredits:
            "Nothing was charged."
        case .costCap:
            "Nothing was charged. It resets on the 1st."
        case .unavailable:
            "Nothing was charged, and the search still works."
        case .failed(let message):
            // No claim about the charge: a reply lost on the way back may have been paid for.
            "Couldn't reach Dropwall: \(message)"
        }
    }

    /// The reason behind the line, a tap away — only where there is more to say than the line.
    var info: InfoNote? {
        switch self {
        case .signedOut:
            InfoNote(title: "Why sign in", lines: ["AI actions use credits, and credits are kept on your account."])
        case .notEnoughCredits:
            InfoNote(title: "Credits", lines: ["Credits never expire, and some are free each month you use them."])
        case .costCap:
            InfoNote(title: "This month's AI limit", lines: ["A safety limit on what this account's AI can cost in a month. It resets on the 1st."])
        case .unavailable, .failed:
            nil
        }
    }

    /// The one thing to press, when there is one: both open You, where sign-in leads the page
    /// and the packs are in Credits.
    var remedy: String? {
        switch self {
        case .signedOut: "Sign in"
        case .notEnoughCredits: "Get credits"
        case .costCap, .unavailable, .failed: nil
        }
    }
}
