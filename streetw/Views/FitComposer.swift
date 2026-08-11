// FitComposer.swift
// Building an outfit out of things you've kept.
//
// Organised by slot rather than as one long list of saves, because that is how the choice
// is actually made — you pick *a* top, then *a* bottom, not "some clothes". Grouping also
// makes the constraint visible without having to state it: one selection per slot, and
// the row you already chose from shows what you chose.
//
// Anything the classifier couldn't place still appears, under "Other". Hiding it would
// mean a saved item silently becoming unusable because a storefront wrote a vague title,
// and the person looking at the photograph knows perfectly well what it is.

import StreetwCore
import SwiftData
import SwiftUI

struct FitComposer: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]

    /// Nil when composing a new fit.
    let fit: Fit?

    @State private var name = ""
    @State private var selected: Set<UUID> = []

    private var wearable: [SavedItem] { saves.filter { $0.update != nil } }

    /// Slots in stack order, each with its saved items. Empty slots are dropped.
    private var sections: [(slot: GarmentSlot, items: [SavedItem])] {
        Dictionary(grouping: wearable, by: \.slot)
            .map { (slot: $0.key, items: $0.value) }
            .sorted { $0.slot.stackOrder < $1.slot.stackOrder }
    }

    private var chosen: [SavedItem] {
        wearable.filter { selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        DataLabel(text: "NAME · OPTIONAL")
                        TextField("Sunday, layered, all black…", text: $name)
                            .font(.editorial(17))
                            .foregroundStyle(Color.ink)
                        Rule()
                    }
                    .padding(.horizontal, 20)

                    if wearable.isEmpty {
                        Text("Save a few things first — a fit is made from your collection.")
                            .font(.editorial(15))
                            .foregroundStyle(Color.muted)
                            .padding(.horizontal, 20)
                    }

                    ForEach(sections, id: \.slot) { section in
                        slotRow(section.slot, items: section.items)
                    }
                }
                .padding(.vertical, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle(fit == nil ? "New fit" : "Edit fit")
            .toolbarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { saveBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                if let fit {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Delete", role: .destructive) {
                            context.delete(fit)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
        }
        .tint(.ink)
        .onAppear {
            guard let fit else { return }
            name = fit.name
            selected = Set(fit.items.map(\.id))
        }
    }

    private func slotRow(_ slot: GarmentSlot, items: [SavedItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: slot.label.uppercased())
                .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(items) { item in
                        Button { toggle(item, in: slot) } label: {
                            PickerTile(
                                url: item.update?.primaryImageURL,
                                title: item.update?.title ?? "",
                                isOn: selected.contains(item.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var saveBar: some View {
        VStack(spacing: 8) {
            if !chosen.isEmpty {
                DataLabel(text: "\(chosen.count) \(chosen.count == 1 ? "PIECE" : "PIECES")")
            }
            Button(action: save) {
                Text("SAVE FIT")
                    .font(.data(12, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.paper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(chosen.count >= 2 ? Color.ink : Color.muted)
            }
            .buttonStyle(.borderless)
            // Two pieces is the floor for something to be an outfit rather than an item.
            .disabled(chosen.count < 2)
        }
        .padding(20)
        .background(.bar)
    }

    /// One selection per slot: picking a second top replaces the first rather than adding
    /// it, because an outfit with two tops is not a thing and a multi-select would let you
    /// build one without noticing.
    private func toggle(_ item: SavedItem, in slot: GarmentSlot) {
        if selected.contains(item.id) {
            selected.remove(item.id)
            return
        }
        for other in wearable where other.slot == slot && selected.contains(other.id) {
            selected.remove(other.id)
        }
        selected.insert(item.id)
    }

    private func save() {
        let items = chosen
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let fit {
            fit.items = items
            fit.name = trimmed
        } else {
            context.insert(Fit(name: trimmed, items: items))
        }
        try? context.save()
        dismiss()
    }

    /// A fit created by keeping a suggestion is inserted *before* this sheet opens, so
    /// cancelling has to undo it — otherwise backing out leaves an outfit you never
    /// confirmed.
    private func cancel() {
        if let fit, fit.name.isEmpty, fit.items.isEmpty {
            context.delete(fit)
            try? context.save()
        }
        dismiss()
    }
}

/// One selectable garment.
struct PickerTile: View {
    let url: URL?
    let title: String
    let isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UpdateImage(url: url, aspect: 1, drawnWidth: 130)
                .frame(width: 104)
                .overlay {
                    if isOn {
                        Rectangle().stroke(Color.signal, lineWidth: 2)
                    }
                }

            Text(title)
                .font(.editorial(11))
                .foregroundStyle(isOn ? Color.ink : Color.muted)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 104, alignment: .leading)
        }
    }
}
