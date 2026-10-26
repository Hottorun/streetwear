import _CryptoExtras
import Foundation
import Testing
import Vapor
import X509

@testable import StreetwServer

// MARK: - Sign in with Apple

/// A key pair standing in for Apple's, published the way Apple publishes its own.
struct TestAppleKeys: Sendable {
    let kid: String
    let key: _RSA.Signing.PrivateKey

    init(kid: String = "TEST-KID") throws {
        self.kid = kid
        self.key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    }

    var jwks: Data {
        get throws {
            let primitives = try key.publicKey.getKeyPrimitives()
            let entry: [String: String] = [
                "kty": "RSA",
                "kid": kid,
                "use": "sig",
                "alg": "RS256",
                "n": primitives.modulus.base64URLEncodedString(),
                "e": primitives.publicExponent.base64URLEncodedString()
            ]
            return try JSONSerialization.data(withJSONObject: ["keys": [entry]])
        }
    }

    /// A token as Apple mints one for this app, for `nonce`.
    func token(
        header: [String: String]? = nil,
        subject: String = "001234.apple-subject",
        nonce: String = "raw-nonce",
        audience: String = AppleSignInConstants.clientID,
        expires: Date = Date().addingTimeInterval(600)
    ) throws -> String {
        let headerJSON = try JSONSerialization.data(withJSONObject: header ?? ["alg": "RS256", "kid": kid])
        let claims: [String: Any] = [
            "iss": AppleSignInConstants.issuer,
            "aud": audience,
            "exp": expires.timeIntervalSince1970,
            "iat": Date().timeIntervalSince1970,
            "sub": subject,
            "nonce": AppleIdentityClaims.hash(nonce)
        ]
        let input = "\(headerJSON.base64URLEncodedString()).\(try JSONSerialization.data(withJSONObject: claims).base64URLEncodedString())"
        let signature = try key.signature(for: Data(input.utf8), padding: .insecurePKCS1v1_5)
        return "\(input).\(signature.rawRepresentation.base64URLEncodedString())"
    }
}

/// Counts what it was asked, so the throttle can be seen.
private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func record() { lock.withLock { _count += 1 } }
}

private func verifier(serving keys: TestAppleKeys, log: FetchLog = FetchLog()) throws -> AppleIdentityTokenVerifier {
    let jwks = try keys.jwks
    return AppleIdentityTokenVerifier(keys: AppleSigningKeys(fetch: {
        log.record()
        return jwks
    }))
}

