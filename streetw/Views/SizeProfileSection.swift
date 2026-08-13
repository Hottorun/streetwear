// SizeProfileSection.swift
// Who you are, as far as the feed is concerned: what you wear and what you want shown.
//
// Both halves are the same kind of statement — "narrow this to me" — so they live in one
// section rather than being split between a sizes screen and a filters screen. They also
// travel together: `SizePayload` carries both to the server, which needs them to decide
// whether a drop is worth waking someone for.
//
// Set as type, not as a form. This was the last screen in the app built out of grouped
// `List` sections, system chips and a `.segmented` picker — so the one place you go to
// tell the app about yourself fell out of the app into Settings.app for a moment. It
// composes `Color.paper`, `.editorial()`, `DataLabel` and `Rule()` like every other
// screen now, and the chips are rectangles rather than capsules because nothing else here
// is a capsule.

import StreetwCore
import SwiftUI

struct SizeProfileSection: View {
    @Environment(SizeProfileStore.self) private var store: SizeProfileStore
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            sizes
            Rule()
            gender
        }
        .onChange(of: store.profile) { _, profile in pushIfNeeded(profile) }
    }

    // MARK: - The three ladders

    private var sizes: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsHeader(
                title: "My sizes",
                note: store.profile.isEmpty
                    ? "Set these and streetw can tell you when something is back in a size you actually wear."
                    : "Restocks in \(store.profile.summary) are ruled in vermilion in your feed."
            )

            SizeChipRow(
                title: "Clothing",
                options: SizeProfile.apparelOptions.map { (display: $0, stored: $0) },
                isSelected: { store.profile.apparel.contains($0) },
                toggle: store.toggleApparel
            )

            // Bottoms are sized by the inch and this ladder did not exist, so every pair
            // of trousers in the app normalised to "unrecognised" — never hidden, and
            // never matched either. On denim and workwear, which is half of what these
            // brands make, the whole size feature was switched off.
            SizeChipRow(
                title: "Waist",
                options: SizeProfile.waistOptions.map { (display: $0, stored: $0) },
                isSelected: { store.profile.waist.contains($0) },
                toggle: store.toggleWaist
            )

            SizeChipRow(
                title: "Shoes",
                options: SizeProfile.shoeOptions(in: store.profile.shoeScale),
                isSelected: { store.profile.shoe.contains($0) },
                toggle: store.toggleShoe,
                // The scale sits on the row it applies to rather than in a separate
                // setting, because "US 9" and "EU 43" are the same shoe and the picker is
                // meaningless without knowing which you're reading.
                accessory: {
                    AnyView(
                        WordPicker(
                            options: SizeScale.allCases.map { ($0.label, $0) },
                            selection: store.profile.shoeScale,
                            select: store.setShoeScale
                        )
                    )
                }
            )
        }
    }

    // MARK: - Who the feed is cut for

    private var gender: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "What to show",
                // Says exactly what it will and won't do. The honesty matters: plenty of
                // brands tag nothing useful, and someone who picks "Menswear" and still
                // sees the occasional women's piece should know that's the filter being
                // careful rather than broken.
                note: store.profile.gender == .everything
                    ? "Everything a brand posts, whoever it's cut for — including kids."
                    : "Hides the opposite gender and kids. Unisex items, and anything a brand doesn't label, are always shown — a missed drop costs more than an extra one."
            )
            WordPicker(
                options: GenderPreference.allCases.map { ($0.label, $0) },
                selection: store.profile.gender,
                select: store.setGender
            )
        }
    }

    /// The server targets alerts using this profile, so a change here is useless until
    /// it's pushed.
    private func pushIfNeeded(_ profile: SizeProfile) {
        guard settings.isConfigured else { return }
        Task { await remote.pushSizes(profile) }
    }
}

// MARK: - Pieces

/// A section title and the sentence under it, in the two faces this app uses for exactly
/// that job everywhere else.
struct SettingsHeader: View {
    let title: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.editorial(22))
                .foregroundStyle(Color.ink)
            if let note {
                Text(note)
                    .font(.data(11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row of words, one of them underlined — the app's segmented control.
///
/// The same object as `SavedView`'s mode strip, for the same reason: a system
/// `.segmented` picker would be the loudest thing on the page, and the loudest thing on a
/// settings page should be the settings.
struct WordPicker<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    let selection: Value
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 18) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { select(option.value) }
                } label: {
                    VStack(spacing: 5) {
                        Text(option.label.uppercased())
                            .font(.wordmark(11, isOn ? .semibold : .regular))
                            .tracking(1.4)
                            .foregroundStyle(isOn ? Color.ink : Color.muted)
                        Rectangle()
                            .fill(isOn ? Color.ink : Color.clear)
                            .frame(height: 1)
                    }
                    .fixedSize()
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct SizeChipRow: View {
    let title: String
    /// `display` is what the chip reads; `stored` is the canonical token the profile
    /// keeps. They differ only for shoes, where the ladder is shown in the user's scale
    /// and stored in US.
    let options: [(display: String, stored: String)]
    let isSelected: (String) -> Bool
    let toggle: (String) -> Void
    var accessory: (() -> AnyView)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                DataLabel(text: title.uppercased(), size: 10)
                Spacer(minLength: 12)
                if let accessory { accessory() }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(options, id: \.stored) { option in
                        let selected = isSelected(option.stored)
                        Button {
                            toggle(option.stored)
                        } label: {
                            Text(option.display)
                                .font(.data(13, selected ? .semibold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(selected ? Color.paper : Color.ink)
                                .frame(minWidth: 34)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(selected ? Color.ink : Color.wash)
                                .contentShape(.rect)
                        }
                        // .borderless, not .plain: inside a row that is itself tappable,
                        // `.plain` lets the row take the tap as a single target and the
                        // chips never fire.
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }
}
