// FitCanvas.swift
// Arranging clothes, rather than filling in a form about them.
//
// The old composer was three fixed rows — pick a top, pick a bottom, pick shoes — which is
// faster to use and completely wrong for what this is. An outfit is not a schema. The
// moment you want to layer two jackets, add a bag, hang a chain over a hoodie or lay
// something out flat rather than person-shaped, a slot builder says no, and it says no
// about the exact things that make an outfit yours.
//
// So: a canvas. Free position, free scale, free rotation, **no snapping** — a grid is what
// turns a collage back into a form. Three things make the difference between this and a
// fiddly mess:
//
// - **Cutouts.** Raw product shots are white rectangles overlapping white rectangles.
//   `Cutout` lifts each garment off its backdrop on the way into the collection, so what
//   lands on the canvas is a sticker. This is the single thing the whole screen depends on.
// - **Layering you can reach.** Tap brings a piece to the front. That is the one ordering
//   control anybody needs while arranging, and it needs no list, no handles and no mode.
// - **A tray from the wardrobe.** Every piece comes from something already saved, so a fit
//   is automatically a list of item ids — which is what keeps it editable, and what makes
//   "one of these came back in stock" a thing the app can say later.
// - **A piece is placed where you put it.** Dragging out of the tray drops the garment
//   under your finger; tapping still lands it on a sensible spot, because a tap has no
//   destination to read. Dropping something already on the canvas moves it rather than
//   minting a second copy of the same garment.
// - **Handles, because a pinch is not always available.** Two fingers on a piece the size
//   of a stamp is a gesture nobody can aim, and pinching the topmost of an overlapping
//   stack is a coin toss. The selected piece therefore carries a corner handle that scales
//   and turns with one finger, and a corner that takes it off the canvas. Pinch and twist
//   still work and are still the fast path — the handles are the one that always works.
//
// Slots do not disappear; they just stop being the interface. `GarmentSlot` still filters
// the tray and still drives `FitSuggestions`. Canvas for the person, slots for the machine.
//
// **This is the only fit editor.** There used to be two: "Wear it with" on a product page and
// "See the fit" on a Discover card opened `FitStudio`, a builder with its own preview and its
// own save, while the fit row, a selection on the wall and "+ New fit" opened this — so which
// editor somebody met depended on where they happened to tap, and the studio's best button was
// "save and arrange it by hand", which opened this anyway. Every entry point now lands here,
// opened with whatever it was proposing (see `Opening`), and the studio's one good idea — a
// ranked shortlist for each position, one tap from being swapped in — is a shelf in the tray.

import StreetwCore
import SwiftData
import SwiftUI

