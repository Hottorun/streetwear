// SavedView.swift
// The calm room: Inspiration (things you liked), Wardrobe (things you own), and Fits (what
// they make together).
//
// Everything the feed does to create urgency is absent here by design — no counts, no
// "new", no stock, no accent colour. Two columns of varying heights so the page reads as
// a wall rather than a table; the images do all the work.
//
// **Select mode.** Every action on a save used to be one save at a time — a long-press menu
// here, a swipe in the feed — so filing twenty things on a new board was twenty long presses,
// and clearing out a board you no longer wanted meant opening each tile. Selecting is the
// platform's own answer: "Select" in the bar, taps toggle, and a row of actions above the tab
// bar acts on the lot. It works the same on Inspiration, Wardrobe and a board, because a
// board is a filter over the same wall rather than a different screen.

import StreetwCore
import SwiftData
import SwiftUI

/// What the strip at the top of the collection is currently showing.
///
/// Three kinds of thing in one control, because they answer different questions and a
/// person doesn't think of them as different: Inspiration/Wardrobe is "do I own this",
/// a board is "what does this belong with", and Fits is "what does it make". All of them
/// are views of one collection — nothing here moves an item into a container.
enum CollectionFilter: Hashable {
    case type(SavedItem.SaveType)
    /// The outfits, kept and proposed — the Style tab's two rows, which moved here when it
    /// went. See `FitsPage`.
    case fits
    case board(UUID)
}

struct SavedView: View {
    @Environment(\.modelContext) private var context
    @Environment(CollectionRoute.self) private var collection: CollectionRoute
    @Environment(AIStore.self) private var ai: AIStore
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    /// `-startTab style` names a tab that is gone, and what it held is the Fits strip here —
    /// see `Tabs.resolve`.
    @State private var filter: CollectionFilter = Tabs.opensOnFits ? .fits : .type(.inspiration)
    @State private var query = ""
    @State private var isNamingBoard = false
    @State private var newBoardName = ""
    @State private var renaming: Board?
    /// The board a confirmation is currently being asked about.
    ///
    /// Delete sits directly under Rename in the same menu, at a spacing of about forty
    /// points, and the two are one mis-tap apart. Nothing is *lost* when it fires — the
    /// relationship nullifies, so the saves and fits survive — but the board itself, its
    /// name and everything filed into it go with no undo, which is enough to be worth one
    /// question.
    @State private var deleting: Board?
    @State private var opened: SavedItem?
    @State private var openedFit: Fit?
    @State private var isScanning = false

    // MARK: Selecting

    @State private var isSelecting = false
    /// By `SavedItem.id`. Only what is on the wall is ever acted on — see `Wall.selected` — so
    /// an id left behind by an item that has moved out of view does nothing.
    @State private var selection: Set<UUID> = []
    @State private var isFilingSelection = false
    @State private var isConfirmingDeletion = false
    @State private var fitStart: FitStart?

    /// A fit begun from a selection: its pieces, and the board it is begun on, if any.
    struct FitStart: Identifiable {
        let id = UUID()
        var items: [SavedItem]
        var board: Board?
    }

    private func visible(in scope: TasteScope) -> [SavedItem] {
        let inMode: [SavedItem]
        switch filter {
        case .type(let type):
            inMode = saves.filter { $0.hasSubject && $0.type == type }
        case .fits:
            inMode = []
        case .board:
            // Read off the board, which is proportional to the answer, rather than asking
            // every save in the collection whether it is on it — a relationship walk per save
            // per render. See `docs/performance.md`.
            inMode = currentBoard?.recentItems.filter(\.hasSubject) ?? []
        }
        // The facet narrows whatever is already showing rather than replacing it, so
        // arriving from your taste on You lands you inside the collection you know rather
        // than in a mode you didn't choose. It is removable, and says so.
        let narrowed = collection.facet.map { facet in
            inMode.filter { facet.matches($0, in: scope) }
        } ?? inMode
        return narrowed.filter { $0.matches(query) }
    }

