// PlannedDropEditor.swift
// Writing down a release the app has no way to observe.
//
// Four things, and no more. Which brand, when, what it is called, and whether to be told.
// A form here would be the same mistake `FitCanvas` was built to undo — this is somebody
// copying a date off an Instagram story while they still remember it, and every extra field
// is a reason to close the sheet instead.
//
// The one thing it insists on is the **time**, not just the day. "Stüssy, Friday" is a
// diary entry; "Stüssy, Friday, 11:00" is something the app can act on, and acting on it —
// an alert at the minute the thing opens — is the entire reason for typing it in.

import StreetwCore
import SwiftData
import SwiftUI
import UserNotifications

struct PlannedDropEditor: View {
    /// What the sheet was opened for. An enum rather than an optional `PlannedDrop` so
    /// "adding one for Palace" and "editing this one" are distinguishable — the first
    /// carries a brand to preselect and no row to write back to.
    enum Subject: Identifiable {
        case new(Brand?)
        case existing(PlannedDrop)

        var id: String {
            switch self {
            case .new(let brand): "new-\(brand?.id.uuidString ?? "none")"
            case .existing(let drop): "edit-\(drop.id)"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    /// Only to know whether there is a server to tell about this date — see `canHint`.
    @Environment(ServerSettings.self) private var settings

    let subject: Subject
    let brands: [Brand]
    /// Run after the store has been written, so the calendar can rebuild and reschedule.
    var onChange: () -> Void

    @State private var brand: Brand?
    @State private var title = ""
    @State private var releaseAt = Date()
    @State private var note = ""
    @State private var remindsOnTheDay = true
    @State private var remindsAtRelease = true
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var hasLoaded = false

    private var isEditing: Bool {
        if case .existing = subject { return true }
        return false
    }

    /// A reminder can only be *asked* for; whether it arrives is the system's call. The
    /// sheet says so rather than accepting the toggle and going quiet.
    private var canNotify: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    private var wantsAReminder: Bool { remindsOnTheDay || remindsAtRelease }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    brandSection
                    Rule()
                    whenSection
                    Rule()
                    remindSection
                    Rule()
                    detailSection
                    if isEditing { deleteButton }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle(isEditing ? "Edit drop" : "Add a drop")
            // **`.inline`, not `.inlineLarge`, and that is not a style choice.** A large
            // title occupies the leading slot, and iOS 26 responds by folding the leading
            // button into a "···" overflow menu — so this shipped, briefly, with an ellipsis
            // whose entire contents was one item called Cancel. The same trap `AddBrandView`
            // hit from the other direction, with a search field taking the slot instead.
            //
            // Every other sheet in the app keeps `.inlineLarge` because it has one trailing
            // action and nothing to displace. This one has two, which is exactly why
            // `FitCanvas` — the other editor — is inline as well.
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .font(.data(13, .semibold))
                        .disabled(brand == nil)
                }
            }
            .task {
                // Loaded once. `.task` fires per appearance, and re-running this would
                // discard whatever had been typed if the sheet ever re-appeared.
                if !hasLoaded { load() }
                hasLoaded = true
                authorization = await PushAuthorization.current()
            }
        }
        .tint(.ink)
    }

    // MARK: - Sections

    /// Who is dropping, as the wordmarks themselves rather than as a dropdown.
    ///
    /// This was a `Menu`, and a menu is the wrong control for this question in three ways.
    /// It hides every option behind a tap, so choosing costs two taps instead of one and you
    /// cannot see what is on offer until you commit to looking. It renders each brand as
    /// plain system text, on a screen where a brand is a **wordmark** everywhere else — the
    /// feed, the brands list, the row this very sheet is about to produce — so the one place
    /// you pick a brand was the one place it did not look like one. And a preselected value
    /// sitting in a closed menu reads as a field already filled in rather than as a choice,
    /// which is exactly how somebody ends up filing a Stüssy drop under Kith.
    ///
    /// A wrapped row of marks answers all three: everything visible, one tap, and each
    /// option drawn the way that brand is drawn everywhere else. `FlowRow` rather than a
    /// horizontal scroller for the same reason `StyleView`'s facets use it — an option you
    /// have to scroll sideways to discover is an option most people never see.
    private var brandSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "WHO", size: 9)

            // Only brands that are followed. The row this produces navigates to a brand
            // page, and offering a name with no page behind it would be offering a dead end
            // — adding the brand is the route, and it is one tab away.
            FlowRow(spacing: 10) {
                ForEach(brands) { candidate in
                    Button {
                        brand = candidate
                    } label: {
                        let isOn = brand?.id == candidate.id
                        Wordmark(name: candidate.name, size: 12, color: isOn ? .paper : .ink)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background {
                                // Filled when chosen rather than merely underlined: this is
                                // the one required field on the sheet, and "which of these
                                // is selected" has to be answerable from across the room.
                                if isOn {
                                    Rectangle().fill(Color.ink)
                                } else {
                                    Rectangle().stroke(Color.hairline, lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.borderless)
                }
            }

            if brands.count > 1 {
                Text("Tap whoever is dropping.")
                    .font(.editorial(13))
                    .foregroundStyle(Color.muted)
            }
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "WHEN", size: 9)
            DatePicker(
                "Release",
                selection: $releaseAt,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.compact)

            Text("The time matters as much as the day — a release is decided in its first minute.")
                .font(.editorial(13))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remindSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DataLabel(text: "REMIND ME", size: 9)

            Toggle(isOn: $remindsOnTheDay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On the day").font(.editorial(15)).foregroundStyle(Color.ink)
                    Text("At \(PlannedDrop.morningHour):00, so you can plan around it")
                        .font(.editorial(12)).foregroundStyle(Color.muted)
                }
            }
            Toggle(isOn: $remindsAtRelease) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("At the drop").font(.editorial(15)).foregroundStyle(Color.ink)
                    Text("The moment it opens")
                        .font(.editorial(12)).foregroundStyle(Color.muted)
                }
            }

            // **A toggle that cannot do anything must say so.** Accepting these while
            // notifications are off would be the app promising an alert it has no way to
            // deliver, and the way you would find out is by missing the drop.
            if wantsAReminder && !canNotify {
                VStack(alignment: .leading, spacing: 8) {
                    Text(authorization == .denied
                        ? "Notifications are off for Dropwall, so these reminders can't reach you. Turn them on in iOS Settings."
                        : "Dropwall needs permission to send you these.")
                        .font(.editorial(13))
                        .foregroundStyle(Color.signal)
                        .fixedSize(horizontal: false, vertical: true)

                    if authorization != .denied {
                        Button("Allow notifications") {
                            Task {
                                await PushAuthorization.request()
                                authorization = await PushAuthorization.current()
                            }
                        }
                        .font(.data(12, .semibold))
                        .buttonStyle(.borderless)
                    }
                }
            }

            // **What the date buys besides an alarm**, said once, where the date is being
            // typed. A reminder firing at eleven is only half of it — the products still
            // have to have been *found* by eleven, and the poller's ordinary cadence is
            // twenty minutes. Nobody would guess that writing a time down changes that, and
            // an invisible benefit is one nobody trusts.
            //
            // Only where it is true. Standalone has no server to tell, and a brand with no
            // `remoteID` is one the server has never heard of — claiming it either way would
            // be the promise this whole screen is careful not to make.
            if canHint {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Rule().frame(width: 14)
                    Text("Dropwall will also watch \(brand?.name ?? "the brand")'s storefront every minute around this time, so the drop is in your feed when the alert arrives.")
                        .font(.editorial(12))
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    /// Whether the server can be told about this date at all — see `DropHints`.
    private var canHint: Bool {
        settings.isConfigured && brand?.remoteID != nil
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "WHAT (OPTIONAL)", size: 9)
            TextField("FW26 week 4", text: $title)
                .font(.editorial(17))
                .textFieldStyle(.plain)
            Rule()
            TextField("Where you heard it", text: $note, axis: .vertical)
                .font(.editorial(14))
                .foregroundStyle(Color.muted)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
        }
    }

    private var deleteButton: some View {
        Button("Delete this drop", systemImage: "trash", role: .destructive) {
            if case .existing(let drop) = subject {
                DropReminders.cancel(drop)
                context.delete(drop)
                try? context.save()
                onChange()
            }
            dismiss()
        }
        .font(.data(13, .semibold))
        .buttonStyle(.borderless)
        .padding(.top, 8)
    }

    // MARK: - Persistence

    private func load() {
        switch subject {
        case .new(let preselected):
            brand = preselected
            // The next round hour that has not happened yet, rather than "now" — which as a
            // release time is always wrong and always needs editing.
            releaseAt = Self.nextHour()
        case .existing(let drop):
            brand = drop.brand
            title = drop.title
            releaseAt = drop.releaseAt
            note = drop.note ?? ""
            remindsOnTheDay = drop.remindsOnTheDay
            remindsAtRelease = drop.remindsAtRelease
        }
    }

    private func save() {
        guard let brand else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        let drop: PlannedDrop
        switch subject {
        case .existing(let existing): drop = existing
        case .new:
            drop = PlannedDrop(brand: brand, releaseAt: releaseAt)
            context.insert(drop)
        }

        drop.brand = brand
        // Re-copied on every save, so renaming a brand — or fixing one the storefront had
        // wrong — reaches a reminder that was scheduled months ago. See `PlannedDrop`.
        drop.brandName = brand.name
        drop.title = trimmedTitle
        drop.releaseAt = releaseAt
        drop.note = trimmedNote.isEmpty ? nil : trimmedNote
        drop.remindsOnTheDay = remindsOnTheDay
        drop.remindsAtRelease = remindsAtRelease

        try? context.save()
        onChange()
        dismiss()
    }

    private static func nextHour() -> Date {
        let calendar = Calendar.current
        let hour = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return calendar.date(
            bySetting: .minute, value: 0, of: hour
        ) ?? hour
    }
}
