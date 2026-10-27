// TodaysPicks.swift
// Choosing today's set, worded where a model can, and said in the morning when asked to be.
//
// Three things that used to be one method on `ShopView`, moved here because two callers need
// them now: Shop, which draws the picks, and a background pass, which chooses them before
// anybody opens the app so the morning alert names the set Shop will show (`PicksNotice`).
//
// - **What is chosen is unchanged.** `DailyPicks` decides and `PickLedger` keeps the day's set;
//   this only gathers the same candidates, the same wardrobe and the same ledger for it, from a
//   view's queries or from the store.
// - **The model words; it never chooses** (`PickReasons`). The top three are sent as a product
//   id, the rule that chose them and the wardrobe partner as a short description — never a
//   photograph, a brand or an id of anything owned — once a day, and a pick with no answer
//   keeps the phone's own sentence, silently. Free, so it needs a model on the server and
//   nothing else. See `docs/ai.md` (*Daily picks*).

import Foundation
import OSLog
import StreetwCore
import SwiftData
import UserNotifications

@MainActor
enum TodaysPicks {
    struct Chosen {
        var picks: [ShopPick]
        var hasWardrobe: Bool
    }

    /// Today's set: what was already chosen today, topped up from the catalogue.
    ///
    /// The candidates are narrowed here to what may be offered at all — from a followed shop,
    /// shown by the gender filter, buyable, an essential garment, not already saved, not turned
    /// down, not from a shop refused on Discover, and in the reader's size wherever the
    /// product's run says what that is — and today's own set is exempt from all but the
    /// filter, because a pick saved an hour ago stays on the page with its bookmark filled.
    ///
    /// Nil when the catalogue is not read yet or the work was cancelled.
    static func choose(
        day: String,
        catalogue: ShopCatalogue,
        saves: [SavedItem],
        tasteBoards: [Board],
        dismissals: [BrandDismissal],
        profile: SizeProfile,
        statement: StyleStatement
    ) async -> Chosen? {
        guard catalogue.phase == .ready else { return nil }
        let kept = PickLedger.kept(on: day)
        let keeping = Set(kept)
        let refused = PickLedger.refused
        let dismissed = Set(dismissals.map(\.remoteID))

        var saved: Set<String> = []
        for update in saves.compactMap(\.update) {
            saved.insert(update.externalID)
            if let product = update.productExternalID { saved.insert(product) }
        }

        let eligible = catalogue.index.listings.filter { listing in
            guard listing.isShown else { return false }
            if keeping.contains(listing.id) { return true }
            return listing.isAvailable
                && GarmentSlot.essential.contains(listing.slot)
                && !saved.contains(listing.id)
                && !refused.contains(listing.id)
        }

        var candidates: [DailyPicks.Candidate] = []
        for listing in DailyPicks.pool(eligible, day: day, keeping: keeping) {
            guard let row = catalogue.row(listing.id) else { continue }
            if !keeping.contains(listing.id) {
                if let brand = row.brand?.remoteID, dismissed.contains(brand) { continue }
                guard wears(row, profile) else { continue }
            }
            candidates.append(DailyPicks.Candidate(
                listing: listing,
                garment: row.garment,
                fact: fact(about: row, profile: profile),
                isInYourSize: catalogue.fits(listing, profile: profile)
            ))
        }

        // What you own, through the one rule: the wardrobe whatever its taste setting, or every
        // save that counts for somebody who never filed anything as owned. A photograph is
        // required, as everywhere a save is drawn — the reason shows it.
        let photographed = saves.filter { $0.update?.hasPhotograph == true }
        let wardrobe = TasteScope(boards: tasteBoards, saves: saves).pairingPool(photographed).compactMap(\.update)
        let garments = wardrobe.map(\.garment)
        var owned: [GarmentSlot: Int] = [:]
        for item in wardrobe { owned[item.garmentSlot, default: 0] += 1 }

        let offered = candidates
        let chosen = await Task.detached(priority: .userInitiated) {
            DailyPicks.choose(
                from: offered,
                wardrobe: garments,
                owned: owned,
                statement: statement,
                day: day,
                keeping: kept
            )
        }.value
        guard !Task.isCancelled else { return nil }

        PickLedger.keep(chosen.map(\.id), on: day)
        let byID = Dictionary(wardrobe.map { ($0.pairingID, $0) }, uniquingKeysWith: { first, _ in first })
        let picks = chosen.compactMap { pick in
            catalogue.row(pick.id).map { ShopPick(update: $0, partner: pick.partnerID.flatMap { byID[$0] }, pick: pick) }
        }
        return Chosen(picks: picks, hasWardrobe: !garments.isEmpty)
    }

