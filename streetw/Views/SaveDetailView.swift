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
//
// That framing was taken too literally. The page dropped the size run, the colourways and
// the watch — everything the *product* is — and kept only the two annotations, which left
// a saved thing looking like a bookmark with a note attached. But the single most common
// reason to keep something you cannot have is that it was sold out, and "tell me when it's
// back" is the one thing this app can do that a screenshot cannot. So the facts come back,
// and the watch sits above the notes rather than below them.

import StreetwCore
import SwiftData
import SwiftUI

struct SaveDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    @Bindable var save: SavedItem

    @State private var note: String = ""
    @State private var sizeNote: String = ""
    @State private var selectedColorway: String?

    private var update: BrandUpdate? { save.update }

    private var colorways: [Colorway] { update?.colorways ?? [] }

    /// Variants in the chosen colourway, or all of them when none is chosen.
    private var visibleVariants: [VariantInfo] {
        let all = update?.variants ?? []
        guard let selectedColorway else { return all }
        return all.filter { $0.color?.caseInsensitiveCompare(selectedColorway) == .orderedSame }
    }

    private var runEntries: [SizeRun.Entry] {
        SizeRun.entries(for: visibleVariants, profile: sizes.profile)
    }

    /// Sold out in everything currently shown — the state the watcher exists for.
    private var isSoldOut: Bool {
        guard !visibleVariants.isEmpty else { return update?.isAvailable == false }
        return !visibleVariants.contains { $0.available }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let update, !update.imageURLs.isEmpty {
                        // The whole set, paged, not just the first frame. You kept this
                        // particular thing; the other seven photographs of it are already
                        // on the phone.
                        ImageGallery(urls: update.imageURLs, kind: update.kind, isZoomable: true)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        heading
                        if !runEntries.isEmpty { sizeSection }
                        if !colorways.isEmpty {
                            ColorwaySection(colorways: colorways, selected: $selectedColorway)
                        }
                        if let update {
                            WatchSection(
                                update: update,
                                colorway: selectedColorway,
                                isSoldOut: isSoldOut
                            )
                        }

                        DataLabel(text: "YOUR NOTES")
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
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let price = update?.priceText {
                    Text(price)
                        .font(.data(15, .medium))
                        .foregroundStyle(Color.ink)
                }
                // A markdown since you kept it is worth knowing on this page more than on
                // any other — it is the answer to "should I finally buy this".
                if let was = update?.previousPriceText, update?.kind == .priceDrop {
                    Text(was)
                        .font(.data(12))
                        .foregroundStyle(Color.muted)
                        .strikethrough(color: .muted)
                }
                Spacer(minLength: 0)
                DataLabel(text: "KEPT \(Stamp.short(save.savedAt).uppercased())")
            }

            if isSoldOut, update?.variants.isEmpty == false {
                DataLabel(text: "SOLD OUT", size: 11, color: .signal)
            }
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DataLabel(text: "SIZES")
                Spacer()
                if !sizes.profile.isEmpty {
                    DataLabel(text: "YOURS: \(sizes.profile.summary.uppercased())", size: 9)
                }
            }
            SizeRun(entries: runEntries, size: 14, limit: .max)
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
