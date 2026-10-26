// Auth.swift
// Opaque per-device bearer tokens. No accounts, no PII — the `users` row exists so
// Sign in with Apple can be hung off it later without a migration of everything else.

import Fluent
import StreetwCore
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

/// Which profile a request acts for — `X-Profile-ID`, checked against the device's account.
///
/// **Absent, nothing changes.** The request acts for the device's own user, which is every
/// request 1.0 and 1.1 make, every request from a device with no account, and every request
/// the holder's profile makes. That is what keeps every existing route working unchanged.
///
/// **Present, it must name a user on the same account as the device's user**, and otherwise
/// the request is refused with `ProfileHeader.refusal` — which the app recognises, so a
/// profile deleted on another phone falls back to the holder instead of reading as an app
/// with nothing in it. A device with no account is refused too: profiles need one.
///
/// In the group rather than in each route, for the reason `RequireDevice` is: a route that
/// read the header itself could forget the account check, and the failure would be one
/// person's follows readable by a stranger who guessed a user id. Routes ask
/// `actingUserID()`, never the header. See `docs/profiles.md`.
struct ActingProfile: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let raw = request.headers.first(name: ProfileHeader.name), !raw.isEmpty else {
            return try await next.respond(to: request)
        }
        guard let profileID = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "\(ProfileHeader.name) is not a profile id")
        }
        let device = try await request.authenticatedDevice()
        if profileID != device.$user.id {
            let own = try await UserModel.find(device.$user.id, on: request.db)
            guard let accountID = own?.$account.id,
                  let profile = try await UserModel.find(profileID, on: request.db),
                  profile.$account.id == accountID
            else { throw Abort(.forbidden, reason: ProfileHeader.refusal) }
        }
        request.storage[ActingUserKey.self] = profileID
        return try await next.respond(to: request)
    }
}

struct ActingUserKey: StorageKey {
    typealias Value = UUID
}

extension Request {
    /// The user whose follows, watches, hints and sizes this request reads and writes: the
    /// profile `ActingProfile` admitted, else the device's own user.
    func actingUserID() async throws -> UUID {
        if let id = storage[ActingUserKey.self] { return id }
        return try await authenticatedDevice().$user.id
    }

    /// The acting user's row, for the routes that need its sizes.
    func actingUser() async throws -> UserModel {
        guard let user = try await UserModel.find(try await actingUserID(), on: db) else {
            throw Abort(.unauthorized, reason: "Register a device and send its token as a bearer token")
        }
        return user
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
