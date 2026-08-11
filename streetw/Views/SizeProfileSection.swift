// SizeProfileSection.swift
// Who you are, as far as the feed is concerned: what you wear and what you want shown.
//
// Both halves are the same kind of statement — "narrow this to me" — so they live in one
// section rather than being split between a sizes screen and a filters screen. They also
// travel together: `SizePayload` carries both to the server, which needs them to decide
// whether a drop is worth waking someone for.

import StreetwCore
import SwiftUI

struct SizeProfileSection: View {
    @Environment(SizeProfileStore.self) private var store: SizeProfileStore
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings

    var body: some View {
        Section {
            SizeChipRow(
                title: "Clothing",
                options: SizeProfile.apparelOptions.map { (display: $0, stored: $0) },
                isSelected: { store.profile.apparel.contains($0) },
                toggle: store.toggleApparel
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
                        Picker("Scale", selection: Binding(
                            get: { store.profile.shoeScale },
                            set: { store.setShoeScale($0) }
                        )) {
                            ForEach(SizeScale.allCases) { scale in
                                Text(scale.label).tag(scale)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 132)
                    )
                }
            )

        } header: {
            Text("My sizes")
        } footer: {
            Text(store.profile.isEmpty
                 ? "Set your sizes and streetw can tell you when something is back in a size you actually wear."
                 : "Restocks in \(store.profile.summary) are highlighted in your feed.")
        }
        .onChange(of: store.profile) { _, profile in pushIfNeeded(profile) }

        Section {
            Picker("Show", selection: Binding(
                get: { store.profile.gender },
                set: { store.setGender($0) }
            )) {
                ForEach(GenderPreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        } header: {
            Text("What to show")
        } footer: {
            // Says exactly what it will and won't do. The honesty matters: plenty of
            // brands tag nothing useful, and someone who picks "Menswear" and still sees
            // the occasional women's piece should know that's the filter being careful
            // rather than broken.
            Text(store.profile.gender == .everything
                 ? "Everything a brand posts, whoever it's cut for — including kids."
                 : "Hides the opposite gender and kids. Unisex items and anything a brand doesn't label are always shown — a missed drop costs more than an extra one.")
        }
        .onChange(of: store.profile.gender) { _, _ in pushIfNeeded(store.profile) }
    }

    /// The server targets alerts using this profile, so a change here is useless until
    /// it's pushed.
    private func pushIfNeeded(_ profile: SizeProfile) {
        guard settings.isConfigured else { return }
        Task { await remote.pushSizes(profile) }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                if let accessory { accessory() }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.stored) { option in
                        let selected = isSelected(option.stored)
                        Button {
                            toggle(option.stored)
                        } label: {
                            Text(option.display)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .monospacedDigit()
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(
                                    selected ? AnyShapeStyle(Color.ink) : AnyShapeStyle(.quaternary),
                                    in: Capsule()
                                )
                                .foregroundStyle(selected ? Color.paper : Color.primary)
                                .contentShape(.capsule)
                        }
                        // .borderless, not .plain: inside a List row, `.plain` lets the
                        // row take the tap as a single target and the chips never fire.
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 2)
    }
}
