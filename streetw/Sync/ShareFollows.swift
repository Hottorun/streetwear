// ShareFollows.swift
// "Follow this shop", chosen in the share sheet, carried out on the next foreground.
//
// The sheet can only record the wish — it has no network — so the follow is made here, through
// the paths the add-brand screen uses and in the same order: **the catalogue is searched
// first**, because it is global and the second person to share Kith should follow the row that
// exists. Only a shop nobody has is checked, and the check is *watched*: the server follows it
// once it settles, with the app closed if need be, and the next foreground that finds it
// settled finishes here. Standalone, the phone discovers the site itself, as `AddBrandView` does.
//
// Then the follow-filter question — what do you want to see from them — is asked through
// `announce`, the seam to that dialog (see `NewFollows`). Each step is kept in `ShareQuestions`
// until it is done, so a follow wished for in the sheet survives a kill, a profile switch and a
// server that was down for an afternoon.

import Foundation
import OSLog
import StreetwCore
import SwiftData

@MainActor
enum ShareFollows {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "share")

    /// A shop that cannot be reached is tried this many times, a foreground apart, and then
    /// let go. The share sheet said the app would ask; it cannot keep asking the network forever.
    static let maxAttempts = 8

    static func process(
        scope: ProfileScope,
        context: ModelContext,
        remote: RemoteSync,
        engine: SyncEngine,
        settings: ServerSettings,
        sizes: SizeProfileStore,
        questions: ShareQuestions,
        announce: (UUID) -> Void
    ) async {
        for follow in questions.follows(for: scope) {
            if let brand = followedBrand(for: follow.url, in: context) {
                // Followed already — from another share, or by hand while this one waited.
                questions.finish(follow, for: scope)
                log.info("already follow \(brand.name, privacy: .public)")
                continue
            }
            let brandID = settings.isConfigured
                ? await followOnServer(follow, scope: scope, remote: remote, sizes: sizes, questions: questions)
                : await followHere(follow, context: context, engine: engine)
            guard let brandID else { continue }
            questions.finish(follow, for: scope)
            announce(brandID)
            log.info("followed \(follow.url.absoluteString, privacy: .public) from a share")
        }
    }

    /// The brand's server id once the follow exists, nil while it is still on its way.
    private static func followOnServer(
        _ follow: ShareQuestions.Follow,
        scope: ProfileScope,
        remote: RemoteSync,
        sizes: SizeProfileStore,
        questions: ShareQuestions
    ) async -> UUID? {
        var follow = follow
        do {
            if let checkID = follow.checkID {
                let check = try await remote.check(id: checkID)
                switch check.status {
                case .checking:
                    return nil
                case .ready:
                    // Watching is idempotent, and is what brings the brand in when the server
                    // made the follow while the app was closed.
                    let watched = try await remote.watch(check: checkID, instagram: nil, sizes: sizes.profile)
                    guard let id = watched.brand?.id else { return nil }
                    await remote.sync(sizes: sizes.profile)
                    return id
                case .refused:
                    // Nothing on the site answers at all. Nothing more can be done from here,
                    // and the add-brand screen is where somebody can see why.
                    log.notice("\(follow.url.absoluteString, privacy: .public) cannot be watched; letting the follow go")
                    questions.finish(follow, for: scope)
                    return nil
                case .interrupted:
                    follow.checkID = nil
                    questions.update(follow, for: scope)
                    return nil
                }
            }

            let host = follow.url.host() ?? follow.url.absoluteString
            let found = try await remote.searchBrands(host)
            if let existing = found.first(where: { dto in
                dto.website.flatMap(URL.init(string:)).map { BrandDiscovery.isSameBrandHost($0, follow.url) } ?? false
            }), let id = existing.id {
                try await remote.followExisting(existing, sizes: sizes.profile)
                return id
            }

            let origin = "https://\(host)"
            let check = try await remote.startCheck(url: origin)
            let watched = try await remote.watch(check: check.id, instagram: nil, sizes: sizes.profile)
            if let id = watched.brand?.id {
                await remote.sync(sizes: sizes.profile)
                return id
            }
            follow.checkID = check.id
            questions.update(follow, for: scope)
            return nil
        } catch {
            follow.attempts += 1
            if follow.attempts >= maxAttempts {
                log.error("gave up following \(follow.url.absoluteString, privacy: .public): \(error)")
                questions.finish(follow, for: scope)
            } else {
                questions.update(follow, for: scope)
            }
            return nil
        }
    }

    /// Standalone: the phone discovers the site and polls it, exactly as `AddBrandView` does.
    private static func followHere(
        _ follow: ShareQuestions.Follow,
        context: ModelContext,
        engine: SyncEngine
    ) async -> UUID? {
        let site = follow.url.host() ?? follow.url.absoluteString
        let discovered = await BrandDiscovery.discover(website: site, instagramHandle: nil)
        let brand = Brand(
            name: discovered.suggestedName ?? follow.name ?? site,
            websiteURL: BrandDiscovery.normalizedURL(site)
        )
        brand.sources = discovered.sources
        brand.logoURLString = discovered.logoURL?.absoluteString
        // Nothing was typed, so the first sync is free to improve on the guess.
        brand.usesGeneratedName = true
        context.insert(brand)
        try? context.save()
        // The first sync is the baseline, so following does not flood the feed.
        await engine.sync(brands: [brand])
        return brand.id
    }

    private static func followedBrand(for url: URL, in context: ModelContext) -> Brand? {
        let brands = (try? context.fetch(FetchDescriptor<Brand>(predicate: #Predicate { $0.followed }))) ?? []
        return brands.first { BrandDiscovery.isSameBrandHost(url, $0.websiteURL) }
    }
}

/// **The seam to the follow-filter dialog**, which is built on another branch
/// (`FollowFilterPrompt`, "what do you want to see from them?").
///
/// That dialog keeps its own persisted per-profile queue and is asked with
/// `session.followPrompt.ask(brandID:)`, by a server id or a local `Brand.id`. Its server-mode
/// follow paths in `RemoteSync` ask on their own, so in server mode the share's follow is asked
/// about twice and deduplicated by that queue; standalone, this is the only call. Until the two
/// branches meet, `announce` posts `NewFollows.followed` with the brand id and the store's home
/// — merging means replacing the body with `session.followPrompt.ask(brandID:)` at the call site
/// in `streetwApp`.
enum NewFollows {
    static let followed = Notification.Name("com.kern.functional.streetw.newFollow")

    static func announce(_ brandID: UUID, scope: ProfileScope) {
        NotificationCenter.default.post(
            name: followed,
            object: nil,
            userInfo: ["brandID": brandID, "home": scope.home as Any]
        )
    }
}
