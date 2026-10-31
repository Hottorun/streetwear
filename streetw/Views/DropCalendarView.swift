// DropCalendarView.swift
// What's coming, and how much of it is actually known.
//
// The four kinds of claim and how each is labelled are `UpcomingDrop`'s; the feed's
// Upcoming filter draws the same rows. This page is the whole calendar — the one place a
// brand's *rhythm* is read, because reading it walks every followed brand's catalogue and is
// a cost for a sheet somebody opened rather than for a screen that redraws on every sync.
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
    /// Dates ahead are one narrow fetch now and the rhythm one walk, and the whole thing runs
    /// in a `.task` so the sheet presents immediately. The countdown rows redraw themselves —
    /// they use `Text(_:style:)`, which does not depend on this at all.
    @State private var entries: [UpcomingDrop] = []
    @State private var hasBuilt = false

    private func build() -> [UpcomingDrop] {
        let now = Date()

        // **Fetched, not queried.** This whole page builds into `@State` once, from a
        // `.task`, so it can present before doing the work — and a `@Query` does not refresh
        // until the next view update, which is *after* the editor's save closure runs. So a
        // drop that had just been added would be missing from the list that rebuilt itself
        // to show it. A descriptor reads the context as it now stands.
        let planned = (try? context.fetch(
            FetchDescriptor<PlannedDrop>(sortBy: [SortDescriptor(\.releaseAt)])
        )) ?? []
        let scheduled = (try? context.fetch(
            FetchDescriptor<BrandUpdate>(predicate: UpcomingDrops.scheduledFilter(now: now))
        )) ?? []

        // The rhythms, which only this page reads: one pass over each catalogue, handing
        // every publication date to `DropCadenceEstimator`.
        var patterns: [UUID: DropCadence] = [:]
        for brand in brands where brand.followMode.admits(.product) {
            if let cadence = DropCadenceEstimator.estimate(from: brand.updates.map(\.publishedAt)),
               cadence.isReliable {
                patterns[brand.id] = cadence
            }
        }

        return UpcomingDrops.build(planned: planned, brands: brands, scheduled: scheduled, patterns: patterns, now: now)
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
                            ? "Follow a brand to see its rhythm."
                            : "Nothing to call yet. Add a date with +."
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
            .navigationTitle("Drop calendar")
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

    /// Re-reads the list, re-schedules every reminder, and re-sends the poll hints. Called
    /// after any change to a planned drop.
    static let info = InfoNote(
        title: "Where the dates come from",
        lines: [
            "A locked storefront and a date a brand states are seen, not guessed.",
            "A pattern is read from the brand's own history, and says how sure it is.",
            "A date you add is marked as yours, with a reminder on the day and at the drop."
        ]
    )

    private func rebuild() {
        entries = build()
        UpcomingDrops.rescheduleAlerts(in: context, via: remote, hints: hints)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Where each date comes from is on its own row; how the kinds differ is a tap away.
                HStack(spacing: 2) {
                    NoteLine(text: "Know a date Dropwall can't see? Add it with +.")
                    InfoButton(note: Self.info)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                UpcomingDropList(
                    entries: entries,
                    addDate: addDate(for:),
                    edit: { editing = .existing($0) },
                    delete: { drop in
                        UpcomingDrops.delete(drop, in: context, via: remote, hints: hints)
                        entries = build()
                    }
                )
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }
}
