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