/// The reason a verification was refused with, or nil if it was not.
private func refusal(_ work: () async throws -> AppleIdentity) async -> Abort? {
    do {
        _ = try await work()
        return nil
    } catch let abort as Abort {
        return abort
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

private func flipLastByte(ofSegment index: Int, in token: String) -> String {
    var parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    var bytes = Data(base64URL: parts[index])!
    bytes[bytes.count - 1] ^= 0x01
    parts[index] = bytes.base64URLEncodedString()
    return parts.joined(separator: ".")
}

@Suite("Sign in with Apple: the identity token's signature")
struct AppleIdentitySignatureTests {
    @Test("A token Apple's key signed verifies, and the claims are then read")
    func verifies() async throws {
        let keys = try TestAppleKeys()
        let identity = try await verifier(serving: keys).verify(identityToken: try keys.token(), nonce: "raw-nonce", now: Date())
        #expect(identity.subject == "001234.apple-subject")
    }

    @Test("A signed token still fails its claims: another app's, or another sign-in's")
    func claimsStillRun() async throws {
        let keys = try TestAppleKeys()
        let verifier = try verifier(serving: keys)
        let otherApp = await refusal { try await verifier.verify(identityToken: try keys.token(audience: "com.example.other"), nonce: "raw-nonce", now: Date()) }
        #expect(otherApp?.reason == AppleIdentityClaims.Failure.wrongAudience.description)
        let otherNonce = await refusal { try await verifier.verify(identityToken: try keys.token(), nonce: "another", now: Date()) }
        #expect(otherNonce?.reason == AppleIdentityClaims.Failure.nonceMismatch.description)
    }

    @Test("A kid Apple does not publish is refused, and re-reading the keys is throttled")
    func unknownKid() async throws {
        let keys = try TestAppleKeys()
        let log = FetchLog()
        let verifier = try verifier(serving: keys, log: log)
        let now = Date()

        for kid in ["forged-1", "forged-2", "forged-3"] {
            let token = try keys.token(header: ["alg": "RS256", "kid": kid])
            let refused = await refusal { try await verifier.verify(identityToken: token, nonce: "raw-nonce", now: now) }
            #expect(refused?.status == .unauthorized)
            #expect(refused?.reason == AppleIdentityTokenVerifier.Failure.unknownKey.description)
        }
        // Three forged kids, one read of Apple's keys.
        #expect(log.count == 1)

        // A genuine kid is answered from the cache, with no read at all.
        _ = try await verifier.verify(identityToken: try keys.token(), nonce: "raw-nonce", now: now)
        #expect(log.count == 1)

        // Past the floor, an unknown kid may read again — once.
        let later = now.addingTimeInterval(AppleSigningKeys.refetchFloor + 1)
        let token = try keys.token(header: ["alg": "RS256", "kid": "forged-4"])
        _ = await refusal { try await verifier.verify(identityToken: token, nonce: "raw-nonce", now: later) }
        _ = await refusal { try await verifier.verify(identityToken: token, nonce: "raw-nonce", now: later) }
        #expect(log.count == 2)
    }

    @Test("A key Apple has just rotated in is found by re-reading")
    func rotation() async throws {
        let old = try TestAppleKeys(kid: "old")
        let new = try TestAppleKeys(kid: "new")
        let served = LockedValue(try old.jwks)
        let verifier = AppleIdentityTokenVerifier(keys: AppleSigningKeys(fetch: { served.value }))
        let now = Date()
        _ = try await verifier.verify(identityToken: try old.token(), nonce: "raw-nonce", now: now)

        served.value = try new.jwks
        let identity = try await verifier.verify(
            identityToken: try new.token(),
            nonce: "raw-nonce",
            now: now.addingTimeInterval(AppleSigningKeys.refetchFloor + 1)
        )
        #expect(identity.subject == "001234.apple-subject")
    }

    @Test("Only RS256: none, HS256 and ES256 are refused whatever they carry")
    func wrongAlgorithm() async throws {
        let keys = try TestAppleKeys()
        let verifier = try verifier(serving: keys)
        let genuine = try keys.token()
        let parts = genuine.split(separator: ".").map(String.init)

        func header(_ alg: String) throws -> String {
            try JSONSerialization.data(withJSONObject: ["alg": alg, "kid": keys.kid]).base64URLEncodedString()
        }

        // `none`, with the empty signature the algorithm calls for.
        let unsigned = "\(try header("none")).\(parts[1])."
        // HS256 keyed with the public modulus — the classic confusion attack.
        let hsInput = "\(try header("HS256")).\(parts[1])"
        let secret = SymmetricKey(data: try keys.key.publicKey.getKeyPrimitives().modulus)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(hsInput.utf8), using: secret))
        let hmac = "\(hsInput).\(mac.base64URLEncodedString())"
        // The genuine RSA signature under a header that claims another algorithm.
        let relabelled = "\(try header("ES256")).\(parts[1]).\(parts[2])"

        for token in [unsigned, hmac, relabelled] {
            let refused = await refusal { try await verifier.verify(identityToken: token, nonce: "raw-nonce", now: Date()) }
            #expect(refused?.reason == AppleIdentityTokenVerifier.Failure.unsupportedAlgorithm.description)
        }
    }

    @Test("A tampered payload or a tampered signature does not verify")
    func tampered() async throws {
        let keys = try TestAppleKeys()
        let verifier = try verifier(serving: keys)
        let genuine = try keys.token(subject: "alice")

        // The claims rewritten to name somebody else, under the original signature.
        var parts = genuine.split(separator: ".").map(String.init)
        let claims = String(decoding: Data(base64URL: parts[1])!, as: UTF8.self).replacingOccurrences(of: "alice", with: "mallory")
        parts[1] = Data(claims.utf8).base64URLEncodedString()
        let rewritten = parts.joined(separator: ".")

        for token in [rewritten, flipLastByte(ofSegment: 2, in: genuine)] {
            let refused = await refusal { try await verifier.verify(identityToken: token, nonce: "raw-nonce", now: Date()) }
            #expect(refused?.reason == AppleIdentityTokenVerifier.Failure.badSignature.description)
        }

        // Signed by a key that is not Apple's, under Apple's kid.
        let impostor = try TestAppleKeys(kid: keys.kid)
        let refused = await refusal { try await verifier.verify(identityToken: try impostor.token(), nonce: "raw-nonce", now: Date()) }
        #expect(refused?.reason == AppleIdentityTokenVerifier.Failure.badSignature.description)
    }

    @Test("Apple unreachable with no keys held is a 503, not a verdict on the token")
    func appleUnreachable() async throws {
        let keys = try TestAppleKeys()
        let verifier = AppleIdentityTokenVerifier(keys: AppleSigningKeys(fetch: { throw Abort(.badGateway) }))
        let refused = await refusal { try await verifier.verify(identityToken: try keys.token(), nonce: "raw-nonce", now: Date()) }
        #expect(refused?.status == .serviceUnavailable)
        #expect(refused?.reason == AppleIdentityTokenVerifier.Failure.keysUnavailable.description)
    }

    @Test("A JWKS with no usable RSA signing key is a failed read")
    func emptyJWKS() throws {
        #expect(throws: (any Error).self) { try AppleSigningKeys.parse(Data(#"{"keys":[]}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try AppleSigningKeys.parse(Data(#"{"keys":[{"kty":"EC","kid":"x","crv":"P-256"}]}"#.utf8))
        }
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - StoreKit

/// A root, an intermediate and a leaf shaped like Apple's — the same marker OIDs — so the
/// verifier can be handed a chain it should accept, and every way of spoiling one.
struct TestStoreChain {
    let rootKey = P256.Signing.PrivateKey()
    let intermediateKey = P256.Signing.PrivateKey()
    let leafKey = P256.Signing.PrivateKey()
    let root: Certificate
    let intermediate: Certificate
    let leaf: Certificate

    static let issued = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
    static let leafExpires = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01

    init(
        leafMarker: Bool = true,
        intermediateMarker: Bool = true,
        leafExpires: Date = TestStoreChain.leafExpires
    ) throws {
        root = try Self.certificate(
            subject: "Test Root", key: rootKey, issuer: "Test Root", issuerKey: rootKey, isCA: true, marker: nil,
            notAfter: Self.issued.addingTimeInterval(20 * 365 * 86_400)
        )
        intermediate = try Self.certificate(
            subject: "Test WWDR", key: intermediateKey, issuer: "Test Root", issuerKey: rootKey, isCA: true,
            marker: intermediateMarker
                ? Certificate.Extension(oid: [1, 2, 840, 113635, 100, 6, 2, 1], critical: false, value: [0x05, 0x00])
                : nil,
            notAfter: Self.issued.addingTimeInterval(10 * 365 * 86_400)
        )
        leaf = try Self.certificate(
            subject: "Test StoreKit Signing", key: leafKey, issuer: "Test WWDR", issuerKey: intermediateKey, isCA: false,
            marker: leafMarker
                ? Certificate.Extension(oid: [1, 2, 840, 113635, 100, 6, 11, 1], critical: false, value: [0x05, 0x00])
                : nil,
            notAfter: leafExpires
        )
    }

    private static func certificate(
        subject: String,
        key: P256.Signing.PrivateKey,
        issuer: String,
        issuerKey: P256.Signing.PrivateKey,
        isCA: Bool,
        /// Apple's markers are non-critical and carry an ASN.1 NULL, as the test ones do.
        marker: Certificate.Extension?,
        notAfter: Date
    ) throws -> Certificate {
        var extensions = [
            try Certificate.Extension(
                isCA ? BasicConstraints.isCertificateAuthority(maxPathLength: nil) : .notCertificateAuthority,
                critical: true
            )
        ]
        if let marker { extensions.append(marker) }
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: issued,
            notValidAfter: notAfter,
            issuer: try DistinguishedName { CommonName(issuer) },
            subject: try DistinguishedName { CommonName(subject) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions(extensions),
            issuerPrivateKey: Certificate.PrivateKey(issuerKey)
        )
    }

    static func der(_ certificate: Certificate) throws -> String {
        Data(try certificate.serializeAsPEM().derBytes).base64EncodedString()
    }

    /// `payload` signed as StoreKit signs it: ES256, raw r‖s, under an `x5c` of the chain.
    func sign(
        _ payload: [String: Any],
        alg: String = "ES256",
        chain: [Certificate]? = nil,
        signingKey: P256.Signing.PrivateKey? = nil
    ) throws -> String {
        let header: [String: Any] = ["alg": alg, "x5c": try (chain ?? [leaf, intermediate, root]).map(Self.der)]
        let input = "\(JWS.base64URLEncoded(try JSONSerialization.data(withJSONObject: header))).\(JWS.base64URLEncoded(try JSONSerialization.data(withJSONObject: payload)))"
        let signature = try (signingKey ?? leafKey).signature(for: Data(input.utf8)).rawRepresentation
        return "\(input).\(JWS.base64URLEncoded(signature))"
    }

    var verifier: AppStoreVerifier { AppStoreVerifier(trustedRoots: [root]) }
}

/// 2026-06-01, inside every test certificate's validity.
let storeSignedDate = Date(timeIntervalSince1970: 1_780_272_000)

private func stamped(_ extra: [String: Any] = [:], signedAt: Date = storeSignedDate) -> [String: Any] {
    var payload: [String: Any] = ["transactionId": "1", "signedDate": signedAt.timeIntervalSince1970 * 1000]
    payload.merge(extra) { $1 }
    return payload
}

private func untrusted(_ verifier: AppStoreVerifier, _ jws: String) async -> Bool {
    do {
        _ = try await verifier.verifiedPayload(of: jws)
        return false
    } catch let error as SignedPayloadError {
        return error == .untrusted
    } catch {
        return false
    }
}

@Suite("App Store: StoreKit 2 signatures")
struct AppStoreSignatureTests {
    @Test("A chain to the trusted root, with Apple's markers and a good signature, verifies")
    func verifies() async throws {
        let chain = try TestStoreChain()
        let payload = try await chain.verifier.verifiedPayload(of: try chain.sign(stamped(["productId": "p"])))
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(object?["productId"] as? String == "p")
    }

    @Test("The root is the server's: a chain to a different root is refused")
    func otherRoot() async throws {
        let chain = try TestStoreChain()
        let stranger = try TestStoreChain()
        // Genuine in every other respect — and the token even carries its own root.
        #expect(await untrusted(stranger.verifier, try chain.sign(stamped())))
        // The production verifier trusts Apple's root alone.
        #expect(await untrusted(AppStoreVerifier(), try chain.sign(stamped())))
    }

    @Test("A chain missing either Apple marker OID is refused")
    func markers() async throws {
        let noLeafMarker = try TestStoreChain(leafMarker: false)
        #expect(await untrusted(noLeafMarker.verifier, try noLeafMarker.sign(stamped())))
        let noIntermediateMarker = try TestStoreChain(intermediateMarker: false)
        #expect(await untrusted(noIntermediateMarker.verifier, try noIntermediateMarker.sign(stamped())))
    }

    @Test("Validity is judged at signedDate: expired then is refused, expired since is not")
    func validityAtSignedDate() async throws {
        let chain = try TestStoreChain()
        let afterExpiry = TestStoreChain.leafExpires.addingTimeInterval(86_400)
        #expect(await untrusted(chain.verifier, try chain.sign(stamped(signedAt: afterExpiry))))

        // Signed while the leaf was valid, checked long after it expired: still Apple's.
        let expiredNow = try TestStoreChain(leafExpires: Date().addingTimeInterval(-86_400))
        let signedBefore = TestStoreChain.issued.addingTimeInterval(86_400)
        _ = try await expiredNow.verifier.verifiedPayload(of: try expiredNow.sign(stamped(signedAt: signedBefore)))
    }

    @Test("A bad signature is refused: tampered, another key's, or DER rather than r‖s")
    func badSignature() async throws {
        let chain = try TestStoreChain()
        let genuine = try chain.sign(stamped(["productId": "small"]))

        var parts = genuine.split(separator: ".").map(String.init)
        parts[1] = JWS.base64URLEncoded(try JSONSerialization.data(withJSONObject: stamped(["productId": "large"])))
        #expect(await untrusted(chain.verifier, parts.joined(separator: ".")))

        #expect(await untrusted(chain.verifier, try chain.sign(stamped(), signingKey: P256.Signing.PrivateKey())))

        parts = genuine.split(separator: ".").map(String.init)
        let input = "\(parts[0]).\(parts[1])"
        parts[2] = JWS.base64URLEncoded(try chain.leafKey.signature(for: Data(input.utf8)).derRepresentation)
        #expect(await untrusted(chain.verifier, parts.joined(separator: ".")))
    }

    @Test("Only ES256 with exactly three certificates")
    func shape() async throws {
        let chain = try TestStoreChain()
        #expect(await untrusted(chain.verifier, try chain.sign(stamped(), alg: "none")))
        #expect(await untrusted(chain.verifier, try chain.sign(stamped(), chain: [chain.leaf, chain.intermediate])))
        // The leaf presented as its own intermediate: no path to the root.
        #expect(await untrusted(chain.verifier, try chain.sign(stamped(), chain: [chain.leaf, chain.leaf, chain.root])))
    }

    @Test("The embedded Apple Root CA - G3 parses and matches its published fingerprint")
    func appleRoot() throws {
        let body = AppleRootCA.g3PEM
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let der = try #require(Data(base64Encoded: body))
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        #expect(fingerprint == AppleRootCA.g3Fingerprint)

        let root = AppleRootCA.g3
        #expect(root.subject.description.contains("CN=Apple Root CA - G3"))
        #expect(root.subject == root.issuer)
        #expect(Data(try root.serializeAsPEM().derBytes) == der)
    }
}
