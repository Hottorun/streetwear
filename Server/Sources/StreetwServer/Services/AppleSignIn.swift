// AppleSignIn.swift
// Everything this server asks of Apple about an account, behind three small seams.
//
// - `AppleIdentityVerifying` — is this identity token Apple's, for this app, current, and
//   minted for the nonce the caller holds? Answers with the `sub`.
// - `AppleClientSecretSigning` — the ES256 JWT Apple wants as a `client_secret`.
// - `AppleTokenExchanging` — `/auth/token` at sign-in (for the refresh token) and
//   `/auth/revoke` at deletion, which Apple requires of an app that deletes accounts.
//
// **The production verifier checks Apple's signature before it reads a claim**
// (`AppleIdentityTokenVerifier`): RS256 against the keys Apple publishes at `/auth/keys`, held
// by `AppleSigningKeys` and re-read only when a token names a key the cache does not hold —
// and then at most once per few minutes, so a forged `kid` cannot make this server hammer
// Apple. RSA is `_CryptoExtras`; the `Crypto` Vapor re-exports has SHA-256 and P-256 and
// nothing else. Accepting a token without its signature would let anybody who can write a
// JSON object sign in as anybody, so the claim checks (`AppleIdentityClaims.check`) only run
// on a token whose signature has verified.
//
// The client secret is P-256, which `Crypto` has, and the token exchange and the revocation
// are plain HTTPS.
//
// **The test verifier is opt-in, and never in production.** `SIWA_TEST_TOKENS=true` on a
// deployment whose environment is not `production` accepts *unsigned* tokens and still runs
// every claim check, so the app can be driven through sign-in → merge → delete against a local
// server from a simulator with no Apple ID. `configure` refuses it on a production
// environment and says so at boot.

import _CryptoExtras
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
    /// Whether this verifier can accept anything. Told to the app (`AccountStatus`), so it
    /// does not offer a button the server will refuse.
    var isAvailable: Bool { get }
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

/// The part of verification that is not cryptography. Read only once the signature has
/// verified (`AppleIdentityTokenVerifier`), or by the unsigned test verifier.
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

/// The production verifier: Apple's signature first, then the claims.
struct AppleIdentityTokenVerifier: AppleIdentityVerifying {
    let keys: AppleSigningKeys
    var isAvailable: Bool { true }

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// Anything but RS256 — `none` and HS256 included. The algorithm is this server's to
        /// choose, never the token's: honouring HS256 would let anybody sign with the public
        /// key as an HMAC secret, and honouring `none` would let them not sign at all.
        case unsupportedAlgorithm
        /// A `kid` Apple does not publish, even after reading its keys again.
        case unknownKey
        case badSignature
        /// Apple's keys could not be read and none are held. The one refusal that is about
        /// this server rather than the token, so a 503 rather than a 401.
        case keysUnavailable

        var description: String {
            switch self {
            case .unsupportedAlgorithm: "The identity token is not signed the way Apple signs"
            case .unknownKey: "The identity token was not signed by a key Apple publishes"
            case .badSignature: "The identity token's signature doesn't verify"
            case .keysUnavailable: "Apple's sign-in keys couldn't be read — try again in a minute"
            }
        }

        var status: HTTPResponseStatus { self == .keysUnavailable ? .serviceUnavailable : .unauthorized }
    }

    private struct Header: Decodable {
        var alg: String?
        var kid: String?
    }

    func verify(identityToken: String, nonce: String, now: Date) async throws -> AppleIdentity {
        let parts = identityToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Data(base64URL: String(parts[0])),
              let header = try? JSONDecoder().decode(Header.self, from: headerData)
        else { throw Abort(.unauthorized, reason: AppleIdentityClaims.Failure.malformed.description) }

        guard header.alg == "RS256" else { throw Self.refusal(.unsupportedAlgorithm) }
        guard let signature = Data(base64URL: String(parts[2])), !signature.isEmpty else {
            throw Self.refusal(.badSignature)
        }
        guard let kid = header.kid, !kid.isEmpty else { throw Self.refusal(.unknownKey) }

        let key: _RSA.Signing.PublicKey
        switch await keys.key(for: kid, now: now) {
        case .key(let found): key = found
        case .unknown: throw Self.refusal(.unknownKey)
        case .unavailable: throw Self.refusal(.keysUnavailable)
        }
        // The two segments exactly as sent, never re-encoded: the signature is over these
        // bytes, and base64url has more than one spelling of the same JSON.
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.isValidSignature(
            _RSA.Signing.RSASignature(rawRepresentation: signature),
            for: signingInput,
            padding: .insecurePKCS1v1_5
        ) else { throw Self.refusal(.badSignature) }

        do {
            return try AppleIdentityClaims.decode(identityToken).check(nonce: nonce, now: now)
        } catch let failure as AppleIdentityClaims.Failure {
            throw Abort(.unauthorized, reason: failure.description)
        }
    }

    private static func refusal(_ failure: Failure) -> Abort {
        Abort(failure.status, reason: failure.description)
    }
}

