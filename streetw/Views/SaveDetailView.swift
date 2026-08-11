// SaveDetailView.swift
// One kept thing, and the two facts about it only you know.
//
// A catalogue can tell you what a garment is called and what it cost. It cannot tell you
// that you bought the L because the M ran short, or that you're waiting on a restock in
// 9.5, or that it was the jacket from the shoot you liked. That is what an archive is
// *for*, and it is the difference between a collection and a list of links.
//
// Reachable by tapping a card in the collection. The feed still opens the storefront on
// tap, because there the question is "can I buy this"; here it is "what did I think".

import StreetwCore
import SwiftData
import SwiftUI

struct SaveDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    @Bindable var save: SavedItem

    @State private var note: String = ""
    @State private var sizeNote: String = ""

    private var update: BrandUpdate? { save.update }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let update, update.primaryImageURL != nil {
                        UpdateImage(url: update.primaryImageURL, kind: update.kind, aspect: 1, contentMode: .fit)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        heading
                        field(
                            title: "Size",
                            prompt: "The one you own, or the one you're waiting for",
                            text: $sizeNote,
                            axis: .horizontal
                        )
                        field(
                            title: "Note",
                            prompt: "Why you kept it",
                            text: $note,
                            axis: .vertical
                        )
                        boardPicker
                        typePicker
                        if let link = update?.linkURL {
                            Button("Open on site") { openURL(link) }
                                .font(.data(12, .medium))
                                .foregroundStyle(Color.ink)
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commit(); dismiss() }
                }
            }
        }
        .tint(.ink)
        .onAppear {
            note = save.note ?? ""
            sizeNote = save.sizeNote ?? ""
        }
        // Committed on the way out rather than on every keystroke: a note is written in
        // one go, and saving per character churns the store for no benefit.
        .onDisappear { commit() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let brand = update?.brand {
                Wordmark(name: brand.name, size: 11, color: .muted)
            }
            Text(update?.title ?? "Saved item")
                .font(.editorial(22))
                .foregroundStyle(Color.ink)
            HStack(spacing: 10) {
                if let price = update?.priceText {
                    DataLabel(text: price, size: 11, color: .ink)
                }
                DataLabel(text: "KEPT \(Stamp.short(save.savedAt).uppercased())")
            }
        }
    }

    private func field(title: String, prompt: String, text: Binding<String>, axis: Axis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DataLabel(text: title.uppercased())
            TextField(prompt, text: text, axis: axis)
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
                .lineLimit(axis == .vertical ? 3...8 : 1...1)
            Rule()
        }
    }

    private var boardPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "BOARD")
            if boards.isEmpty {
                Text("No boards yet — make one in the collection.")
                    .font(.editorial(14))
                    .foregroundStyle(Color.muted)
            } else {
                // Wraps rather than scrolls: on a detail page you want to see every
                // board at once, not hunt along a strip.
                FlowRow(spacing: 8) {
                    ForEach(boards) { board in
                        chip(label: board.name, isOn: save.board?.id == board.id) {
                            save.board = save.board?.id == board.id ? nil : board
                            try? context.save()
                        }
                    }
                }
            }
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "KEPT AS")
            HStack(spacing: 8) {
                ForEach(SavedItem.SaveType.allCases) { type in
                    chip(label: type.label, isOn: save.type == type) {
                        save.type = type
                        try? context.save()
                    }
                }
            }
        }
    }

    private func chip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(.wordmark(10, isOn ? .semibold : .regular))
                .tracking(1.1)
                .foregroundStyle(isOn ? Color.paper : Color.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isOn ? Color.ink : Color.wash)
        }
        .buttonStyle(.borderless)
    }

    private func commit() {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSize = sizeNote.trimmingCharacters(in: .whitespacesAndNewlines)
        save.note = trimmedNote.isEmpty ? nil : trimmedNote
        save.sizeNote = trimmedSize.isEmpty ? nil : trimmedSize
        try? context.save()
    }
}

/// Lays children left to right, wrapping onto new lines. SwiftUI has no built-in for
/// this and a `LazyVGrid` would force a fixed column count, which looks wrong for chips
/// whose widths come from their words.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var (x, y, lineHeight) = (CGFloat.zero, CGFloat.zero, CGFloat.zero)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var (x, y, lineHeight) = (bounds.minX, bounds.minY, CGFloat.zero)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
