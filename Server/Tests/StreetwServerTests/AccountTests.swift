import Fluent
import Foundation
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

/// A verifier that knows which tokens are which, so a test can sign in as somebody without
/// Apple. Each token is the subject itself — the claim rules are tested separately on
/// `AppleIdentityClaims`, where they live.
private struct StubVerifier: AppleIdentityVerifying {
    var isAvailable: Bool { true }

    func verify(identityToken: String, nonce: String, now: Date) async throws -> AppleIdentity {
        guard nonce == "raw-nonce" else { throw Abort(.unauthorized, reason: "nonce") }
        return AppleIdentity(subject: identityToken)
    }
}

/// Stands in for Apple's token endpoints and remembers what it was asked.
private final class StubTokens: AppleTokenExchanging, @unchecked Sendable {
    private let lock = NSLock()
    private var _exchanged: [String] = []
    private var _revoked: [String] = []
    var failRevoke = false

    var exchanged: [String] { lock.withLock { _exchanged } }
    var revoked: [String] { lock.withLock { _revoked } }

    func refreshToken(forCode code: String) async throws -> String? {
        lock.withLock { _exchanged.append(code) }
        return "refresh-for-\(code)"
    }

    func revoke(refreshToken: String) async throws {
        lock.withLock { _revoked.append(refreshToken) }
        if failRevoke { throw Abort(.badGateway) }
    }
}

private func register(_ app: Application, sizes: SizePayload? = nil) async throws -> (headers: HTTPHeaders, device: DeviceModel) {
    var token = ""
    try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
        try req.content.encode(RegisterDevice(sizes: sizes))
    }, afterResponse: { res async throws in
        token = try res.content.decode(DeviceResponse.self).token
    })
    let device = try #require(try await DeviceModel.query(on: app.db).filter(\.$authToken == token).first())
    return (HTTPHeaders([("Authorization", "Bearer \(token)")]), device)
}

private func signIn(
    _ app: Application,
    as subject: String,
    code: String? = nil,
    headers: HTTPHeaders
) async throws -> AccountSession {
    var session: AccountSession?
    try await app.testing().test(.POST, "v1/account/apple", headers: headers, beforeRequest: { req in
        try req.content.encode(AppleSignIn(identityToken: subject, authorizationCode: code, nonce: "raw-nonce"))
    }, afterResponse: { res async throws in
        #expect(res.status == .ok, "\(res.body.string)")
        session = try res.content.decode(AccountSession.self)
    })
    return try #require(session)
}

private func brand(_ app: Application, _ slug: String) async throws -> UUID {
    let brand = BrandModel(name: slug, slug: slug, website: "https://\(slug)", instagramHandle: nil, usesGeneratedName: false)
    try await brand.save(on: app.db)
    return try brand.requireID()
}

private func product(_ app: Application, brandID: UUID) async throws -> UUID {
    let product = ProductModel(
        brandID: brandID,
        sourceID: nil,
        item: FetchedItem(externalID: "shopify:\(UUID().uuidString)", title: "Hoodie", publishedAt: Date(), kind: .product)
    )
    try await product.save(on: app.db)
    return try product.requireID()
}

private func follow(_ app: Application, user: UUID, brand: UUID, mode: FollowMode = .everything) async throws {
    try await FollowModel(userID: user, brandID: brand, mode: mode).save(on: app.db)
}

private func watch(_ app: Application, user: UUID, brand: UUID, product: UUID, size: String?) async throws {
    try await WatchModel(userID: user, brandID: brand, productID: product, size: size, color: nil).save(on: app.db)
}

