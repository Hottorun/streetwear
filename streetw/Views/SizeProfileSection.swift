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

    // MARK: - The ladders

    private var sizes: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsHeader(title: "My sizes", info: SizeProfileSection.sizesInfo)

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
                            options: SizeScale.shoeScales.map { ($0.label, $0) },
                            selection: store.profile.shoeScale,
                            select: store.setShoeScale
                        )
                    )
                }
            )

            DressAndSuitRows()
        }
    }

    // MARK: - Who the feed is cut for

    private var gender: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "What to show",
                note: store.profile.gender.detail.uppercased(),
                info: SizeProfileSection.genderInfo
            )
            WordPicker(
                options: GenderPreference.allCases.map { ($0.label, $0) },
                selection: store.profile.gender,
                select: store.setGender
            )
        }
    }

    /// Said once, behind the ⓘ: what a size does, and the one thing it never does.
    static let sizesInfo = InfoNote(
        title: "Your sizes",
        lines: [
            "Your sizes are ruled in vermilion on every product, and restocks in them are what alerts you.",
            "A size never hides anything. Only What to show does.",
            "A ladder you leave empty doesn't filter."
        ]
    )

    /// Why somebody filtering to menswear still sees the odd women's piece: the filter being
    /// careful, not broken.
    static let genderInfo = InfoNote(
        title: "What to show",
        lines: [
            "Menswear or Womenswear hides the other, and kids.",
            "Unisex pieces, and anything a brand doesn't label, are always shown — a missed drop costs more than an extra one."
        ]
    )

    /// The server targets alerts using this profile, so a change here is useless until
    /// it's pushed.
    private func pushIfNeeded(_ profile: SizeProfile) {
        guard settings.isConfigured else { return }
        Task { await remote.pushSizes(profile) }
    }
}

extension GenderPreference {
    /// What the choice does, in a few words — the same line in onboarding and on You.
    var detail: String {
        switch self {
        case .everything: "Menswear, womenswear and kids"
        case .mens: "Hides womenswear and kids"
        case .womens: "Hides menswear and kids"
        }
    }
}

// MARK: - Pieces

/// The women's dress ladder and the men's tailoring ladder, in onboarding and in Settings.
///
/// One view for both screens because they must not disagree about what can be entered:
/// the first is where the first sync's highlighting is decided, the second is where it is
/// corrected. Each ladder sits on its own row with its own scale, for the reason the shoe
/// row carries its scale — a "38" means nothing until you know which ladder it is read on,
/// which is the bug these ladders exist to fix.
struct DressAndSuitRows: View {
    @Environment(SizeProfileStore.self) private var store: SizeProfileStore

    var body: some View {
        SizeChipRow(
            title: "Dress",
            options: SizeProfile.dressOptions(in: store.profile.dressScale),
            isSelected: { store.profile.dress.contains($0) },
            toggle: store.toggleDress,
            accessory: {
                AnyView(
                    WordPicker(
                        options: SizeScale.dressScales.map { ($0.label, $0) },
                        selection: store.profile.dressScale,
                        select: store.setDressScale
                    )
                )
            }
        )

        SizeChipRow(
            title: "Suit",
            options: SizeProfile.suitOptions(in: store.profile.suitScale),
            isSelected: { store.profile.suit.contains($0) },
            toggle: store.toggleSuit,
            accessory: {
                AnyView(
                    WordPicker(
                        options: SizeScale.suitScales.map { ($0.suitLabel, $0) },
                        selection: store.profile.suitScale,
                        select: store.setSuitScale
                    )
                )
            }
        )

        // Its own row because a length is a fact about a height and a chest about a build:
        // somebody between a 40 and a 42 is still a Regular in both.
        SizeChipRow(
            title: "Suit length",
            options: SizeProfile.suitLengthOptions,
            isSelected: { store.profile.suitLength.contains($0) },
            toggle: store.toggleSuitLength
        )
    }
}

/// A section title, an optional ⓘ beside it, and at most one short line under it.
///
/// The line is a status or a label — "FROM 6 SAVES", "DROPWALL 1.4 (5)" — never an explanation;
/// what has to be explained goes in `info`, a tap away (`CLAUDE.md`, *Copy*).
struct SettingsHeader: View {
    let title: String
    var note: String?
    var info: InfoNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 2) {
                Text(title)
                    .font(.editorial(22))
                    .foregroundStyle(Color.ink)
                if let info { InfoButton(note: info) }
            }
            if let note { NoteLine(text: note) }
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
    /// keeps. They differ where a ladder is shown in the user's scale and stored in a
    /// canonical one — shoes, dresses and suits — and for suit lengths, which are spelled
    /// out on the chip and stored as a letter.
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

            // **It wraps; it does not scroll.** Every ladder used to be a horizontal
            // `ScrollView` that ended flush with the right margin — no peeking chip, no
            // indicator — so the visible window was `XXS…XL`, `26…31`, `US 6…8.5` and
            // somebody who wears XXL or a 34 waist was looking at a control that appeared
            // not to contain their size. On the first screen of the app, for the feature
            // the whole product turns on. It was also ~500pt of empty space below, which
            // is exactly what wrapping spends: the ladder is now entirely visible, there
            // is no gesture to discover, and the step stops being top-heavy.
            FlowRow(spacing: 7) {
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
        }
    }
}
