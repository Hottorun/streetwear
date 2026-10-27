// UpcomingDrops.swift
// What's coming, and how much of it is actually known — shared by the feed's Upcoming filter,
// the line above the feed, and the full drop calendar.
//
// Nobody publishes a machine-readable release calendar, so this is careful about the
// difference between very different kinds of claim, and labels each one:
//
// - **Locked** — the storefront is password-walled right now. Observed, and the strongest
//   signal there is: brands do this in the minutes before a release.
// - **Scheduled** — a product exists in the catalogue with a publication date in the
//   future. Rare, but it is the brand's own stated date.
// - **Expected** — derived from the brand's own history (`DropCadence`). A pattern, and
//   worded as one; a brand with no rhythm is left out rather than guessed at. **Only on the
//   calendar**, never in the feed: the feed is about what is known to be happening, and a
//   rhythm is a guess — and reading one walks every followed brand's whole catalogue, which
//   is a cost for a sheet somebody opened and not for a screen that redraws on every sync.
// - **Yours** — a date you entered, because you read it somewhere the app cannot. See
//   `PlannedDrop` for why this is a fourth kind rather than an improvement to the other
//   three: it is the only one that is not observed, so it is labelled as what it is and
//   never blended with a date the storefront stated.
//
// Inventing a *fifth* kind — scraped from someone else's hand-edited calendar — is what this
// deliberately does not do.

import StreetwCore
import SwiftData
import SwiftUI

/// One thing coming.
struct UpcomingDrop: Identifiable {
    enum Kind {
        case locked
        case scheduled(String)
        case expected(DropCadence)
        /// A date somebody entered by hand. See `PlannedDrop`.
        case planned(PlannedDrop)
    }

    /// Optional, because a planned drop outlives the brand being unfollowed — the row
    /// keeps the name it was written with and simply stops being a link.
    var brand: Brand?
    var kind: Kind
    var date: Date?

    var id: String {
        switch kind {
        case .locked: "locked-\(brand?.id.uuidString ?? "?")"
        case .scheduled(let title): "scheduled-\(brand?.id.uuidString ?? "?")-\(title)"
        case .expected: "expected-\(brand?.id.uuidString ?? "?")"
        case .planned(let drop): "planned-\(drop.id)"
        }
    }

    var isLocked: Bool { if case .locked = kind { true } else { false } }

    var plannedDrop: PlannedDrop? {
        if case .planned(let drop) = kind { drop } else { nil }
    }

    /// Whose drop this is, whether or not the brand is still followed.
    var brandName: String {
        if let brand { return brand.name }
        if case .planned(let drop) = kind, !drop.brandName.isEmpty { return drop.brandName }
        return "Unknown"
    }

    /// A locked storefront the app cannot put a time on — the single case a hand-entered
    /// date helps most, and the one the calendar used to be silent about. The strongest
    /// signal in the app, arriving with no countdown attached.
    var wantsADate: Bool { isLocked && date == nil }

    /// Close enough to spend the accent on: locked now, or under a day away — the point at
    /// which the countdown starts counting seconds, for the same reason.
    func isImminent(now: Date = Date()) -> Bool {
        if isLocked { return true }
        guard let date else { return false }
        return date > now && date.timeIntervalSince(now) < 86_400
    }

    var headline: String {
        switch kind {
        case .locked: "Storefront locked"
        case .scheduled(let title): title
        case .expected(let cadence): "Usually \(cadence.weekdayName)s"
        case .planned(let drop): drop.label
        }
    }

    /// Says how much this is worth trusting, in plain words rather than a number.
    var qualifier: String {
        switch kind {
        case .locked:
            "Happening now"
        case .scheduled:
            "Date set by the brand"
        case .expected(let cadence):
            "Pattern · \(Int(cadence.confidence * 100))% of \(cadence.sampleSize) recent drops"
        case .planned(let drop):
            // Named as yours, and it says whether it will actually reach you. A reminder
            // silently not scheduled is the worst outcome here: you would find out by
            // missing the drop.
            drop.remindsAtRelease || drop.remindsOnTheDay
                ? "Added by you · reminder set"
                : "Added by you · no reminder"
        }
    }