@Suite("Identity token claims")
struct AppleClaimTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func token(_ claims: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncodedString()
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URLEncodedString()
        return "\(header).\(payload).sig"
    }

    private func valid(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var claims: [String: Any] = [
            "iss": "https://appleid.apple.com",
            "aud": "com.kern.functional.streetw",
            "exp": now.timeIntervalSince1970 + 600,
            "sub": "001234.abcdef",
            "nonce": AppleIdentityClaims.hash("raw-nonce")
        ]
        for (key, value) in overrides { claims[key] = value }
        return claims
    }

    private func check(_ claims: [String: Any], nonce: String = "raw-nonce") throws -> AppleIdentity {
        try AppleIdentityClaims.decode(try token(claims)).check(nonce: nonce, now: now)
    }

    @Test("A current token for this app, minted for this nonce, names its subject")
    func acceptsAValidToken() throws {
        #expect(try check(valid()).subject == "001234.abcdef")
        // The JWT spec allows an array audience; Apple sends a string today.
        #expect(try check(valid(["aud": ["other", "com.kern.functional.streetw"]])).subject == "001234.abcdef")
    }

    @Test("Each claim is enforced")
    func refusesEachBadClaim() throws {
        typealias F = AppleIdentityClaims.Failure
        #expect(throws: F.wrongIssuer) { try check(valid(["iss": "https://evil.example"])) }
        #expect(throws: F.wrongAudience) { try check(valid(["aud": "com.example.other"])) }
        #expect(throws: F.expired) { try check(valid(["exp": now.timeIntervalSince1970 - 1])) }
        #expect(throws: F.nonceMismatch) { try check(valid(), nonce: "another-nonce") }
        #expect(throws: F.nonceMismatch) { try check(valid(["nonce": NSNull()])) }
        #expect(throws: F.noSubject) { try check(valid(["sub": ""])) }
        #expect(throws: F.malformed) { try AppleIdentityClaims.decode("not-a-jwt") }
    }

    /// The claim is printed in the token, so a caller sending it back proves nothing. Only
    /// the preimage does.
    @Test("Sending the hash instead of the nonce is refused")
    func theHashIsNotTheNonce() throws {
        #expect(throws: AppleIdentityClaims.Failure.nonceMismatch) {
            try check(valid(), nonce: AppleIdentityClaims.hash("raw-nonce"))
        }
    }

    @Test("The unsigned test verifier still runs every claim check")
    func testVerifierChecksClaims() async throws {
        let verifier = UnsignedAppleIdentityVerifier()
        let good = try token(valid())
        #expect(try await verifier.verify(identityToken: good, nonce: "raw-nonce", now: now).subject == "001234.abcdef")
        await #expect(throws: Abort.self) {
            try await verifier.verify(identityToken: good, nonce: "wrong", now: now)
        }
    }
}

