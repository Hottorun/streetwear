// SizeProfileSection.swift
// Size picker chips for the Style tab.

import StreetwCore
import SwiftUI

struct SizeProfileSection: View {
    @Environment(SizeProfileStore.self) private var store: SizeProfileStore

    var body: some View {
        @Bindable var store = store

        Section {
                SizeChipRow(
                    title: "Clothing",
                    options: SizeProfile.apparelOptions,
                    isSelected: { store.profile.apparel.contains($0) },
                    toggle: store.toggleApparel
                )
                SizeChipRow(
                    title: "Shoes (US)",
                    options: SizeProfile.shoeOptions,
                    isSelected: { store.profile.shoe.contains($0) },
                    toggle: store.toggleShoe
                )
                Toggle("Include one-size items", isOn: $store.profile.includeOneSize)
                    .font(.subheadline)
            } header: {
                Text("My sizes")
            } footer: {
                Text(store.profile.isEmpty
                     ? "Set your sizes and streetw can tell you when something is back in a size you actually wear."
                     : "Restocks in \(store.profile.summary) are highlighted in your feed.")
            }
    }
}

struct SizeChipRow: View {
    let title: String
    let options: [String]
    let isSelected: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        let selected = isSelected(option)
                        Button {
                            toggle(option)
                        } label: {
                            Text(option)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .monospacedDigit()
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(
                                    selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                    in: Capsule()
                                )
                                .foregroundStyle(selected ? .white : .primary)
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