    /// Whether the wall currently shows more than one label.
    ///
    /// A brand name on a tile earns its place by marking a change of brand. On a view that
    /// is entirely one label — a board, or a collection early on — it prints the same words
    /// down every tile and becomes the most repeated thing on a page about the clothes.
    /// Computed from what is *visible*, not from the whole collection, so filtering to a
    /// single-brand board quiets it and going back to Inspiration brings it back.
    /// Counted on the label the tile would actually print, not on the brand row behind it —
    /// a wall of shares from three shops nobody follows has three labels and no brands, and
    /// silencing all of them would leave the same wordmark logic in the wrong state.
    ///
    /// **Takes the wall as a parameter rather than reading `visible`.** It was a computed
    /// property read from *inside* the `ForEach` element closure, so it was evaluated once
    /// for every tile the lazy stack realised — and each evaluation re-ran the whole filter
    /// chain and faulted `save.update` → `update.brand` down it. With forty tiles on screen
    /// that is forty full passes over the collection to answer one yes/no question about it.
    private static func isMixedBrand(_ wall: [SavedItem]) -> Bool {
        var seen: Set<String> = []
        for save in wall {
            guard let label = save.update?.brandLabel else { continue }
            seen.insert(label)
            if seen.count > 1 { return true }
        }
        return false
    }

    private var currentBoard: Board? {
        guard case .board(let id) = filter else { return nil }
        return boards.first { $0.id == id }
    }

    /// The fits filed onto the board being viewed, newest first.
    ///
    /// A fit is filed exactly as an item is, so a board can legitimately hold outfits and
    /// no garments — "the fits I wore in Tokyo" is a board. It is therefore *not* empty,
    /// and the page must not say it is. Hidden while searching, because the query matches
    /// saved items and a row that ignores it reads as a search that failed to apply.
    private var visibleFits: [Fit] {
        guard query.isEmpty, let board = currentBoard else { return [] }
        return board.fits.sorted { $0.createdAt > $1.createdAt }
    }

    private var filterLabel: String {
        switch filter {
        case .type(let type): return type.label
        case .fits: return "Fits"
        case .board: return currentBoard?.name ?? "Board"
        }
    }

    /// Split by hand rather than with `LazyVGrid`, which forces every row to the height
    /// of its tallest cell and would flatten the wall back into a table.
    private static func columns(_ wall: [SavedItem]) -> ([SavedItem], [SavedItem]) {
        var left: [SavedItem] = []
        var right: [SavedItem] = []
        for (index, item) in wall.enumerated() {
            if index.isMultiple(of: 2) { left.append(item) } else { right.append(item) }
        }
        return (left, right)
    }

    /// The wall and everything read off it, worked out **once** per render.
    ///
    /// `visible` is a filter chain over every save — a relationship fault per item, a
    /// `CollectionFacet.matches` when a facet is on, and a `matches(query)` that re-trims and
    /// re-lowercases the query string per item. It was being evaluated at least five times
    /// per body (twice for the empty checks, twice more via `columns.0` and `columns.1`,
    /// each of which re-ran the split) and then once *per realised tile* through
    /// `isMixedBrand`.
    private struct Wall {
        var items: [SavedItem] = []
        var left: [SavedItem] = []
        var right: [SavedItem] = []
        var isMixedBrand = false
        var isEmpty: Bool { items.isEmpty }

        /// What a selection action acts on: the selected tiles that are on the wall now, in
        /// the wall's order.
        func selected(_ ids: Set<UUID>) -> [SavedItem] {
            items.filter { ids.contains($0.id) }
        }
    }

    private func buildWall() -> Wall {
        // Built from the boards this view already holds, so it costs nothing it was not
        // already paying. A facet opened from your taste is a query over the reading, and
        // the reading leaves things out — see `CollectionFacet.matches`.
        let items = visible(in: TasteScope(boards: boards, saves: saves))
        let (left, right) = Self.columns(items)
        return Wall(items: items, left: left, right: right, isMixedBrand: Self.isMixedBrand(items))
    }

