// Board.swift
// A collection within the collection.
//
// Boards are **private by default**, and that is recorded on the model rather than left
// implicit. There is no sharing in the app yet, so `isPrivate` gates nothing today — but
// writing it down now means privacy is a property of the data from the first row, not
// something retrofitted the day sharing arrives and quietly defaults the wrong way.
//
// Deliberately orthogonal to `SavedItem.SaveType`: Inspiration/Wardrobe answers "do I
// own this", a board answers "what does this belong with". An item can be in the
// wardrobe *and* on a board, so boards are a filter over the collection, never a folder
// that owns items — which is also why deleting one leaves its saves alone.

import Foundation
import SwiftData

@Model
final class Board {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    /// Manual order, so the strip reads the way the user arranged it rather than
    /// alphabetically.
    var sortIndex: Int = 0
    var isPrivate: Bool = true

    /// `.nullify`, emphatically not `.cascade`: removing a board must never take the
    /// saved things with it. Losing an archive because a grouping was tidied away is
    /// the single worst thing this app could do.
    @Relationship(deleteRule: .nullify, inverse: \SavedItem.board)
    var items: [SavedItem] = []

    init(name: String, sortIndex: Int = 0, isPrivate: Bool = true) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.sortIndex = sortIndex
        self.isPrivate = isPrivate
    }

    /// Newest first — a board is browsed, not read in order.
    var recentItems: [SavedItem] {
        items.sorted { $0.savedAt > $1.savedAt }
    }
}
