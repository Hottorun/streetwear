// AppleSignIn.swift
// Everything this server asks of Apple about an account, behind three small seams.
//
// - `AppleIdentityVerifying` — is this identity token Apple's, for this app, current, and
//   minted for the nonce the caller holds? Answers with the `sub`.
// - `AppleClientSecretSigning` — the ES256 JWT Apple wants as a `client_secret`.
// - `AppleTokenExchanging` — `/auth/token` at sign-in (for the refresh token) and
//   `/auth/revoke` at deletion, which Apple requires of an app that deletes accounts.
//
// **The production verifier refuses.** Checking an identity token's signature is RS256
// against Apple's published keys, and RSA is not in anything this package already links:
// `Crypto` (re-exported by Vapor) has SHA-256 and P-256 and nothing else. The dependency that
// adds it has not been approved, so until it is, sign-in is refused with a reason a person
// can read — the same stance `AdminAuthenticator` takes on a missing key. Accepting a token
// without its signature would let anybody who can write a JSON object sign in as anybody.
//
// What *is* real: the claim checks (`AppleIdentityClaims.check`), the client secret (P-256 is
// in `Crypto`, so no dependency), the token exchange and the revocation. A real verifier is
// a signature check in front of a function that already exists and is tested.
//
// **The test verifier is opt-in, and never in production.** `SIWA_TEST_TOKENS=true` on a
// deployment whose environment is not `production` accepts *unsigned* tokens and still runs
// every claim check, so the app can be driven through sign-in → merge → delete against a local
// server from a simulator with no Apple ID. `configure` refuses it on a production
// environment and says so at boot.

import Foundation
import Vapor

/// Apple's own issuer, and the audience every token for this app carries — the bundle id,
/// exactly as `APNS_TOPIC` must be. A constant rather than an environment value: a token
/// for some other app is never valid here, whatever a deployment is configured with.
enum AppleSignInConstants {
    static let issuer = "https://appleid.apple.com"
    static let clientID = "com.kern.functional.streetw"
}

struct AppleIdentity: Sendable, Equatable {
    /// Apple's `sub`: stable per developer team, opaque.
    var subject: String
}

protocol AppleIdentityVerifying: Sendable {
    func verify(identityToken: String, nonce: String, now: Date) async throws -> AppleIdentity
}

protocol AppleClientSecretSigning: Sendable {
    func clientSecret(now: Date) throws -> String
}

protocol AppleTokenExchanging: Sendable {
    /// Trades a sign-in's one-time code for the refresh token deletion will need. Nil when
    /// Apple answered without one.
    func refreshToken(forCode code: String) async throws -> String?
    func revoke(refreshToken: String) async throws
}

// MARK: - The claims

/// The part of verification that is not cryptography, and so is real today.
///
/// Every rule is something an attacker holding *a* genuine token would otherwise get past:
/// a token minted for another app (`aud`), by somebody else (`iss`), last week (`exp`), or for
/// another session's sign-in sheet (`nonce`).
struct AppleIdentityClaims: Decodable, Sendable {
    var iss: String
    var aud: Audience
    var exp: Double
    var sub: String
    var nonce: String?