struct FitCanvas: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(StyleStatementStore.self) private var statement: StyleStatementStore

    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    /// Nil when composing a new fit.
    let fit: Fit?

    /// What a new fit opens with. **Nothing is stored until Save**, whichever it is — the
    /// contract every one of these used to break in its own way: `StyleView.keep` wrote a fit
    /// before anybody had agreed to it, and the studio saved one first so the canvas had
    /// something to edit. Closing the canvas leaves nothing behind.
    enum Opening {
        /// Pieces chosen by hand — a selection on the wall, or nothing at all.
        case pieces([SavedItem])
        /// A proposal off the fit row, which may borrow a garment from the catalogue to fill a
        /// slot the wardrobe cannot.
        case suggestion(SuggestedFit)
        /// An outfit built around one garment — "Wear it with" on a product or a saved item, and
        /// a Discover card's pairing. Opens on `FitProposal.opening`, with the shortlist for each
        /// position in the tray. `anchor` is the wardrobe piece the card was already naming.
        case around(FitSubject, anchor: String?)
    }

    let starting: Opening
    /// The board a fit begun from a board's selection is filed on, which is where somebody
    /// looking at that board would expect to find it. Still changeable before saving.
    let startingBoard: Board?

    init(fit: Fit?, starting: Opening = .pieces([]), board: Board? = nil) {
        self.fit = fit
        self.starting = starting
        self.startingBoard = board
    }

    /// One garment on the canvas: something already kept, or something that becomes a save
    /// only when the fit does.
    ///
    /// The second case is what lets every entry point open here. A fit is made of `SavedItem`s
    /// and has to be — that is what makes an outfit a list of things you own — but a proposal
    /// built around a product page's garment, a Discover card, or a catalogue piece filling a
    /// gap in the wardrobe is about something nobody has kept yet. Keeping it on the way *in*
    /// would put a garment in the collection for opening a sheet, and for a Discover card would
    /// write a row the deck's no-pollution rule forbids. So it waits on the canvas as what it
    /// is, and `save()` is the one moment it becomes a save.
    enum Piece {
        case kept(SavedItem)
        case pending(FitSubject)

        /// What `Outfit` judges the finished fit on. Taken before anything is materialised,
        /// because a discovery card's measured colour lives on the card, not on the row.
        var garment: Garment? {
            switch self {
            case .kept(let save): return save.update?.garment
            case .pending(let subject): return subject.garment
            }
        }

        func resolve(in context: ModelContext) -> SavedItem? {
            switch self {
            case .kept(let save): return save.isGone ? nil : save
            case .pending(let subject): return subject.materialise(in: context)
            }
        }
    }

    /// What the tray is showing.
    private enum Shelf: Hashable {
        /// The proposal's shortlist, every position's best first. Only there when the canvas
        /// was opened around a garment and the wardrobe has something to put with it.
        case proposal
        case all
        case slot(GarmentSlot)
    }

    @State private var name = ""
    @State private var placements: [FitPlacement] = []
    @State private var chosen: [UUID: Piece] = [:]
    @State private var selected: UUID?
    @State private var shelf: Shelf = .all
    @State private var board: Board?
    /// The ground, held here so a change is live on the canvas and written on save. See
    /// `FitBackground`.
    @State private var background: FitBackground = .base
    @State private var isNaming = false
    @State private var isDropTarget = false
    @State private var isNamingBoard = false
    @State private var newBoardName = ""

    /// The outfit this canvas was opened around, ranked once when it opened — see
    /// `FitProposal` for why the shelves must never re-sort while somebody is choosing.
    @State private var proposal: FitProposal?
    /// Which position on the body each machine-placed piece stands in, so choosing another
    /// from the same shelf *swaps* it — taking its place, size and layer — rather than adding a
    /// second pair of trousers beside the first. Pieces placed from the rest of the tray are not
    /// in here: the canvas is free, and a jacket somebody added by hand is theirs to keep.
    @State private var positions: [UUID: FitPosition] = [:]

    /// Only ever grows. Sparse z values mean bringing something to the front is one write
    /// rather than renumbering everything behind it.
    @State private var topZ = 0
    @State private var didArrangeStarting = false

    /// What the tray is made of, worked out **once** per render.
    ///
    /// The same correction `FeedView` carries, and this screen needed it more: these were
    /// four computed properties reading each other, on a view whose `@Query` is unpredicated
    /// — so every `context.save()` anywhere in the app, including each batch of the
    /// photograph analysis draining in the background, rebuilt the lot while somebody was
    /// arranging a fit.
    ///
    /// `wearable` filters the whole collection and faults `save.update` per row. It was read
    /// by `trayItems`, by `traySlots` and again by `drop`. And `traySlots` runs
    /// `GarmentClassifier.classify` on every save — a slot is computed, not stored — so the
    /// chip row alone classified the entire collection on each pass, and `trayItems` did it
    /// again for the filter.
    private struct Tray {
        var wearable: [SavedItem] = []
        /// Paired with the slot rather than asking for it twice: `SavedItem.slot`
        /// classifies from scratch on every read.
        var items: [SavedItem] = []
        var slots: [GarmentSlot] = []
    }

    private func buildTray() -> Tray {
        // A photograph is not decoration here, it *is* the piece — there is nothing else to
        // lift a cutout from and nothing else to drag around. Some products genuinely have
        // none (Palace's sitemap publishes entries with no image), and those were arriving
        // in the tray as blank tiles that placed a blank rectangle you could move, scale and
        // rotate but never see. Kept out of the tray rather than drawn as a placeholder: a
        // collage is made of pictures, and offering one that isn't there is offering nothing.
        let wearable = saves.filter { $0.update?.imageURLStrings.isEmpty == false }

        // Classified once, then used for both the chips and the filter.
        let classified = wearable.map { (item: $0, slot: $0.slot) }
        let slots = Set(classified.map(\.slot))
            .filter { $0 != .unknown }
            .sorted { $0.stackOrder < $1.stackOrder }

        let items: [SavedItem]
        switch shelf {
        case .proposal: items = []
        case .all: items = wearable
        case .slot(let filter): items = classified.filter { $0.slot == filter }.map(\.item)
        }

        return Tray(wearable: wearable, items: items, slots: slots)
    }

    private var placedPieces: [(piece: Piece, placement: FitPlacement)] {
        placements
            .compactMap { placement in chosen[placement.itemID].map { (piece: $0, placement: placement) } }
            .sorted { $0.placement.z < $1.placement.z }
    }

    var body: some View {
        let tray = buildTray()

        return NavigationStack {
            VStack(spacing: 0) {
                canvas(tray)
                Rule()
                trayRow(tray)
            }
            .background(Color.paper)
            .navigationTitle(fit == nil ? "New fit" : "Edit fit")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Name this fit", systemImage: "textformat") { isNaming = true }
                        boardMenu
                        // Only for a fit that has been saved: sharing renders the stored
                        // canvas, and a draft has none. Offering it on an unsaved fit would
                        // either share the last version or share nothing.
                        if let fit, fit.renderFile != nil, let image = fit.renderImage {
                            ShareLink(
                                item: Image(uiImage: image),
                                preview: SharePreview(
                                    fit.name.isEmpty ? "A fit" : fit.name,
                                    image: Image(uiImage: image)
                                )
                            ) {
                                Label("Share fit", systemImage: "square.and.arrow.up")
                            }
                        }
                        if !placements.isEmpty {
                            Button("Clear canvas", systemImage: "trash", role: .destructive) {
                                // Everything that says what is on the canvas, not only the
                                // placements: the tray reads `chosen` to mark what is down,
                                // and clearing the picture alone left every tile dimmed as
                                // if it were still placed.
                                placements = []
                                chosen = [:]
                                positions = [:]
                                selected = nil
                            }
                        }
                        if let fit {
                            Button("Delete fit", systemImage: "trash", role: .destructive) {
                                delete(fit)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .font(.data(13, .semibold))
                        .disabled(placements.count < 2)
                }
            }
            .alert("Name this fit", isPresented: $isNaming) {
                TextField("Sunday, layered, all black…", text: $name)
                Button("Done") {}
            }
            .alert("New board", isPresented: $isNamingBoard) {
                TextField("Name", text: $newBoardName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createBoard() }
            } message: {
                Text("Boards are private. Nothing is shared anywhere.")
            }
            // **The stickers are lifted here too.** The pass runs where its results are about
            // to be used, and this is the screen built out of them — reachable from a product
            // page, a Discover card or the fit row without the Saved wall ever having been
            // opened, which left the pieces un-lifted for exactly the person about to need
            // them. Concurrent calls are safe: a second one waits on the drain in flight.
            .task(id: ImageTagger.backlog(in: saves)) {
                await ImageTagger.analyzePending(in: context)
            }
        }
        .tint(.ink)
        .onAppear(perform: load)
    }

    // MARK: - Canvas

    private func canvas(_ tray: Tray) -> some View {
        GeometryReader { geometry in
            ZStack {
                background.color
                    // Tapping the backdrop deselects. Without it the last piece touched
                    // keeps its outline for the rest of the session and reads as stuck.
                    .contentShape(.rect)
                    .onTapGesture { selected = nil }

                ForEach(placedPieces, id: \.placement.itemID) { entry in
                    PlacedPiece(
                        piece: entry.piece,
                        placement: binding(for: entry.placement.itemID),
                        canvas: geometry.size,
                        space: Self.space,
                        isSelected: selected == entry.placement.itemID,
                        onSelect: { bringToFront(entry.placement.itemID) },
                        onSendToBack: { sendToBack(entry.placement.itemID) },
                        onRemove: { remove(entry.placement.itemID) }
                    )
                }

                if placements.isEmpty { emptyCanvas }
            }
            // Named rather than local: the resize handle rides inside the piece's rotated
            // coordinate space, so the only frame its arithmetic can trust is the canvas.
            .coordinateSpace(.named(Self.space))
            .dropDestination(for: String.self) { payloads, location in
                drop(payloads, at: location, in: geometry.size, from: tray.wearable)
            } isTargeted: {
                isDropTarget = $0
            }
            .overlay {
                if isDropTarget {
                    Rectangle()
                        .strokeBorder(Color.signal, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.impact(weight: .light), trigger: placements.count)
    }

    private var emptyCanvas: some View {
        VStack(spacing: 10) {
            Text("Build a fit")
                .font(.editorial(22))
                // The ground's own ink, not the app's: `Color.ink` inverts and this ground
                // does not, so on a dark phone the invitation was white on bone.
                .foregroundStyle(background.ink)
            Text("Drag anything below onto the canvas, or tap to drop it in. Move it with a finger, size it with the corner handle or a pinch.")
                .font(.editorial(14))
                .foregroundStyle(background.ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44)
        .allowsHitTesting(false)
    }

    // MARK: - Tray

    private func trayRow(_ tray: Tray) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FitGroundPicker(selection: $background)
                .padding(.horizontal, 20)

            if !tray.slots.isEmpty || proposal?.isEmpty == false {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        // First, and selected on the way in, when there is one: it is what the
                        // canvas was opened to show — what goes with the garment it is built
                        // around — and the whole wardrobe is one chip along.
                        if proposal?.isEmpty == false {
                            trayChip(label: "GOES WITH IT", isOn: shelf == .proposal) { shelf = .proposal }
                        }
                        trayChip(label: "ALL", isOn: shelf == .all) { shelf = .all }
                        ForEach(tray.slots, id: \.self) { slot in
                            trayChip(label: slot.label.uppercased(), isOn: shelf == .slot(slot)) {
                                shelf = shelf == .slot(slot) ? .all : .slot(slot)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }

            if shelf == .proposal, let proposal {
                proposalShelf(proposal)
            } else if tray.wearable.isEmpty {
                Text("Save a few things first — a fit is made from your collection.")
                    .font(.editorial(14))
                    .foregroundStyle(Color.muted)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(tray.items) { item in
                            Button { toggle(item) } label: {
                                TrayTile(item: item, isPlaced: chosen[item.id] != nil)
                            }
                            .buttonStyle(.plain)
                            // Lift-and-drag rather than a raw `DragGesture`: the tray is a
                            // horizontal scroller, and any gesture that begins on touch
                            // fights the scroll for the same finger. `.draggable` waits for
                            // the long press, so scrolling the tray still scrolls it.
                            .draggable(Self.dragPayload(for: item)) {
                                FitPieceImage(item: item)
                                    .frame(width: 110, height: 110)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: 204)
        .background(Color.wash.opacity(0.5))
    }

    /// The shortlist for every position the proposal can fill, head down, each position's best
    /// first — the studio's rows, laid end to end in the tray.
    ///
    /// A tap **swaps**: the piece takes the place, size and layer of whatever stood in that
    /// position, so trying three pairs of trousers is three taps rather than three removals and
    /// three re-arrangements. Tapping the one already down takes it off, which is the only way
    /// to say "no jacket" without hunting for a control that says so. Each tile says which
    /// position it stands in and the line `Pairing` gave it, because the row runs one position
    /// into the next and a suggestion nobody can account for is indistinguishable from a
    /// shuffle.
    private func proposalShelf(_ proposal: FitProposal) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(proposal.shelves) { shelf in
                    ForEach(shelf.options) { option in
                        Button { choose(option) } label: {
                            ShelfTile(option: option, isPlaced: chosen[option.id] != nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func trayChip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.wordmark(10, isOn ? .semibold : .regular))
                    .tracking(1.2)
                    .foregroundStyle(isOn ? Color.ink : Color.muted)
                Rectangle()
                    .fill(isOn ? Color.ink : Color.clear)
                    .frame(height: 1)
            }
            .fixedSize()
        }
        .buttonStyle(.borderless)
    }

    /// Filing a fit, which it has always been able to do — `Fit.board` nullifies exactly as
    /// `SavedItem.board` does and `SavedView` draws a board's fits alongside its saves.
    ///
    /// It was only ever *reachable*, though, when a board already existed: the whole menu
    /// was behind `if !boards.isEmpty`, so somebody who had never made one was shown no
    /// way to file anything and no hint that filing was possible. A menu that hides the
    /// thing you would use it for is worse than no menu.
    private var boardMenu: some View {
        Menu("File on a board", systemImage: "square.grid.2x2") {
            Button("New board…", systemImage: "plus") {
                newBoardName = ""
                isNamingBoard = true
            }
            if !boards.isEmpty {
                Divider()
                Button {
                    board = nil
                } label: {
                    Label("None", systemImage: board == nil ? "checkmark" : "")
                }
                ForEach(boards) { candidate in
                    Button {
                        board = candidate
                    } label: {
                        Label(candidate.name, systemImage: board?.id == candidate.id ? "checkmark" : "")
                    }
                }
            }
        }
    }

    private func createBoard() {
        let name = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let created = Board(name: name, sortIndex: (boards.map(\.sortIndex).max() ?? 0) + 1)
        context.insert(created)
        try? context.save()
        board = created
    }

    // MARK: - Editing

    /// A binding straight into the array, so a drag writes through to the model's shape
    /// rather than into per-piece state that then has to be reconciled on save.
    private func binding(for id: UUID) -> Binding<FitPlacement> {
        Binding(
            get: { placements.first { $0.itemID == id } ?? FitPlacement(itemID: id) },
            set: { updated in
                guard let index = placements.firstIndex(where: { $0.itemID == id }) else { return }
                placements[index] = updated
            }
        )
    }

    /// Tapping the tray drops a piece in; tapping it again takes it back out, so the tray
    /// doubles as the list of what is on the canvas.
    private func toggle(_ item: SavedItem) {
        if chosen[item.id] != nil {
            remove(item.id)
            return
        }
        let spot = Self.dropSpots[placements.count % Self.dropSpots.count]
        place(item, x: spot.x, y: spot.y)
    }

    /// A piece off the proposal's shelf: into its position, in place of whatever stood there.
    private func choose(_ option: FitProposal.Option) {
        let id = option.id
        if chosen[id] != nil {
            remove(id)
            return
        }
        if let occupant = positions.first(where: { $0.value == option.position })?.key,
           let index = placements.firstIndex(where: { $0.itemID == occupant }) {
            // The swap keeps the placement — where it was, how big, which way up, what it is
            // layered under — because those are what somebody may already have adjusted, and
            // the question being asked is only *which* trousers.
            placements[index].itemID = id
            chosen[occupant] = nil
            positions[occupant] = nil
        } else {
            // An empty position takes the spot the arrangement table gives it, so a cap added
            // from its shelf lands where a cap goes rather than at the next free drop spot.
            let layered = FitArrangement.isLayered(Array(positions.values) + [option.position])
            let spot = FitArrangement.spot(for: option.position, layered: layered)
            topZ += 1
            placements.append(
                FitPlacement(itemID: id, x: spot.x, y: spot.y, scale: spot.scale, rotation: 0, z: topZ)
            )
        }
        chosen[id] = .kept(option.save)
        positions[id] = option.position
        selected = id
    }

    /// A garment dragged out of the tray and let go over the canvas.
    ///
    /// Dropping something that is already placed **moves** it instead of adding a second
    /// copy: one saved thing is one garment, and two of the same jacket is not a fit — the
    /// tray marks what is already down for exactly this reason.
    private func drop(
        _ payloads: [String],
        at point: CGPoint,
        in size: CGSize,
        from wearable: [SavedItem]
    ) -> Bool {
        guard size.width > 0, size.height > 0,
              let id = payloads.compactMap(Self.itemID(fromPayload:)).first,
              let item = wearable.first(where: { $0.id == id })
        else { return false }

        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)

        if let index = placements.firstIndex(where: { $0.itemID == id }) {
            placements[index].x = x
            placements[index].y = y
            bringToFront(id)
        } else {
            place(item, x: x, y: y)
        }
        return true
    }

    private func place(_ item: SavedItem, x: Double, y: Double) {
        topZ += 1
        chosen[item.id] = .kept(item)
        placements.append(
            FitPlacement(itemID: item.id, x: x, y: y, scale: 0.8, rotation: 0, z: topZ)
        )
        selected = item.id
    }

    /// The canvas' own coordinate space, so a gesture inside a rotated, scaled piece can
    /// still speak in the frame the placement is stored against.
    private static let space = "fit-canvas"

    /// What a tray tile carries while it is being dragged.
    ///
    /// A plain `String` rather than a custom `Transferable`: a bespoke UTI has to be
    /// declared in the Info.plist to be legal, and this project has already been bitten by
    /// keys Xcode silently drops. The prefix is what makes the payload unambiguous —
    /// anything else dropped on the canvas, from this app or another, is refused rather
    /// than parsed hopefully.
    private nonisolated static let dragPrefix = "streetw:fit-piece:"

    private static func dragPayload(for item: SavedItem) -> String {
        dragPrefix + item.id.uuidString
    }

    /// `nonisolated` so it can be handed to `compactMap` as a function reference — a
    /// String in, a UUID out, and nothing on the main actor in between.
    private nonisolated static func itemID(fromPayload payload: String) -> UUID? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(dragPrefix.count)))
    }

    /// Where each new piece lands, in order.
    ///
    /// Spread across the canvas rather than stacked on one point, and roughly in the
    /// places an outfit already wants to occupy — top above bottom, shoes low, a bag out
    /// to the side. It is not a slot system and nothing is pinned there; it just means the
    /// first thing you do is adjust an arrangement instead of dragging six identical
    /// squares off each other.
    private static let dropSpots: [(x: Double, y: Double)] = [
        (0.5, 0.28), (0.5, 0.62), (0.32, 0.85), (0.74, 0.44),
        (0.26, 0.44), (0.72, 0.76), (0.5, 0.1), (0.5, 0.45)
    ]

    private func remove(_ id: UUID) {
        placements.removeAll { $0.itemID == id }
        chosen[id] = nil
        positions[id] = nil
        if selected == id { selected = nil }
    }

    private func bringToFront(_ id: UUID) {
        selected = id
        guard let index = placements.firstIndex(where: { $0.itemID == id }) else { return }
        topZ += 1
        placements[index].z = topZ
    }

    /// The other half of layering, and the only way to reach a piece a big coat has buried.
    /// `z` is sparse and unbounded in both directions, so this is one write too.
    private func sendToBack(_ id: UUID) {
        guard let index = placements.firstIndex(where: { $0.itemID == id }) else { return }
        placements[index].z = (placements.map(\.z).min() ?? 0) - 1
        selected = id
    }

    // MARK: - Persistence

    private func load() {
        guard let fit else {
            arrangeStarting()
            return
        }
        // Once, for the reason `arrangeStarting` gives: `onAppear` fires again whenever
        // something presented over the canvas goes away, and reloading would undo every move.
        guard !didArrangeStarting else { return }
        didArrangeStarting = true

        name = fit.name
        placements = fit.placements
        chosen = Dictionary(fit.items.map { ($0.id, Piece.kept($0)) }, uniquingKeysWith: { first, _ in first })
        board = fit.board
        background = fit.ground
        topZ = placements.map(\.z).max() ?? 0

        // The placements and the items are two lists describing the same outfit, and they
        // can fall out of step: a fit made before the canvas existed has items and no
        // placements at all, and a placement can outlive the item it names. Either way the
        // canvas opens blank while the *card* still draws the stored render — so the fit
        // looks intact everywhere except the one screen that can edit it, and Save then
        // writes that emptiness back over it. Reconciled on the way in, in both directions.
        placements.removeAll { chosen[$0.itemID] == nil }
        var placed = Set(placements.map(\.itemID))
        for item in fit.ordered where !placed.contains(item.id) {
            let spot = Self.dropSpots[placed.count % Self.dropSpots.count]
            topZ += 1
            placements.append(
                FitPlacement(itemID: item.id, x: spot.x, y: spot.y, scale: 0.85, z: topZ)
            )
            placed.insert(item.id)
        }
    }

    /// Lays out whatever this fit was opened with, once.
    ///
    /// Once, because `onAppear` fires again whenever something presented over the canvas goes
    /// away, and re-running this would undo every move made since. Every machine arrangement
    /// goes through `FitArrangement`, the one table that lays a fit out — the studio had a
    /// private table and `StyleView.keep` had none, and the two disagreed about the same
    /// outfit.
    private func arrangeStarting() {
        guard !didArrangeStarting else { return }
        didArrangeStarting = true
        board = startingBoard

        switch starting {
        case .pieces(let items):
            arrange(items)
        case .suggestion(let suggestion):
            arrange(suggestion)
        case .around(let subject, let anchor):
            arrange(around: subject, anchor: anchor)
        }
        topZ = placements.map(\.z).max() ?? 0
    }

    /// A selection from the wall. Two pieces that belong in the same position — two pairs of
    /// trousers selected together — are stepped apart rather than stacked exactly, or the
    /// second is invisible under the first and the canvas looks as if it dropped one.
    private func arrange(_ items: [SavedItem]) {
        let garments = items.compactMap { item in item.update.map { (item: item, garment: $0.garment) } }
        guard !garments.isEmpty else { return }
        let splitting = garments.count { $0.garment.slot == .top } > 1
        let arranged = garments.map {
            (position: FitArrangement.position(for: $0.garment, splittingTops: splitting), itemID: $0.item.id)
        }

        var taken: [FitPosition: Int] = [:]
        placements = zip(arranged, FitArrangement.placements(for: arranged)).map { piece, placement in
            let step = Double(taken[piece.position, default: 0])
            taken[piece.position, default: 0] += 1
            var stepped = placement
            stepped.x = min(max(placement.x + step * 0.07, 0.1), 0.9)
            stepped.y = min(max(placement.y + step * 0.05, 0.1), 0.9)
            return stepped
        }
        chosen = Dictionary(garments.map { ($0.item.id, Piece.kept($0.item)) }, uniquingKeysWith: { first, _ in first })
    }

    /// A proposal off the fit row, laid out as the card drew it. A garment it borrowed from
    /// the catalogue waits on the canvas unsaved — see `Piece` — so trying a proposal and
    /// closing it keeps nothing, where tapping the card used to keep the fit *and* the
    /// borrowed piece in one go.
    private func arrange(_ suggestion: SuggestedFit) {
        let ordered = suggestion.ordered
        // Split tops only when the proposal actually holds two, so a fit of one tee and one
        // pair of trousers is laid out exactly as it always was.
        let splitting = ordered.filter { $0.update.garment.slot == .top }.count > 1
        var arranged: [(position: FitPosition, itemID: UUID)] = []
        for piece in ordered {
            let subject = FitSubject.product(piece.update)
            if let save = piece.save ?? subject.existingSave {
                chosen[save.id] = .kept(save)
                arranged.append((FitArrangement.position(for: piece.update.garment, splittingTops: splitting), save.id))
            } else {
                let key = UUID()
                chosen[key] = .pending(subject)
                arranged.append((FitArrangement.position(for: piece.update.garment, splittingTops: splitting), key))
            }
        }
        placements = FitArrangement.placements(for: arranged)
    }

    /// An outfit around one garment: the subject in its position, the proposal's opening in
    /// theirs, and the tray turned to the shortlist.
    private func arrange(around subject: FitSubject, anchor: String?) {
        let built = FitProposal(
            around: subject,
            anchor: anchor,
            saves: saves,
            boards: boards,
            statement: statement.statement
        )
        proposal = built

        // Something already kept goes down as itself; anything else waits to be kept.
        let key = subject.existingSave?.id ?? UUID()
        chosen[key] = subject.existingSave.map(Piece.kept) ?? .pending(subject)
        var arranged: [(position: FitPosition, itemID: UUID)] = [(built.subjectPosition, key)]
        for option in built.opening {
            chosen[option.id] = .kept(option.save)
            arranged.append((option.position, option.id))
        }
        placements = FitArrangement.placements(for: arranged)
        positions = Dictionary(arranged.map { ($0.itemID, $0.position) }, uniquingKeysWith: { first, _ in first })
        if !built.isEmpty { shelf = .proposal }
    }

    private func save() {
        // **Every piece becomes a save here and nowhere earlier** — a garment borrowed from a
        // product page, a Discover card or the catalogue is kept at the moment the outfit is,
        // which is the honest reading of the tap and the one moment the deck's no-pollution
        // rule allows a discovery card a row. Its placement is re-keyed onto the save it became.
        var items: [SavedItem] = []
        var stored: [FitPlacement] = []
        var garments: [Garment] = []
        for placement in placements {
            guard let piece = chosen[placement.itemID] else { continue }
            // Read before resolving: a discovery card's measured colour is on the card.
            let garment = piece.garment
            guard let item = piece.resolve(in: context),
                  !items.contains(where: { $0.id == item.id })
            else { continue }
            items.append(item)
            var keyed = placement
            keyed.itemID = item.id
            stored.append(keyed)
            if let garment { garments.append(garment) }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let target = fit ?? Fit()
        // **What the card under it says when nobody has named it** (`Fit.verdict`), worked out
        // by the one editor whichever way the fit was begun. It used to be written only by the
        // two machine paths, so a fit arranged here by hand went nameless while the same
        // garments kept off the row said "Olive against neutrals". Rewritten only when the
        // garments change: it is a sentence about which clothes are in the fit, and moving
        // them about says nothing new.
        if fit == nil || Set(target.items.map(\.id)) != Set(items.map(\.id)) {
            target.verdict = Outfit.score(garments, statement: statement.statement).reason
        }
        target.name = trimmed
        target.items = items
        target.placements = stored
        target.board = board
        target.backgroundName = background.rawValue
        if fit == nil { context.insert(target) }

        // Written before the render, so the canvas it draws is the one being saved.
        try? context.save()
        // A new fit, not an edit — re-saving one somebody already made is not another outfit.
        if fit == nil { UsageCounts.record(.fitCreated) }

        // The sheet closes now rather than waiting on the render. Everything the canvas
        // needs is already decoded — it was just on screen — so the warm-up is normally
        // instant, and a fit that has to re-fetch a photograph must not hold the UI.
        Task {
            // A render is only written when every piece actually decoded. `ImageRenderer`
            // draws one frame synchronously, so a piece still loading comes out as an empty
            // rectangle — and that gets written to disk and shown on the card *for as long
            // as the fit exists*, since nothing recomputes a render that already succeeded.
            // Saving a fit a second after opening it produced exactly that: a picture of
            // two garments and two grey squares. Better to keep the previous render, or
            // none at all and let the card draw the live surface, than to bake in a hole.
            guard await FitRender.warm(target), !target.isGone else { return }
            let file = await FitRender.write(target)
            // Checked once more: `write` renders and encodes, and the delete can land in
            // the middle of that. Assigning a stored property on a deleted `@Model` traps.
            guard !target.isGone, let file else { return }
            target.renderFile = file
            try? context.save()
        }
        dismiss()
    }

    private func delete(_ fit: Fit) {
        if let render = fit.renderFile { FitRender.remove(render) }
        context.delete(fit)
        try? context.save()
        dismiss()
    }
}

// MARK: - One piece on the canvas

/// A garment you can move, scale and turn.
///
/// Gestures are `simultaneously` rather than exclusive: pinching an object almost always
/// drifts it a little, and a pinch that cancels the moment your fingers move is the single
/// most frustrating thing a canvas can do. Each gesture keeps a live delta and commits it
/// on end, so the stored placement is never mid-gesture — which matters because that
/// placement is also what the render and the model read.
///
/// Size is carried by the **frame**, not by a `scaleEffect`. For a `scaledToFit` image the
/// two draw the same pixels, but a scale effect multiplies everything laid over the piece
/// with it — so the selection outline thickened, and the handles would have been thumbnails
/// on a big jacket and specks on a small ring. Framing the piece at its drawn size leaves
/// the chrome in screen units, where a touch target has to live.
private struct PlacedPiece: View {
    let piece: FitCanvas.Piece
    @Binding var placement: FitPlacement
    let canvas: CGSize
    let space: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onSendToBack: () -> Void
    let onRemove: () -> Void

    @State private var drag: CGSize = .zero
    @State private var pinch: CGFloat = 1
    @State private var twist: Angle = .zero

    /// Live deltas for the corner handle, committed on end exactly as the pinch is.
    @State private var handleScale: CGFloat = 1
    @State private var handleTwist: Angle = .zero
    /// The last angle the handle was seen at, so a turn past half a revolution keeps
    /// counting instead of snapping back the other way when `atan2` wraps.
    @State private var handleAngle: Double?

    /// The nominal size of a piece at scale 1 — a bit under half the canvas, so a first
    /// drop reads as one garment among several rather than as a full-bleed photograph.
    private var side: CGFloat { min(canvas.width, canvas.height) * 0.42 }

    private var drawn: CGFloat { side * placement.scale * pinch * handleScale }

    private var angle: Angle { .radians(placement.rotation) + twist + handleTwist }

    /// Where the piece is anchored, ignoring an in-flight move.
    private var centre: CGPoint {
        CGPoint(x: placement.x * canvas.width, y: placement.y * canvas.height)
    }

    private var position: CGPoint {
        CGPoint(x: centre.x + drag.width, y: centre.y + drag.height)
    }

    var body: some View {
        ZStack {
            CanvasPieceImage(piece: piece)
                .frame(width: drawn, height: drawn)
            if isSelected {
                chrome.frame(width: drawn, height: drawn)
            }
        }
        // Room for the handles to sit *on* the corners rather than beyond the bounds.
        // A view drawn outside its parent is one clip away from being untappable, and the
        // padding costs nothing: it is empty, so it draws nothing and catches no touch —
        // which is what keeps the gap between two pieces from stealing a drag.
        .padding(Handle.touch / 2)
        .rotationEffect(angle)
        .position(position)
        .gesture(move)
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Send to back", systemImage: "square.3.layers.3d.bottom.filled", action: onSendToBack)
            Button("Reset size", systemImage: "arrow.counterclockwise") {
                placement.scale = 0.8
                placement.rotation = 0
            }
            Button("Take off the canvas", systemImage: "minus.circle", role: .destructive, action: onRemove)
        }
    }

    // MARK: - Chrome

    /// Drawn only while selected, and only ever two controls. A canvas covered in handles
    /// is a form again.
    private var chrome: some View {
        Rectangle()
            .stroke(Color.signal, lineWidth: 1)
            .overlay(alignment: .topLeading) {
                Handle(icon: "xmark")
                    .offset(x: -Handle.touch / 2, y: -Handle.touch / 2)
                    .onTapGesture(perform: onRemove)
            }
            .overlay(alignment: .bottomTrailing) {
                Handle(icon: "arrow.up.left.and.arrow.down.right")
                    .offset(x: Handle.touch / 2, y: Handle.touch / 2)
                    .highPriorityGesture(resize)
            }
    }

    // MARK: - Gestures

    private var move: some Gesture {
        DragGesture()
            .onChanged { value in
                if !isSelected { onSelect() }
                drag = value.translation
            }
            .onEnded { value in
                // Clamped to the canvas. The canvas clips, so an unclamped drag can post a
                // garment off the edge into somewhere it can never be grabbed back from —
                // the centre staying on means every piece is always reachable, while half
                // of one can still bleed off the side, which is a real collage move.
                placement.x = clamped(placement.x + value.translation.width / canvas.width, 0, 1)
                placement.y = clamped(placement.y + value.translation.height / canvas.height, 0, 1)
                drag = .zero
            }
            .simultaneously(with: MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { value in
                    // Clamped: a piece scaled to nothing can't be grabbed again,
                    // and one scaled past the canvas hides everything under it.
                    placement.scale = clamped(placement.scale * value.magnification, Self.minScale, Self.maxScale)
                    pinch = 1
                }
            )
            .simultaneously(with: RotateGesture()
                .onChanged { twist = $0.rotation }
                .onEnded { value in
                    placement.rotation += value.rotation.radians
                    twist = .zero
                }
            )
    }

    /// One finger on the corner: distance from the centre is the size, and the angle around
    /// it is the turn.
    ///
    /// Both at once on purpose. The handle sits on a corner, and a corner has no meaning
    /// other than "this point of the garment" — dragging it along an axis while the piece
    /// stays upright is a rectangle's idea of resizing, not a sticker's. The gesture reads
    /// in the **canvas** coordinate space because the handle it starts on is itself
    /// rotating and scaling as the drag proceeds; measured locally it would be chasing its
    /// own tail.
    private var resize: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                if !isSelected { onSelect() }
                let start = polar(of: value.startLocation)
                let now = polar(of: value.location)

                handleScale = now.radius / start.radius

                var step = now.angle - (handleAngle ?? start.angle)
                step = atan2(sin(step), cos(step))
                handleTwist = handleTwist + .radians(step)
                handleAngle = now.angle
            }
            .onEnded { _ in
                placement.scale = clamped(placement.scale * handleScale, Self.minScale, Self.maxScale)
                placement.rotation += handleTwist.radians
                handleScale = 1
                handleTwist = .zero
                handleAngle = nil
            }
    }

    /// A point on the canvas, as distance and bearing from the piece's centre. The radius
    /// has a floor because a drag that starts on the centre would otherwise divide by zero
    /// and blow the piece up to the clamp in one frame.
    private func polar(of point: CGPoint) -> (radius: CGFloat, angle: Double) {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        return (max(hypot(dx, dy), 1), atan2(Double(dy), Double(dx)))
    }

    private func clamped(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    private static let minScale: Double = 0.2
    private static let maxScale: Double = 3
}

/// A corner control on the selected piece.
///
/// Visibly small, because it sits over a photograph; touchable at 36pt, because a finger is
/// not. The two sizes are separate for that reason and the offsets that place these on a
/// corner are measured against the touch box, not the ink.
private struct Handle: View {
    let icon: String

    static let ink: CGFloat = 26
    static let touch: CGFloat = 36

    var body: some View {
        Color.clear
            .frame(width: Self.touch, height: Self.touch)
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.paper)
                    .frame(width: Self.ink, height: Self.ink)
                    .background(Circle().fill(Color.ink))
                    .overlay(Circle().stroke(Color.paper, lineWidth: 1))
            }
            .contentShape(.circle)
    }
}

