// StreetwAPI.swift
// Talks to the Dropwall server. Wire types come from StreetwCore, so this file only
// deals with transport, auth and error reporting.

import Foundation
import StreetwCore

enum APIError: LocalizedError {
    case notConfigured
    case unauthorized
    /// Refused, but **not** because the credential is stale.
    ///
    /// Kept apart from `.unauthorized` because the two have opposite repairs and only one
    /// of them is safe. A 401 means "I don't know this token" and re-registering is the
    /// cure; a 403 means "I know who you are and the answer is no" — a WAF rule, an edge
    /// blocking the request before it reaches Vapor, a route that has been locked down.
    /// Spending the token on that throws away a working identity and, because
    /// `POST /v1/devices` mints a device with no follows, the follow list with it.
    case forbidden(String?)
    /// The request named a profile this device may no longer act for — deleted on another
    /// phone, the account deleted, or the device re-registered. Told apart from `.forbidden`
    /// by the server's exact reason (`ProfileHeader.refusal`), because the repair is to fall
    /// back to the holder's profile and that must not happen on a 403 from an edge.
    case profileRefused
    case server(Int, String?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No server URL set"
        case .unauthorized: "This device isn't registered with the server"
        case .forbidden(let reason): reason.map { "\($0) (403)" } ?? "Dropwall refused the request (403)"
        case .profileRefused: "This profile is no longer on your account"
        case .server(let code, let reason): reason.map { "\($0) (\(code))" } ?? "Server error \(code)"
        case .transport(let message): message
        }
    }
}

/// Where the server lives and who we are to it. Persisted so a relaunch doesn't
/// re-register and orphan the previous device's follows.
@MainActor
@Observable
final class ServerSettings {
    var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: "serverBaseURL") }
    }

    /// Bearer credential issued by `POST /v1/devices`.
    ///
    /// Stored in UserDefaults for now. It grants access only to this device's own feed
    /// and follows, but it is still a credential — Keychain is the right home once the
    /// app does anything more sensitive.
    var token: String? {
        didSet {
            UserDefaults.standard.set(token, forKey: "serverToken")
            // An account hangs off the device the token names. A new token is a new
            // anonymous device, whatever the old one was signed in as.
            if token != oldValue { account = nil }
        }
    }

    /// The Sign in with Apple account this device is on, as the server last said. Nil for
    /// an anonymous device. A remembered answer, so the You page can draw without a
    /// round trip; `RemoteSync.refreshAccount` corrects it, which is what notices a
    /// deletion made from another phone.
    var account: AccountDTO? {
        didSet {
            UserDefaults.standard.set(account.flatMap { try? JSONEncoder().encode($0) }, forKey: "serverAccount")
            if account?.id != oldValue?.id { accountChanged?() }
        }
    }

    /// Told when the account changes — a sign-in, a deletion, or a token the server no longer
    /// knows, which re-registers as nobody — so `ProfileStore` can move the app onto a store
    /// the new account may see. Without it a lapsed token left the phone signed out on the
    /// previous account's own store, and its first sync re-followed that account's brands on
    /// the new anonymous device.
    @ObservationIgnored var accountChanged: (() -> Void)?

    /// The deployed server. There is exactly one, and it is not user-configurable.
    ///
    /// A domain we control, deliberately, rather than the platform-generated hostname this
    /// shipped with in development. The address is compiled in and there is no UI to change
    /// it, so a host that can be renamed out from under us — by a project rename, or by
    /// moving off the platform — strands every installed copy with no recovery path and no
    /// error a user could act on.
    static let defaultBaseURLString = "app.streetw.hottorun.com"

    /// Hosts this app has shipped pointing at before, and must move off.
    ///
    /// `init` prefers a stored address over the default. That is right for a value somebody
    /// *chose* and wrong for one the app wrote itself on first launch — and since the field
    /// that let anyone choose is gone, every stored value is now the latter. Without this
    /// set, changing `defaultBaseURLString` moves new installs only: every phone that has
    /// ever launched the app keeps talking to the old host for as long as it stays
    /// installed, which is precisely the dependency the change exists to end.
    ///
    /// Compared against the stored string as written — a bare host, no scheme, which is
    /// what `init` persists.
    static let legacyBaseURLStrings: Set<String> = [
        "selfless-exploration-production-86b2.up.railway.app"
    ]

    init() {
        // An empty stored value used to mean "deliberately standalone", because Settings
        // had a field you could clear. That field is gone — so an empty value is no
        // longer a choice anyone can make on purpose, and treating it as one strands the
        // app offline forever with no way back. Anyone who cleared it while the field
        // still existed is silently unrecoverable: the catalog search returns nothing,
        // brand recommendations never load, and watches never reach the server.
        //
        // So: empty falls back to the default, and opting out is an explicit dev flag
        // that cannot be reached by accident.
        let stored = UserDefaults.standard.string(forKey: "serverBaseURL") ?? ""
        let isStandalone = UserDefaults.standard.bool(forKey: "standalone")

        // An address the app wrote itself is not a preference to be preserved, so a stored
        // value only wins while it is still one we ship — see `legacyBaseURLStrings`.
        let isStale = stored.isEmpty || Self.legacyBaseURLStrings.contains(stored)
        baseURLString = isStandalone ? "" : (isStale ? Self.defaultBaseURLString : stored)
        // **Both read before either is assigned, and the account after the token.** On an
        // `@Observable` class an assignment here goes through the generated setter, `didSet`
        // included, once every stored property has a value — so the token's "a new token is a
        // new device" rule ran on every launch, cleared the account and deleted its key before
        // the next line could read it. A signed-in phone launched as signed out until You
        // asked the server again, and the current profile, which needs an account, fell back
        // to the holder on every launch.
        let storedToken = UserDefaults.standard.string(forKey: "serverToken")
        let storedAccount = UserDefaults.standard.data(forKey: "serverAccount")
            .flatMap { try? JSONDecoder().decode(AccountDTO.self, from: $0) }
        token = storedToken
        account = storedAccount

        // Assigning the stored property in `init` bypasses `didSet`, so persist here.
        if !baseURLString.isEmpty {
            UserDefaults.standard.set(baseURLString, forKey: "serverBaseURL")
        }
    }

    var baseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }

    var isConfigured: Bool { baseURL != nil }
    var isRegistered: Bool { token != nil }
}