    /// Apple sends a string; the JWT spec allows an array. Both are read so a change of
    /// shape is not an outage.
    enum Audience: Decodable, Sendable {
        case one(String)
        case many([String])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                self = .one(single)
            } else {
                self = .many(try container.decode([String].self))
            }
        }

        func contains(_ value: String) -> Bool {
            switch self {
            case .one(let single): single == value
            case .many(let all): all.contains(value)
            }
        }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case malformed
        case wrongIssuer
        case wrongAudience
        case expired
        case nonceMismatch
        case noSubject

        var description: String {
            switch self {
            case .malformed: "The identity token could not be read"
            case .wrongIssuer: "The identity token was not issued by Apple"
            case .wrongAudience: "The identity token is for a different app"
            case .expired: "The identity token has expired — sign in again"
            case .nonceMismatch: "The identity token was not issued for this sign-in"
            case .noSubject: "The identity token names nobody"
            }
        }
    }

    /// Reads the payload of a compact JWS. The signature is not looked at here — that is the
    /// verifier's job, and it must have been done before these claims mean anything.
    static func decode(_ token: String) throws -> AppleIdentityClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Data(base64URL: String(parts[1])) else {
            throw Failure.malformed
        }
        do {
            return try JSONDecoder().decode(AppleIdentityClaims.self, from: payload)
        } catch {
            throw Failure.malformed
        }
    }

    /// - Parameter nonce: the raw nonce the caller sent. Apple's claim is its SHA-256 in
    ///   lowercase hex, which is what the app put on the request.
    func check(nonce: String, now: Date) throws -> AppleIdentity {
        guard iss == AppleSignInConstants.issuer else { throw Failure.wrongIssuer }
        guard aud.contains(AppleSignInConstants.clientID) else { throw Failure.wrongAudience }
        guard now.timeIntervalSince1970 < exp else { throw Failure.expired }
        // A token with no nonce is refused rather than waved through: every sign-in this app
        // makes sets one, so a token without it came from somewhere else.
        guard let claimed = nonce.isEmpty ? nil : self.nonce,
              AdminAuthenticator.constantTimeEquals(claimed, Self.hash(nonce))
        else { throw Failure.nonceMismatch }
        guard !sub.isEmpty else { throw Failure.noSubject }
        return AppleIdentity(subject: sub)
    }

    static func hash(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Verifiers

/// What a deployment uses until RS256 is available: a refusal, with the reason.
struct UnavailableAppleIdentityVerifier: AppleIdentityVerifying {
    static let reason = "Sign in with Apple is not available on this server yet"

    func verify(identityToken: String, nonce: String, now: Date) async throws -> AppleIdentity {
        throw Abort(.serviceUnavailable, reason: Self.reason)
    }
}

/// Accepts an **unsigned** token and checks everything else. Local development only — see the
/// file header and `AppleSignInConfiguration.make`.
struct UnsignedAppleIdentityVerifier: AppleIdentityVerifying {
    func verify(identityToken: String, nonce: String, now: Date) async throws -> AppleIdentity {
        do {
            return try AppleIdentityClaims.decode(identityToken).check(nonce: nonce, now: now)
        } catch let failure as AppleIdentityClaims.Failure {
            throw Abort(.unauthorized, reason: failure.description)
        }
    }
}

// MARK: - The client secret

/// The ES256 JWT Apple accepts as `client_secret` on `/auth/token` and `/auth/revoke`.
///
/// Built from the Sign in with Apple key (`SIWA_PRIVATE_KEY`, the `.p8`'s PEM), which is a
/// P-256 key — so this needs nothing beyond the `Crypto` Vapor already links. Short-lived on
/// purpose: Apple allows six months, and a secret that is minted per call and lives five
/// minutes is one nobody has a reason to keep.
struct AppleClientSecret: AppleClientSecretSigning {
    let keyID: String
    let teamID: String
    let clientID: String
    let key: P256.Signing.PrivateKey
    var lifetime: TimeInterval = 300

    init(keyID: String, teamID: String, clientID: String = AppleSignInConstants.clientID, pem: String) throws {
        self.keyID = keyID
        self.teamID = teamID
        self.clientID = clientID
        // Deployment platforms mangle multi-line values; the escaped form is accepted for the
        // same reason `APNS_KEY_P8` is.
        self.key = try P256.Signing.PrivateKey(pemRepresentation: pem.replacingOccurrences(of: "\\n", with: "\n"))
    }

    init(keyID: String, teamID: String, clientID: String = AppleSignInConstants.clientID, key: P256.Signing.PrivateKey) {
        self.keyID = keyID
        self.teamID = teamID
        self.clientID = clientID
        self.key = key
    }

    func clientSecret(now: Date) throws -> String {
        struct Header: Encodable { let alg = "ES256"; let kid: String }
        struct Claims: Encodable {
            let iss: String
            let iat: Int
            let exp: Int
            let aud: String
            let sub: String
        }
        let issued = Int(now.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = try encoder.encode(Header(kid: keyID)).base64URLEncodedString()
        let claims = try encoder.encode(Claims(
            iss: teamID,
            iat: issued,
            exp: issued + Int(lifetime),
            aud: AppleSignInConstants.issuer,
            sub: clientID
        )).base64URLEncodedString()
        let signingInput = "\(header).\(claims)"
        // `rawRepresentation` is r‖s, 64 bytes — what JWS calls an ES256 signature. The DER
        // form is the other encoding of the same thing, and Apple refuses it.
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "\(signingInput).\(signature.base64URLEncodedString())"
    }
}

// MARK: - Apple's token endpoints

/// `/auth/token` and `/auth/revoke`, form-encoded, through a closure so a test can stand in
/// for Apple without a network.
struct AppleTokenEndpoint: AppleTokenExchanging {
    typealias Post = @Sendable (_ url: URI, _ form: [String: String]) async throws -> (status: UInt, body: Data)

    let signer: any AppleClientSecretSigning
    let post: Post
    var clientID = AppleSignInConstants.clientID

    static let tokenURL: URI = "https://appleid.apple.com/auth/token"
    static let revokeURL: URI = "https://appleid.apple.com/auth/revoke"

    enum Failure: Error, CustomStringConvertible {
        case refused(endpoint: String, status: UInt)

        /// Names the endpoint and the status only. Apple's error body is safe, but a habit of
        /// printing bodies from these endpoints is one refactor away from printing a token.
        var description: String {
            switch self {
            case .refused(let endpoint, let status): "Apple \(endpoint) answered \(status)"
            }
        }
    }

    func refreshToken(forCode code: String) async throws -> String? {
        let (status, body) = try await post(Self.tokenURL, [
            "client_id": clientID,
            "client_secret": try signer.clientSecret(now: Date()),
            "code": code,
            "grant_type": "authorization_code"
        ])
        guard (200..<300).contains(status) else { throw Failure.refused(endpoint: "/auth/token", status: status) }
        struct Answer: Decodable { var refresh_token: String? }
        return try JSONDecoder().decode(Answer.self, from: body).refresh_token
    }

    func revoke(refreshToken: String) async throws {
        let (status, _) = try await post(Self.revokeURL, [
            "client_id": clientID,
            "client_secret": try signer.clientSecret(now: Date()),
            "token": refreshToken,
            "token_type_hint": "refresh_token"
        ])
        guard (200..<300).contains(status) else { throw Failure.refused(endpoint: "/auth/revoke", status: status) }
    }

    /// The real transport: Vapor's client, form-encoded as Apple requires.
    static func vapor(_ client: any Client) -> Post {
        { url, form in
            let response = try await client.post(url) { request in
                try request.content.encode(form, as: .urlEncodedForm)
            }
            let body = response.body.map { Data(buffer: $0) } ?? Data()
            return (response.status.code, body)
        }
    }
}

// MARK: - Wiring

/// What the account routes use, read from `app.storage` at request time so a test can swap
/// either half after `configure`.
struct AppleSignInConfiguration: Sendable {
    var verifier: any AppleIdentityVerifying
    /// Nil when the deployment has no Sign in with Apple key: sign-in still works, and the
    /// exchange and revocation are skipped and logged as skipped.
    var tokens: (any AppleTokenExchanging)?

    static func make(for app: Application) -> AppleSignInConfiguration {
        let verifier: any AppleIdentityVerifying
        if Environment.get("SIWA_TEST_TOKENS") == "true" {
            if app.environment == .production {
                app.logger.critical("siwa: SIWA_TEST_TOKENS is set on a production environment — ignored")
                verifier = UnavailableAppleIdentityVerifier()
            } else {
                app.logger.warning("siwa: accepting UNSIGNED identity tokens (SIWA_TEST_TOKENS) — local development only")
                verifier = UnsignedAppleIdentityVerifier()
            }
        } else {
            app.logger.notice("siwa: identity tokens cannot be verified yet — sign-in will refuse")
            verifier = UnavailableAppleIdentityVerifier()
        }

        guard
            let keyID = Environment.get("SIWA_KEY_ID"), !keyID.isEmpty,
            let teamID = Environment.get("SIWA_TEAM_ID"), !teamID.isEmpty,
            let pem = Environment.get("SIWA_PRIVATE_KEY"), !pem.isEmpty
        else {
            app.logger.notice("siwa: no key (SIWA_KEY_ID/SIWA_TEAM_ID/SIWA_PRIVATE_KEY) — token exchange and revocation skipped")
            return AppleSignInConfiguration(verifier: verifier, tokens: nil)
        }
        do {
            let signer = try AppleClientSecret(keyID: keyID, teamID: teamID, pem: pem)
            app.logger.notice("siwa: key \(keyID) configured for token exchange and revocation")
            return AppleSignInConfiguration(
                verifier: verifier,
                tokens: AppleTokenEndpoint(signer: signer, post: AppleTokenEndpoint.vapor(app.client))
            )
        } catch {
            // The error, never the value: this is a private key.
            app.logger.error("siwa: SIWA_PRIVATE_KEY could not be read as a P-256 key — exchange and revocation skipped")
            return AppleSignInConfiguration(verifier: verifier, tokens: nil)
        }
    }
}

struct AppleSignInKey: StorageKey {
    typealias Value = AppleSignInConfiguration
}

extension Application {
    var appleSignIn: AppleSignInConfiguration {
        get { storage[AppleSignInKey.self] ?? AppleSignInConfiguration(verifier: UnavailableAppleIdentityVerifier(), tokens: nil) }
        set { storage[AppleSignInKey.self] = newValue }
    }
}

extension Data {
    init?(base64URL string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