/// The sticker, or the photograph when there is no sticker.
///
/// A cutout is a local file and deliberately not routed through `CachedImage`: there is no
/// network, no retry and no CDN rendition to negotiate, and `UIImage(contentsOfFile:)`
/// decodes lazily. The fallback matters as much as the cutout — plenty of items have no
/// single subject to lift, and a canvas that silently omits them would look broken.
struct FitPieceImage: View {
    /// The product to draw. Everything this view reads has always come off the
    /// `BrandUpdate` rather than off the save, so taking it directly is what lets a
    /// suggestion draw a garment nobody has kept — see `FitPiece`.
    let update: BrandUpdate?

    init(update: BrandUpdate?) {
        self.update = update
    }

    init(item: SavedItem) {
        self.update = item.update
    }

    /// How wide the photograph is asked for when there is no cutout. Also what
    /// `FitRender.warm` preloads at, and the two must agree or the renderer finds an empty
    /// cache and draws nothing.
    static let drawnWidth = 400

    /// Cached, because this is read from a body that re-evaluates on every frame of a drag.
    /// See `LocalImage`.
    private var cutout: UIImage? {
        LocalImage.load(update?.cutoutURL)
    }

    /// The photograph to fall back to when there is no cutout — the **packshot**, not the
    /// lead shot.
    ///
    /// They are usually the same photograph and on a lookbook-first brand they are not: a
    /// Stüssy shirt's lead image is a model in trousers and boots, and dropping that onto a
    /// fit as a stand-in for a shirt is worse than dropping nothing. `ProductShot` decides;
    /// this only has to ask. Nil until the item has been analysed, which is why the lead
    /// shot remains the fallback's fallback.
    ///
    /// **`FitRender.warm` must ask for the same URL at the same width**, or the renderer
    /// finds an empty cache and writes a fit with a hole in it.
    static func source(for item: SavedItem) -> URL? {
        source(for: item.update)
    }