    var when: String? {
        switch kind {
        case .locked:
            guard let date else { return "NOW" }
            return Self.dayAndTime.string(from: date)
        case .scheduled, .planned:
            guard let date else { return nil }
            return Self.dayAndTime.string(from: date)
        case .expected(let cadence):
            guard let date else { return nil }
            return "\(Self.day.string(from: date)) · \(String(format: "%02d:00", cadence.hour))"
        }
    }

    /// "TUESDAY 10:00", "TOMORROW 18:00", "LOCKED NOW" — how the line above the feed says
    /// when, which is the one question it is there to answer at a glance.
    func soon(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "LOCKED NOW" }
        let time = Self.time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "TOMORROW \(time)"
        }
        return "\(Self.weekday.string(from: date).uppercased()) \(time)"
    }

    /// Built once. A `DateFormatter` is expensive to construct — it resolves a locale
    /// and compiles a format — and this made a fresh one **per row, per render**, three
    /// call sites deep in a list that redraws as its countdowns tick.
    private static let dayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM · HH:mm"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()
}

@MainActor
enum UpcomingDrops {
    /// How far ahead a date earns the line above the feed. Two days: far enough that a
    /// Thursday drop is in sight on Tuesday evening, near enough that the line means "soon".
    static let lineHorizon: TimeInterval = 48 * 3600

    /// The rows that could be dated ahead, narrowed by the store. A superset — a release
    /// date can be in the past — so `build` checks the date.
    nonisolated static func scheduledFilter(now: Date) -> Predicate<BrandUpdate> {
        #Predicate<BrandUpdate> { $0.publishedAt > now || $0.releaseDate != nil }
    }

    /// Everything ahead, locked first — it is the only one measured in minutes — then by date.
    ///
    /// - Parameters:
    ///   - scheduled: rows that may carry a date ahead (`scheduledFilter`).
    ///   - patterns: each brand's rhythm, where the caller read one. The feed passes none.
    static func build(
        planned: [PlannedDrop],
        brands: [Brand],
        scheduled: [BrandUpdate],
        patterns: [UUID: DropCadence] = [:],
        now: Date = Date()
    ) -> [UpcomingDrop] {
        var entries: [UpcomingDrop] = []

        // A drop whose time has passed is dropped rather than kept as history — this is
        // about what is coming — but the row is left in the store, so nothing you typed
        // disappears without you deleting it.
        for drop in planned where drop.releaseAt > now {
            entries.append(UpcomingDrop(brand: drop.brand, kind: .planned(drop), date: drop.releaseAt))
        }

        // A brand whose mode keeps its drops out of the feed keeps them out of here too — it
        // is the feed's view of the future, not the brand's. A date somebody typed is above
        // and stays whatever the mode, because they asked for it by name.
        // And a product dated ahead that the follow's filter keeps out is not announced either.
        let admitted = Set(brands.filter { $0.followMode.admits(.product) }.map(\.id))
        var filters: [UUID: FollowFilter.Matcher] = [:]

        var announced: [UUID: [Date]] = [:]
        for update in scheduled {
            guard let brand = update.brand, admitted.contains(brand.id) else { continue }
            let filter = filters[brand.id] ?? brand.followFilterMatcher
            filters[brand.id] = filter
            guard filter.admits(update.kind, update.followItem) else { continue }
            if let release = update.releaseDate {
                guard release > now else { continue }
                announced[brand.id, default: []].append(release)
                entries.append(UpcomingDrop(brand: brand, kind: .scheduled(update.title), date: release))
            } else if update.publishedAt > now {
                entries.append(UpcomingDrop(brand: brand, kind: .scheduled(update.title), date: update.publishedAt))
            }
        }

        for brand in brands where admitted.contains(brand.id) {
            if brand.isAnnouncingLock {
                // A locked storefront that also *names* a start time is the best entry this
                // can hold: observed and exact.
                entries.append(UpcomingDrop(brand: brand, kind: .locked, date: announced[brand.id]?.min()))
            }
            if let cadence = patterns[brand.id], let next = cadence.nextOccurrence(after: now) {
                entries.append(UpcomingDrop(brand: brand, kind: .expected(cadence), date: next))
            }
        }

        return entries.sorted { a, b in
            if a.isLocked != b.isLocked { return a.isLocked }
            return (a.date ?? .distantFuture) < (b.date ?? .distantFuture)
        }
    }