struct StreetwAPI: Sendable {
    let baseURL: URL
    let token: String?
    /// The profile every request acts for, sent as `ProfileHeader.name`. Nil for the holder —
    /// and for every install that never signed in — which sends no header at all, so the
    /// requests are byte for byte what they were before profiles. See `docs/profiles.md`.
    var profileID: UUID? = nil

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    // MARK: Endpoints

    /// Whether a push could reach *this* device.
    ///
    /// Was `/status`, which answers about everybody and also reports the environment, the
    /// user count and the database error verbatim — a description of the deployment handed
    /// to anyone who asked. That endpoint is behind the admin key now; this is the part the
    /// app legitimately needs, scoped to the caller.
    func delivery() async throws -> DeliveryStatus {
        try await send(path: "v1/devices/me/delivery", method: "GET", body: Optional<Never>.none)
    }

    func register(_ body: RegisterDevice) async throws -> DeviceResponse {
        try await send(path: "v1/devices", method: "POST", body: body, authenticated: false)
    }

    func updateDevice(_ body: UpdateDevice) async throws {
        try await sendVoid(path: "v1/devices/me", method: "PATCH", body: body)
    }

    func account() async throws -> AccountStatus {
        try await send(path: "v1/account", method: "GET", body: Optional<Never>.none)
    }

    func signInWithApple(_ body: AppleSignIn) async throws -> AccountSession {
        try await send(path: "v1/account/apple", method: "POST", body: body)
    }