    static func source(for update: BrandUpdate?) -> URL? {
        update?.packshotURL ?? update?.primaryImageURL
    }

    /// The photograph, but only if it is already decoded.
    ///
    /// This is what makes a fit renderable. `ImageRenderer` draws one frame, synchronously,
    /// and never gives an async load a chance to finish — so a canvas built out of
    /// `CachedImage` renders as a stack of empty tiles, which is exactly what the first
    /// saved fit produced. Reading the decoded cache directly gives the renderer a real
    /// image; `FitRender.warm` is what guarantees it is there.
    private var warmed: UIImage? {
        Self.source(for: update)
            .map { ImageRendition.sized($0, width: Self.drawnWidth) }
            .flatMap { ImageLoader.shared.cached($0) }
    }

    var body: some View {
        if let image = cutout ?? warmed {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            // Not yet decoded: on screen this fills in a moment later. A renderer never
            // reaches here, because it warms the cache first.
            UpdateImage(
                url: Self.source(for: update),
                aspect: 1,
                contentMode: .fit,
                drawnWidth: Self.drawnWidth
            )
        }
    }
}

/// The row of grounds a fit can be arranged on.
///
/// **Swatches, not a menu.** A colour named "Clay" in a list is a word; the whole question here
/// is what the garments look like against it, so the choice has to be visible and one tap away
/// — the same argument that moved the Discover filter out of a funnel glyph and into a row of
/// words. It is deliberately a short row of fixed grounds rather than a colour picker: see
/// `FitBackground`.
struct FitGroundPicker: View {
    @Binding var selection: FitBackground

