// Sales.swift
// A brand going on sale, said once — from its catalogue (`Poller.settleSale`) or from its
// announcement bar (`SaleBanners`).

import Fluent
import Foundation
import SQLKit
import StreetwCore
import Vapor

/// The one place a `.sale` event is written.
enum SaleEvents {
    /// How long one sale announcement speaks for the brand.
    ///
    /// **Two detectors, one sale.** An end-of-season sale marks the catalogue down *and* puts
    /// "SALE NOW ON" in the bar, and the two are read on different schedules, minutes apart;
    /// announcing each would be two pushes for one thing. So whichever sees it first says it,
    /// and the other records what it saw without saying it again. In practice they rarely
    /// overlap the other way: a code sale changes no price in the catalogue, and a markdown
    /// rail usually comes with a bar that says only "sale". A day, because a brand starting
    /// two genuinely different sales within one is rare, and a second push about the same
    /// sale is not.
    static let quietPeriod: TimeInterval = 24 * 3600

    /// Writes the event, unless the brand announced a sale within `quietPeriod`. Returns
    /// whether it wrote one.
    @discardableResult
    static func announce(
        on db: any Database,
        brandID: UUID,
        title: String,
        summary: String?,
        now: Date = Date()
    ) async throws -> Bool {
        let recent = try await EventModel.query(on: db)
            .filter(\.$brand.$id == brandID)
            .filter(\.$kind == UpdateKind.sale.rawValue)
            .filter(\.$createdAt > now.addingTimeInterval(-quietPeriod))
            .count()
        guard recent == 0 else { return false }
        try await EventModel(
            brandID: brandID,
            productID: nil,
            kind: .sale,
            title: title,
            summary: summary
        ).save(on: db)
        return true
    }
}

/// Reads followed brands' homepages for a sale in the announcement bar.
///
/// A code sale — "25% off everything with code AUTUMN" — moves no price in the catalogue: the
/// discount is taken in the cart. The bar is the only place it exists, so it is read on a
/// schedule of its own, per brand, through the same `PoliteFetcher` as every poll, and what it
/// says is decided by `SaleBanner` and `SaleBannerLedger` in `StreetwCore`.
///
/// Three rules worth knowing:
///
/// - **Only brands somebody would hear from.** A brand followed by nobody, or only by quiet
///   follows, is never read — a homepage is the heaviest page a storefront serves, and a sale
///   nobody can be told about is not worth a request.
/// - **The first read of a brand is a baseline.** `banner_check_at` is nil until then; a sale
///   already in the bar when this shipped, or when the brand was first followed, is recorded
///   and not announced.
/// - **The schedule moves whatever happens**, like `next_check_at` after a failed poll: a
///   homepage that errors is asked again at the next interval, never on the next tick.
struct SaleBanners {
    let app: Application
    let http: any HTTPFetching

    /// Homepages read per pass. Three every thirty seconds is a few hundred brands an hour,
    /// which covers every followed brand inside its interval with room to spare, and never
    /// enough to put two reads to one host back to back.
    static let budget = 3

    /// How long a lease holds a brand off the queue while its homepage is being read.
    static let leaseDuration: TimeInterval = 5 * 60

    /// Between thirty and sixty minutes, fixed per brand.
    ///
    /// A sale code is worth hearing about within the hour and is never a matter of minutes —
    /// the bar is up for days. Spread by the brand's id rather than drawn at random, so the
    /// reads of a few hundred brands do not bunch at the half hour and one brand's cadence
    /// is the same on every deploy.
    static func interval(for brandID: UUID) -> TimeInterval {
        let bytes = withUnsafeBytes(of: brandID.uuid) { Array($0) }
        let spread = bytes.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % 31
        return TimeInterval(30 + spread) * 60
    }

    /// A homepage robots.txt asks us not to read is not asked again for a day: the answer
    /// is the site's, not a failure, and it rarely changes.
    static let refusedInterval: TimeInterval = 24 * 3600

    @discardableResult
    func checkDue(limit: Int = SaleBanners.budget, now: Date = Date()) async -> Int {
        let due: [(brand: BrandModel, isFirstCheck: Bool)]
        do {
            due = try await claim(limit: limit, now: now)
        } catch {
            app.logger.error("banners: could not claim due brands: \(error)")
            return 0
        }

        var read = 0
        for (brand, isFirstCheck) in due {
            do {
                if try await check(brand, isFirstCheck: isFirstCheck, now: now) { read += 1 }
            } catch {
                app.logger.error("banners: could not store \(brand.name)'s bar: \(error)")
            }
        }
        return read
    }

