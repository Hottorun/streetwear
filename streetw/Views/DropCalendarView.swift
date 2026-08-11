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
//
// Inventing a fourth kind — scraped from someone else's hand-edited calendar — is what
// this deliberately does not do.

import StreetwCore
import SwiftData
import SwiftUI

struct DropCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Brand> { $0.followed }, sort: \Brand.name) private var brands: [Brand]

    private var entries: [Entry] {
        var entries: [Entry] = []

        for brand in brands {
            if brand.isLockedForDrop {
                // A locked storefront that also *names* a start time is the best entry
                // this calendar can hold: observed and exact.
                let announced = brand.updates
                    .compactMap(\.releaseDate)
                    .filter { $0 > Date() }
                    .min()
                entries.append(Entry(brand: brand, kind: .locked, date: announced))
            }

            // A date the brand stated itself, either as an announced release time or as
            // a product published into the future.
            for update in brand.updates {
                if let announced = update.releaseDate, announced > Date() {
                    entries.append(Entry(brand: brand, kind: .scheduled(update.title), date: announced))
                } else if update.publishedAt > Date() {
                    entries.append(Entry(brand: brand, kind: .scheduled(update.title), date: update.publishedAt))
                }
            }

            if let cadence = DropCadenceEstimator.estimate(from: brand.updates.map(\.publishedAt)),
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
                if entries.isEmpty {
                    EditorialEmptyState(
                        title: "Nothing on the horizon",
                        action: brands.isEmpty
                            ? "ADD BRANDS AND THEIR RHYTHM APPEARS HERE"
                            : "NO BRAND YOU FOLLOW HAS A PATTERN CLEAR ENOUGH TO CALL YET"
                    )
                } else {
                    list
                }
            }
            .background(Color.paper)
            .navigationTitle("Upcoming")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.ink)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Locked storefronts and stated dates are observed. Everything else is a pattern read from each brand's own history.")
                    .font(.editorial(14))
                    .foregroundStyle(Color.muted)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                ForEach(entries) { entry in
                    row(entry)
                    Rule().padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(name: entry.brand.name, size: 14)
                Text(entry.headline)
                    .font(.editorial(14))
                    .foregroundStyle(Color.ink)
                DataLabel(text: entry.qualifier.uppercased(), size: 10, color: entry.isLocked ? .signal : .muted)
            }
            Spacer(minLength: 8)
            if let when = entry.when {
                DataLabel(text: when.uppercased(), size: 11, color: entry.isLocked ? .signal : .ink)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Entries

    struct Entry: Identifiable {
        enum Kind {
            case locked
            case scheduled(String)
            case expected(DropCadence)
        }

        var brand: Brand
        var kind: Kind
        var date: Date?

        var id: String {
            switch kind {
            case .locked: "locked-\(brand.id)"
            case .scheduled(let title): "scheduled-\(brand.id)-\(title)"
            case .expected: "expected-\(brand.id)"
            }
        }

        var isLocked: Bool { if case .locked = kind { true } else { false } }

        var headline: String {
            switch kind {
            case .locked: "Storefront locked"
            case .scheduled(let title): title
            case .expected(let cadence): "Usually \(cadence.weekdayName)s"
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
            }
        }

        var when: String? {
            switch kind {
            case .locked:
                guard let date else { return "NOW" }
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMM · HH:mm"
                return formatter.string(from: date)
            case .scheduled:
                guard let date else { return nil }
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMM · HH:mm"
                return formatter.string(from: date)
            case .expected(let cadence):
                guard let date else { return nil }
                let formatter = DateFormatter()
                formatter.dateFormat = "d MMM"
                return "\(formatter.string(from: date)) · \(String(format: "%02d:00", cadence.hour))"
            }
        }
    }
}
