// DropCalendarView.swift
// What's coming, and how much of it is actually known.
//
// Nobody publishes a machine-readable release calendar, so this is careful about the
// difference between three very different kinds of claim, and labels each one:
//
// - **Locked** — the storefront is password-walled right now. Observed, and the strongest
//   signal there is: brands do this in the minutes before a release.
// - **Scheduled** — a product exists in the catalogue with a publication date in the
//   future. Rare, but it is the brand's own stated date.
// - **Expected** — derived from the brand's own history (`DropCadence`). A pattern, and
//   worded as one; a brand with no rhythm is left out rather than guessed at.
// - **Yours** — a date you entered, because you read it somewhere the app cannot. See
//   `PlannedDrop` for why this is a fourth kind rather than an improvement to the other
//   three: it is the only one that is not observed, so it is labelled as what it is and
//   never blended with a date the storefront stated.
//
// Inventing a *fifth* kind — scraped from someone else's hand-edited calendar — is what this
// deliberately does not do.
//
// This is also the one screen that schedules anything. Everything else the app announces has
// already happened; a release is the only thing worth being told about in advance, and
// `DropReminders` is what turns a row here into an alert on the day and at the minute.

import StreetwCore
import SwiftData
import SwiftUI

struct DropCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    /// Only to carry poll hints — see `rebuild()`. This page reads nothing from the server.
    @Environment(RemoteSync.self) private var remote
    /// What the server said about those hints, printed per row. See `DropHintStore`.
    @Environment(DropHintStore.self) private var hints
    @Query(filter: #Predicate<Brand> { $0.followed }, sort: \Brand.name) private var brands: [Brand]

    /// The drop being added or edited, and nil when neither.
    @State private var editing: PlannedDropEditor.Subject?

    /// Worked out after the sheet is on screen, not while it is opening.
    ///
    /// This was a computed property read twice per body — once for the empty check and once
    /// for the list — and each read walked **every followed brand's entire catalogue three
    /// separate times**: once for announced release dates, once for future publications, and
    /// once more to hand every publication date to `DropCadenceEstimator`, which then
    /// converts each one through `Calendar.dateComponents` and hashes it into a
    /// `Set<DateComponents>`. Twenty brands at 250 rows was ~30,000 row visits and ~10,000
    /// calendar conversions to open one sheet, all before the first frame.
    ///
    /// The three walks are one walk now, and the whole thing runs in a `.task` so the sheet
    /// presents immediately. The countdown rows redraw themselves — they use
    /// `Text(_:style:)`, which does not depend on this at all.
    @State private var entries: [Entry] = []
    @State private var hasBuilt = false

    private func build() -> [Entry] {
        var entries: [Entry] = []
        let now = Date()

        // **Fetched, not queried.** This whole page builds into `@State` once, from a
        // `.task`, so it can present before doing the work — and a `@Query` does not refresh
        // until the next view update, which is *after* the editor's save closure runs. So a
        // drop that had just been added would be missing from the list that rebuilt itself
        // to show it. A descriptor reads the context as it now stands.
        let planned = (try? context.fetch(
            FetchDescriptor<PlannedDrop>(sortBy: [SortDescriptor(\.releaseAt)])
        )) ?? []

        // Yours first in construction order; the sort below decides where they actually
        // land. A drop whose time has passed is dropped rather than kept as history — this
        // page is called Upcoming — but the row is left in the store, so nothing you typed
        // disappears without you deleting it.
        for drop in planned where drop.releaseAt > now {
            entries.append(Entry(brand: drop.brand, kind: .planned(drop), date: drop.releaseAt))
        }

        for brand in brands {
            // **One pass over the catalogue, collecting everything all three questions
            // wanted.** The relationship is faulted once instead of three times.
            var published: [Date] = []
            var announcedAhead: [Date] = []
            published.reserveCapacity(brand.updates.count)

            for update in brand.updates {
                published.append(update.publishedAt)
                if let announced = update.releaseDate {
                    if announced > now {
                        announcedAhead.append(announced)
                        entries.append(Entry(brand: brand, kind: .scheduled(update.title), date: announced))
                    }
                } else if update.publishedAt > now {
                    entries.append(Entry(brand: brand, kind: .scheduled(update.title), date: update.publishedAt))
                }
            }

            if brand.isLockedForDrop {
                // A locked storefront that also *names* a start time is the best entry
                // this calendar can hold: observed and exact.
                entries.append(Entry(brand: brand, kind: .locked, date: announcedAhead.min()))
            }

            if let cadence = DropCadenceEstimator.estimate(from: published),
               cadence.isReliable,
               let next = cadence.nextOccurrence() {
                entries.append(Entry(brand: brand, kind: .expected(cadence), date: next))
            }
        }

        // Locked first — it is the only one measured in minutes — then by date.
        return entries.sorted { a, b in
            if a.isLocked != b.isLocked { return a.isLocked }
            return (a.date ?? .distantFuture) < (b.date ?? .distantFuture)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                // `hasBuilt` rather than `entries.isEmpty`, or the sheet flashes "Nothing on
                // the horizon" for the frame before the pass has run.
                if !hasBuilt {
                    Color.paper
                } else if entries.isEmpty {
                    EditorialEmptyState(
                        title: "Nothing on the horizon",
                        action: brands.isEmpty
                            ? "ADD BRANDS AND THEIR RHYTHM APPEARS HERE"
                            : "NO BRAND YOU FOLLOW HAS A PATTERN CLEAR ENOUGH TO CALL YET — ADD A DATE YOURSELF WITH +"
                    )
                } else {
                    list
                }
            }
            .background(Color.paper)
            .task {
                entries = build()
                hasBuilt = true
            }
            .navigationTitle("Upcoming")
            .toolbarTitleDisplayMode(.inlineLarge)
            // This sheet has its own stack, so it needs its own registration — a
            // destination declared on the feed's stack is not visible from inside a
            // presented one. See `appDestinations`.
            .appDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a date", systemImage: "plus") { addDate(for: nil) }
                        .disabled(brands.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { subject in
                PlannedDropEditor(subject: subject, brands: brands) { rebuild() }
            }
        }
        .tint(.ink)
    }

    // MARK: - Dates you added

    /// Opened from a brand's own row, that brand is chosen; opened from "+", nothing is.
    ///
    /// It used to fall back to `brands.first`, which is alphabetical and therefore arbitrary
    /// — harmless while the picker was a closed menu that nobody read, and misleading now
    /// that the choice is drawn as a filled wordmark. An arbitrary brand asserted confidently
    /// is how a Stüssy drop gets filed under Kith. `Save` stays disabled until one is picked.
    private func addDate(for brand: Brand?) {
        editing = .new(brand)
    }

    private func delete(_ drop: PlannedDrop) {
        // Cancelled by identifier before the row goes, because `refresh` rebuilds from the
        // store and cannot see what is no longer in it. Belt and braces — `refresh` clears
        // everything this owns first — but a reminder about a drop somebody deleted is the
        // one failure that would make the whole feature untrustworthy.
        DropReminders.cancel(drop)
        context.delete(drop)
        try? context.save()
        rebuild()
    }

    /// Re-reads the list, re-schedules every reminder, and re-sends the poll hints. Called
    /// after any change to a planned drop, from one place so the three can never be done
    /// separately — a reminder without a hint fires on time about products that are not
    /// there yet, and a hint without a reminder polls hard while nobody is watching.
    private func rebuild() {
        entries = build()
        Task {
            await DropReminders.refresh(in: context)
            await DropHints.refresh(in: context, via: remote, status: hints)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Locked storefronts and stated dates are observed; patterns are read from each brand's own history. Know a date the app can't see? Add it with + and get a reminder on the day and at the drop.")
                    .font(.editorial(14))
                    .foregroundStyle(Color.muted)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                ForEach(entries) { entry in
                    // **Every row here names a brand, and naming one was all it did.**
                    //
                    // This page answers "who is about to drop"; the next question is
                    // always "what have they been doing", and there was no way to ask it
                    // — the wordmark was set at the top of every row and inert, so the
                    // only route to the brand was to dismiss the sheet and go looking for
                    // it in another tab. A locked storefront in particular is the app's
                    // strongest signal and the moment somebody most wants the page.
                    //
                    // A planned drop for a brand that has since been unfollowed has no page
                    // to open, so it is the one row drawn without a link rather than with a
                    // link that goes nowhere.
                    ZStack(alignment: .trailing) {
                        if let brand = entry.brand {
                            NavigationLink(value: BrandRoute(brand: brand)) {
                                row(entry)
                            }
                            .buttonStyle(.plain)
                        } else {
                            row(entry)
                        }

                        // Laid *over* the link rather than nested inside it, so the two hit
                        // areas cannot argue about a tap. It only appears where the trailing
                        // column is empty anyway — a locked storefront with no time on it —
                        // so it covers nothing.
                        if entry.wantsADate {
                            Button("Set a date") { addDate(for: entry.brand) }
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
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    /// Edit and delete for something you wrote; "add a date" for everything else, which is
    /// the discoverable route for a brand whose row is fine and simply has no time on it.
    @ViewBuilder
    private func menu(for entry: Entry) -> some View {
        if let drop = entry.plannedDrop {
            Button("Edit", systemImage: "pencil") { editing = .existing(drop) }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(drop) }
        } else {
            Button("Add a date", systemImage: "calendar.badge.plus") { addDate(for: entry.brand) }
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(name: entry.brandName, size: 14)
                Text(entry.headline)
                    .font(.editorial(14))
                    .foregroundStyle(Color.ink)
                DataLabel(text: entry.qualifier.uppercased(), size: 10, color: entry.isLocked ? .signal : .muted)
                watchLine(entry)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                if let when = entry.when {
                    DataLabel(text: when.uppercased(), size: 11, color: entry.isLocked ? .signal : .ink)
                }
                countdown(to: entry)
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
    /// Only on a date **you** entered. The other three kinds are observed, and the poller's
    /// behaviour around them is its own business: a locked storefront is already at sixty
    /// seconds and a read rhythm already opens its own window, neither of which anybody
    /// asked for or can change. Saying it on those rows would be the app narrating its
    /// plumbing on the page least able to afford the space.
    ///
    /// Silent for `.local`, which is standalone mode and the pre-registration moment. The
    /// row above already promises exactly what still happens there — a reminder — so a line
    /// saying "reminders only" would be repeating it in a more worrying voice.
    @ViewBuilder
    private func watchLine(_ entry: Entry) -> some View {
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
    /// done in your head before it means anything, and the whole value of this screen is
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
    private func countdown(to entry: Entry) -> some View {
        if let date = entry.date, date > Date() {
            let isImminent = date.timeIntervalSinceNow < 86_400
            Text(date, style: isImminent ? .timer : .relative)
                .font(.data(isImminent ? 13 : 10, isImminent ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isImminent ? Color.signal : Color.muted)
        }
    }

    // MARK: - Entries

    struct Entry: Identifiable {
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
        /// date helps most, and the one this page used to be silent about. The strongest
        /// signal in the app, arriving with no countdown attached.
        var wantsADate: Bool { isLocked && date == nil }

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
    }
}
