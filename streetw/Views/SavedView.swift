// SavedView.swift
// The calm room: Inspiration (things you liked) and Wardrobe (things you own).
//
// Everything the feed does to create urgency is absent here by design — no counts, no
// "new", no stock, no accent colour. Two columns of varying heights so the page reads as
// a wall rather than a table; the images do all the work.

import SwiftData
import SwiftUI

/// What the strip at the top of the collection is currently showing.
///
/// Two kinds of thing in one control, because they answer different questions and a
/// person doesn't think of them as different: Inspiration/Wardrobe is "do I own this",
/// a board is "what does this belong with". Both are *filters* over one collection —
/// nothing here moves an item into a container.
enum CollectionFilter: Hashable {
    case type(SavedItem.SaveType)
    case board(UUID)
}

struct SavedView: View {
    @Environment(\.modelContext) private var context
    @Environment(CollectionRoute.self) private var collection: CollectionRoute
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    @State private var filter: CollectionFilter = .type(.inspiration)
    @State private var query = ""
    @State private var isNamingBoard = false
    @State private var newBoardName = ""
    @State private var renaming: Board?
    @State private var opened: SavedItem?
    @State private var openedFit: Fit?

    private var visible: [SavedItem] {
        let inMode = saves.filter { save in
            guard save.update != nil else { return false }
            switch filter {
            case .type(let type): return save.type == type
            case .board(let id): return save.board?.id == id
            }
        }
        // The facet narrows whatever is already showing rather than replacing it, so
        // arriving from the Style tab lands you inside the collection you know rather
        // than in a mode you didn't choose. It is removable, and says so.
        let narrowed = collection.facet.map { facet in
            inMode.filter(facet.matches)
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
    private var isMixedBrand: Bool {
        var seen: Set<UUID> = []
        for save in visible {
            guard let id = save.update?.brand?.id else { continue }
            seen.insert(id)
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
        case .board: return currentBoard?.name ?? "Board"
        }
    }

    /// Split by hand rather than with `LazyVGrid`, which forces every row to the height
    /// of its tallest cell and would flatten the wall back into a table.
    private var columns: ([SavedItem], [SavedItem]) {
        var left: [SavedItem] = []
        var right: [SavedItem] = []
        for (index, item) in visible.enumerated() {
            if index.isMultiple(of: 2) { left.append(item) } else { right.append(item) }
        }
        return (left, right)
    }

    var body: some View {
        NavigationStack {
            Group {
                if visible.isEmpty, visibleFits.isEmpty {
                    EditorialEmptyState(
                        title: emptyTitle,
                        action: emptyAction
                    )
                } else {
                    wall
                }
            }
            .background(Color.paper)
            .navigationTitle("Saved")
            .toolbarTitleDisplayMode(.inlineLarge)
            // Searching a collection is how it stays usable past a few hundred items —
            // and a saved archive is the one part of the app that only ever grows.
            .searchable(text: $query, prompt: "Search your collection")
            .safeAreaInset(edge: .top) { header }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New board", systemImage: "plus") {
                            newBoardName = ""
                            isNamingBoard = true
                        }
                        if let board = currentBoard {
                            Button("Rename board", systemImage: "pencil") {
                                newBoardName = board.name
                                renaming = board
                                isNamingBoard = true
                            }
                            Button("Delete board", systemImage: "trash", role: .destructive) {
                                delete(board)
                            }
                        }
                    } label: {
                        Label("Boards", systemImage: "ellipsis")
                    }
                }
            }
            .sheet(item: $opened) { SaveDetailView(save: $0) }
            .sheet(item: $openedFit) { FitCanvas(fit: $0) }
            // Analysing here rather than at save time: this is the one screen whose
            // whole content is saved items, so the work is done where its results are
            // about to be used, and never for the 250 catalogue items nobody kept.
            .task(id: saves.count) { await ImageTagger.analyzePending(in: context) }
            .alert(renaming == nil ? "New board" : "Rename board", isPresented: $isNamingBoard) {
                TextField("Name", text: $newBoardName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { commitBoardName() }
            } message: {
                Text("Boards are private. Nothing is shared anywhere.")
            }
        }
        .tint(.ink)
    }

    // MARK: - Board management

    private func commitBoardName() {
        let name = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renaming = nil }
        guard !name.isEmpty else { return }

        if let board = renaming {
            board.name = name
        } else {
            let board = Board(name: name, sortIndex: (boards.map(\.sortIndex).max() ?? 0) + 1)
            context.insert(board)
            try? context.save()
            filter = .board(board.id)
            return
        }
        try? context.save()
    }

    /// Deleting a board never deletes its saves — the relationship nullifies. The view
    /// falls back to Inspiration so it isn't left filtering on something gone.
    private func delete(_ board: Board) {
        context.delete(board)
        try? context.save()
        filter = .type(.inspiration)
    }

    /// A search that finds nothing needs to say so, rather than reusing the "you have
    /// saved nothing" copy — which reads as though the collection had been emptied.
    private var emptyTitle: String {
        if !query.isEmpty { return "No matches" }
        switch filter {
        case .type(.inspiration): return "Nothing kept yet"
        case .type(.wardrobe): return "Wardrobe is empty"
        case .board: return "This board is empty"
        }
    }

    private var emptyAction: String {
        if !query.isEmpty { return "NOTHING IN \(filterLabel.uppercased()) MATCHES \"\(query.uppercased())\"" }
        switch filter {
        case .type(.inspiration): return "TAP THE BOOKMARK ON ANYTHING IN YOUR FEED"
        case .type(.wardrobe): return "LONG-PRESS AN ITEM AND CHOOSE ADD TO WARDROBE"
        case .board: return "SWIPE A CARD IN THE FEED, OR LONG-PRESS ANY SAVE TO FILE IT HERE"
        }
    }

    private var wall: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                boardFits
                if visible.isEmpty {
                    // Fits and nothing else. The wall stays, so the line explains the
                    // absence of tiles rather than the whole page claiming to be empty.
                    Text(emptyAction)
                        .font(.data(12))
                        .tracking(0.4)
                        .foregroundStyle(Color.muted)
                        .padding(.horizontal, 20)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        column(columns.0, offset: 0)
                        column(columns.1, offset: 1)
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
    /// pieces, and the Style tab is where outfits live.
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

    private func column(_ items: [SavedItem], offset: Int) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(items) { save in
                CollectionTile(
                    save: save,
                    aspect: aspect(for: save, offset: offset),
                    onOpen: { opened = save },
                    showsBrand: isMixedBrand
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
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
    private func aspect(for save: SavedItem, offset: Int) -> CGFloat {
        if let measured = save.update?.imageAspect, measured > 0 {
            return min(max(CGFloat(measured), 0.4), 2.2)
        }
        let ratios: [CGFloat] = [1, 0.8, 1, 0.75]
        let index = abs(save.id.hashValue &+ offset) % ratios.count
        return ratios[index]
    }

    /// The mode strip, plus the facet you arrived on if you arrived on one.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            modePicker
            if let facet = collection.facet { facetChip(facet) }
        }
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
}

#Preview {
    SavedView()
        .modelContainer(PreviewData.container)
}
