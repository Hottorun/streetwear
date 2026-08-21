// StreetwAPI.swift
// Talks to the streetw server. Wire types come from StreetwCore, so this file only
// deals with transport, auth and error reporting.

import Foundation
import StreetwCore

enum APIError: LocalizedError {
    case notConfigured
    case unauthorized
    case server(Int, String?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No server URL set"
        case .unauthorized: "This device isn't registered with the server"
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
        didSet { UserDefaults.standard.set(token, forKey: "serverToken") }
    }

    /// The deployed server. There is exactly one, and it is not user-configurable.
    static let defaultBaseURLString = "selfless-exploration-production-86b2.up.railway.app"

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

        baseURLString = isStandalone ? "" : (stored.isEmpty ? Self.defaultBaseURLString : stored)
        token = UserDefaults.standard.string(forKey: "serverToken")

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

    func discover(_ body: DiscoverBrand) async throws -> BrandDTO {
        try await send(path: "v1/brands/discover", method: "POST", body: body)
    }

    func probe(url: String) async throws -> BrandProbe {
        try await send(
            path: "v1/brands/probe",
            method: "GET",
            body: Optional<Never>.none,
            query: [URLQueryItem(name: "url", value: url)]
        )
    }

    func follows() async throws -> [BrandDTO] {
        try await send(path: "v1/follows", method: "GET", body: Optional<Never>.none)
    }

    func follow(brandID: UUID) async throws {
        try await sendVoid(path: "v1/follows", method: "POST", body: FollowBrand(brandID: brandID))
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

    func createWatch(_ body: CreateWatch) async throws -> WatchDTO {
        try await send(path: "v1/watches", method: "POST", body: body)
    }

    func deleteWatch(id: UUID) async throws {
        try await sendVoid(path: "v1/watches/\(id.uuidString)", method: "DELETE", body: Optional<Never>.none)
    }

    func watches() async throws -> [WatchDTO] {
        try await send(path: "v1/watches", method: "GET", body: Optional<Never>.none)
    }

    func feed(since: Date?, limit: Int = 200) async throws -> FeedResponse {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let since {
            query.append(URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since)))
        }
        return try await send(path: "v1/feed", method: "GET", body: Optional<Never>.none, query: query)
    }

    /// One brand's recent history, outside the feed cursor. See the route's own note for
    /// why this cannot be a `since` on `/v1/feed`.
    func brandFeed(brandID: UUID, limit: Int = 60) async throws -> FeedResponse {
        try await send(
            path: "v1/brands/\(brandID.uuidString)/feed",
            method: "GET",
            body: Optional<Never>.none,
            query: [URLQueryItem(name: "limit", value: String(limit))]
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
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200...299:
            return data
        case 401, 403:
            throw APIError.unauthorized
        default:
            // Vapor reports failures as {"error": true, "reason": "..."}.
            let reason = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["reason"]?.stringValue
            throw APIError.server(code, reason)
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
