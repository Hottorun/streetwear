// QuickSave.swift
// The two things you do to a card in the feed, on the two directions available.
//
// - **Right — read it.** Dismissing is by far the commonest action: most of a drop is
//   things you don't want, and clearing them is how the feed gets back to empty. It
//   takes no decision, so it takes no dialog.
// - **Left — file it.** This one *is* a decision — which board — so it opens a picker.
//   A gesture cannot express "which of six", and guessing would be worse than asking.
//
// The asymmetry is the point: the frequent, decisionless action is instant, and the rare
// one that needs a choice gets a choice. Both name what they'll do under your thumb while
// you drag, so neither has to be explained.
//
// **The card moves as one piece, but only the caption listens.** Product photographs page
// horizontally now, and that is the same gesture. Attaching the drag to the whole card
// would mean the photograph could never page; attaching it to nothing would lose the
// actions. So the modifier offsets the entire card — it has to, or the hint appears
// beside a card that hasn't moved — while `quickSaveHandle()` marks the region that
// actually recognises the drag. In practice that is everything below the image.

import SwiftData
import SwiftUI

struct QuickSaveModifier: ViewModifier {
    @Environment(\.modelContext) private var context

    let update: BrandUpdate

    @State private var offset: CGFloat = 0
    @State private var isChoosingBoard = false
    @State private var didMarkRead = false

    /// Far enough that a scroll can't trigger it, close enough for one thumb.
    private static let threshold: CGFloat = 78

    private enum Intent {
        case markRead
        case file

        var label: String {
            switch self {
            case .markRead: "READ"
            case .file: "ADD TO BOARD"
            }
        }
    }

    private var pending: Intent? {
        if offset > 24 { return .markRead }
        if offset < -24 { return .file }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .environment(\.quickSaveDrag, drag)
            .offset(x: offset)
            .background(alignment: offset > 0 ? .leading : .trailing) { hint }
            .animation(.interactiveSpring(duration: 0.25), value: offset)
            .sensoryFeedback(.success, trigger: didMarkRead)
            .sheet(isPresented: $isChoosingBoard) {
                BoardPicker(update: update)
                    .presentationDetents([.medium])
            }
    }

    /// Handed down the view tree rather than attached here, so the caller decides which
    /// part of the card is draggable. Attaching it at this level would swallow the
    /// photograph's paging gesture.
    ///
    /// Type-erased to `AnyGesture<Void>` because it travels through the environment,
    /// which needs a concrete type; the value it produces is never read.
    private var drag: AnyGesture<Void> {
        AnyGesture(rawDrag.map { _ in () })
    }

    private var rawDrag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                // Horizontal intent only. Without this the vertical scroll and
                // the card fight each other and neither feels right.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // Resists past the threshold rather than following the finger
                // forever, so the commit point is felt instead of guessed.
                let raw = value.translation.width
                offset = abs(raw) <= Self.threshold
                    ? raw
                    : raw / abs(raw) * (Self.threshold + (abs(raw) - Self.threshold) / 4)
            }
            .onEnded { _ in
                if abs(offset) >= Self.threshold, let pending {
                    commit(pending)
                }
                offset = 0
            }
    }

    /// What the gesture will do, printed in the gap the card leaves behind.
    @ViewBuilder
    private var hint: some View {
        if let pending {
            DataLabel(
                text: pending.label,
                size: 11,
                color: abs(offset) >= Self.threshold ? .signal : .muted
            )
            .padding(.horizontal, 22)
        }
    }

    private func commit(_ intent: Intent) {
        switch intent {
        case .markRead:
            update.isSeen = true
            update.brand?.lastOpenedAt = Date()
            try? context.save()
            didMarkRead.toggle()
        case .file:
            isChoosingBoard = true
        }
    }
}

/// Choose where this goes. Opened by a left swipe, and the only modal in the feed.
struct BoardPicker: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Board.sortIndex), SortDescriptor(\Board.createdAt)])
    private var boards: [Board]

    let update: BrandUpdate

    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(update.title)
                        .font(.editorial(17))
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)

                    // The two built-in destinations first: most things are kept without
                    // ever being filed, and requiring a board would defeat a quick save.
                    ForEach(SavedItem.SaveType.allCases) { type in
                        row(label: type.label, isOn: update.save?.board == nil && update.save?.type == type) {
                            file(type: type, board: nil)
                        }
                    }

                    if !boards.isEmpty {
                        DataLabel(text: "BOARDS")
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                    }

                    ForEach(boards) { board in
                        row(label: board.name, isOn: update.save?.board?.id == board.id) {
                            file(type: update.save?.type ?? .inspiration, board: board)
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
            .navigationTitle("Add to")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New board", isPresented: $isNaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createBoard() }
            } message: {
                Text("Boards are private. Nothing is shared anywhere.")
            }
        }
        .tint(.ink)
    }

    private func row(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
                Spacer()
                // The same vermilion rule the size run uses for "this one is yours", so
                // selection reads the same way everywhere in the app.
                Rectangle()
                    .fill(isOn ? Color.signal : Color.hairline)
                    .frame(width: 22, height: isOn ? 3 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
    }

    private func createBoard() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let board = Board(name: name, sortIndex: (boards.map(\.sortIndex).max() ?? 0) + 1)
        context.insert(board)
        file(type: update.save?.type ?? .inspiration, board: board)
    }

    /// Filing something implies keeping it, so this saves it if it wasn't already —
    /// and marks it read, because acting on a card is acknowledging you've seen it.
    private func file(type: SavedItem.SaveType, board: Board?) {
        let save = update.save ?? {
            let created = SavedItem(update: update, type: type)
            context.insert(created)
            return created
        }()
        save.type = type
        save.board = board
        update.isSeen = true
        try? context.save()
        dismiss()
    }
}

/// Carries the card's drag gesture down to whichever subview should recognise it.
///
/// An environment value rather than a parameter because the handle is usually several
/// layers below the modifier — inside a caption stack, inside a card — and threading a
/// gesture through every intermediate view's signature would be worse than this.
private struct QuickSaveDragKey: EnvironmentKey {
    static let defaultValue: AnyGesture<Void>? = nil
}

extension EnvironmentValues {
    var quickSaveDrag: AnyGesture<Void>? {
        get { self[QuickSaveDragKey.self] }
        set { self[QuickSaveDragKey.self] = newValue }
    }
}

private struct QuickSaveHandle: ViewModifier {
    @Environment(\.quickSaveDrag) private var drag

    func body(content: Content) -> some View {
        if let drag {
            content.gesture(drag)
        } else {
            // No enclosing `quickSave` — the brand page's gallery cards before they were
            // given one, and previews. The view is simply undraggable rather than broken.
            content
        }
    }
}

extension View {
    /// Swipe right to mark read, left to choose a board.
    ///
    /// Pair with `quickSaveHandle()` on the region that should recognise the drag; without
    /// one the card renders normally and simply isn't swipeable.
    func quickSave(_ update: BrandUpdate) -> some View {
        modifier(QuickSaveModifier(update: update))
    }

    /// Marks this view as the part of the card that recognises the quick-save drag.
    /// Everything outside it — notably the photograph — keeps its own gestures.
    func quickSaveHandle() -> some View {
        modifier(QuickSaveHandle())
    }
}