    var body: some View {
        let wall = buildWall()

        return NavigationStack {
            Group {
                if filter == .fits {
                    FitsPage(saves: saves, boards: boards, query: query)
                } else if wall.isEmpty, visibleFits.isEmpty {
                    EditorialEmptyState(
                        title: emptyTitle,
                        action: emptyAction
                    )
                } else {
                    self.wall(wall)
                }
            }
            .background(Color.paper)
            .navigationTitle(isSelecting ? selectionTitle(wall) : "Saved")
            .toolbarTitleDisplayMode(.inlineLarge)
            // Searching a collection is how it stays usable past a few hundred items —
            // and a saved archive is the one part of the app that only ever grows.
            .searchable(text: $query, prompt: "Search your collection")
            .safeAreaInset(edge: .top) { header }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar(wall) }
            }
            // Before the page's own toolbar, so the avatar is the last item in the corner.
            .youButton()
            .toolbar { toolbar(wall) }
            .sheet(item: $opened) { SaveDetailView(save: $0) }
            .scanSheet(isPresented: $isScanning)
            .sheet(item: $openedFit) { FitCanvas(fit: $0) }
            .sheet(isPresented: $isFilingSelection) {
                BulkBoardSheet(saves: wall.selected(selection))
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $fitStart) { start in
                FitCanvas(fit: nil, starting: .pieces(start.items), board: start.board)
            }
            // Analysing here rather than at save time: this is the one screen whose
            // whole content is saved items, so the work is done where its results are
            // about to be used, and never for the 250 catalogue items nobody kept.
            // Keyed on the backlog rather than the save count — see `ImageTagger.backlog`.
            // A share whose photographs arrive on a later foreground has to be picked up
            // without waiting for somebody to keep something else.
            .task(id: ImageTagger.backlog(in: saves)) {
                await ImageTagger.analyzePending(in: context)
            }
            // Said on this screen in particular because the wall is what it changes: until
            // a photograph has been measured its tile is drawn to a hash of the item id,
            // so the layout visibly resettles as the pass lands.
            .safeAreaInset(edge: .top) {
                if let remaining = ImageTagger.progress.remaining {
                    AnalysisLine(remaining: remaining)
                }
            }
            .animation(.easeOut(duration: 0.2), value: ImageTagger.progress.remaining)
            // A selection only ever holds what is on the wall. Switching filters, searching,
            // or an action that moves things off this view (keeping them as Wardrobe while
            // looking at Inspiration) drops them from it rather than leaving invisible items
            // selected — an action on things you cannot see is an action you did not choose.
            .onChange(of: wall.items.map(\.id)) { _, ids in
                selection.formIntersection(ids)
                if ids.isEmpty { isSelecting = false }
            }
            // A facet is a question about saved things, and Fits shows outfits — so arriving on
            // one from your taste while Fits is up opens the wall it narrows, rather than a
            // filter applied to a page it cannot apply to.
            .onChange(of: collection.requests) { _, _ in
                if filter == .fits { filter = .type(.inspiration) }
            }
            .alert(renaming == nil ? "New board" : "Rename board", isPresented: $isNamingBoard) {
                TextField("Name", text: $newBoardName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { commitBoardName() }
            } message: {
                Text("Boards are private. Nothing is shared anywhere.")
            }
            .confirmationDialog(
                "Delete \(deleting?.name ?? "this board")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete board", role: .destructive) {
                    if let board = deleting { delete(board) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                // Says what survives, because that is the part somebody hesitating is
                // actually worried about.
                Text("The saves and fits filed here are kept — only the board goes.")
            }
        }
        .tint(.ink)
    }

    // MARK: - The bar