    /// The same choice for a pass with no view on screen: everything a view's queries would
    /// hold, asked of the store once.
    static func choose(day: String, in context: ModelContext, profile: SizeProfile, statement: StyleStatement) async -> Chosen? {
        let catalogue = ShopCatalogue()
        await catalogue.refreshIfNeeded(in: context, profile: profile)
        let saves = (try? context.fetch(FetchDescriptor<SavedItem>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)]))) ?? []
        let boards = (try? context.fetch(FetchDescriptor<Board>(predicate: Board.shapingTaste))) ?? []
        let dismissals = (try? context.fetch(FetchDescriptor<BrandDismissal>())) ?? []
        return await choose(
            day: day,
            catalogue: catalogue,
            saves: saves,
            tasteBoards: boards,
            dismissals: dismissals,
            profile: profile,
            statement: statement
        )
    }

    /// Buyable in the reader's size where the product's run says what that is; buyable at all
    /// where it does not.
    ///
    /// `matches`, the filter, and not `claims`: this decides whether a pick may be *offered*,
    /// and the filter's rule is the right one for that — a run it cannot read, a one-size
    /// beanie, a profile with no shoe sizes, none of those is a reason to withhold the pick.
    /// The card's size run is where the claim is made, in vermilion, by `claims`.
    private static func wears(_ update: BrandUpdate, _ profile: SizeProfile) -> Bool {
        let variants = update.variants
        guard !variants.isEmpty else { return true }
        let context = update.sizeContext
        return variants.contains { $0.available && profile.matches($0, in: context) }
    }

    /// What the store knows happened to a product, for a pick that has nothing to pair with.
    private static func fact(about update: BrandUpdate, profile: SizeProfile) -> DailyPicks.Fact? {
        if update.kind == .restock {
            let mine = update.restockedSizes(matching: profile)
            if !mine.isEmpty { return .backInYourSize(mine) }
        }
        // The same 5% the feed calls an event (`PriceChange`), so a pick never calls a price
        // "marked down" that the feed did not.
        if let share = update.discountShare, share >= 0.05 {
            return .markedDown(Int((share * 100).rounded()))
        }
        if Date().timeIntervalSince(update.publishedAt) < 7 * 86_400 {
            return .new
        }
        return nil
    }
}

// MARK: - The model's sentence

/// The top few picks' reasons, worded by the model and kept for the day.
///
/// **Asked once per pick per day.** The set is kept for the day (`PickLedger`), so the same
/// three ids would be sent on every visit; the answers are written down beside the day and a
/// pick that was already asked about — answered or refused — is not asked again. Only a request
/// that never reached the server is retried, on the next visit. Per profile and local, like the
/// ledger; the server caches by the request alone, with nobody on the row.
@MainActor
enum PickReasons {
    private static var key: String { ProfileScope.active.key("shopPickReasons") }

    private struct Day: Codable {
        var day: String
        var reasons: [String: String] = [:]
        var asked: [String] = []
    }