    /// The one the line above the feed names: the soonest that is locked or inside
    /// `lineHorizon`. `entries` is already in that order.
    static func next(in entries: [UpcomingDrop], now: Date = Date()) -> UpcomingDrop? {
        entries.first { entry in
            if entry.isLocked { return true }
            guard let date = entry.date else { return false }
            return date > now && date.timeIntervalSince(now) <= lineHorizon
        }
    }

    /// Re-schedules every reminder and re-sends the poll hints, after any change to a
    /// planned drop — from one place so the two can never be done separately: a reminder
    /// without a hint fires on time about products that are not there yet, and a hint
    /// without a reminder polls hard while nobody is watching.
    static func rescheduleAlerts(in context: ModelContext, via remote: RemoteSync, hints: DropHintStore) {
        Task {
            await DropReminders.refresh(in: context)
            await DropHints.refresh(in: context, via: remote, status: hints)
        }
    }

    /// Deletes a date somebody wrote down, and the reminders it scheduled.
    ///
    /// Cancelled by identifier before the row goes, because `DropReminders.refresh` rebuilds
    /// from the store and cannot see what is no longer in it. Belt and braces — `refresh`
    /// clears everything it owns first — but a reminder about a drop somebody deleted is the
    /// one failure that would make the whole feature untrustworthy.
    static func delete(_ drop: PlannedDrop, in context: ModelContext, via remote: RemoteSync, hints: DropHintStore) {
        DropReminders.cancel(drop)
        context.delete(drop)
        try? context.save()
        rescheduleAlerts(in: context, via: remote, hints: hints)
    }
}

/// The rows of what is coming, each opening its brand. Drawn by the drop calendar and by the
/// feed's Upcoming filter, inside whatever scroll view the host has.
struct UpcomingDropList: View {
    let entries: [UpcomingDrop]
    /// A date for this brand, or for none when the brand is nil.
    var addDate: (Brand?) -> Void
    var edit: (PlannedDrop) -> Void
    var delete: (PlannedDrop) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                // **Every row here names a brand, and naming one was all it did.**
                //
                // This answers "who is about to drop"; the next question is always "what
                // have they been doing", and there was no way to ask it — the wordmark was
                // set at the top of every row and inert. A locked storefront in particular is
                // the app's strongest signal and the moment somebody most wants the page.
                //
                // A planned drop for a brand that has since been unfollowed has no page to
                // open, so it is the one row drawn without a link rather than with a link
                // that goes nowhere.
                ZStack(alignment: .trailing) {
                    if let brand = entry.brand {
                        NavigationLink(value: BrandRoute(brand: brand)) {
                            UpcomingDropRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    } else {
                        UpcomingDropRow(entry: entry)
                    }

                    // Laid *over* the link rather than nested inside it, so the two hit
                    // areas cannot argue about a tap. It only appears where the trailing
                    // column is empty anyway — a locked storefront with no time on it —
                    // so it covers nothing.
                    if entry.wantsADate {
                        Button("Set a date") { addDate(entry.brand) }
                            .font(.data(11, .semibold))
                            .foregroundStyle(Color.signal)
                            .buttonStyle(.borderless)
                            .padding(.trailing, 20)
                    }
                }
                .contextMenu { menu(for: entry) }
                Rule().padding(.horizontal, 20)
            }
        }
    }

    /// Edit and delete for something you wrote; "add a date" for everything else, which is
    /// the discoverable route for a brand whose row is fine and simply has no time on it.
    @ViewBuilder
    private func menu(for entry: UpcomingDrop) -> some View {
        if let drop = entry.plannedDrop {
            Button("Edit", systemImage: "pencil") { edit(drop) }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(drop) }
        } else {
            Button("Add a date", systemImage: "calendar.badge.plus") { addDate(entry.brand) }
        }
    }
}

/// One thing coming: who, what, how far it can be trusted, and how long until it.
struct UpcomingDropRow: View {
    /// What the server said about poll hints, printed on the rows somebody typed.
    @Environment(DropHintStore.self) private var hints

