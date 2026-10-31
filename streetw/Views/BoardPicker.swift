// BoardPicker.swift
// Filing a save: what it is kept as, and which boards it is on.
//
// This file used to be `QuickSave` — a right swipe on a feed card to mark it read and a left
// swipe to file it, with a coordinator so the drag survived re-renders. Both directions went
// with the Phase 1 feed: there is no unread state to clear by hand any more, and a half-width
// card in a two-column grid cannot be dragged sideways without covering its neighbour. Saving
// from a card is the bookmark and the long-press menu; filing is this, reached from the
// confirmation every save raises (`SaveConfirmation`) and from the menu's "Add to board".

import StreetwCore
import SwiftData
import SwiftUI

/// Choose where this goes. Opened from the save confirmation's Board — the one way to file
/// something in the moment of saving it, now that the feed has no swipe to do it with.
///
/// Two kinds of row, because they are two kinds of choice. *Kept as* is one of two answers, so
/// choosing it is the whole decision and closes the sheet, as it always did. A board is a
/// toggle: a save can be on several, so a tap files or unfiles it and the sheet stays open for
/// the next one. This used to be one list of radio buttons, in which picking a board quietly
/// took the item off the one it was already on.
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
                        BoardRow(label: type.label, filing: update.save?.type == type ? .all : .none) {
                            keep(as: type)
                            dismiss()
                        }
                    }

                    if !boards.isEmpty {
                        DataLabel(text: "BOARDS")
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                    }

                    ForEach(boards) { board in
                        BoardRow(label: board.name, filing: update.save?.isFiled(on: board) == true ? .all : .none) {
                            CollectionEdit.toggle([keep(as: update.save?.type ?? .inspiration)], on: board, in: context)
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
                // "Done", not "Cancel": every tap above has already happened, and a button
                // offering to take them back would be a lie.
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New board", isPresented: $isNaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createBoard() }
            }
        }
        .tint(.ink)
    }

    private func createBoard() {
        guard let board = CollectionEdit.newBoard(named: newName, after: boards, in: context) else { return }
        CollectionEdit.file([keep(as: update.save?.type ?? .inspiration)], on: board, in: context)
    }

    /// Filing something implies keeping it, so this saves it if it wasn't already —
    /// and marks it read, because acting on a card is acknowledging you've seen it.
    @discardableResult
    private func keep(as type: SavedItem.SaveType) -> SavedItem {
        if let save = update.save, save.type == type, update.isSeen { return save }
        let save = update.save ?? {
            let created = SavedItem(update: update, type: type)
            context.insert(created)
            UsageCounts.record(.saveAdded)
            return created
        }()
        save.type = type
        update.isSeen = true
        try? context.save()
        return save
    }
}

/// One destination in a board picker: its name, and a rule saying whether what is being
/// filed is there.
///
/// The same vermilion rule the size run uses for "this one is yours", so selection reads the
/// same way everywhere in the app. Half a rule when only some of a selection is there — the one
/// state a single save never has and a selection on the wall often does.
struct BoardRow: View {
    let label: String
    let filing: CollectionEdit.Filing
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
                Spacer()
                mark
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
        .accessibilityAddTraits(filing == .all ? .isSelected : [])
        .accessibilityValue(filing == .some ? "Some" : "")
    }

    @ViewBuilder
    private var mark: some View {
        switch filing {
        case .all:
            Rectangle().fill(Color.signal).frame(width: 22, height: 3)
        case .some:
            HStack(spacing: 0) {
                Rectangle().fill(Color.signal).frame(width: 11, height: 3)
                Rectangle().fill(Color.hairline).frame(width: 11, height: 1)
            }
        case .none:
            Rectangle().fill(Color.hairline).frame(width: 22, height: 1)
        }
    }
}