/// Apple's published identity-token keys (a JWKS), read on first use and cached.
///
/// **Re-read on an unknown `kid`, and never more often than `refetchFloor`.** Apple rotates
/// its keys, so a `kid` the cache has not seen may be a genuine new one — but a forged token
/// can name any `kid` it likes, and an unthrottled re-read would let anybody make this server
/// hammer Apple on their behalf. Concurrent misses share one read. The set is also re-read
/// once it is a day old, so a key Apple has withdrawn stops being trusted; if that read fails,
/// the set already held is kept rather than refusing every sign-in.
actor AppleSigningKeys {
    typealias Fetch = @Sendable () async throws -> Data

    static let url: URI = "https://appleid.apple.com/auth/keys"
    /// The least time between two reads, after one that answered.
    static let refetchFloor: TimeInterval = 300
    /// …and after one that did not: shorter, so a first read that failed at boot does not shut
    /// sign-in for five minutes, and still a bound on what a stream of forged tokens costs.
    static let retryFloor: TimeInterval = 30
    static let maximumAge: TimeInterval = 86_400

    enum Lookup {
        case key(_RSA.Signing.PublicKey)
        case unknown
        case unavailable
    }

    private let fetch: Fetch
    private var keys: [String: _RSA.Signing.PublicKey] = [:]
    private var readAt: Date?
    private var attemptedAt: Date?
    private var lastAttemptFailed = false
    private var inFlight: Task<[String: _RSA.Signing.PublicKey], any Error>?
    /// How many reads were started, for the test suite's throttle checks.
    private(set) var reads = 0

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    func key(for kid: String, now: Date) async -> Lookup {
        let fresh = readAt.map { now.timeIntervalSince($0) < Self.maximumAge } ?? false
        if fresh, let key = keys[kid] { return .key(key) }

        if inFlight != nil || mayRead(now: now) {
            await read(now: now)
        }
        if let key = keys[kid] { return .key(key) }
        return keys.isEmpty && lastAttemptFailed ? .unavailable : .unknown
    }

    private func mayRead(now: Date) -> Bool {
        guard let attemptedAt else { return true }
        let floor = lastAttemptFailed ? Self.retryFloor : Self.refetchFloor
        return now.timeIntervalSince(attemptedAt) >= floor
    }

    private func read(now: Date) async {
        if let inFlight {
            // Joining a read already under way. Assigning its answer a second time is
            // harmless, and means a joiner that resumes before the reader never sees the old set.
            if let answer = try? await inFlight.value { keys = answer }
            return
        }
        attemptedAt = now
        reads += 1
        let fetch = self.fetch
        let task = Task { try Self.parse(try await fetch()) }
        inFlight = task
        do {
            keys = try await task.value
            readAt = now
            lastAttemptFailed = false
        } catch {
            lastAttemptFailed = true
        }
        inFlight = nil
    }

    /// The RSA signing keys in a JWKS. A set with none in it is a failed read rather than an
    /// empty one, because adopting it would refuse every sign-in.
    static func parse(_ data: Data) throws -> [String: _RSA.Signing.PublicKey] {
        struct JWKS: Decodable {
            struct Key: Decodable {
                var kty: String?
                var kid: String?
                var alg: String?
                var use: String?
                var n: String?
                var e: String?
            }
            var keys: [Key]
        }
        var found: [String: _RSA.Signing.PublicKey] = [:]
        for entry in try JSONDecoder().decode(JWKS.self, from: data).keys {
            guard entry.kty == "RSA",
                  entry.alg == nil || entry.alg == "RS256",
                  entry.use == nil || entry.use == "sig",
                  let kid = entry.kid, !kid.isEmpty,
                  let n = entry.n.flatMap({ Data(base64URL: $0) }),
                  let e = entry.e.flatMap({ Data(base64URL: $0) }),
                  let key = try? _RSA.Signing.PublicKey(n: n, e: e),
                  // `init(n:e:)` takes any size. Apple's are 2048 bits; nothing smaller is one.
                  key.keySizeInBits >= 2048
            else { continue }
            found[kid] = key
        }
        guard !found.isEmpty else { throw Abort(.badGateway, reason: "Apple published no usable signing keys") }
        return found
    }

    /// The real transport: Vapor's client, as for the token endpoint.
    static func vapor(_ client: any Client) -> Fetch {
        {
            let response = try await client.get(url)
            guard (200..<300).contains(response.status.code), let body = response.body else {
                throw Abort(.badGateway, reason: "Apple's keys answered \(response.status.code)")
            }
            return Data(buffer: body)
        }
    }
}

/// What `app.appleSignIn` answers before `configure` has set anything: a refusal with its
/// reason, rather than a verifier nobody chose.
struct UnavailableAppleIdentityVerifier: AppleIdentityVerifying {
    static let reason = "Sign in with Apple is not available on this server yet"
    var isAvailable: Bool { false }

    func verify(identityToken: String, nonce: String, now: Date) async throws -> AppleIdentity {
        throw Abort(.serviceUnavailable, reason: Self.reason)
    }
}

/// Accepts an **unsigned** token and checks everything else. Local development only — see the
/// file header and `AppleSignInConfiguration.make`.
struct UnsignedAppleIdentityVerifier: AppleIdentityVerifying {
    var isAvailable: Bool { true }

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
        let signed = AppleIdentityTokenVerifier(keys: AppleSigningKeys(fetch: AppleSigningKeys.vapor(app.client)))
        let verifier: any AppleIdentityVerifying
        if Environment.get("SIWA_TEST_TOKENS") == "true" {
            if app.environment == .production {
                app.logger.critical("siwa: SIWA_TEST_TOKENS is set on a production environment — ignored")
                verifier = signed
            } else {
                app.logger.warning("siwa: accepting UNSIGNED identity tokens (SIWA_TEST_TOKENS) — local development only")
                verifier = UnsignedAppleIdentityVerifier()
            }
        } else {
            app.logger.notice("siwa: identity tokens verified against Apple's published keys")
            verifier = signed
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