    /// One brand's bar. Returns whether the page was actually read.
    private func check(_ brand: BrandModel, isFirstCheck: Bool, now: Date) async throws -> Bool {
        guard let brandID = brand.id else { return false }
        var next = Self.interval(for: brandID)
        var didRead = false

        // A locked storefront shows its password page, which is about the drop and not a sale
        // — and whatever is in it is gone the moment the store reopens.
        if !brand.lockedForDrop, let home = Self.homepage(of: brand.website) {
            do {
                let response = try await http.get(home)
                if response.status == 200, !response.isLocked {
                    didRead = true
                    let banner = SaleBanner.read(html: String(decoding: response.data, as: UTF8.self))
                    let outcome = SaleBannerLedger.decide(
                        found: banner,
                        stored: brand.saleBanner,
                        seenAt: brand.saleBannerSeenAt,
                        isFirstCheck: isFirstCheck,
                        now: now
                    )
                    if outcome.announce, let banner {
                        try await SaleEvents.announce(
                            on: app.db,
                            brandID: brandID,
                            title: banner.title,
                            summary: banner.message,
                            now: now
                        )
                    }
                    brand.saleBanner = outcome.stored
                    brand.saleBannerSeenAt = outcome.seenAt
                }
            } catch SourceError.disallowedByRobots {
                next = Self.refusedInterval
            } catch {
                app.logger.info("banners: \(home.host() ?? "?") did not answer: \(error)")
            }
        }

        // A first look that could not read anything is still the first look: leaving the
        // schedule nil would make the next read a baseline as well, which is correct, but
        // an unreadable homepage would then be asked on every pass.
        brand.bannerCheckAt = now.addingTimeInterval(next)
        try await brand.save(on: app.db)
        return didRead
    }

    /// The root of the brand's own site, on the host it was added with.
    static func homepage(of website: String?) -> URL? {
        guard let website, var components = URLComponents(string: website), components.host != nil else {
            return nil
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The due brands, each with whether this is its first read — taken before the lease
    /// overwrites the schedule that says so.
    ///
    /// **A lease, as the poll queue's claim is.** Two instances reading one brand's bar would
    /// both see a new sale and both announce it; `FOR UPDATE SKIP LOCKED` hands each brand to
    /// one of them, and pushing `banner_check_at` forward in the same statement keeps a
    /// process killed mid-read from stranding the brand. Postgres only; SQLite has neither
    /// the syntax nor a second instance.
    private func claim(limit: Int, now: Date) async throws -> [(brand: BrandModel, isFirstCheck: Bool)] {
        let db = app.db
        let lease = now.addingTimeInterval(Self.leaseDuration)

        if let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" {
            let query: SQLQueryString = """
                WITH due AS ( \
                    SELECT id, banner_check_at FROM brands \
                    WHERE website IS NOT NULL \
                    AND (banner_check_at IS NULL OR banner_check_at <= \(bind: now)) \
                    AND id IN (SELECT brand_id FROM follows WHERE mode <> 'quiet') \
                    ORDER BY banner_check_at NULLS FIRST \
                    LIMIT \(bind: limit) \
                    FOR UPDATE SKIP LOCKED \
                ) \
                UPDATE brands SET banner_check_at = \(bind: lease) FROM due \
                WHERE brands.id = due.id \
                RETURNING brands.id AS id, due.banner_check_at AS previous
                """
            let rows = try await sql.raw(query).all()
            var firstCheck: [UUID: Bool] = [:]
            for row in rows {
                let id = try row.decode(column: "id", as: UUID.self)
                firstCheck[id] = try row.decodeNil(column: "previous")
            }
            guard !firstCheck.isEmpty else { return [] }
            return try await BrandModel.query(on: db)
                .filter(\.$id ~~ Array(firstCheck.keys))
                .all()
                .compactMap { brand in brand.id.flatMap { firstCheck[$0] }.map { (brand, $0) } }
        }

        let followed = try await FollowModel.query(on: db)
            .filter(\.$modeRaw != FollowMode.quiet.rawValue)
            .all()
            .map(\.$brand.id)
        guard !followed.isEmpty else { return [] }
        let brands = try await BrandModel.query(on: db)
            .filter(\.$id ~~ Array(Set(followed)))
            .filter(\.$website != nil)
            .group(.or) { $0.filter(\.$bannerCheckAt == nil).filter(\.$bannerCheckAt <= now) }
            .sort(\.$bannerCheckAt)
            .limit(limit)
            .all()
        return brands.map { ($0, $0.bannerCheckAt == nil) }
    }
}