    private static func stored(on day: String) -> Day {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Day.self, from: data),
              stored.day == day
        else { return Day(day: day) }
        return stored
    }

    private static func store(_ entry: Day) {
        if let data = try? JSONEncoder().encode(entry) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// What is already known for today, with no request.
    static func cached(on day: String) -> [String: String] {
        stored(on: day).reasons
    }

    /// The day's reasons, asking for the top picks not yet asked about.
    static func load(for picks: [ShopPick], day: String, via ai: AIStore) async -> [String: String] {
        var entry = stored(on: day)
        let wanted = picks.prefix(AIPicks.maxReasons).filter { !entry.asked.contains($0.id) }
        guard ai.isAvailable, !wanted.isEmpty else { return entry.reasons }

        let request = AIPickReasons(picks: wanted.map {
            AIPickReasonRequest(productExternalID: $0.id, anchor: anchor(for: $0.partner), basis: basis(of: $0.pick.reason))
        })
        switch await ai.pickReasons(request) {
        case .success(let answer):
            // Only for what was asked: a sentence about a pick no longer on the page is noise.
            for pick in wanted {
                if let sentence = answer.reasons[pick.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                    entry.reasons[pick.id] = sentence
                }
            }
            entry.asked += wanted.map(\.id)
        case .failure(.failed):
            // Never reached anybody: asked again next time.
            return entry.reasons
        case .failure:
            // Refused for a reason today's next visit will not change.
            entry.asked += wanted.map(\.id)
        }
        store(entry)
        return entry.reasons
    }

    /// The owned piece **as a short description only** — its measured colour and what it is.
    /// Not its title, which can carry a brand ("Kith x New Balance"), and nothing that names it.
    static func anchor(for partner: BrandUpdate?) -> String? {
        guard let partner else { return nil }
        let type = partner.productType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noun = type.flatMap { $0.isEmpty || $0.count > 32 ? nil : $0 } ?? noun(for: partner.garmentSlot)
        let words = [partner.visionColor?.lowercased(), noun].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func noun(for slot: GarmentSlot) -> String? {
        switch slot {
        case .outerwear: "jacket"
        case .top: "top"
        case .bottom: "trousers"
        case .footwear: "shoes"
        case .headwear: "hat"
        case .accessory: "accessory"
        case .unknown: nil
        }
    }

    /// The rule that chose it, by name.
    static func basis(of reason: DailyPicks.Reason) -> String {
        switch reason {
        case .goesWith(fills: nil): "goes_with"
        case .goesWith: "missing"
        case .fills: "missing"
        case .fact(.backInYourSize): "back_in_your_size"
        case .fact(.markedDown): "marked_down"
        case .fact(.new): "new"
        case .fromYourShops: "followed_shop"
        }
    }
}

// MARK: - The morning alert

/// "3 picks for today: …" — a local notification, off by default, about a set already chosen.
///
/// **Always true, because it names a set that exists.** It is scheduled only by a pass that has
/// just chosen — and kept — the day's picks, so the alert and the page cannot disagree; and the
/// moment Shop shows the picks the alert has nothing left to say and is withdrawn. Nothing about
/// picks reaches the server to send it, which is why it is local.
///
/// At nine in the morning when the pass runs before then; at once when it runs later in the day
/// and nobody has looked yet; never after nine at night, when "today's picks" is nearly
/// tomorrow's. Its own `picks-` identifiers, so nothing here clears a drop reminder or a watch.
@MainActor
enum PicksNotice {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "picks")

    /// The phone's, like the saved-price-drop switch: whether this phone is woken for picks.
    static let settingKey = "alertsDailyPicks"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    static let morningHour = 9
    static let lastHour = 21
    private static let prefix = "picks-"

    /// The day an alert was scheduled, or the picks were seen, per profile.
    private static func doneKey(_ scope: ProfileScope) -> String { scope.key("shopPicksAnnounced") }

    private static func identifier(_ scope: ProfileScope) -> String {
        prefix + (scope.home?.uuidString ?? "default")
    }

    /// The picks are on screen: nothing to announce today.
    static func seen(on day: String, scope: ProfileScope) {
        UserDefaults.standard.set(day, forKey: doneKey(scope))
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(scope)])
    }

    /// Turned off: anything pending goes.
    static func withdrawAll() async {
        let centre = UNUserNotificationCenter.current()
        let ours = await centre.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        centre.removePendingNotificationRequests(withIdentifiers: ours)
    }

    /// The background pass's half: chooses today's set for the profile on screen, if nobody has
    /// seen or been told about it yet, and schedules the alert about it.
    static func backgroundPass(until deadline: Date) async {
        guard isEnabled, let session = BackgroundServices.profiles?.session else {
            log.debug("picks alert off")
            return
        }
        let scope = session.scope
        let now = Date()
        let day = DailyPicks.day(of: now)
        guard UserDefaults.standard.string(forKey: doneKey(scope)) != day,
              Calendar.current.component(.hour, from: now) < lastHour,
              now < deadline,
              await UNUserNotificationCenter.current().notificationSettings().authorizationStatus != .denied
        else {
            log.debug("picks alert not due: already said or seen today, too late, or alerts denied")
            return
        }

        guard let chosen = await TodaysPicks.choose(
            day: day,
            in: session.container.mainContext,
            profile: session.sizes.profile,
            statement: session.statement.statement
        ), !chosen.picks.isEmpty else {
            log.info("no picks to announce today")
            return
        }
        await announce(chosen.picks, day: day, scope: scope)
    }

    private static func announce(_ picks: [ShopPick], day: String, scope: ProfileScope) async {
        let calendar = Calendar.current
        let now = Date()
        guard let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: now) else { return }

        let trigger: UNNotificationTrigger = now < morning
            ? UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: morning),
                repeats: false
            )
            : UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)

        let content = UNMutableNotificationContent()
        content.title = "Today’s picks"
        content.body = scope.labelled(body(picks))
        content.sound = .default
        // One thread for the whole app — `PushGrouping`'s rule, which every local alert keeps.
        content.threadIdentifier = PushGrouping.threadID
        var info = ["tab": "shop"]
        if let id = scope.id { info["profileID"] = id.uuidString }
        content.userInfo = info

        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier(scope), content: content, trigger: trigger)
            )
            UserDefaults.standard.set(day, forKey: doneKey(scope))
            log.info("scheduled today's picks alert for \(picks.count) picks")
        } catch {
            log.error("could not schedule the picks alert: \(error.localizedDescription)")
        }
    }

    /// "3 picks for today: Nylon Chore Jacket, Pleated Trouser and Canvas Derby." — at most
    /// three named, and the rest counted.
    static func body(_ picks: [ShopPick]) -> String {
        let titles = picks.prefix(3).map(\.update.title)
        let rest = picks.count - titles.count
        let named: String
        if rest > 0 {
            named = titles.joined(separator: ", ") + " and \(rest) more"
        } else if titles.count > 1 {
            named = titles.dropLast().joined(separator: ", ") + " and " + titles[titles.count - 1]
        } else {
            named = titles.first ?? ""
        }
        let count = picks.count == 1 ? "1 pick for today" : "\(picks.count) picks for today"
        return "\(count): \(named)."
    }
}