    let entry: UpcomingDrop

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(name: entry.brandName, size: 14)
                Text(entry.headline)
                    .font(.editorial(14))
                    .foregroundStyle(Color.ink)
                DataLabel(text: entry.qualifier.uppercased(), size: 10, color: entry.isLocked ? .signal : .muted)
                watchLine
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                if let when = entry.when {
                    DataLabel(text: when.uppercased(), size: 11, color: entry.isLocked ? .signal : .ink)
                }
                countdown
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // The whole row is the target, gaps included — a link whose hit area is only the
        // glyphs reads as unreliable rather than as a miss.
        .contentShape(.rect)
    }

    /// Whether the server is going to be looking, on the one row where that is in doubt.
    ///
    /// **The reason this line exists.** A poll hint is invisible whether it works or not:
    /// the row says "added by you" either way, the reminders fire either way, and the only
    /// observable difference is whether the products are actually there when the alert
    /// arrives at eleven. That is the shape of failure this project keeps a list of — every
    /// layer reports healthy and the feature does not exist — so the answer is printed.
    ///
    /// Only on a date **you** entered. The other kinds are observed, and the poller's
    /// behaviour around them is its own business: a locked storefront is already at sixty
    /// seconds and a read rhythm already opens its own window, neither of which anybody
    /// asked for or can change. Saying it on those rows would be the app narrating its
    /// plumbing on the page least able to afford the space.
    ///
    /// Silent for `.local`, which is standalone mode and the pre-registration moment. The
    /// row above already promises exactly what still happens there — a reminder — so a line
    /// saying "reminders only" would be repeating it in a more worrying voice.
    @ViewBuilder
    private var watchLine: some View {
        if let drop = entry.plannedDrop {
            let state = hints.state(brandID: drop.brand?.remoteID, releaseAt: drop.releaseAt)
            if let label = state.label {
                DataLabel(
                    text: label.uppercased(),
                    size: 10,
                    color: state.isWarning ? .signal : .muted
                )
            }
        }
    }

    /// How long until it, ticking.
    ///
    /// A date is a fact and a countdown is a *prompt* — "11 Feb · 11:00" needs arithmetic
    /// done in your head before it means anything, and the whole value of this list is
    /// knowing whether to be somewhere in nine minutes or nine days. Streetwear is decided
    /// in the first minute of a release, so the page that lists releases has to say how far
    /// away one is without being read carefully.
    ///
    /// `Text(_:style:)` re-renders itself, so there is no timer here and nothing to
    /// invalidate — SwiftUI drives it. Below a day it counts in hours, minutes and seconds
    /// and takes the accent, because that is when it is worth acting on; above a day it is
    /// "in 3 days" in the quiet voice, because a second-by-second count of something four
    /// days out is a distraction pretending to be information.
    @ViewBuilder
    private var countdown: some View {
        if let date = entry.date, date > Date() {
            let isImminent = date.timeIntervalSinceNow < 86_400
            Text(date, style: isImminent ? .timer : .relative)
                .font(.data(isImminent ? 13 : 10, isImminent ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isImminent ? Color.signal : Color.muted)
        }
    }
}

/// **The one line above the feed about the future.** "● TUESDAY 10:00 · ONDO CLUB · Summer
/// capsule", in vermilion when it is imminent.
///
/// Not a card. The prototype pinned upcoming drops as cards at the head of the feed, and a
/// grey tile with a calendar glyph is the largest object on the screen saying the least: a
/// date is one line of information, and it pushed the first photograph below the fold. One
/// line, the soonest thing inside two days, and the full list one tap away under Upcoming.
struct UpcomingLine: View {
    let entry: UpcomingDrop
    let open: () -> Void

    var body: some View {
        let isImminent = entry.isImminent()
        let colour = isImminent ? Color.signal : Color.ink

        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(isImminent ? Color.signal : Color.muted)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                Text("\(entry.soon()) · \(entry.brandName.uppercased())")
                    .font(.data(10.5, .medium))
                    .tracking(0.5)
                    .foregroundStyle(colour)
                    .fixedSize()
                Text("· \(entry.isLocked ? "Drop imminent" : entry.headline)")
                    .font(.editorial(14))
                    .foregroundStyle(colour)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
        .accessibilityLabel("Coming up: \(entry.brandName), \(entry.headline), \(entry.soon())")
        .accessibilityHint("Shows everything coming up")
    }
}