    /// Deletes the account and every device on it, this one included — the token this was
    /// sent with stops working as it answers.
    func deleteAccount() async throws {
        try await sendVoid(path: "v1/account", method: "DELETE", body: Optional<Never>.none)
    }

    func profiles() async throws -> [ProfileDTO] {
        try await send(path: "v1/account/profiles", method: "GET", body: Optional<Never>.none)
    }

    func createProfile(_ body: CreateProfile) async throws -> ProfileDTO {
        try await send(path: "v1/account/profiles", method: "POST", body: body)
    }

    func updateProfile(id: UUID, _ body: UpdateProfile) async throws -> ProfileDTO {
        try await send(path: "v1/account/profiles/\(id.uuidString)", method: "PATCH", body: body)
    }

    func deleteProfile(id: UUID) async throws {
        try await sendVoid(path: "v1/account/profiles/\(id.uuidString)", method: "DELETE", body: Optional<Never>.none)
    }

    func discover(_ body: DiscoverBrand) async throws -> BrandDTO {
        try await send(path: "v1/brands/discover", method: "POST", body: body)
    }

    func startCheck(url: String) async throws -> BrandCheck {
        try await send(path: "v1/brands/checks", method: "POST", body: StartBrandCheck(url: url))
    }

    func check(id: UUID) async throws -> BrandCheck {
        try await send(path: "v1/brands/checks/\(id.uuidString)", method: "GET", body: Optional<Never>.none)
    }

    func watchCheck(id: UUID, instagram: String?) async throws -> BrandCheck {
        try await send(
            path: "v1/brands/checks/\(id.uuidString)/watch",
            method: "POST",
            body: WatchBrandCheck(instagram: instagram)
        )
    }

    func follows() async throws -> [BrandDTO] {
        try await send(path: "v1/follows", method: "GET", body: Optional<Never>.none)
    }

    /// - Parameter mode: nil for a new follow, which the server makes `.everything`; set only
    ///   when a follow is being *restored* and the mode it had is known.
    func follow(brandID: UUID, mode: FollowMode? = nil) async throws {
        try await sendVoid(
            path: "v1/follows",
            method: "POST",
            body: FollowBrand(brandID: brandID, mode: mode)
        )
    }

    func setFollowMode(brandID: UUID, mode: FollowMode) async throws {
        try await sendVoid(
            path: "v1/follows/\(brandID.uuidString)",
            method: "PATCH",
            body: UpdateFollow(mode: mode)
        )
    }

    func unfollow(brandID: UUID) async throws {
        try await sendVoid(path: "v1/follows/\(brandID.uuidString)", method: "DELETE", body: Optional<Never>.none)
    }

    /// Search the shared catalog. One field takes a name or an address.
    func searchBrands(_ query: String) async throws -> [BrandDTO] {
        try await send(
            path: "v1/brands",
            method: "GET",
            body: Optional<Never>.none,
            query: [URLQueryItem(name: "q", value: query)]
        )
    }

