// Auth.swift
// Opaque per-device bearer tokens. No accounts, no PII — the `users` row exists so
// Sign in with Apple can be hung off it later without a migration of everything else.

import Fluent
import Vapor

struct DeviceAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard let device = try await DeviceModel.query(on: request.db)
            .filter(\.$authToken == bearer.token)
            .first()
        else { return } // leave unauthenticated; the guard below turns it into a 401
        request.storage[DeviceKey.self] = device
    }
}

struct DeviceKey: StorageKey {
    typealias Value = DeviceModel
}

extension Request {
    func authenticatedDevice() async throws -> DeviceModel {
        guard let device = storage[DeviceKey.self] else {
            throw Abort(.unauthorized, reason: "Register a device and send its token as a bearer token")
        }
        return device
    }
}

/// Makes membership of the authenticated group actually mean something.
///
/// **`grouped(DeviceAuthenticator())` does not require a device — it only offers to find
/// one.** Every route under it was protected purely because its handler happened to call
/// `authenticatedDevice()`, so a route that did not — the catalogue search, the site probe,
/// brand discovery — was wide open despite sitting in the group named `authed`. Discovery in
/// particular makes the server fetch a URL a stranger chose and write a row into a catalogue
/// everybody shares.
///
/// With this in front, being in the group is the guarantee it looks like, and a new route
/// cannot be accidentally public by forgetting a line inside its body.
struct RequireDevice: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        _ = try await request.authenticatedDevice()
        return try await next.respond(to: request)
    }
}

/// The operator's key, for the routes that poll on demand, send test pushes, and delete
/// brands.
///
/// **Closed by default, and that is the whole point.** These routes were reachable by
/// anybody who knew the path: `/admin/poll` makes the server fetch fifty storefronts,
/// `/admin/push-test` wakes every phone holding a token, and
/// `/admin/brands/<id>/delete?force=true` removes a brand and cascades away every follow on
/// it. None of that needed a password.
///
/// So a missing `ADMIN_TOKEN` **refuses** rather than allows. The tempting alternative —
/// "open when unset, so nothing breaks" — is a lock that is unlocked until somebody
/// remembers, on a deployment where forgetting is silent and the cost is somebody else
/// deleting the catalogue. Refusing is loud, and the fix is one environment variable.
///
/// Compared with `constantTimeEquals` rather than `==`, because a plain string comparison
/// on a secret leaks its length and its prefix to anybody willing to time the responses.
struct AdminAuthenticator: AsyncMiddleware {
    /// What a caller must present. Read from the environment **once**, where the group is
    /// built, rather than per request — partly so a request does no environment lookup, and
    /// mostly so the rule below can be tested without mutating process state that every
    /// other test in a parallel suite is also reading.
    var expected: String? = Environment.get("ADMIN_TOKEN")

    enum Decision: Equatable {
        case allow
        /// A key was offered and it was wrong, or none was offered.
        case unauthorized
        /// The deployment has no key set, so nothing can be allowed.
        case unconfigured
    }

    static func decide(offered: String?, expected: String?) -> Decision {
        guard let expected, !expected.isEmpty else { return .unconfigured }
        guard let offered, constantTimeEquals(offered, expected) else { return .unauthorized }
        return .allow
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let offered = request.headers.bearerAuthorization?.token
            ?? request.headers.first(name: "X-Admin-Token")
        switch Self.decide(offered: offered, expected: expected) {
        case .allow:
            return try await next.respond(to: request)
        case .unconfigured:
            request.logger.error("admin: refused — ADMIN_TOKEN is not set on this deployment")
            throw Abort(.serviceUnavailable, reason: "ADMIN_TOKEN is not configured on this deployment")
        case .unauthorized:
            throw Abort(.unauthorized, reason: "Send the admin token as a bearer token")
        }
    }

    /// Compares every byte regardless of where the first difference is, so the time taken
    /// says nothing about how much of the secret was right.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(left, right) { difference |= x ^ y }
        return difference == 0
    }
}
