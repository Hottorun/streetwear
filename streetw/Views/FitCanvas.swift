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

import StreetwCore
import SwiftData
import SwiftUI

struct FitCanvas: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    /// Nil when composing a new fit.
    let fit: Fit?

    @State private var name = ""
    @State private var placements: [FitPlacement] = []
    @State private var chosen: [UUID: SavedItem] = [:]
    @State private var selected: UUID?
    @State private var trayFilter: GarmentSlot?
    @State private var board: Board?
    @State private var isNaming = false
    @State private var isDropTarget = false
    @State private var isNamingBoard = false
    @State private var newBoardName = ""

    /// Only ever grows. Sparse z values mean bringing something to the front is one write
    /// rather than renumbering everything behind it.
    @State private var topZ = 0

    private var wearable: [SavedItem] { saves.filter { $0.update != nil } }

    private var trayItems: [SavedItem] {
        guard let trayFilter else { return wearable }
        return wearable.filter { $0.slot == trayFilter }
    }

    /// Slots that actually have something in them, in the order a fit is read.
    private var traySlots: [GarmentSlot] {
        Array(Set(wearable.map(\.slot)))
            .filter { $0 != .unknown }
            .sorted { $0.stackOrder < $1.stackOrder }
    }

    private var placedItems: [(item: SavedItem, placement: FitPlacement)] {
        placements
            .compactMap { placement in chosen[placement.itemID].map { (item: $0, placement: placement) } }
            .sorted { $0.placement.z < $1.placement.z }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvas
                Rule()
                tray
            }
            .background(Color.paper)
            .navigationTitle(fit == nil ? "New fit" : "Edit fit")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { cancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Name this fit", systemImage: "textformat") { isNaming = true }
                        boardMenu
                        if !placements.isEmpty {
                            Button("Clear canvas", systemImage: "trash", role: .destructive) {
                                placements = []
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
        }
        .tint(.ink)
        .onAppear(perform: load)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color.paper
                    // Tapping the backdrop deselects. Without it the last piece touched
                    // keeps its outline for the rest of the session and reads as stuck.
                    .contentShape(.rect)
                    .onTapGesture { selected = nil }

                ForEach(placedItems, id: \.placement.itemID) { entry in
                    PlacedPiece(
                        item: entry.item,
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
                drop(payloads, at: location, in: geometry.size)
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
                .foregroundStyle(Color.ink)
            Text("Drag anything below onto the canvas, or tap to drop it in. Move it with a finger, size it with the corner handle or a pinch.")
                .font(.editorial(14))
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44)
        .allowsHitTesting(false)
    }

    // MARK: - Tray

    private var tray: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !traySlots.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        trayChip(label: "ALL", isOn: trayFilter == nil) { trayFilter = nil }
                        ForEach(traySlots, id: \.self) { slot in
                            trayChip(label: slot.label.uppercased(), isOn: trayFilter == slot) {
                                trayFilter = trayFilter == slot ? nil : slot
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }

            if wearable.isEmpty {
                Text("Save a few things first — a fit is made from your collection.")
                    .font(.editorial(14))
                    .foregroundStyle(Color.muted)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(trayItems) { item in
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
        .frame(height: 168)
        .background(Color.wash.opacity(0.5))
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

    /// A garment dragged out of the tray and let go over the canvas.
    ///
    /// Dropping something that is already placed **moves** it instead of adding a second
    /// copy: one saved thing is one garment, and two of the same jacket is not a fit — the
    /// tray marks what is already down for exactly this reason.
    private func drop(_ payloads: [String], at point: CGPoint, in size: CGSize) -> Bool {
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
        chosen[item.id] = item
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
        guard let fit else { return }
        name = fit.name
        placements = fit.placements
        chosen = Dictionary(fit.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        board = fit.board
        topZ = placements.map(\.z).max() ?? 0

        // A fit made before the canvas existed has items and no placements. Rather than
        // opening empty — which would read as data loss — its pieces are laid out down the
        // middle in the order a fit is read, which is what the old stacked card drew.
        if placements.isEmpty, !fit.items.isEmpty {
            for (index, item) in fit.ordered.enumerated() {
                topZ += 1
                placements.append(
                    FitPlacement(
                        itemID: item.id,
                        x: 0.5,
                        y: 0.2 + Double(index) * 0.22,
                        scale: 0.9,
                        z: topZ
                    )
                )
            }
        }
    }

    private func save() {
        let items = placements.compactMap { chosen[$0.itemID] }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let target = fit ?? Fit()
        target.name = trimmed
        target.items = items
        target.placements = placements
        target.board = board
        if fit == nil { context.insert(target) }

        // Written before the render, so the canvas it draws is the one being saved.
        try? context.save()

        // The sheet closes now rather than waiting on the render. Everything the canvas
        // needs is already decoded — it was just on screen — so the warm-up is normally
        // instant, and a fit that has to re-fetch a photograph must not hold the UI.
        Task {
            await FitRender.warm(target)
            target.renderFile = FitRender.write(target)
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

    /// A fit created by keeping a suggestion is inserted *before* this sheet opens, so
    /// cancelling has to undo it — otherwise backing out leaves an outfit you never
    /// confirmed.
    private func cancel() {
        if let fit, fit.name.isEmpty, fit.placements.isEmpty, fit.renderFile == nil {
            context.delete(fit)
            try? context.save()
        }
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
    let item: SavedItem
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
            FitPieceImage(item: item)
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
    let item: SavedItem

    /// How wide the photograph is asked for when there is no cutout. Also what
    /// `FitRender.warm` preloads at, and the two must agree or the renderer finds an empty
    /// cache and draws nothing.
    static let drawnWidth = 400

    private var cutout: UIImage? {
        item.update?.cutoutURL.flatMap { UIImage(contentsOfFile: $0.path(percentEncoded: false)) }
    }

    /// The photograph, but only if it is already decoded.
    ///
    /// This is what makes a fit renderable. `ImageRenderer` draws one frame, synchronously,
    /// and never gives an async load a chance to finish — so a canvas built out of
    /// `CachedImage` renders as a stack of empty tiles, which is exactly what the first
    /// saved fit produced. Reading the decoded cache directly gives the renderer a real
    /// image; `FitRender.warm` is what guarantees it is there.
    private var warmed: UIImage? {
        item.update?.primaryImageURL
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
                url: item.update?.primaryImageURL,
                aspect: 1,
                contentMode: .fit,
                drawnWidth: Self.drawnWidth
            )
        }
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
