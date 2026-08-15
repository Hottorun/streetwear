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
//
// Two things about *how* that is wired, both of which it got wrong the first time and
// both of which made the gesture simply not fire:
//
// - **The handle sits on a `NavigationLink`.** A link installs its own recogniser, and an
//   inner gesture beats an outer one by default — so a plain `.gesture()` wrapped around
//   the link lost every drag to the link's press handling. It has to be
//   `.highPriorityGesture`. Taps still reach the link, because the drag needs 18pt of
//   movement before it claims anything.
// - **A gesture cannot travel through the environment.** It used to be shipped down as an
//   `AnyGesture`, rebuilt on every `body` evaluation — which is every frame of a drag, so
//   each frame replaced the recogniser that was mid-drag with a fresh one. What travels
//   now is a coordinator with a *stable identity*; the handle owns the real gesture and
//   reports to it.

import SwiftData
import SwiftUI

/// The shared drag state between the card and whichever part of it is draggable.
///
/// A reference type on purpose. The environment value must be stable across renders or
/// the subtree reading it is invalidated on every frame of the drag, which is exactly
/// what killed the gesture before.
@MainActor
@Observable
final class QuickSaveCoordinator {
    /// Far enough that a scroll can't trigger it, close enough for one thumb.
    static let threshold: CGFloat = 78

    enum Intent {
        case markRead
        case file

        var label: String {
            switch self {
            case .markRead: "READ"
            case .file: "ADD TO BOARD"
            }
        }
    }

    private(set) var offset: CGFloat = 0

    var pending: Intent? {
        if offset > 24 { return .markRead }
        if offset < -24 { return .file }
        return nil
    }

    var isPastThreshold: Bool { abs(offset) >= Self.threshold }

    func dragged(_ translation: CGSize) {
        // Horizontal intent only. Without this the vertical scroll and the card fight
        // each other and neither feels right.
        guard abs(translation.width) > abs(translation.height) else { return }
        // Resists past the threshold rather than following the finger forever, so the
        // commit point is felt instead of guessed.
        let raw = translation.width
        offset = abs(raw) <= Self.threshold
            ? raw
            : raw / abs(raw) * (Self.threshold + (abs(raw) - Self.threshold) / 4)
    }

    /// Returns what should happen, and resets. Nil when the drag didn't go far enough.
    func ended() -> Intent? {
        let committed = isPastThreshold ? pending : nil
        offset = 0
        return committed
    }
}

struct QuickSaveModifier: ViewModifier {
    @Environment(\.modelContext) private var context

    let update: BrandUpdate

    @State private var coordinator = QuickSaveCoordinator()
    @State private var isChoosingBoard = false
    @State private var didMarkRead = false

    func body(content: Content) -> some View {
        content
            .environment(\.quickSaveCoordinator, coordinator)
            .environment(\.quickSaveCommit, commit)
            .offset(x: coordinator.offset)
            .background(alignment: coordinator.offset > 0 ? .leading : .trailing) { hint }
            .animation(.interactiveSpring(duration: 0.25), value: coordinator.offset)
            .sensoryFeedback(.success, trigger: didMarkRead)
            .sheet(isPresented: $isChoosingBoard) {
                BoardPicker(update: update)
                    .presentationDetents([.medium])
            }
    }

    /// What the gesture will do, printed in the gap the card leaves behind.
    @ViewBuilder
    private var hint: some View {
        if let pending = coordinator.pending {
            DataLabel(
                text: pending.label,
                size: 11,
                color: coordinator.isPastThreshold ? .signal : .muted
            )
            .padding(.horizontal, 22)
        }
    }

    private func commit(_ intent: QuickSaveCoordinator.Intent) {
        switch intent {
        case .markRead:
            // Animated, because every list this card sits in filters on `isSeen` and the
            // card is therefore about to be *removed* — an unanimated removal is a hitch:
            // the card is there, then the page has silently shifted up by its height and
            // whatever was below is now under your thumb. It read as the app pausing to
            // think. What is actually being animated is the gap closing, which is the one
            // thing that makes the next item feel like it arrived rather than appeared.
            withAnimation(.easeOut(duration: 0.22)) {
                update.isSeen = true
                update.brand?.lastOpenedAt = Date()
            }
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

/// Carries the card's drag state down to whichever subview should recognise it.
///
/// An environment value rather than a parameter because the handle is usually several
/// layers below the modifier — inside a caption stack, inside a card — and threading it
/// through every intermediate view's signature would be worse than this. What travels is
/// the coordinator and a commit callback, never a gesture: a gesture value rebuilt on
/// each render replaces the recogniser mid-drag, which is why this used to do nothing.
private struct QuickSaveCoordinatorKey: EnvironmentKey {
    static let defaultValue: QuickSaveCoordinator? = nil
}

private struct QuickSaveCommitKey: EnvironmentKey {
    static let defaultValue: ((QuickSaveCoordinator.Intent) -> Void)? = nil
}

extension EnvironmentValues {
    var quickSaveCoordinator: QuickSaveCoordinator? {
        get { self[QuickSaveCoordinatorKey.self] }
        set { self[QuickSaveCoordinatorKey.self] = newValue }
    }

    var quickSaveCommit: ((QuickSaveCoordinator.Intent) -> Void)? {
        get { self[QuickSaveCommitKey.self] }
        set { self[QuickSaveCommitKey.self] = newValue }
    }
}

private struct QuickSaveHandle: ViewModifier {
    @Environment(\.quickSaveCoordinator) private var coordinator
    @Environment(\.quickSaveCommit) private var commit

    func body(content: Content) -> some View {
        if let coordinator, let commit {
            content
                // **High priority, not `.gesture`.** This is nearly always attached to a
                // `NavigationLink`, and a link's own recogniser is *inside* this view —
                // where inner beats outer by default, so a plain `.gesture` lost every
                // drag to the link's press handling and the swipe appeared dead. The link
                // still receives taps: 18pt of movement is required before this claims
                // anything, and a tap never travels that far.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { coordinator.dragged($0.translation) }
                        .onEnded { _ in
                            if let intent = coordinator.ended() { commit(intent) }
                        }
                )
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
