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
//
// Having won both halves back, the page then printed them as one undifferentiated column:
// the size run, the colourways, the watch, a floating "YOUR NOTES", two fields and two
// rows of chips, all at the same rhythm and all the same weight. Two things fix that and
// they are the whole of this layout:
//
// - **The page is in two parts and now says so.** Above the rule is the garment, and it is
//   the same garment anybody else would see. Below it is only yours — what you wrote, where
//   you filed it, why you kept it. A ruled masthead between them costs one line and is the
//   difference between a form and a page.
// - **The way out is pinned, not buried.** "Open on site" was a small text link *below* two
//   rows of chips, so the most consequential thing on the page sat at the bottom of a
//   scroll. It is `StorefrontBar` now, the same one the product page uses.
//
// And one thing the archive can say that no catalogue can: what you have worn this with.
// `SavedItem.fits` is already there and was going unread.

import StreetwCore
import SwiftData
import SwiftUI

struct SaveDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    @Bindable var save: SavedItem

    @State private var note: String = ""
    @State private var sizeNote: String = ""
    @State private var selectedColorway: String?
    /// Held here rather than inside the gallery: choosing a colourway is a statement about
    /// which photograph you want to be looking at.
    @State private var imageIndex = 0
    @State private var openedFit: Fit?
    @State private var isConfirmingRemoval = false
    @State private var isRemoved = false
    @State private var isNamingBoard = false
    @State private var newBoardName = ""

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
                        ImageGallery(
                            urls: update.imageURLs,
                            kind: update.kind,
                            isZoomable: true,
                            // The same fixed sweep the wall uses. Opening a tile must not
                            // change what the garment is standing on.
                            backdrop: .sweep,
                            mark: update.brand?.name,
                            selection: $imageIndex
                        )
                    }

                    VStack(alignment: .leading, spacing: 26) {
                        heading
                        if !runEntries.isEmpty { sizeSection }
                        if !colorways.isEmpty {
                            ColorwaySection(colorways: colorways, selected: $selectedColorway)
                                .onChange(of: selectedColorway) { _, colour in
                                    guard let index = update?.imageIndex(forColorway: colour) else { return }
                                    withAnimation(.easeInOut(duration: 0.25)) { imageIndex = index }
                                }
                        }
                        if let update {
                            WatchSection(
                                update: update,
                                colorway: selectedColorway,
                                isSoldOut: isSoldOut
                            )
                        }
                        wornIn
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)

                    // Everything past here is yours and nobody else's, and the page is
                    // divided rather than merely continued.
                    // Generous, because the section above it ends in a rule of its own
                    // (the watch) as often as not, and two hairlines a few points apart
                    // read as a printing error rather than as a division.
                    masthead
                        .padding(.horizontal, 20)
                        .padding(.top, 44)
                        .padding(.bottom, 20)

                    VStack(alignment: .leading, spacing: 26) {
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
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle(update?.brand?.name ?? "Saved")
            .toolbarTitleDisplayMode(.inline)
            // Pinned rather than left at the foot of the scroll. Everything below the rule
            // is an annotation you can come back to; going to look at the thing is not.
            .safeAreaInset(edge: .bottom) {
                if let link = update?.linkURL {
                    StorefrontBar(url: link, isSoldOut: isSoldOut)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Remove from collection", systemImage: "trash", role: .destructive) {
                            isConfirmingRemoval = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commit(); dismiss() }
                        .font(.data(13, .semibold))
                }
            }
            .alert("New board", isPresented: $isNamingBoard) {
                TextField("Name", text: $newBoardName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createBoard() }
            } message: {
                Text("Boards are private. Nothing is shared anywhere.")
            }
            .confirmationDialog(
                "Remove this from your collection?",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) { remove() }
            } message: {
                // Said plainly, because it is the one surprising consequence: a fit is a
                // list of things you own, and un-saving does not rewrite the fits it was in.
                Text(
                    save.fits.isEmpty
                        ? "Your note and where you filed it go too."
                        : "Your note and where you filed it go too. Fits it appears in are left alone."
                )
            }
        }
        .tint(.ink)
        .sheet(item: $openedFit) { FitCanvas(fit: $0) }
        .onAppear {
            note = save.note ?? ""
            sizeNote = save.sizeNote ?? ""
        }
        // Committed on the way out rather than on every keystroke: a note is written in
        // one go, and saving per character churns the store for no benefit.
        .onDisappear { commit() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                DataLabel(text: "KEPT \(Stamp.short(save.savedAt).uppercased())")
                if isSoldOut, update?.variants.isEmpty == false {
                    DataLabel(text: "· SOLD OUT", size: 11, color: .signal)
                }
                Spacer(minLength: 0)
            }

            Text(update?.title ?? "Saved item")
                .font(.editorial(25))
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
            }
        }
    }

    /// The outfits this piece is in.
    ///
    /// The one statement an archive can make that a storefront cannot: not what the thing
    /// is, but what you have worn it with. `SavedItem.fits` was already carrying this and
    /// nothing read it — so a fit could be built out of an item and the item's own page
    /// would never mention it.
    @ViewBuilder
    private var wornIn: some View {
        if !save.fits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DataLabel(text: save.fits.count == 1 ? "IN ONE FIT" : "IN \(save.fits.count) FITS")
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(save.fits.sorted { $0.createdAt > $1.createdAt }) { fit in
                            Button { openedFit = fit } label: { FitCard(fit: fit, width: 132) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // Bleeds to the page edge, like every other horizontal rail in the app,
                // rather than stopping short inside the text column.
                .padding(.horizontal, -20)
                .contentMargins(.horizontal, 20, for: .scrollContent)
            }
        }
    }

    /// The line that divides the garment from your reading of it.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rule()
            HStack(alignment: .firstTextBaseline) {
                Text("Yours")
                    .font(.editorial(19))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                DataLabel(text: "PRIVATE", size: 9)
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
            // Wrapped, for the same reason as `ProductDetailView`: an unlimited run is
            // `.fixedSize()` end to end and would otherwise set the width of the page.
            SizeRun(entries: runEntries, size: 14, limit: .max, wraps: true)
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

    /// Where this is filed, and — the part that was missing — the way to make somewhere to
    /// file it. The empty state used to read "No boards yet — make one in the collection",
    /// which names a place rather than offering to do it, on the one screen where somebody
    /// has just decided this thing belongs with something else.
    private var boardPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "BOARD")
            // Wraps rather than scrolls: on a detail page you want to see every board at
            // once, not hunt along a strip.
            FlowRow(spacing: 8) {
                ForEach(boards) { board in
                    chip(label: board.name, isOn: save.board?.id == board.id) {
                        save.board = save.board?.id == board.id ? nil : board
                        try? context.save()
                    }
                }
                chip(label: boards.isEmpty ? "New board" : "+ New", isOn: false) {
                    newBoardName = ""
                    isNamingBoard = true
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

    /// Filing straight onto a board that did not exist a second ago, which is the usual
    /// way a board gets made: you find the second thing that belongs with the first.
    private func createBoard() {
        let name = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let created = Board(name: name, sortIndex: (boards.map(\.sortIndex).max() ?? 0) + 1)
        context.insert(created)
        save.board = created
        try? context.save()
    }

    private func commit() {
        guard !isRemoved else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSize = sizeNote.trimmingCharacters(in: .whitespacesAndNewlines)
        save.note = trimmedNote.isEmpty ? nil : trimmedNote
        save.sizeNote = trimmedSize.isEmpty ? nil : trimmedSize
        try? context.save()
    }

    /// Un-saving, from the page that is about the save. Deleting the `SavedItem` leaves the
    /// `BrandUpdate` — the product is catalogue, not collection — and leaves the fits it
    /// was in, which is `Fit.items` cascading in neither direction and is the whole reason
    /// the dialog says so.
    ///
    /// `onDisappear` fires `commit` on the way out and would otherwise be writing a note
    /// onto a model that no longer exists, so the delete is latched rather than trusted to
    /// be a harmless no-op.
    private func remove() {
        isRemoved = true
        context.delete(save)
        try? context.save()
        dismiss()
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