    func popularBrands(limit: Int = 12) async throws -> [PopularBrand] {
        try await send(
            path: "v1/brands/popular",
            method: "GET",
            body: Optional<Never>.none,
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    /// A page of garments from brands this device does not follow.
    ///
    /// The cursor is opaque and is echoed back exactly as it arrived — it encodes a depth
    /// through every unfollowed catalogue, not a date, and nothing on this side should be
    /// doing arithmetic on it.
    func discover(cursor: String?) async throws -> DiscoverResponse {
        try await send(
            path: "v1/discover",
            method: "GET",
            body: Optional<Never>.none,
            query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        )
    }

    func createWatch(_ body: CreateWatch) async throws -> WatchDTO {
        try await send(path: "v1/watches", method: "POST", body: body)
    }

    func deleteWatch(id: UUID) async throws {
        try await sendVoid(path: "v1/watches/\(id.uuidString)", method: "DELETE", body: Optional<Never>.none)
    }

    func watches() async throws -> [WatchDTO] {
        try await send(path: "v1/watches", method: "GET", body: Optional<Never>.none)
    }

    /// One page of the feed — the head of a read, or the rest of one. See `FeedPager`.
    func feed(_ request: FeedPager.Request, limit: Int = 200) async throws -> FeedResponse {
        // Every kind this build can draw. Without it the server sends only what 1.0 knows,
        // which is the point of it — see `FeedKinds`.
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: FeedKinds.parameter, value: FeedKinds.understood)
        ]
        switch request {
        case .head(let since):
            if let since {
                query.append(URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since)))
            }
        case .resume(let token):
            // Echoed exactly as it arrived; it is the server's own place in its own order.
            query.append(URLQueryItem(name: "continuation", value: token))
        }
        return try await send(path: "v1/feed", method: "GET", body: Optional<Never>.none, query: query)
    }

    /// Replaces this device's whole set of poll hints. See `DropHints` for what goes in it
    /// and `PollHintPolicy` for what the server will accept.
    ///
    /// `PUT`, not `POST`, because that is what it is: the body is the complete set, and an
    /// empty one withdraws everything. The response says what was taken and what was
    /// refused, per brand — "your hint didn't work" is equally true for a brand you have
    /// unfollowed and a date that has already passed.
    func putPollHints(_ hints: [PollHint]) async throws -> PollHintsResponse {
        try await send(path: "v1/poll-hints", method: "PUT", body: PollHintSync(hints: hints))
    }

    /// Adds this device's tallies to everybody's totals. See `UsageCounts`.
    func reportUsage(_ report: UsageReport) async throws -> UsageReceipt {
        try await send(path: "v1/usage", method: "POST", body: report)
    }

    /// The balance, this month's usage and the packs — or `signedIn: false` and nothing else.
    /// See `CreditStore`.
    func credits() async throws -> CreditsSummary {
        try await send(path: "v1/credits", method: "GET", body: Optional<Never>.none)
    }

    /// Hands one StoreKit transaction to the server, exactly as StoreKit signed it. Any 2xx
    /// is final; anything else leaves the transaction to be posted again.
    func postPurchase(signedTransaction: String) async throws -> CreditPurchaseReceipt {
        try await send(
            path: "v1/credits/purchases",
            method: "POST",
            body: CreditPurchase(signedTransaction: signedTransaction)
        )
    }

    /// One brand's recent history, outside the feed cursor. See the route's own note for
    /// why this cannot be a `since` on `/v1/feed`.
    func brandFeed(brandID: UUID, limit: Int = 60) async throws -> FeedResponse {
        try await send(
            path: "v1/brands/\(brandID.uuidString)/feed",
            method: "GET",
            body: Optional<Never>.none,
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: FeedKinds.parameter, value: FeedKinds.understood)
            ]
        )
    }

    // MARK: Transport

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        query: [URLQueryItem] = [],
        authenticated: Bool = true
    ) async throws -> Response {
        let data = try await perform(path: path, method: method, body: body, query: query, authenticated: authenticated)
        do {
            return try APICoding.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.transport("Unexpected response: \(error.localizedDescription)")
        }
    }

    private func sendVoid<Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        authenticated: Bool = true
    ) async throws {
        _ = try await perform(path: path, method: method, body: body, query: [], authenticated: authenticated)
    }

    private func perform<Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        query: [URLQueryItem],
        authenticated: Bool
    ) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.notConfigured }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try APICoding.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token else { throw APIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let profileID {
                request.setValue(profileID.uuidString, forHTTPHeaderField: ProfileHeader.name)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        // Vapor reports failures as {"error": true, "reason": "..."}.
        func reason() -> String? {
            (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["reason"]?.stringValue
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200...299:
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            let said = reason()
            if profileID != nil, said == ProfileHeader.refusal { throw APIError.profileRefused }
            throw APIError.forbidden(said)
        default:
            throw APIError.server(code, reason())
        }
    }
}

/// Minimal decoder for Vapor's error envelope, whose values are mixed types.
private enum JSONValue: Decodable {
    case string(String)
    case bool(Bool)
    case other

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .other
        }
    }
}
