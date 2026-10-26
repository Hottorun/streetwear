import Fluent
import FluentPostgresDriver
import Foundation
import StreetwCore
import Testing
import Vapor
import VaporTesting

@testable import StreetwServer

/// Each token is the subject itself, as in `AccountTests` — the claim rules are tested there.
private struct SubjectVerifier: AppleIdentityVerifying {
    var isAvailable: Bool { true }

    func verify(identityToken: String, nonce: String, now: Date) async throws -> AppleIdentity {
        AppleIdentity(subject: identityToken)
    }
}

private func register(_ app: Application, apnsToken: String? = nil) async throws -> (headers: HTTPHeaders, device: DeviceModel) {
    var token = ""
    try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
        try req.content.encode(RegisterDevice(apnsToken: apnsToken, environment: "sandbox"))
    }, afterResponse: { res async throws in
        token = try res.content.decode(DeviceResponse.self).token
    })
    let device = try #require(try await DeviceModel.query(on: app.db).filter(\.$authToken == token).first())
    return (HTTPHeaders([("Authorization", "Bearer \(token)")]), device)
}

@discardableResult
private func signIn(_ app: Application, as subject: String, headers: HTTPHeaders) async throws -> AccountSession {
    var session: AccountSession?
    try await app.testing().test(.POST, "v1/account/apple", headers: headers, beforeRequest: { req in
        try req.content.encode(AppleSignIn(identityToken: subject, authorizationCode: nil, nonce: "n"))
    }, afterResponse: { res async throws in
        #expect(res.status == .ok, "\(res.body.string)")
        session = try res.content.decode(AccountSession.self)
    })
    return try #require(session)
}

private func addProfile(_ app: Application, named name: String, headers: HTTPHeaders) async throws -> ProfileDTO {
    var created: ProfileDTO?
    try await app.testing().test(.POST, "v1/account/profiles", headers: headers, beforeRequest: { req in
        try req.content.encode(CreateProfile(name: name))
    }, afterResponse: { res async throws in
        #expect(res.status == .ok, "\(res.body.string)")
        created = try res.content.decode(ProfileDTO.self)
    })
    return try #require(created)
}

private func acting(as profile: UUID, _ headers: HTTPHeaders) -> HTTPHeaders {
    var headers = headers
    headers.replaceOrAdd(name: ProfileHeader.name, value: profile.uuidString)
    return headers
}

private func brand(_ app: Application, _ slug: String, name: String? = nil) async throws -> UUID {
    let brand = BrandModel(name: name ?? slug, slug: slug, website: "https://\(slug)", instagramHandle: nil, usesGeneratedName: false)
    try await brand.save(on: app.db)
    return try brand.requireID()
}

private func product(_ app: Application, brandID: UUID, title: String = "Hoodie") async throws -> ProductModel {
    let product = ProductModel(
        brandID: brandID,
        sourceID: nil,
        item: FetchedItem(externalID: "shopify:\(UUID().uuidString)", title: title, publishedAt: Date(), kind: .product)
    )
    try await product.save(on: app.db)
    return product
}

private func followed(_ app: Application, headers: HTTPHeaders) async throws -> Set<UUID> {
    var ids: Set<UUID> = []
    try await app.testing().test(.GET, "v1/follows", headers: headers) { res async throws in
        #expect(res.status == .ok, "\(res.body.string)")
        ids = Set(try res.content.decode([BrandDTO].self).compactMap(\.id))
    }
    return ids
}

private func follow(_ app: Application, _ brandID: UUID, headers: HTTPHeaders) async throws {
    try await app.testing().test(.POST, "v1/follows", headers: headers, beforeRequest: { req in
        try req.content.encode(FollowBrand(brandID: brandID))
    }, afterResponse: { res in
        #expect(res.status == .created, "\(res.body.string)")
    })
}