    /// What the wheel is currently showing. Held separately from `selection` because a
    /// `ColorPicker` binding is written continuously while somebody drags — every frame of it
    /// would otherwise mint a new `.custom` ground and rewrite the fit's stored token.
    @State private var chosen: Color = .white

    /// Whether the selection is a colour somebody mixed rather than one of the seven.
    private var isCustom: Bool {
        !FitBackground.presets.contains(selection)
    }

    var body: some View {
        HStack(spacing: 10) {
            DataLabel(text: "GROUND", size: 9)

            ForEach(FitBackground.presets) { ground in
                Button {
                    selection = ground
                } label: {
                    swatch(ground.color, isOn: selection == ground)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(ground.label)
            }

            // **The way past the seven.** A wheel rather than an eighth swatch, and it sits
            // at the end rather than replacing anything: the short list is still the argument
            // — see `FitBackground` — and this is the answer to the one case it cannot cover,
            // a ground picked to sit against one particular garment.
            //
            // The label is the swatch itself, so the control reads as one more ground in the
            // row rather than as a system component parachuted into it, and it carries the
            // same selection ring as its neighbours. The `+` shows only while none of them is
            // selected; once it is, the swatch *is* the colour and a glyph over it would be
            // covering the only thing worth seeing.
            ColorPicker(selection: $chosen, supportsOpacity: false) {
                EmptyView()
            }
            .labelsHidden()
            .opacity(0.02)
            .frame(width: 26, height: 26)
            .background {
                swatch(isCustom ? selection.color : Color.wash, isOn: isCustom)
                    .overlay {
                        if !isCustom {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.muted)
                        }
                    }
            }
            .accessibilityLabel("Custom ground")

            Spacer(minLength: 0)
        }
        .frame(height: 28)
        // Written back only when the wheel actually lands somewhere new, and through
        // `chosen(_:)` so picking a colour that *is* one of the seven selects that swatch
        // rather than minting an identical-looking eighth beside it.
        .onChange(of: chosen) { _, colour in
            selection = FitBackground.chosen(colour)
        }
        // Seeding the wheel from the fit's own ground, so reopening a fit that already has a
        // custom colour opens the picker on that colour rather than on white.
        .onAppear { chosen = selection.color }
    }

