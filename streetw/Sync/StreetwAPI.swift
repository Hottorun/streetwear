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

    /// The deployed server, so a fresh install is server-backed without anyone
    /// typing a URL. Applied only when *nothing* has been stored yet: clearing the
    /// field in Settings persists an empty string, which is a deliberate choice to
    /// run standalone and must not snap back to this on the next launch.
    static let defaultBaseURLString = "selfless-exploration-production-86b2.up.railway.app"

    init() {
        // `nil` means "never configured" — an explicitly cleared field reads as "".
        baseURLString = UserDefaults.standard.string(forKey: "serverBaseURL")
            ?? Self.defaultBaseURLString
        token = UserDefaults.standard.string(forKey: "serverToken")

        // Assigning the stored property in `init` bypasses `didSet`, so persist here.
        // This covers both the shipped default and `-serverBaseURL`, whose value lives
        // only in the volatile argument domain — writing it back makes the flag behave
        // like the other dev flags and survive a relaunch.
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

    func status() async throws -> StatusResponse {
        try await send(path: "status", method: "GET", body: Optional<Never>.none)
    }

    func register(_ body: RegisterDevice) async throws -> DeviceResponse {
        try await send(path: "v1/devices", method: "POST", body: body, authenticated: false)
    }

    func updateDevice(_ body: UpdateDevice) async throws {
        try await sendVoid(path: "v1/devices/me", method: "PATCH", body: body)
    }

    func discover(_ body: DiscoverBrand) async throws -> BrandDTO {
        try await send(path: "v1/brands/discover", method: "POST", body: body, authenticated: false)
    }

    func probe(url: String) async throws -> BrandProbe {
        try await send(
            path: "v1/brands/probe",
            method: "GET",
            body: Optional<Never>.none,
            query: [URLQueryItem(name: "url", value: url)],
            authenticated: false
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

    func feed(since: Date?, limit: Int = 200) async throws -> FeedResponse {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let since {
            query.append(URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since)))
        }
        return try await send(path: "v1/feed", method: "GET", body: Optional<Never>.none, query: query)
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