    @ToolbarContentBuilder
    private func toolbar(_ wall: Wall) -> some ToolbarContent {
        // Trailing, both of them, and never a leading text button: with a search field in the
        // bar iOS folds a lone leading action into a "···" menu — see CLAUDE.md, *A lone
        // `.cancellationAction` beside a `.searchable`*.
        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                let everything = Set(wall.items.map(\.id))
                Button(everything.isSubset(of: selection) ? "None" : "All") {
                    selection = everything.isSubset(of: selection) ? [] : everything
                }
                .font(.data(13))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endSelecting() }
                    .font(.data(13, .semibold))
            }
        } else {
            // Not on Fits: a selection acts on saves, and that page shows outfits.
            if filter != .fits {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") {
                        selection = []
                        isSelecting = true
                    }
                    .font(.data(13))
                    .disabled(wall.isEmpty)
                }
            }
            // **"+" adds to the collection**: a garment you photograph, or a board. The scan is
            // drawn only where the server can read a photograph (`AIStore.isAvailable`); without
            // it the "+" is the one thing it held before, and a menu of one is a lid on a button.
            ToolbarItem(placement: .topBarTrailing) {
                if ai.isAvailable {
                    Menu {
                        Button("Scan a garment", systemImage: "camera") { isScanning = true }
                        Button("New board", systemImage: "square.grid.2x2") { startNewBoard() }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                } else {
                    Button("New board", systemImage: "plus") { startNewBoard() }
                }
            }
            if let board = currentBoard {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename board", systemImage: "pencil") {
                            newBoardName = board.name
                            renaming = board
                            isNamingBoard = true
                        }
                        tastePicker(for: board)
                            .pickerStyle(.menu)
                        Button("Delete board", systemImage: "trash", role: .destructive) {
                            deleting = board
                        }
                    } label: {
                        Label("Board", systemImage: "ellipsis")
                    }
                }
            }
        }
    }

    private func startNewBoard() {
        newBoardName = ""
        isNamingBoard = true
    }

    private func selectionTitle(_ wall: Wall) -> String {
        let count = wall.selected(selection).count
        return count == 0 ? "Select" : "\(count) selected"
    }

    private func deletionTitle(_ count: Int) -> String {
        count == 1
            ? "Remove this from your collection?"
            : "Remove \(count) things from your collection?"
    }

    /// Worded as the single-item dialogs are, because it is the same act and a second wording
    /// of one promise is how the two stop agreeing.
    private func deletionMessage(_ count: Int) -> String {
        count == 1
            ? "Your note and where you filed it go too. Fits it appears in are left alone."
            : "Their notes and where you filed them go too. Fits they appear in are left alone."
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    // MARK: - Board management

    private func commitBoardName() {
        defer { renaming = nil }
        if let board = renaming {
            let name = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != board.name else { return }
            board.name = name
            try? context.save()
            return
        }
        guard let board = CollectionEdit.newBoard(named: newBoardName, after: boards, in: context) else { return }
        try? context.save()
        filter = .board(board.id)
    }

    /// Deleting a board never deletes its saves — the relationship nullifies. The view
    /// falls back to Inspiration so it isn't left filtering on something gone.
    private func delete(_ board: Board) {
        context.delete(board)
        try? context.save()
        filter = .type(.inspiration)
    }

    /// How this board counts towards taste, as a choice of three. See `TasteRule`.
    ///
    /// In the board's own menu, beside Rename and Delete, because it is a property of the
    /// board; and repeated as the line under the strip whenever it is set to anything but the
    /// default, because a setting that changes what three other tabs show must be visible
    /// from the board it is set on.
    private func tastePicker(for board: Board) -> some View {
        Picker(
            "Your taste",
            systemImage: "sparkles",
            selection: Binding(
                get: { board.tasteMode },
                set: { CollectionEdit.setTaste($0, on: board, among: boards, in: context) }
            )
        ) {
            ForEach(TasteMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
    }

    /// A search that finds nothing needs to say so, rather than reusing the "you have
    /// saved nothing" copy — which reads as though the collection had been emptied.
    ///
    /// A facet is the same case. It is a query over the taste reading, so it leaves out what
    /// does not count — and on a board that doesn't count it leaves out everything, where
    /// "This board is empty" would be false about a board that is full.
    private var emptyTitle: String {
        if !query.isEmpty || collection.facet != nil { return "No matches" }
        switch filter {
        case .type(.inspiration): return "Nothing kept yet"
        case .type(.wardrobe): return "Wardrobe is empty"
        case .fits: return "No fits yet"
        case .board: return "This board is empty"
        }
    }

    private var emptyAction: String {
        if !query.isEmpty { return "NOTHING IN \(filterLabel.uppercased()) MATCHES \"\(query.uppercased())\"" }
        if let facet = collection.facet {
            return "NOTHING IN \(filterLabel.uppercased()) THAT COUNTS TOWARD YOUR TASTE READS AS \(facet.value.uppercased())"
        }
        switch filter {
        case .type(.inspiration): return "TAP THE BOOKMARK ON ANYTHING IN YOUR FEED"
        case .type(.wardrobe): return "LONG-PRESS AN ITEM AND CHOOSE ADD TO WARDROBE"
        case .fits: return "SAVE A FEW THINGS AND THE OUTFITS THEY MAKE START HERE"
        // Not a swipe: the feed's swipe to file went with the spreads in Phase 1.
        case .board: return "LONG-PRESS ANYTHING AND CHOOSE ADD TO BOARD"
        }
    }

    private func wall(_ wall: Wall) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Once, the first time there is something on the wall to move.
                if !isSelecting, filter == .type(.inspiration) {
                    PaperTip(tip: WardrobeTip())
                        .padding(.horizontal, 20)
                }
                if !isSelecting { boardFits }
                if wall.isEmpty {
                    // Fits and nothing else. The wall stays, so the line explains the
                    // absence of tiles rather than the whole page claiming to be empty.
                    Text(emptyAction)
                        .font(.data(12))
                        .tracking(0.4)
                        .foregroundStyle(Color.muted)
                        .padding(.horizontal, 20)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        column(wall.left, offset: 0, showsBrand: wall.isMixedBrand)
                        column(wall.right, offset: 1, showsBrand: wall.isMixedBrand)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    /// Fits filed onto the board being viewed.
    ///
    /// A fit is its own kind of thing — it references saved items rather than containing
    /// them — but it files onto a board exactly as an item does, so a board that has both
    /// should show both. Only on a board: Inspiration and Wardrobe are about individual
    /// pieces, and Fits is where outfits live. Hidden while selecting, which acts on saves
    /// and nothing else.
    @ViewBuilder
    private var boardFits: some View {
        if !visibleFits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DataLabel(text: "\(visibleFits.count) \(visibleFits.count == 1 ? "FIT" : "FITS")")
                    .padding(.horizontal, 20)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(visibleFits) { fit in
                            Button { openedFit = fit } label: { FitCard(fit: fit, width: 140) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func column(_ items: [SavedItem], offset: Int, showsBrand: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(items) { save in
                CollectionTile(
                    save: save,
                    aspect: aspect(for: save, offset: offset),
                    onOpen: { isSelecting ? toggleSelection(save) : (opened = save) },
                    showsBrand: showsBrand,
                    isSelected: isSelecting ? selection.contains(save.id) : nil,
                    onSelect: {
                        selection = [save.id]
                        isSelecting = true
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func toggleSelection(_ save: SavedItem) {
        if selection.contains(save.id) {
            selection.remove(save.id)
        } else {
            selection.insert(save.id)
        }
    }

    /// The photograph's own shape once it has been measured, and a deterministic guess
    /// until then.
    ///
    /// The guess is deterministic rather than random so a tile doesn't change shape on
    /// every redraw — a collection that reflows while you look at it is the opposite of
    /// calm.
    ///
    /// A measured aspect is used as-is, because the tile is what stops the picture being
    /// cropped: the image is drawn `.fit`, so any clamp here is a clamp on the *photo*,
    /// and the old 0.66–1.5 window squared off every lookbook shot on the wall. The
    /// remaining bounds are only there to stop a panorama or a size chart from blowing
    /// one column out and leaving the other empty.
    ///
    /// The *cover's* shape — see `SavedItem.coverAspectMeasured` — because that is the
    /// photograph the tile draws.
    private func aspect(for save: SavedItem, offset: Int) -> CGFloat {
        if let measured = save.coverAspectMeasured, measured > 0 {
            return min(max(CGFloat(measured), 0.4), 2.2)
        }
        let ratios: [CGFloat] = [1, 0.8, 1, 0.75]
        let index = abs(save.id.hashValue &+ offset) % ratios.count
        return ratios[index]
    }

    /// The mode strip, plus the facet you arrived on if you arrived on one, plus what the
    /// board being looked at is doing to your taste when it is doing anything.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            modePicker
            if let facet = collection.facet, filter != .fits { facetChip(facet) }
            if let board = currentBoard, board.tasteMode != .counts { tasteLine(board) }
        }
    }

    /// The board's taste setting, said under the strip, and the way to change it.
    ///
    /// Only for a board that is not on the default: a board that counts is what every board
    /// is, and a line saying so on all of them would be a line nobody reads. Anything else
    /// changes what your taste, Discover and the brand suggestions show, which is too much
    /// to leave findable only inside a menu.
    private func tasteLine(_ board: Board) -> some View {
        // The three choices inline. A submenu here would make the line a menu whose only item
        // is another menu — a lid on a button.
        Menu {
            tastePicker(for: board)
                .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: board.tasteMode == .mood ? "sparkles" : "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                DataLabel(text: board.tasteMode.boardLine, size: 10, color: .ink)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .buttonStyle(.borderless)
    }

    /// What the collection has been narrowed to, and the way out of it.
    ///
    /// Always removable, and always visible while it applies. A filter you cannot see is
    /// indistinguishable from a collection that has lost things — and this one is set from
    /// another tab entirely, so without the chip somebody could arrive here days later
    /// wondering where half their saves went.
    private func facetChip(_ facet: CollectionFacet) -> some View {
        Button {
            collection.clear()
        } label: {
            HStack(spacing: 7) {
                Text(facet.value.uppercased())
                    .font(.wordmark(10, .semibold))
                    .tracking(1.1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.ink, in: Capsule())
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .accessibilityLabel("Showing \(facet.value) only. Tap to show everything.")
    }

    /// A row of words, set as type. A segmented control here would be the loudest object
    /// on a page whose whole job is to be quiet. Scrolls once boards are added, so the
    /// strip grows without ever becoming a second row of chrome.
    private var modePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(SavedItem.SaveType.allCases) { type in
                    entry(label: type.label, value: .type(type))
                }
                // Third, before the boards: it is one of the three ways of looking at the
                // whole collection, where a board is a slice of it.
                entry(label: "Fits", value: .fits)
                ForEach(boards) { board in
                    entry(label: board.name, value: .board(board.id))
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 12)
        .background(Color.paper)
    }

    private func entry(label: String, value: CollectionFilter) -> some View {
        let isOn = filter == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { filter = value }
        } label: {
            VStack(spacing: 5) {
                Text(label.uppercased())
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

    // MARK: - Acting on a selection

    /// What can be done to everything selected, in a row above the tab bar.
    ///
    /// The save confirmation's vocabulary — a glyph over tracked caps — so the two places the
    /// app acts on a save look like one app. Every action applies at once and the selection
    /// stays, the way the platform's own photo library behaves: filing a dozen things on two
    /// boards is two actions, not two rounds of selecting. Deleting is the exception, because
    /// what it acted on is gone.
    private func selectionBar(_ wall: Wall) -> some View {
        let chosen = wall.selected(selection)
        let isEmpty = chosen.isEmpty
        let board = currentBoard
        // A fit is made of photographs — see `FitCanvas.buildTray` — so a selection with none
        // has nothing to start one from.
        let wearable = chosen.filter(\.hasPhotograph)
        let allLeftOut = !chosen.isEmpty && chosen.allSatisfy(\.isExcludedFromTaste)

        return VStack(spacing: 0) {
            Rule()
            HStack(spacing: 0) {
                barButton("Boards", systemImage: "square.grid.2x2") { isFilingSelection = true }
                    .disabled(isEmpty)
                if let board {
                    // The commonest thing to do with a selection on a board is to take it off
                    // the board. Nothing is lost, so nothing is asked.
                    barButton("Take off", systemImage: "minus.square") {
                        CollectionEdit.unfile(chosen, from: board, in: context)
                    }
                    .disabled(isEmpty)
                    .accessibilityLabel("Take off \(board.name)")
                }
                Menu {
                    ForEach(SavedItem.SaveType.allCases) { type in
                        Button(type.label, systemImage: type.symbol) {
                            CollectionEdit.keep(chosen, as: type, in: context)
                        }
                    }
                } label: {
                    barLabel("Keep as", systemImage: "tshirt")
                }
                .disabled(isEmpty)
                barButton("Fit", systemImage: "hanger") {
                    fitStart = FitStart(items: wearable, board: board)
                }
                .disabled(wearable.isEmpty)
                Menu {
                    Button("Use for my taste", systemImage: "eye") {
                        CollectionEdit.exclude(chosen, false, in: context)
                    }
                    Button("Don't use for my taste", systemImage: "eye.slash") {
                        CollectionEdit.exclude(chosen, true, in: context)
                    }
                } label: {
                    barLabel("Taste", systemImage: allLeftOut ? "eye.slash" : "eye")
                }
                .disabled(isEmpty)
                barButton("Delete", systemImage: "trash") { isConfirmingDeletion = true }
                    .disabled(isEmpty)
                    // Always asked, unlike one bare bookmark: a selection is the one place a
                    // single tap removes many things, and any of them may carry a note. On the
                    // button rather than on the page, because on iOS 26 the dialog is a popover
                    // that points at whatever it is attached to — from the page it pointed at
                    // the title, the far end of the screen from the button that raised it.
                    .confirmationDialog(
                        deletionTitle(chosen.count),
                        isPresented: $isConfirmingDeletion,
                        titleVisibility: .visible
                    ) {
                        Button("Remove", role: .destructive) {
                            endSelecting()
                            CollectionEdit.delete(chosen, in: context)
                        }
                        Button("Keep", role: .cancel) {}
                    } message: {
                        Text(deletionMessage(chosen.count))
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .background(Color.paper)
    }

    private func barButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(title, systemImage: systemImage) }
            // `.plain` would let the enclosing row take the tap as one target — the same trap
            // as buttons in a `List` row, and the save confirmation's buttons.
            .buttonStyle(.borderless)
    }

    private func barLabel(_ title: String, systemImage: String) -> some View {
        SelectionBarLabel(title: title, systemImage: systemImage)
    }
}

/// One action in the selection bar: a glyph over tracked caps, muted while it cannot act.
///
/// Its own view so it can read `isEnabled`. The colour is set explicitly — ink, never the
/// tint — and an explicit colour is not dimmed by `.disabled`, so with nothing selected every
/// action was drawn exactly as if a tap would do something.
private struct SelectionBarLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
            Text(title.uppercased())
                .font(.wordmark(8, .semibold))
                .tracking(0.8)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(isEnabled ? Color.ink : Color.muted.opacity(0.6))
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
}

/// Filing a selection: every board, and whether all, some or none of the selection is on it.
///
/// The board picker's rows, for the same reason the two share `BoardRow` — filing is one
/// act whether it is one thing or twenty. A tap on a board files the whole selection on it, or
/// takes it all off when it is already all there (`CollectionEdit.toggle`).
struct BulkBoardSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    let saves: [SavedItem]

    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DataLabel(text: saves.count == 1 ? "1 THING SELECTED" : "\(saves.count) THINGS SELECTED")
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                    ForEach(boards) { board in
                        BoardRow(label: board.name, filing: CollectionEdit.filing(of: saves, on: board)) {
                            CollectionEdit.toggle(saves, on: board, in: context)
                        }
                    }

                    Button {
                        newName = ""
                        isNaming = true
                    } label: {
                        Label("New board", systemImage: "plus")
                            .font(.data(12, .medium))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle("Boards")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New board", isPresented: $isNaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    guard let board = CollectionEdit.newBoard(named: newName, after: boards, in: context) else { return }
                    CollectionEdit.file(saves, on: board, in: context)
                }
            } message: {
                Text("Boards are private. Nothing is shared anywhere.")
            }
        }
        .tint(.ink)
    }
}

extension TasteMode {
    /// What the choice is called in a board's menu.
    var label: String {
        switch self {
        case .counts: "Counts toward your taste"
        case .ignored: "Doesn't count"
        case .mood: "Inspire me from this"
        }
    }

    /// What a board on this setting says under the strip.
    var boardLine: String {
        switch self {
        case .counts: "COUNTS TOWARD YOUR TASTE"
        case .ignored: "DOESN'T COUNT TOWARD YOUR TASTE"
        case .mood: "YOUR MOOD · DISCOVER, BRANDS AND FITS LEAN THIS WAY"
        }
    }
}

#Preview {
    SavedView()
        .modelContainer(PreviewData.container)
}
