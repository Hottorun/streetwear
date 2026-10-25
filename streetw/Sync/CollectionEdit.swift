// CollectionEdit.swift
// Every change made to saves and boards from a menu, a sheet or a selection, in one place.
//
// Five screens file things on boards — the card menu, the left-swipe picker, the save
// confirmation's picker, an item's own page and now a selection on the wall — and they used
// to do it with their own two lines each. That was fine while a filing was one assignment.
// With several boards per save and several saves per action, the details that matter are the
// same everywhere and easy to get wrong in any one copy:
//
// - **A write that changes nothing is not made.** `context.save()` invalidates every `@Query`
//   in the app, so "file these twelve on Tokyo" when all twelve already are must cost nothing.
//   Each function here returns whether it changed anything, and saves only then.
// - **Membership is compared by `id`**, the way the rest of the app compares boards.
// - **A mood is one board at a time** — see `setTaste`.

import Foundation
import StreetwCore
import SwiftData

@MainActor
enum CollectionEdit {
    /// Whether a set of saves is on a board: all of them, some, or none. What a row in a board
    /// picker draws, and what a tap on it does — see `toggle(_:on:in:)`.
    enum Filing {
        case all, some, none
    }

    static func filing(of saves: [SavedItem], on board: Board) -> Filing {
        let on = saves.count { $0.isFiled(on: board) }
        if on == 0 { return .none }
        return on == saves.count ? .all : .some
    }

    /// Files every save on the board, or — when every one of them already is — takes them all
    /// off. A partial selection is filed rather than unfiled, because "put these together" is
    /// what somebody holding a mixed selection most plausibly means; a second tap undoes it.
    @discardableResult
    static func toggle(_ saves: [SavedItem], on board: Board, in context: ModelContext) -> Bool {
        filing(of: saves, on: board) == .all
            ? unfile(saves, from: board, in: context)
            : file(saves, on: board, in: context)
    }

    @discardableResult
    static func file(_ saves: [SavedItem], on board: Board, in context: ModelContext) -> Bool {
        var changed = false
        for save in saves where !save.isFiled(on: board) {
            save.boards.append(board)
            changed = true
        }
        if changed { try? context.save() }
        return changed
    }

    @discardableResult
    static func unfile(_ saves: [SavedItem], from board: Board, in context: ModelContext) -> Bool {
        var changed = false
        for save in saves where save.isFiled(on: board) {
            save.boards.removeAll { $0.id == board.id }
            changed = true
        }
        if changed { try? context.save() }
        return changed
    }

    @discardableResult
    static func keep(_ saves: [SavedItem], as type: SavedItem.SaveType, in context: ModelContext) -> Bool {
        var changed = false
        for save in saves where save.type != type {
            save.type = type
            changed = true
        }
        if changed { try? context.save() }
        return changed
    }

    /// "Don't use for my taste", or its undoing, on each save.
    @discardableResult
    static func exclude(_ saves: [SavedItem], _ excluded: Bool, in context: ModelContext) -> Bool {
        var changed = false
        for save in saves where save.isExcludedFromTaste != excluded {
            save.isExcludedFromTaste = excluded
            changed = true
        }
        if changed { try? context.save() }
        return changed
    }

    /// Un-saving several things at once. The same act as `removeSave`: the product stays in the
    /// catalogue, and the fits they were in are left alone — `Fit.items` cascades in neither
    /// direction.
    static func delete(_ saves: [SavedItem], in context: ModelContext) {
        guard !saves.isEmpty else { return }
        for save in saves where !save.isGone { context.delete(save) }
        try? context.save()
    }

    /// How a board counts towards taste.
    ///
    /// **One mood at a time.** "Inspire me from this" is a statement that this board is the
    /// source of taste for now — the roadmap's suits-versus-streetwear case is one person in
    /// one mood — and two boards each claiming that would be two leans averaged into neither.
    /// So choosing a mood puts any other mood board back to counting, which its own menu then
    /// shows; nothing is silently ignored.
    @discardableResult
    static func setTaste(
        _ mode: TasteMode,
        on board: Board,
        among boards: [Board],
        in context: ModelContext
    ) -> Bool {
        var changed = false
        if mode == .mood {
            for other in boards where other.id != board.id && other.tasteMode == .mood {
                other.tasteMode = .counts
                changed = true
            }
        }
        if board.tasteMode != mode {
            board.tasteMode = mode
            changed = true
        }
        if changed { try? context.save() }
        return changed
    }

    /// A new board at the end of the strip.
    static func newBoard(named name: String, after boards: [Board], in context: ModelContext) -> Board? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let board = Board(name: trimmed, sortIndex: (boards.map(\.sortIndex).max() ?? 0) + 1)
        context.insert(board)
        return board
    }
}