@Suite("Apple client secret and token endpoints")
struct AppleTokenTests {
    @Test("The client secret is an ES256 JWT Apple can verify")
    func signsTheClientSecret() throws {
        // Generated here, never read from anywhere: no real key exists in the repository.
        let key = P256.Signing.PrivateKey()
        let signer = AppleClientSecret(keyID: "KEY123", teamID: "JD6NETLE45", key: key)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = try signer.clientSecret(now: now)

        let parts = jwt.split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        let header = try JSONSerialization.jsonObject(with: try #require(Data(base64URL: parts[0]))) as? [String: Any]
        #expect(header?["alg"] as? String == "ES256")
        #expect(header?["kid"] as? String == "KEY123")

        let claims = try JSONSerialization.jsonObject(with: try #require(Data(base64URL: parts[1]))) as? [String: Any]
        #expect(claims?["iss"] as? String == "JD6NETLE45")
        #expect(claims?["sub"] as? String == "com.kern.functional.streetw")
        #expect(claims?["aud"] as? String == "https://appleid.apple.com")
        #expect(claims?["iat"] as? Int == 1_800_000_000)
        #expect(claims?["exp"] as? Int == 1_800_000_300)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64URL: parts[2])))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test("A p8 key is read from its PEM, escaped newlines included")
    func readsThePEM() throws {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        #expect(throws: Never.self) { try AppleClientSecret(keyID: "K", teamID: "T", pem: pem) }
        let oneLine = pem.replacingOccurrences(of: "\n", with: "\\n")
        #expect(throws: Never.self) { try AppleClientSecret(keyID: "K", teamID: "T", pem: oneLine) }
        #expect(throws: (any Error).self) { try AppleClientSecret(keyID: "K", teamID: "T", pem: "not a key") }
    }

    @Test("The exchange and the revocation post what Apple asks for")
    func postsTheRightForms() async throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var calls: [(String, [String: String])] = []
        }
        let recorder = Recorder()
        let endpoint = AppleTokenEndpoint(
            signer: AppleClientSecret(keyID: "K", teamID: "T", key: P256.Signing.PrivateKey()),
            post: { url, form in
                recorder.lock.withLock { recorder.calls.append((url.string, form)) }
                return (200, Data(#"{"access_token":"a","refresh_token":"r-123","id_token":"i"}"#.utf8))
            }
        )

        #expect(try await endpoint.refreshToken(forCode: "code-1") == "r-123")
        try await endpoint.revoke(refreshToken: "r-123")

        let calls = recorder.lock.withLock { recorder.calls }
        try #require(calls.count == 2)
        #expect(calls[0].0 == "https://appleid.apple.com/auth/token")
        #expect(calls[0].1["grant_type"] == "authorization_code")
        #expect(calls[0].1["code"] == "code-1")
        #expect(calls[0].1["client_id"] == "com.kern.functional.streetw")
        #expect(calls[0].1["client_secret"]?.split(separator: ".").count == 3)
        #expect(calls[1].0 == "https://appleid.apple.com/auth/revoke")
        #expect(calls[1].1["token"] == "r-123")
        #expect(calls[1].1["token_type_hint"] == "refresh_token")
    }

    @Test("A refusal from Apple is an error, not a nil")
    func refusalThrows() async throws {
        let endpoint = AppleTokenEndpoint(
            signer: AppleClientSecret(keyID: "K", teamID: "T", key: P256.Signing.PrivateKey()),
            post: { _, _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        )
        await #expect(throws: AppleTokenEndpoint.Failure.self) { try await endpoint.refreshToken(forCode: "x") }
        await #expect(throws: AppleTokenEndpoint.Failure.self) { try await endpoint.revoke(refreshToken: "x") }
    }
}

@Suite("Accounts")
struct AccountTests {
    /// Signing in is refused, with a reason, until identity tokens can be verified — the
    /// suite runs with no `SIWA_TEST_TOKENS`, which is the production configuration.
    @Test("With no verifier, sign-in refuses rather than trusting the token")
    func refusesWithoutAVerifier() async throws {
        try await withServer { app in
            let (headers, _) = try await register(app)
            try await app.testing().test(.POST, "v1/account/apple", headers: headers, beforeRequest: { req in
                try req.content.encode(AppleSignIn(identityToken: "a.b.c", authorizationCode: nil, nonce: "n"))
            }, afterResponse: { res async throws in
                #expect(res.status == .serviceUnavailable)
                #expect(res.body.string.contains(UnavailableAppleIdentityVerifier.reason))
            })
            #expect(try await AccountModel.query(on: app.db).count() == 0)
            // And the app is told, so it does not offer the button.
            try await app.testing().test(.GET, "v1/account", headers: headers) { res async throws in
                #expect(try res.content.decode(AccountStatus.self).signInAvailable == false)
            }
        }
    }

    @Test("Account routes refuse an anonymous caller")
    func requiresADevice() async throws {
        try await withServer { app in
            try await app.testing().test(.GET, "v1/account") { res in #expect(res.status == .unauthorized) }
            try await app.testing().test(.POST, "v1/account/apple") { res in #expect(res.status == .unauthorized) }
            try await app.testing().test(.DELETE, "v1/account") { res in #expect(res.status == .unauthorized) }
        }
    }

    @Test("The first sign-in puts this device's own user on the account")
    func firstSignInAdoptsTheUser() async throws {
        try await withServer { app in
            app.appleSignIn = AppleSignInConfiguration(verifier: StubVerifier(), tokens: nil)
            let (headers, device) = try await register(app, sizes: SizePayload(apparel: ["M"], shoe: []))

            try await app.testing().test(.GET, "v1/account", headers: headers) { res async throws in
                let status = try res.content.decode(AccountStatus.self)
                #expect(status.account == nil)
                #expect(status.signInAvailable == true)
            }

            let session = try await signIn(app, as: "alice", headers: headers)
            #expect(session.isNew)
            #expect(!session.merged)
            #expect(session.sizes.apparel == ["M"])

            let user = try #require(try await UserModel.find(device.$user.id, on: app.db))
            #expect(user.$account.id == session.account.id)

            try await app.testing().test(.GET, "v1/account", headers: headers) { res async throws in
                #expect(try res.content.decode(AccountStatus.self).account?.id == session.account.id)
            }

            // Signing in again from the same device changes nothing.
            let again = try await signIn(app, as: "alice", headers: headers)
            #expect(!again.isNew)
            #expect(!again.merged)
            #expect(again.account.id == session.account.id)
            #expect(try await UserModel.query(on: app.db).count() == 1)
        }
    }

    /// The reinstall and the second phone: everything this install had goes onto the
    /// account, the account's own choices win where both made one, and the empty anonymous
    /// user is deleted.
    @Test("A later sign-in merges the device's anonymous user into the account's")
    func laterSignInMerges() async throws {
        try await withServer { app in
            app.appleSignIn = AppleSignInConfiguration(verifier: StubVerifier(), tokens: nil)
            let kith = try await brand(app, "kith.com")
            let palace = try await brand(app, "palace.com")
            let ald = try await brand(app, "ald.com")
            let hoodie = try await product(app, brandID: kith)

            // The first phone: signed in, with choices of its own.
            let (firstHeaders, first) = try await register(
                app, sizes: SizePayload(apparel: ["M"], shoe: [], gender: "mens")
            )
            let account = try await signIn(app, as: "alice", headers: firstHeaders).account
            let accountUser = first.$user.id
            try await follow(app, user: accountUser, brand: kith, mode: .quiet)
            try await follow(app, user: accountUser, brand: palace)
            try await watch(app, user: accountUser, brand: kith, product: hoodie, size: "M")
            try await PollHintModel(userID: accountUser, brandID: kith, releaseAt: Date().addingTimeInterval(3600)).save(on: app.db)

            // The second install, anonymous, overlapping in places.
            let (secondHeaders, second) = try await register(
                app, sizes: SizePayload(apparel: ["L"], shoe: ["9"], waist: ["32"], gender: "womens")
            )
            let anonymousUser = second.$user.id
            try await follow(app, user: anonymousUser, brand: kith, mode: .everything)
            try await follow(app, user: anonymousUser, brand: ald, mode: .salesOnly)
            try await watch(app, user: anonymousUser, brand: kith, product: hoodie, size: "M")
            try await watch(app, user: anonymousUser, brand: kith, product: hoodie, size: "L")
            try await PollHintModel(userID: anonymousUser, brandID: kith, releaseAt: Date().addingTimeInterval(7200)).save(on: app.db)
            try await PollHintModel(userID: anonymousUser, brandID: ald, releaseAt: Date().addingTimeInterval(7200)).save(on: app.db)

            let session = try await signIn(app, as: "alice", headers: secondHeaders)
            #expect(!session.isNew)
            #expect(session.merged)
            #expect(session.account.id == account.id)

            // The device moved and kept its credential.
            let moved = try #require(try await DeviceModel.find(second.id, on: app.db))
            #expect(moved.$user.id == accountUser)
            #expect(moved.authToken == second.authToken)

            // The anonymous user is gone, and nothing still points at it.
            #expect(try await UserModel.find(anonymousUser, on: app.db) == nil)
            #expect(try await FollowModel.query(on: app.db).filter(\.$user.$id == anonymousUser).count() == 0)
            #expect(try await WatchModel.query(on: app.db).filter(\.$user.$id == anonymousUser).count() == 0)

            // Follows: a union, the account's mode where both had one.
            let follows = try await FollowModel.query(on: app.db).filter(\.$user.$id == accountUser).all()
            let modes = Dictionary(uniqueKeysWithValues: follows.map { ($0.$brand.id, $0.mode) })
            #expect(modes == [kith: .quiet, palace: .everything, ald: .salesOnly])

            // Watches: a union on product, size and colour — the duplicate M is one watch.
            let sizes = try await WatchModel.query(on: app.db).filter(\.$user.$id == accountUser).all().compactMap(\.size)
            #expect(sizes.sorted() == ["L", "M"])

            // Hints: one per brand, the account's where both had one.
            let hints = try await PollHintModel.query(on: app.db).filter(\.$user.$id == accountUser).all()
            #expect(Set(hints.map(\.$brand.id)) == [kith, ald])

            // Sizes per ladder: the account's where set, the device's where not.
            let merged = try #require(try await UserModel.find(accountUser, on: app.db)).sizeProfile
            #expect(merged.apparel == ["M"])
            #expect(merged.shoe == ["9"])
            #expect(merged.waist == ["32"])
            #expect(merged.gender == .mens)
            #expect(Set(session.sizes.shoe) == ["9"])

            // And the second phone now reads the account's follow list.
            try await app.testing().test(.GET, "v1/follows", headers: secondHeaders) { res async throws in
                #expect(try res.content.decode([BrandDTO].self).count == 3)
            }
        }
    }

    /// The merge is several statements across five tables; a failure in the middle must
    /// leave both users exactly as they were. This runs it inside a transaction that then
    /// fails, which is what any error after the merge inside `signIn` amounts to.
    @Test("The merge is all or nothing")
    func mergeRollsBack() async throws {
        try await withServer { app in
            let kith = try await brand(app, "kith.com")
            let (_, first) = try await register(app)
            let (_, second) = try await register(app)
            try await follow(app, user: second.$user.id, brand: kith)
            let target = try #require(try await UserModel.find(first.$user.id, on: app.db))
            let anonymous = try #require(try await UserModel.find(second.$user.id, on: app.db))

            struct Boom: Error {}
            await #expect(throws: Boom.self) {
                try await app.db.transaction { db in
                    try await Accounts.merge(anonymous, into: target, on: db)
                    throw Boom()
                }
            }

            #expect(try await UserModel.find(second.$user.id, on: app.db) != nil)
            #expect(try await DeviceModel.find(second.id, on: app.db)?.$user.id == second.$user.id)
            #expect(try await FollowModel.query(on: app.db).filter(\.$user.$id == second.$user.id).count() == 1)
        }
    }

    /// Signed in as one person, then as another: the phone changes hands, the first
    /// person's data does not.
    @Test("Switching accounts never folds one account's user into another")
    func switchingAccountsKeepsBothApart() async throws {
        try await withServer { app in
            app.appleSignIn = AppleSignInConfiguration(verifier: StubVerifier(), tokens: nil)
            let kith = try await brand(app, "kith.com")
            let (headers, device) = try await register(app)
            let alice = try await signIn(app, as: "alice", headers: headers)
            let aliceUser = device.$user.id
            try await follow(app, user: aliceUser, brand: kith)

            let bob = try await signIn(app, as: "bob", headers: headers)
            #expect(bob.isNew)
            #expect(!bob.merged)
            #expect(bob.account.id != alice.account.id)

            let moved = try #require(try await DeviceModel.find(device.id, on: app.db))
            #expect(moved.$user.id != aliceUser)
            let alicesUser = try #require(try await UserModel.find(aliceUser, on: app.db))
            #expect(alicesUser.$account.id == alice.account.id)
            #expect(try await FollowModel.query(on: app.db).filter(\.$user.$id == aliceUser).count() == 1)
            #expect(try await FollowModel.query(on: app.db).filter(\.$user.$id == moved.$user.id).count() == 0)
        }
    }

    @Test("Deleting the account deletes everything personal and nothing else")
    func deleteTakesEverythingPersonal() async throws {
        try await withServer { app in
            let tokens = StubTokens()
            app.appleSignIn = AppleSignInConfiguration(verifier: StubVerifier(), tokens: tokens)
            let kith = try await brand(app, "kith.com")
            let hoodie = try await product(app, brandID: kith)

            // Two phones on the account, and a stranger who follows the same brand.
            let (firstHeaders, first) = try await register(app)
            _ = try await signIn(app, as: "alice", code: "code-1", headers: firstHeaders)
            #expect(tokens.exchanged == ["code-1"])
            let (secondHeaders, _) = try await register(app)
            _ = try await signIn(app, as: "alice", headers: secondHeaders)
            let user = first.$user.id
            try await follow(app, user: user, brand: kith)
            try await watch(app, user: user, brand: kith, product: hoodie, size: nil)
            try await PollHintModel(userID: user, brandID: kith, releaseAt: Date().addingTimeInterval(3600)).save(on: app.db)

            let (strangerHeaders, stranger) = try await register(app)
            try await follow(app, user: stranger.$user.id, brand: kith)

            try await app.testing().test(.DELETE, "v1/account", headers: firstHeaders) { res async throws in
                #expect(res.status == .noContent)
            }

            #expect(try await AccountModel.query(on: app.db).count() == 0)
            #expect(try await UserModel.find(user, on: app.db) == nil)
            #expect(try await DeviceModel.query(on: app.db).filter(\.$user.$id == user).count() == 0)
            #expect(try await FollowModel.query(on: app.db).filter(\.$user.$id == user).count() == 0)
            #expect(try await WatchModel.query(on: app.db).filter(\.$user.$id == user).count() == 0)
            #expect(try await PollHintModel.query(on: app.db).filter(\.$user.$id == user).count() == 0)
            #expect(tokens.revoked == ["refresh-for-code-1"])

            // The catalogue and the stranger are untouched.
            #expect(try await BrandModel.find(kith, on: app.db) != nil)
            #expect(try await ProductModel.find(hoodie, on: app.db) != nil)
            #expect(try await FollowModel.query(on: app.db).filter(\.$user.$id == stranger.$user.id).count() == 1)
            try await app.testing().test(.GET, "v1/follows", headers: strangerHeaders) { res async throws in
                #expect(res.status == .ok)
            }

            // Both phones' credentials are dead, and either can start again anonymously.
            for headers in [firstHeaders, secondHeaders] {
                try await app.testing().test(.GET, "v1/follows", headers: headers) { res async throws in
                    #expect(res.status == .unauthorized)
                }
            }
            let (fresh, _) = try await register(app)
            try await app.testing().test(.GET, "v1/account", headers: fresh) { res async throws in
                #expect(try res.content.decode(AccountStatus.self).account == nil)
            }
        }
    }

    @Test("Deletion stands when there is no key, and when Apple refuses the revocation")
    func deleteDoesNotDependOnApple() async throws {
        try await withServer { app in
            app.appleSignIn = AppleSignInConfiguration(verifier: StubVerifier(), tokens: nil)
            let (headers, _) = try await register(app)
            _ = try await signIn(app, as: "alice", code: "ignored", headers: headers)
            try await app.testing().test(.DELETE, "v1/account", headers: headers) { res async throws in
                #expect(res.status == .noContent)
            }
            #expect(try await AccountModel.query(on: app.db).count() == 0)

            let tokens = StubTokens()
            tokens.failRevoke = true
            app.appleSignIn = AppleSignInConfiguration(verifier: StubVerifier(), tokens: tokens)
            let (again, _) = try await register(app)
            _ = try await signIn(app, as: "bob", code: "c", headers: again)
            try await app.testing().test(.DELETE, "v1/account", headers: again) { res async throws in
                #expect(res.status == .noContent)
            }
            #expect(tokens.revoked == ["refresh-for-c"])
            #expect(try await AccountModel.query(on: app.db).count() == 0)
        }
    }

    @Test("Deleting from a device that never signed in is a 404, not a deletion")
    func deleteNeedsAnAccount() async throws {
        try await withServer { app in
            let (headers, device) = try await register(app)
            try await app.testing().test(.DELETE, "v1/account", headers: headers) { res async throws in
                #expect(res.status == .notFound)
            }
            #expect(try await DeviceModel.find(device.id, on: app.db) != nil)
        }
    }

    @Test("The owner can list accounts and give one unlimited credits")
    func adminCredits() async throws {
        try await withServer { app in
            app.appleSignIn = AppleSignInConfiguration(verifier: StubVerifier(), tokens: nil)
            let (firstHeaders, _) = try await register(app)
            let account = try await signIn(app, as: "owner", headers: firstHeaders).account
            let (secondHeaders, _) = try await register(app)
            _ = try await signIn(app, as: "owner", headers: secondHeaders)

            try await app.testing().test(.GET, "admin/accounts") { res async throws in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(.POST, "admin/accounts/\(account.id)/credits") { res async throws in
                #expect(res.status == .unauthorized)
            }

            try await app.testing().test(.GET, "admin/accounts", headers: adminAuth) { res async throws in
                let rows = try res.content.decode([AdminAccount].self)
                #expect(rows.count == 1)
                #expect(rows.first?.id == account.id)
                #expect(rows.first?.userCount == 1)
                #expect(rows.first?.deviceCount == 2)
                #expect(rows.first?.unlimited == false)
            }

            try await app.testing().test(.POST, "admin/accounts/\(account.id)/credits", headers: adminAuth, beforeRequest: { req in
                try req.content.encode(SetAccountCredits(unlimited: true, monthlyCostCapMicros: 25_000_000_000))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let row = try res.content.decode(AdminAccount.self)
                #expect(row.unlimited)
                #expect(row.monthlyCostCapMicros == 25_000_000_000)
            })
            let stored = try #require(try await AccountModel.find(account.id, on: app.db))
            #expect(stored.unlimitedCredits)
            #expect(stored.monthlyCostCapMicros == 25_000_000_000)

            try await app.testing().test(.POST, "admin/accounts/\(account.id)/credits", headers: adminAuth, beforeRequest: { req in
                try req.content.encode(SetAccountCredits(unlimited: true, monthlyCostCapMicros: -1))
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
            try await app.testing().test(.POST, "admin/accounts/\(UUID())/credits", headers: adminAuth, beforeRequest: { req in
                try req.content.encode(SetAccountCredits(unlimited: true))
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Sizes merge per ladder")
    func sizesMergePerLadder() {
        var account = SizeProfile()
        account.apparel = ["M"]
        var device = SizeProfile()
        device.apparel = ["S"]
        device.suit = ["40"]
        device.gender = .womens
        let merged = Accounts.mergedSizes(account: account, device: device)
        #expect(merged.apparel == ["M"])
        #expect(merged.suit == ["40"])
        #expect(merged.gender == .womens)
    }
}
