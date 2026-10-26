// AppStoreSignature.swift
// Proving a StoreKit 2 JWS is Apple's: a signed transaction, a notification, renewal info.
//
// The header carries `alg: ES256` and an `x5c` of three certificates — leaf, Apple's WWDR
// intermediate, root. **The root in the token is never believed**: the chain is built from the
// leaf through the intermediate to a root *this server holds* (Apple Root CA - G3, compiled in
// below), and the token's own third certificate plays no part. Then the two Apple marker OIDs,
// then the ES256 signature with the leaf's key. This is what Apple's
// app-store-server-library-swift does, without its JWT stack.
//
// **Validity is checked at the payload's `signedDate`, not now**, as Apple's own libraries do
// when they are not checking revocation online. A transaction is signed once and may be posted
// again on a launch months later, and a refund notification can be about a purchase older than
// the certificate now in use — so checking at "now" would one day refuse something that was
// genuine when Apple signed it. The date is read from the payload before the chain is checked;
// that only lets a caller choose *when* a chain is judged, and the chain must still end at
// Apple's root and the signature still verify against its leaf.
//
// **No online revocation check (OCSP).** That is the price of judging at `signedDate`: a leaf
// Apple revoked after a key leaked would still verify here. Checking would put a request to
// Apple's OCSP responder in front of every purchase and every refund, and make crediting depend
// on its uptime. Apple's library makes it a switch (`enableOnlineChecks`); this is that switch
// off. Revisit if Apple ever reports a compromised App Store signing key.

import Foundation
import Vapor
@_spi(FixedExpiryValidationTime) import X509

struct AppStoreVerifier: SignedTransactionVerifying {
    /// Apple's root in production; a test passes its own, which is the only way to sign a
    /// chain the verifier will accept.
    var trustedRoots: [Certificate] = [AppleRootCA.g3]

    /// The leaf's extension: Mac App Store receipt signing.
    static let leafMarker = "1.2.840.113635.100.6.11.1"
    /// The intermediate's: Apple Worldwide Developer Relations.
    static let intermediateMarker = "1.2.840.113635.100.6.2.1"

    private struct Header: Decodable {
        var alg: String?
        var x5c: [String]?
    }

    private struct Stamp: Decodable {
        /// Milliseconds since 1970, as Apple writes every date.
        var signedDate: Double?
    }

    func verifiedPayload(of jws: String) async throws -> Data {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = JWS.base64URLDecoded(parts[0]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              let payload = JWS.base64URLDecoded(parts[1]),
              let signature = JWS.base64URLDecoded(parts[2])
        else { throw SignedPayloadError.malformed }

        guard header.alg == "ES256", let x5c = header.x5c, x5c.count == 3 else {
            throw SignedPayloadError.untrusted
        }
        // `x5c` is standard base64 DER (RFC 7515 §4.1.6), not base64url.
        let certificates = try x5c.map { encoded -> Certificate in
            guard let der = Data(base64Encoded: encoded),
                  let certificate = try? Certificate(derEncoded: Array(der))
            else { throw SignedPayloadError.untrusted }
            return certificate
        }
        let leaf = certificates[0]

        // JWS ES256 is r‖s, 64 bytes — not the DER `Signature` X.509 uses.
        guard let key = P256.Signing.PublicKey(leaf.publicKey),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(ecdsa, for: Data("\(parts[0]).\(parts[1])".utf8))
        else { throw SignedPayloadError.untrusted }

        // A payload with no `signedDate` is judged at now, which is stricter, never looser.
        let signedAt = (try? JSONDecoder().decode(Stamp.self, from: payload))?.signedDate
            .map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        var verifier = Verifier(rootCertificates: CertificateStore(trustedRoots)) {
            RFC5280Policy(fixedExpiryValidationTime: signedAt)
        }
        let result = await verifier.validate(leaf: leaf, intermediates: CertificateStore([certificates[1]]))
        guard case .validCertificate(let chain) = result, Self.carriesAppleMarkers(Array(chain)) else {
            throw SignedPayloadError.untrusted
        }
        return payload
    }

    /// Leaf, intermediate, root — exactly three, with Apple's marker on each of the first two.
    /// Without the markers, any certificate Apple's root ever vouched for (a TLS server's, a
    /// developer's) could sign a purchase.
    static func carriesAppleMarkers(_ chain: [Certificate]) -> Bool {
        guard chain.count == 3 else { return false }
        func carries(_ certificate: Certificate, _ oid: String) -> Bool {
            certificate.extensions.contains { $0.oid.description == oid }
        }
        return carries(chain[0], leafMarker) && carries(chain[1], intermediateMarker)
    }
}

/// The one certificate this server trusts for App Store signatures.
enum AppleRootCA {
    /// Apple Root CA - G3, from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
    /// (DER there; PEM here). A public certificate, not a secret. Valid 2014-04-30 to
    /// 2039-04-30; when Apple issues a successor, it goes beside this one in `trustedRoots`.
    static let g3PEM = """
    -----BEGIN CERTIFICATE-----
    MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
    QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
    IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
    MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
    b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
    aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
    AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
    TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
    IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
    MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
    MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
    at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
    6BgD56KyKA==
    -----END CERTIFICATE-----
    """

    /// SHA-256 of the DER, as Apple publishes it on that page — what the suite checks
    /// `g3PEM` against, so a mangled paste cannot ship.
    static let g3Fingerprint = "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79"

    /// A compiled-in constant, parsed and fingerprinted by the suite, so the `try!` can only
    /// fail on a build whose tests failed first.
    static let g3: Certificate = try! Certificate(pemEncoded: g3PEM)
}