/// A signed-in phone with a second profile on its account.
private func household(_ app: Application, apnsToken: String? = "token-a") async throws -> (headers: HTTPHeaders, holder: UUID, anna: ProfileDTO) {
    app.appleSignIn = AppleSignInConfiguration(verifier: SubjectVerifier(), tokens: nil)
    let (headers, device) = try await register(app, apnsToken: apnsToken)
    try await signIn(app, as: "alice", headers: headers)
    let anna = try await addProfile(app, named: "  Anna \n", headers: headers)
    return (headers, device.$user.id, anna)
}

@Suite("Profiles")
struct ProfileTests {
    @Test("Profiles need an account")
    func needsAnAccount() async throws {
        try await withServer { app in
            let (headers, _) = try await register(app)
            try await app.testing().test(.GET, "v1/account/profiles", headers: headers) { res in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.POST, "v1/account/profiles", headers: headers, beforeRequest: { req in
                try req.content.encode(CreateProfile(name: "Anna"))
            }, afterResponse: { res in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("An account lists its holder first, and a profile is a named user under it")
    func createAndList() async throws {
        try await withServer { app in
            let (headers, holder, anna) = try await household(app)
            #expect(anna.name == "Anna")
            #expect(!anna.isHolder)
            #expect(anna.alertsEnabled)

            try await app.testing().test(.GET, "v1/account/profiles", headers: headers) { res async throws in
                let list = try res.content.decode([ProfileDTO].self)
                #expect(list.map(\.id) == [holder, anna.id])
                #expect(list.first?.isHolder == true)
                #expect(list.first?.name == nil)
            }
            let row = try #require(try await UserModel.find(anna.id, on: app.db))
            #expect(row.$account.id != nil)
            #expect(row.$account.id == (try await UserModel.find(holder, on: app.db))?.$account.id)
        }
    }

    @Test("A profile needs a name, and an account holds a bounded number")
    func refusesBadProfiles() async throws {
        try await withServer { app in
            let (headers, _, anna) = try await household(app)

            try await app.testing().test(.POST, "v1/account/profiles", headers: headers, beforeRequest: { req in
                try req.content.encode(CreateProfile(name: " \n "))
            }, afterResponse: { res in #expect(res.status == .badRequest) })

            // Renaming another profile to nothing is refused; its name labels its alerts.
            try await app.testing().test(.PATCH, "v1/account/profiles/\(anna.id)", headers: headers, beforeRequest: { req in
                try req.content.encode(UpdateProfile(name: ""))
            }, afterResponse: { res in #expect(res.status == .badRequest) })

            for index in 2..<Profiles.maxPerAccount {
                _ = try await addProfile(app, named: "Profile \(index)", headers: headers)
            }
            try await app.testing().test(.POST, "v1/account/profiles", headers: headers, beforeRequest: { req in
                try req.content.encode(CreateProfile(name: "One too many"))
            }, afterResponse: { res in #expect(res.status == .conflict) })
        }
    }

    @Test("Rename and the alerts switch change only what was sent")
    func renameAndAlerts() async throws {
        try await withServer { app in
            let (headers, holder, anna) = try await household(app)

            try await app.testing().test(.PATCH, "v1/account/profiles/\(anna.id)", headers: headers, beforeRequest: { req in
                try req.content.encode(UpdateProfile(alertsEnabled: false))
            }, afterResponse: { res async throws in
                let dto = try res.content.decode(ProfileDTO.self)
                #expect(dto.name == "Anna")
                #expect(!dto.alertsEnabled)
            })
            try await app.testing().test(.PATCH, "v1/account/profiles/\(holder)", headers: headers, beforeRequest: { req in
                try req.content.encode(UpdateProfile(name: "Alice"))
            }, afterResponse: { res async throws in
                let dto = try res.content.decode(ProfileDTO.self)
                #expect(dto.name == "Alice")
                #expect(dto.isHolder)
                #expect(dto.alertsEnabled)
            })
        }
    }

    /// The header is the whole of "which profile": with it a route reads and writes the
    /// profile's rows, without it the holder's, exactly as before.
    @Test("A request acts for the profile it names, and for the device's user without one")
    func actsForTheNamedProfile() async throws {
        try await withServer { app in
            let (headers, holder, anna) = try await household(app)
            let kith = try await brand(app, "kith.com")
            let staud = try await brand(app, "staud.clothing")

            try await follow(app, kith, headers: headers)
            try await follow(app, staud, headers: acting(as: anna.id, headers))

            #expect(try await followed(app, headers: headers) == [kith])
            #expect(try await followed(app, headers: acting(as: anna.id, headers)) == [staud])
            // Naming the holder is the same as naming nobody.
            #expect(try await followed(app, headers: acting(as: holder, headers)) == [kith])

            // Sizes go to the acting profile, the token to the device.
            try await app.testing().test(.PATCH, "v1/devices/me", headers: acting(as: anna.id, headers), beforeRequest: { req in
                try req.content.encode(UpdateDevice(apnsToken: "token-b", sizes: SizePayload(apparel: ["S"], shoe: [], gender: "womens")))
            }, afterResponse: { res in #expect(res.status == .noContent) })
            let annaRow = try #require(try await UserModel.find(anna.id, on: app.db))
            let holderRow = try #require(try await UserModel.find(holder, on: app.db))
            #expect(annaRow.sizeProfile.apparel == ["S"])
            #expect(annaRow.sizeProfile.gender == .womens)
            #expect(holderRow.sizeProfile.apparel.isEmpty)
            #expect(try await DeviceModel.query(on: app.db).filter(\.$user.$id == holder).first()?.apnsToken == "token-b")

            // The feed reads the profile's follows.
            try await EventModel(brandID: staud, productID: try await product(app, brandID: staud).requireID(), kind: .product)
                .save(on: app.db)
            try await app.testing().test(.GET, "v1/feed", headers: acting(as: anna.id, headers)) { res async throws in
                #expect(try res.content.decode(FeedResponse.self).items.map(\.brandID) == [staud])
            }
            try await app.testing().test(.GET, "v1/feed", headers: headers) { res async throws in
                #expect(try res.content.decode(FeedResponse.self).items.isEmpty)
            }
        }
    }

    @Test("A profile on another account, or on no account, is refused with the reason the app knows")
    func refusesAStrangersProfile() async throws {
        try await withServer { app in
            let (_, _, anna) = try await household(app)

            // Somebody else's signed-in phone.
            let (other, _) = try await register(app)
            try await signIn(app, as: "bob", headers: other)
            try await app.testing().test(.GET, "v1/follows", headers: acting(as: anna.id, other)) { res async throws in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains(ProfileHeader.refusal))
            }

            // A phone with no account at all.
            let (anonymous, _) = try await register(app)
            try await app.testing().test(.GET, "v1/follows", headers: acting(as: anna.id, anonymous)) { res in
                #expect(res.status == .forbidden)
            }
            // Without the header, both are exactly what they were.
            try await app.testing().test(.GET, "v1/follows", headers: anonymous) { res in
                #expect(res.status == .ok)
            }

            var garbage = anonymous
            garbage.replaceOrAdd(name: ProfileHeader.name, value: "not-a-uuid")
            try await app.testing().test(.GET, "v1/follows", headers: garbage) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Deleting a profile takes its follows, watches and hints, never the catalogue or the holder's")
    func deleteProfile() async throws {
        try await withServer { app in
            let (headers, holder, anna) = try await household(app)
            let kith = try await brand(app, "kith.com")
            let hoodie = try await product(app, brandID: kith)

            try await follow(app, kith, headers: headers)
            try await follow(app, kith, headers: acting(as: anna.id, headers))
            try await WatchModel(userID: anna.id, brandID: kith, productID: try hoodie.requireID(), size: "M", color: nil)
                .save(on: app.db)
            try await PollHintModel(userID: anna.id, brandID: kith, releaseAt: Date().addingTimeInterval(3600))
                .save(on: app.db)

            try await app.testing().test(.DELETE, "v1/account/profiles/\(holder)", headers: headers) { res in
                #expect(res.status == .conflict)
            }
            try await app.testing().test(.DELETE, "v1/account/profiles/\(anna.id)", headers: headers) { res in
                #expect(res.status == .noContent)
            }

            #expect(try await UserModel.find(anna.id, on: app.db) == nil)
            #expect(try await FollowModel.query(on: app.db).filter(\.$user.$id == anna.id).count() == 0)
            #expect(try await WatchModel.query(on: app.db).filter(\.$user.$id == anna.id).count() == 0)
            #expect(try await PollHintModel.query(on: app.db).filter(\.$user.$id == anna.id).count() == 0)
            #expect(try await followed(app, headers: headers) == [kith])
            #expect(try await BrandModel.find(kith, on: app.db) != nil)
            #expect(try await ProductModel.find(hoodie.requireID(), on: app.db) != nil)

            // A phone still acting for the deleted profile is told so, in the words it knows.
            try await app.testing().test(.GET, "v1/follows", headers: acting(as: anna.id, headers)) { res async throws in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains(ProfileHeader.refusal))
            }
        }
    }

    @Test("Deleting the account deletes every profile on it")
    func accountDeletionTakesProfiles() async throws {
        try await withServer { app in
            let (headers, holder, anna) = try await household(app)
            let kith = try await brand(app, "kith.com")
            try await follow(app, kith, headers: acting(as: anna.id, headers))

            try await app.testing().test(.DELETE, "v1/account", headers: headers) { res in
                #expect(res.status == .noContent)
            }
            #expect(try await UserModel.find(holder, on: app.db) == nil)
            #expect(try await UserModel.find(anna.id, on: app.db) == nil)
            #expect(try await FollowModel.query(on: app.db).count() == 0)
            #expect(try await BrandModel.find(kith, on: app.db) != nil)
        }
    }

    /// What the app needs to put a watch back on a phone that has never seen the product.
    @Test("The watch list describes the product")
    func watchesDescribeTheirProduct() async throws {
        try await withServer { app in
            let (headers, holder, _) = try await household(app)
            let kith = try await brand(app, "kith.com")
            let hoodie = try await product(app, brandID: kith, title: "Box Logo Hoodie")
            hoodie.imageURLs = ["https://cdn.example/hoodie.jpg"]
            hoodie.linkURL = "https://kith.com/products/hoodie"
            hoodie.priceText = "$180"
            try await hoodie.save(on: app.db)
            try await VariantModel(
                productID: try hoodie.requireID(),
                info: VariantInfo(id: "1", title: "M", available: false, price: "$180", size: "M")
            ).save(on: app.db)
            try await WatchModel(userID: holder, brandID: kith, productID: try hoodie.requireID(), size: "M", color: nil)
                .save(on: app.db)

            try await app.testing().test(.GET, "v1/watches", headers: headers) { res async throws in
                let watch = try #require(try res.content.decode([WatchDTO].self).first)
                #expect(watch.productTitle == "Box Logo Hoodie")
                #expect(watch.imageURLs == ["https://cdn.example/hoodie.jpg"])
                #expect(watch.productURL == "https://kith.com/products/hoodie")
                #expect(watch.priceText == "$180")
                #expect(watch.variants?.map(\.size) == ["M"])
            }
        }
    }
}

@Suite("Sign-in races")
struct SignInRaceTests {
    /// The bug: two first sign-ins for one Apple ID both missed, both inserted, and the second
    /// insert hit the unique constraint on `apple_subject` and came back a 500.
    @Test("A sign-in that loses the race to create the account reads the winner's row")
    func lostRaceReadsTheWinner() async throws {
        try await withServer { app in
            let winner = AccountModel(appleSubject: "alice")
            let (account, isNew) = try await Accounts.findOrCreate(subject: "alice", on: app.db, racing: {
                // The other sign-in lands between this one's lookup and its insert.
                try await winner.save(on: app.db)
            })
            #expect(!isNew)
            #expect(account.id == winner.id)
            #expect(try await AccountModel.query(on: app.db).count() == 1)
        }
    }
}

/// The concurrent half of the race, which only Postgres can show: SQLite takes no row locks and
/// serialises writers, so there two sign-ins either queue or one is refused as busy, and neither
/// says anything about the lock. Runs only when `STREETW_TEST_POSTGRES_URL` names a scratch
/// database — the whole migration chain is applied and reverted, as `CreditRaceTests` does.
@Suite(
    "Sign-in races on Postgres",
    .enabled(if: ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"] != nil),
    .serialized
)
struct SignInPostgresRaceTests {
    private func withPostgres(_ body: (Application) async throws -> Void) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["STREETW_TEST_POSTGRES_URL"])
        let app = try await Application.make(.testing)
        var config = try SQLPostgresConfiguration(url: url)
        config.coreConfiguration.tls = .disable
        app.databases.use(.postgres(configuration: config, maxConnectionsPerEventLoop: 8), as: .psql)
        addMigrations(to: app)
        do {
            try await app.autoMigrate()
            try await body(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// Ten phones, one Apple ID, all at once: one account, one user on it, and every phone on
    /// that user — never a second user that would read as a nameless profile.
    @Test("Phones signing in at once end up on one account with one user")
    func concurrentFirstSignIns() async throws {
        try await withPostgres { app in
            var devices: [DeviceModel] = []
            for index in 0..<10 {
                let user = UserModel()
                user.country = index == 3 ? "GB" : nil
                try await user.save(on: app.db)
                let device = DeviceModel(userID: try user.requireID(), apnsToken: nil, environment: "sandbox", locale: nil)
                try await device.save(on: app.db)
                devices.append(device)
            }
            let results = await withTaskGroup(of: Bool.self) { group in
                for device in devices {
                    group.addTask { (try? await Accounts.signIn(subject: "alice", device: device, on: app.db)) != nil }
                }
                return await group.reduce(into: [Bool]()) { $0.append($1) }
            }
            #expect(results.allSatisfy { $0 })
            let accounts = try await AccountModel.query(on: app.db).all()
            #expect(accounts.count == 1)
            let accountID = try #require(accounts.first?.id)
            let users = try await UserModel.query(on: app.db).filter(\.$account.$id == accountID).all()
            #expect(users.count == 1)
            let holder = try #require(users.first)
            #expect(try await DeviceModel.query(on: app.db).filter(\.$user.$id == holder.requireID()).count() == 10)
            // The one phone that knew where it was gave the account its country.
            #expect(holder.country == "GB")
        }
    }
}

/// "Profiles share the account, the credits and the location" (`ROADMAP.md`). A profile is
/// somebody you shop *for*: still your money, still your country.
@Suite("Profiles and the account's country and credits")
struct ProfileAccountTests {
    private func countries(_ app: Application) async throws -> [String?] {
        try await UserModel.query(on: app.db).all().map(\.country)
    }

    private func patchCountry(_ app: Application, _ country: String, headers: HTTPHeaders) async throws {
        try await app.testing().test(.PATCH, "v1/devices/me", headers: headers, beforeRequest: { req in
            try req.content.encode(UpdateDevice(country: country))
        }, afterResponse: { res in #expect(res.status == .noContent) })
    }

    @Test("A country sent as any profile is the whole account's, and a new profile starts there")
    func countryIsTheAccounts() async throws {
        try await withServer { app in
            let (headers, holder, anna) = try await household(app)

            try await patchCountry(app, "gb", headers: acting(as: anna.id, headers))
            #expect(try await UserModel.find(holder, on: app.db)?.country == "GB",
                    "Anna's phone said where it is, and that is where the account is")
            #expect(try await UserModel.find(anna.id, on: app.db)?.country == "GB")

            let bea = try await addProfile(app, named: "Bea", headers: headers)
            #expect(try await UserModel.find(bea.id, on: app.db)?.country == "GB")

            // Cleared from the holder, cleared everywhere.
            try await patchCountry(app, "", headers: headers)
            #expect(try await countries(app).allSatisfy { $0 == nil })
        }
    }

    @Test("The sign-in merge gives every profile the account's country")
    func mergeCarriesCountryToProfiles() async throws {
        try await withServer { app in
            let (_, _, anna) = try await household(app)
            // A second phone, somewhere, signs in to the same account.
            let (second, _) = try await register(app)
            try await patchCountry(app, "DE", headers: second)
            try await signIn(app, as: "alice", headers: second)
            #expect(try await UserModel.find(anna.id, on: app.db)?.country == "DE")
            #expect(try await countries(app).allSatisfy { $0 == "DE" })
        }
    }

    /// The storefront rules are unchanged code reading a column the account keeps equal on
    /// every profile — so a profile's follow is a follow *there*, and it is served there.
    @Test("A profile is served, polled for and pushed from its holder's country's shop")
    func profileUsesTheHoldersShop() async throws {
        try await withServer { app in
            app.storefrontCountries = ["GB"]
            let brandID = try await seedBothShops(app)
            let (headers, _, anna) = try await household(app, apnsToken: "phone")
            try await patchCountry(app, "GB", headers: headers)
            // Only Anna follows the brand.
            try await follow(app, brandID, headers: acting(as: anna.id, headers))

            let shop = try #require(try await StorefrontModel.query(on: app.db).first())
            #expect(try await Storefronts.wanted(enabled: ["GB"], on: app.db) == [try shop.requireID()],
                    "the British shop is read because somebody there follows the brand")

            try await app.testing().test(.GET, "v1/feed", headers: acting(as: anna.id, headers)) { res async throws in
                #expect(try res.content.decode(FeedResponse.self).items.map(\.title) == ["UK Tee"])
            }
            try await app.testing().test(.GET, "v1/follows", headers: acting(as: anna.id, headers)) { res async throws in
                #expect(try res.content.decode([BrandDTO].self).first?.storefront?.country == "GB")
            }

            let sender = RecordingSender()
            await Notifier(app: app, sender: sender).dispatch()
            #expect(sender.sent.map(\.body) == ["For Anna: New: UK Tee"])
        }
    }

    @Test("Credits asked as any profile are the account's one ledger")
    func creditsAreTheAccounts() async throws {
        try await withServer { app in
            let (headers, _, anna) = try await household(app)
            func summary(_ headers: HTTPHeaders) async throws -> CreditsSummary {
                var summary: CreditsSummary?
                try await app.testing().test(.GET, "v1/credits", headers: headers) { res async throws in
                    #expect(res.status == .ok)
                    summary = try res.content.decode(CreditsSummary.self)
                }
                return try #require(summary)
            }
            let mine = try await summary(headers)
            let hers = try await summary(acting(as: anna.id, headers))
            #expect(mine.signedIn && hers.signedIn)
            #expect(mine.accountToken != nil)
            #expect(hers.accountToken == mine.accountToken)
            #expect(hers.balance == mine.balance)
        }
    }
}

@Suite("Profile notifications")
struct ProfileNotifierTests {
    private func event(_ app: Application, brandID: UUID, kind: UpdateKind, title: String) async throws -> EventModel {
        let product = try await product(app, brandID: brandID, title: title)
        let event = EventModel(brandID: brandID, productID: try product.requireID(), kind: kind)
        try await event.save(on: app.db)
        return event
    }

    /// The account's phone hears about both people, the other one labelled — and inside the
    /// cooldown, about neither again.
    @Test("Each profile hears about a brand once per cooldown, the other profile labelled")
    func oneAlertPerProfile() async throws {
        try await withServer { app in
            let (headers, holder, anna) = try await household(app)
            let kith = try await brand(app, "kith.com", name: "Kith")
            try await follow(app, kith, headers: headers)
            try await follow(app, kith, headers: acting(as: anna.id, headers))
            _ = try await event(app, brandID: kith, kind: .product, title: "Chore Jacket")

            let sender = RecordingSender()
            let notifier = Notifier(app: app, sender: sender)
            #expect(await notifier.dispatch().sent == 2)

            let bodies = Set(sender.sent.map(\.body))
            #expect(bodies == ["New: Chore Jacket", "For Anna: New: Chore Jacket"])
            #expect(Set(sender.sent.map(\.title)) == ["Kith"])
            #expect(Set(sender.sent.map(\.deviceToken)) == ["token-a"])

            let mine = try #require(sender.sent.first { !$0.body.hasPrefix("For ") })
            let hers = try #require(sender.sent.first { $0.body.hasPrefix("For ") })
            #expect(mine.collapseID == kith.uuidString)
            #expect(hers.collapseID == "\(kith.uuidString)/\(anna.id.uuidString.prefix(8))")
            #expect(hers.collapseID!.utf8.count <= 64)
            #expect(mine.profileID == holder)
            #expect(hers.profileID == anna.id)

            _ = try await event(app, brandID: kith, kind: .product, title: "Chore Pant")
            #expect(await notifier.dispatch().sent == 0)
            #expect(sender.sent.count == 2)
        }
    }

    @Test("A profile with alerts off hears nothing; the others are unaffected")
    func alertsSwitch() async throws {
        try await withServer { app in
            let (headers, _, anna) = try await household(app)
            let kith = try await brand(app, "kith.com", name: "Kith")
            try await follow(app, kith, headers: headers)
            try await follow(app, kith, headers: acting(as: anna.id, headers))
            try await app.testing().test(.PATCH, "v1/account/profiles/\(anna.id)", headers: headers, beforeRequest: { req in
                try req.content.encode(UpdateProfile(alertsEnabled: false))
            }, afterResponse: { res in #expect(res.status == .ok) })
            _ = try await event(app, brandID: kith, kind: .product, title: "Chore Jacket")

            let sender = RecordingSender()
            #expect(await Notifier(app: app, sender: sender).dispatch().sent == 1)
            #expect(sender.sent.map(\.body) == ["New: Chore Jacket"])
        }
    }

    @Test("A watch for a profile fires labelled, and is spent with its alerts off too")
    func watchForAProfile() async throws {
        try await withServer { app in
            let (headers, _, anna) = try await household(app)
            let kith = try await brand(app, "kith.com", name: "Kith")
            try await follow(app, kith, headers: acting(as: anna.id, headers))

            let hoodie = try await product(app, brandID: kith, title: "Box Tee")
            let productID = try hoodie.requireID()
            try await VariantModel(
                productID: productID,
                info: VariantInfo(id: "1", title: "M", available: true, price: "$60", size: "M")
            ).save(on: app.db)
            let watch = WatchModel(userID: anna.id, brandID: kith, productID: productID, size: "M", color: nil)
            try await watch.save(on: app.db)
            try await EventModel(brandID: kith, productID: productID, kind: .restock, sizes: ["M"]).save(on: app.db)

            let sender = RecordingSender()
            let notifier = Notifier(app: app, sender: sender)
            #expect(await notifier.dispatch().sent == 1)
            #expect(sender.sent.first?.body == "For Anna: Back in M — Box Tee")
            #expect(sender.sent.first?.profileID == anna.id)

            // Off, the next watch is still spent but says nothing.
            let anna2 = try #require(try await UserModel.find(anna.id, on: app.db))
            anna2.alertsEnabled = false
            try await anna2.save(on: app.db)
            let second = WatchModel(userID: anna.id, brandID: kith, productID: productID, size: nil, color: nil)
            try await second.save(on: app.db)
            try await EventModel(brandID: kith, productID: productID, kind: .restock, sizes: ["M"]).save(on: app.db)
            #expect(await notifier.dispatch().sent == 0)
            #expect(try await WatchModel.find(second.requireID(), on: app.db)?.firedAt != nil)
        }
    }

    /// Every phone that never signed in reads exactly as it did.
    @Test("An anonymous follower's alert carries no label and no profile")
    func anonymousIsUnchanged() async throws {
        try await withServer { app in
            let (headers, _) = try await register(app, apnsToken: "token-z")
            let kith = try await brand(app, "kith.com", name: "Kith")
            try await follow(app, kith, headers: headers)
            _ = try await event(app, brandID: kith, kind: .product, title: "Chore Jacket")

            let sender = RecordingSender()
            #expect(await Notifier(app: app, sender: sender).dispatch().sent == 1)
            let message = try #require(sender.sent.first)
            #expect(message.body == "New: Chore Jacket")
            #expect(message.collapseID == kith.uuidString)
            #expect(message.profileID == nil)
        }
    }
}
