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
                        isSelected: selected == entry.placement.itemID,
                        onSelect: { bringToFront(entry.placement.itemID) },
                        onRemove: { remove(entry.placement.itemID) }
                    )
                }

                if placements.isEmpty { emptyCanvas }
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyCanvas: some View {
        VStack(spacing: 10) {
            Text("Build a fit")
                .font(.editorial(22))
                .foregroundStyle(Color.ink)
            Text("Tap anything below to drop it in. Drag to move, pinch to size, twist to turn.")
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
                            Button { add(item) } label: {
                                TrayTile(item: item, isPlaced: chosen[item.id] != nil)
                            }
                            .buttonStyle(.plain)
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

    @ViewBuilder
    private var boardMenu: some View {
        if !boards.isEmpty {
            Menu("File on a board", systemImage: "square.grid.2x2") {
                Button("None") { board = nil }
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
    private func add(_ item: SavedItem) {
        if chosen[item.id] != nil {
            remove(item.id)
            return
        }
        topZ += 1
        chosen[item.id] = item
        let spot = Self.dropSpots[placements.count % Self.dropSpots.count]
        placements.append(
            FitPlacement(
                itemID: item.id,
                x: spot.x,
                y: spot.y,
                scale: 0.8,
                rotation: 0,
                z: topZ
            )
        )
        selected = item.id
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
private struct PlacedPiece: View {
    let item: SavedItem
    @Binding var placement: FitPlacement
    let canvas: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var drag: CGSize = .zero
    @State private var pinch: CGFloat = 1
    @State private var twist: Angle = .zero

    /// The nominal size of a piece at scale 1 — a bit under half the canvas, so a first
    /// drop reads as one garment among several rather than as a full-bleed photograph.
    private var side: CGFloat { min(canvas.width, canvas.height) * 0.42 }

    private var position: CGPoint {
        CGPoint(
            x: placement.x * canvas.width + drag.width,
            y: placement.y * canvas.height + drag.height
        )
    }

    var body: some View {
        FitPieceImage(item: item)
            .frame(width: side, height: side)
            .scaleEffect(placement.scale * pinch)
            .rotationEffect(.radians(placement.rotation) + twist)
            .overlay {
                if isSelected {
                    Rectangle()
                        .stroke(Color.signal, lineWidth: 1)
                        .scaleEffect(placement.scale * pinch)
                        .rotationEffect(.radians(placement.rotation) + twist)
                }
            }
            .position(position)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isSelected { onSelect() }
                        drag = value.translation
                    }
                    .onEnded { value in
                        placement.x += value.translation.width / canvas.width
                        placement.y += value.translation.height / canvas.height
                        drag = .zero
                    }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { pinch = $0.magnification }
                        .onEnded { value in
                            // Clamped: a piece scaled to nothing can't be grabbed again,
                            // and one scaled past the canvas hides everything under it.
                            placement.scale = min(max(placement.scale * value.magnification, 0.2), 3)
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
            )
            .onTapGesture { onSelect() }
            .contextMenu {
                Button("Take off the canvas", systemImage: "minus.circle", role: .destructive, action: onRemove)
            }
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
                    let side = min(geometry.size.width, geometry.size.height) * 0.42
                    FitPieceImage(item: entry.item)
                        .frame(width: side, height: side)
                        .scaleEffect(entry.placement.scale)
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
