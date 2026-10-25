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
//
// And an item can be on **several** boards. 1.0 allowed one, through a to-one relationship,
// which made a board a folder in everything but name: the jacket from the Tokyo trip could
// be on "Tokyo" or on "Outerwear" and not both, and filing it on the second silently took it
// off the first. See `BoardFiling` for how the old filings were carried across.

import Foundation
import OSLog
import StreetwCore
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

    /// How what is on this board counts towards the wearer's taste, as `TasteMode`'s raw value.
    ///
    /// A string rather than the enum, for the reason `BrandUpdate.genderRaw` is one: SwiftData
    /// decodes a stored enum with an internal `try!`, so a mode added by a later build would be
    /// a crash on launch for anybody who went back to this one. Read through `tasteMode`, which
    /// falls back to `.counts` — what every board was before modes existed.
    var tasteModeRaw: String = TasteMode.counts.rawValue

    /// **Legacy: the inverse of `SavedItem.board`**, the 1.0 to-one filing. Kept only so the
    /// stored relationship and its nullify rule stay exactly as the old schema declared them
    /// while `BoardFiling.adoptLegacy` empties it. Empty on every board after the first launch
    /// of a build with `saves`; read `saves`, never this.
    @Relationship(deleteRule: .nullify, inverse: \SavedItem.board)
    var items: [SavedItem] = []

    /// What is filed here. Many-to-many with `SavedItem.boards`.
    ///
    /// `.nullify`, emphatically not `.cascade`: removing a board must never take the
    /// saved things with it. Losing an archive because a grouping was tidied away is
    /// the single worst thing this app could do.
    @Relationship(deleteRule: .nullify, inverse: \SavedItem.boards)
    var saves: [SavedItem] = []

    /// Fits file onto a board exactly as items do, and for the same reason: a board is a
    /// grouping, and "the outfits I wore in Tokyo" is a grouping. Nullify, again — deleting
    /// a board must not delete an outfit any more than it deletes a jacket.
    @Relationship(deleteRule: .nullify, inverse: \Fit.board)
    var fits: [Fit] = []

    init(name: String, sortIndex: Int = 0, isPrivate: Bool = true) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.sortIndex = sortIndex
        self.isPrivate = isPrivate
    }

    var tasteMode: TasteMode {
        get { TasteMode(rawValue: tasteModeRaw) ?? .counts }
        set { tasteModeRaw = newValue.rawValue }
    }

    /// Newest first — a board is browsed, not read in order.
    var recentItems: [SavedItem] {
        saves.sorted { $0.savedAt > $1.savedAt }
    }

    /// The boards that change what counts towards taste, as a query.
    ///
    /// Everything that infers taste needs these and nothing else: a `.counts` board changes
    /// nothing (`TasteRule.role`), and most people will never set one to anything else — so a
    /// view asking for these subscribes to almost nothing. The literal is `TasteMode.counts`;
    /// a `#Predicate` cannot read a static property.
    static var shapingTaste: Predicate<Board> {
        #Predicate<Board> { $0.tasteModeRaw != "counts" }
    }
}

/// Carrying 1.0's one-board filings onto the many-to-many, once.
///
/// **Why a launch pass and not a schema migration plan.** A `VersionedSchema` would have to
/// restate all eight models exactly as 1.0 shipped them — `BrandUpdate` alone has some sixty
/// stored properties — and a single mismatch with the store on a phone is a container that
/// refuses to open, which is a crash on launch with the collection inside it. Changing
/// `SavedItem.board` from to-one to to-many in place leans on Core Data inferring that the old
/// foreign key should become rows in a new join table, which nobody documents and nothing here
/// could verify for every store in the field. Adding a *new* relationship is the one change a
/// lightweight migration cannot get wrong, so `boards` is new and this copies the old filing
/// into it in code, where it can be read.
///
/// Three properties are load-bearing:
///
/// - **It moves rather than copies.** The legacy field is cleared in the same save that writes
///   the new one, so the pass is idempotent by construction — a second launch finds nothing to
///   do — and a filing somebody later removes cannot be resurrected from a stale copy.
/// - **It is atomic.** One save: either every filing has moved or none has.
/// - **It runs before anything can read a board.** From `streetwApp.init`, after the container
///   opens and before the first view exists, so no screen ever draws a board half-migrated.
@MainActor
enum BoardFiling {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "boards")

    static func adoptLegacy(in context: ModelContext) {
        let legacy = FetchDescriptor<SavedItem>(predicate: #Predicate { $0.board != nil })
        guard let filed = try? context.fetch(legacy), !filed.isEmpty else { return }

        for save in filed {
            guard let board = save.board else { continue }
            if !save.isFiled(on: board) { save.boards.append(board) }
            save.board = nil
        }
        do {
            try context.save()
            log.info("moved \(filed.count) board filings onto the many-to-many")
        } catch {
            // Left in the context rather than rolled back: nothing has been lost, the old
            // field still holds every filing in the store, and the next launch tries again.
            log.error("could not move board filings: \(error.localizedDescription)")
        }
    }
}