    /// One ground in the row. The mark is a ring rather than a tick: a tick has to be drawn
    /// *on* the swatch, which means picking a colour to draw it in that reads on all of them
    /// — and on chalk and on slate it cannot be the same one.
    private func swatch(_ color: Color, isOn: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay { Circle().stroke(Color.hairline, lineWidth: 0.5) }
            .overlay {
                if isOn {
                    Circle().stroke(Color.ink, lineWidth: 1.5).padding(-3)
                }
            }
            .contentShape(.circle)
    }
}

/// One garment in the tray, with a mark when it is already on the canvas.
private struct TrayTile: View {
    let item: SavedItem
    let isPlaced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FitPieceImage(item: item)
                .frame(width: 76, height: 76)
                .background(Color.paper)
                .overlay {
                    if isPlaced { Rectangle().stroke(Color.ink, lineWidth: 1.5) }
                }
                .opacity(isPlaced ? 0.45 : 1)

            Text(item.update?.title ?? "")
                .font(.editorial(10))
                .foregroundStyle(Color.muted)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
        }
    }
}

/// One candidate on the proposal's shelf: where it would go, and why it is in the running.
///
/// The position rather than the title, because the shelf runs one position into the next and
/// the photograph already says what the garment is. The reason is the line `Pairing` actually
/// used — the contract `PairingTile` holds — and prints nothing rather than filler when nothing
/// has been measured, which in the Simulator is always.
private struct ShelfTile: View {
    let option: FitProposal.Option
    let isPlaced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FitPieceImage(update: option.update)
                .frame(width: 76, height: 76)
                .background(Color.paper)
                .overlay {
                    if isPlaced { Rectangle().stroke(Color.ink, lineWidth: 1.5) }
                }
                .padding(.bottom, 2)

            DataLabel(
                text: option.position.label.uppercased(),
                size: 9,
                color: isPlaced ? .ink : .muted
            )
            .lineLimit(1)
            if let reason = option.reason {
                DataLabel(text: reason.uppercased(), size: 8)
                    .lineLimit(1)
            }
        }
        .frame(width: 76, alignment: .leading)
        .contentShape(.rect)
    }
}

/// A piece on the canvas, drawn as whatever the app actually has of it.
private struct CanvasPieceImage: View {
    let piece: FitCanvas.Piece

    var body: some View {
        switch piece {
        case .kept(let save): FitPieceImage(item: save)
        case .pending(let subject): FitSubjectImage(subject: subject)
        }
    }
}

/// A garment nobody has kept yet, drawn as whatever the app has of it.
///
/// A `BrandUpdate` goes through `FitPieceImage`, which is what every other surface uses. A
/// discovery card has no row and therefore no cutout file — but `DiscoveryAnalysis` lifts a
/// sticker in memory for the cards at the viewport, so where that ran the piece lands on the
/// canvas cut out, exactly like the wardrobe pieces beside it. Where it did not — the
/// photograph is still decoding, or this is the Simulator, where Vision's subject lifting does
/// not run at all — it degrades to the photograph, which is what `FitPieceImage` does too.
///
/// **The fallback is the packshot, not the lead shot**, for the reason `FitPieceImage` prefers
/// `packshotURL`. A gallery's order is a merchandising decision: Stüssy leads with four model
/// shots, so falling back to the first frame drops a whole person in trousers and boots into
/// somebody's outfit as a stand-in for a t-shirt. The *card* still shows the lead — on a model
/// is how the brand wants the garment seen.
private struct FitSubjectImage: View {
    let subject: FitSubject

    var body: some View {
        switch subject {
        case .product(let update):
            FitPieceImage(update: update)
        case .discovery(let card, let sticker, _, let packshot):
            if let sticker {
                Image(uiImage: sticker).resizable().scaledToFit()
            } else {
                UpdateImage(
                    url: packshot ?? card.imageURLs.first.flatMap(URL.init(string:)),
                    aspect: 1,
                    contentMode: .fit,
                    drawnWidth: FitPieceImage.drawnWidth,
                    backdrop: .clear,
                    mark: card.brand.name
                )
            }
        }
    }
}

// MARK: - Drawing a fit outside the editor

/// The canvas without the editing, used by the renderer and by anything that wants to draw
/// a fit at an arbitrary size.
///
/// Normalised placements are what make this work: the same structure lays out identically
/// at 900px for a render and at 168pt for a card, so there is exactly one description of
/// what a fit looks like.
struct FitCanvasSurface: View {
    let fit: Fit
    var isEditing = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The ground is read from the fit, and a fit deleted while this was on
                // screen answers with the default rather than trapping — see `Fit.isGone`.
                // **The fit's own ground, drawn here rather than by each caller.** The
                // renderer used to lay the canvas over an adaptive `Color.paper`, so a fit
                // saved after dark had a near-black backdrop written into its PNG for good —
                // and the card, the share sheet and the editor could all disagree about what
                // the same outfit was arranged on. One place, fixed colours: see
                // `FitBackground`.
                fit.ground.color
                ForEach(fit.placed, id: \.placement.itemID) { entry in
                    // Framed at the drawn size rather than scaled, matching the editor —
                    // and a scale effect would enlarge the *rendered* tile, so a piece
                    // blown up on a 900px render would come out of a 400pt drawing.
                    let side = min(geometry.size.width, geometry.size.height) * 0.42 * entry.placement.scale
                    FitPieceImage(item: entry.item)
                        .frame(width: side, height: side)
                        .rotationEffect(.radians(entry.placement.rotation))
                        .position(
                            x: entry.placement.x * geometry.size.width,
                            y: entry.placement.y * geometry.size.height
                        )
                }
            }
        }
        .clipped()
    }
}
