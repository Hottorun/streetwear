// SavedItem.swift
// Model for content the user has saved (wardrobe/inspiration)
import Foundation
import StreetwCore
import SwiftData

@Model
final class SavedItem {
    enum SaveType: String, Codable, Sendable, CaseIterable, Identifiable {
        case inspiration
        case wardrobe

        var id: String { rawValue }

        var label: String {
            switch self {
            case .inspiration: "Inspiration"
            case .wardrobe: "Wardrobe"
            }
        }

        var symbol: String {
            switch self {
            case .inspiration: "bookmark"
            case .wardrobe: "tshirt"
            }
        }
    }

    var id: UUID = UUID()
    var update: BrandUpdate?
    var savedAt: Date = Date()
    var type: SaveType = SaveType.inspiration
    var note: String?

    /// **Legacy, and read by exactly one thing: `BoardFiling.adoptLegacy`.**
    ///
    /// 1.0 filed a save on at most one board, through this to-one, although boards were
    /// always meant to be filters rather than folders — an item belongs with the other tees
    /// *and* with Tokyo. It stays in the schema because that is the safe way to migrate a store
    /// already on phones: the many-to-many below is a brand-new relationship, which is the one
    /// change a lightweight migration cannot get wrong, and the launch pass moves every filing
    /// across and clears this in the same save. After the first launch of a build that has
    /// `boards`, this is nil on every row. Never read it for anything else and never write it.
    var board: Board?

    /// The boards this is filed on. Empty is the common case and stays allowed: most saves
    /// never get filed anywhere, and requiring a board before you can keep something would
    /// defeat the point of a one-tap save.
    ///
    /// Many-to-many and a cascade in neither direction — deleting a board must never take its
    /// saves with it, and un-saving something just takes it off the boards it was on. The
    /// inverse and the delete rule are declared once, on `Board.saves`.
    var boards: [Board] = []

    /// "Don't use for my taste." See `TasteRule` — this beats every board setting.
    ///
    /// Taste only: the item still shows everywhere it always did, and a wardrobe piece flagged
    /// this way still goes into fits and still answers "goes with your …", because owning
    /// something is a fact and liking it is not. See `TasteScope` for who reads what.
    var isExcludedFromTaste: Bool = false

    /// The photograph somebody chose to stand for this on the wall, overriding the packshot.
    ///
    /// Stored as one of the product's own image strings, and only honoured while it still is
    /// one: a share whose gallery `SharedSaveImporter.repair` later replaces must not go on
    /// pointing at a photograph the product no longer has. See `cover`.
    var coverImageURLString: String?

    /// Width ÷ height of `coverImageURLString`, measured when it was chosen.
    ///
    /// The wall never crops — a tile takes its photograph's shape — and `imageAspect` was
    /// measured on the packshot, so a cover somebody picked needs a shape of its own or the
    /// tile is laid out for a different picture.
    var coverAspect: Double?

    /// The size you own, or the one you're waiting for. Free text on purpose — brands
    /// run their own scales and "44" or "Youth L" must be as storable as "M".
    var sizeNote: String?

    /// Outfits this item appears in. Many-to-many, and *not* a cascade in either
    /// direction: deleting a fit must not delete the clothes, and un-saving something
    /// leaves the fits it was in rather than silently rewriting them.
    var fits: [Fit] = []

    // MARK: - A garment of your own

    // **A save with no product behind it** — something you photographed and the scan read
    // (`docs/ai.md`, *The scan*). Until Phase 4 every save had a `BrandUpdate`, and the
    // smallest safe change was to let `update` be nil here and carry what the scan said on the
    // save itself: optional columns and two defaulted arrays, which a lightweight migration
    // adds to a store written by any earlier build with no migration plan. A new model, or a
    // `BrandUpdate` minted for a garment nobody sells, would have put a product into the
    // catalogue's tables — the feed, Shop's search on the phone and "more like this" all read
    // those, and none of them should ever offer somebody their own jacket.
    //
    // `ownPhotoFile` is the marker: nil on every save from before, and on every catalogue save.

    /// The reader's own photograph, a JPEG in this store's `OwnPhotos` directory. A file name,
    /// never a path: the app's container moves between installs and updates.
    var ownPhotoFile: String?
    /// The garment lifted off it, a PNG beside the photograph, when `Cutout` found one.
    var ownCutoutFile: String?
    /// Width ÷ height of the photograph, so the wall lays the tile out at its shape.
    var ownAspect: Double?
    /// The scan's one line about it — "Black canvas chore jacket". What the wall prints.
    var ownTitle: String?
    /// What it is, in a shop's words — "chore jacket".
    var ownType: String?
    /// `GarmentSlot` raw value, as the scan read it off the photograph.
    var ownSlot: String?
    /// Colour names, main first, in `ColorHarmony`'s vocabulary where one fit.
    var ownColours: [String] = []
    var ownMaterial: String?
    var ownPattern: String?
    var ownStyle: [String] = []
    /// What "find this" searches for — the scan's `searchText`.
    var ownSearchText: String?

    init(update: BrandUpdate?, savedAt: Date = Date(), type: SaveType = .inspiration, note: String? = nil) {
        self.id = UUID()
        self.update = update
        self.savedAt = savedAt
        self.type = type
        self.note = note
    }

    /// Matches a free-text search across everything a person might remember about a
    /// saved thing: what it was called, who made it, how it was tagged, and whatever
    /// they wrote on it. Deliberately not a `#Predicate` — the fields worth searching
    /// live across a relationship and in arrays, which SwiftData predicates handle
    /// poorly, and a collection is small enough to filter in memory.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        guard let update else {
            let own = (ownWords + [note ?? ""]).joined(separator: " ").lowercased()
            return isOwnGarment && needle.split(separator: " ").allSatisfy { own.contains($0) }
        }

        let haystack = [
            update.title,
            update.summary ?? "",
            update.brand?.name ?? "",
            update.productType ?? "",
            note ?? "",
            update.tags.joined(separator: " "),
            // The host, so "kith" finds things shared from kith.com even before that
            // brand is followed and has a name attached.
            update.linkURL?.host() ?? ""
        ].joined(separator: " ").lowercased()

        // Every word must appear somewhere, so "kith hoodie" narrows rather than widens.
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    /// Whether this row has been deleted out from under whatever is still drawing it.
    ///
    /// The `Fit.isGone` rule, for the same reason: reading any property of a deleted `@Model`
    /// traps, and a bulk delete on the wall removes rows a `LazyVStack` may still hold for
    /// one more pass. `isDeleted` alone is not enough — a model whose context has gone
    /// answers false to it and still traps.
    var isGone: Bool { isDeleted || modelContext == nil }

    // MARK: - Boards

    func isFiled(on board: Board) -> Bool {
        boards.contains { $0.id == board.id }
    }

    /// Where this went, in words — what the save confirmation says it was kept to.
    ///
    /// The board when it is on exactly one, since that is the most specific true answer; the
    /// type otherwise, including when it is on several, because a list of board names is not
    /// something a one-line confirmation can say.
    var destinationLabel: String {
        boards.count == 1 ? boards[0].name : type.label
    }

    // MARK: - The cover

    /// The photograph the wall and this item's own page lead with.
    ///
    /// **The shop's first photograph, unless somebody — or the server, confidently — says
    /// otherwise.** The order is: a photograph chosen by hand; then the **server's** stand-in
    /// (`BrandUpdate.serverShot`: the first photograph is on a person and a later one is the
    /// whole garment on its own, read once per product off the embeddings with close-ups
    /// ruled out, and there before anything on this phone has looked); else the lead shot.
    /// Vision's packshot (`packshotURLString`) is no longer in the order — it chose by
    /// "nobody in it", and on Motel Rocks that is the fabric close-up as often as the
    /// packshot. The server's reading can see the difference; the phone's cannot, so it
    /// goes back to choosing what to *measure*. See `docs/collection.md`.
    var coverURLString: String? {
        guard let update else { return ownPhotoURL?.absoluteString }
        if let chosen = coverImageURLString, update.imageURLStrings.contains(chosen) { return chosen }
        return update.automaticCoverURLString
    }

    var coverURL: URL? {
        guard update != nil else { return ownPhotoURL }
        return coverURLString.flatMap(URL.init(string:)) ?? update?.primaryImageURL
    }

    /// The cover's measured shape, or nil when nothing has measured it yet.
    ///
    /// `imageAspect` is the shape of the photograph `imageAspectURL` names, and it is only
    /// the cover's shape while that is the cover: the server's stand-in can arrive or be
    /// withdrawn after a row was measured, and until `ImageTagger` reads the new cover (which
    /// `adoptReading` makes due) the tile is drawn to a guess rather than to the shape of a
    /// different photograph. A row measured before the stamp existed is shaped for Vision's
    /// packshot, which is the cover only where that was the lead; `needsCoverShape` gives it
    /// one more pass. A cover chosen by hand carries its own.
    var coverAspectMeasured: Double? {
        guard let update else { return ownAspect }
        if let chosen = coverImageURLString, chosen == coverURLString { return coverAspect }
        let measured = update.imageAspectURL ?? update.packshotURLString
        return measured == coverURLString ? update.imageAspect : nil
    }

    /// Chooses the cover. Returns whether anything changed, so a caller can skip the save.
    ///
    /// Choosing the photograph the automatic rule would pick anyway **clears** the choice
    /// rather than pinning it: that is the way back to "whatever the rule says", and it means
    /// a stand-in the server reads later still reaches this item.
    @discardableResult
    func setCover(_ string: String, aspect: Double?) -> Bool {
        guard let update, update.imageURLStrings.contains(string) else { return false }
        let pinned = string == update.automaticCoverURLString ? nil : string
        let shape = pinned == nil ? nil : aspect
        guard pinned != coverImageURLString || shape != coverAspect else { return false }
        coverImageURLString = pinned
        coverAspect = shape
        return true
    }

    /// The product's photographs in the order this item's page pages through them: the cover
    /// first, then everything else in the brand's own order. Only ever reordered, never
    /// filtered — every photograph is still there to swipe to, which is `ProductShot`'s rule.
    var galleryURLs: [URL] {
        guard let update else { return ownPhotoURL.map { [$0] } ?? [] }
        var strings = update.imageURLStrings
        if let cover = coverURLString, let index = strings.firstIndex(of: cover), index > 0 {
            strings.insert(strings.remove(at: index), at: 0)
        }
        return strings.compactMap(URL.init(string:))
    }
}

// MARK: - Whatever is behind it

/// What every surface that draws a save asks, so none of them has to know whether a product
/// is behind it. A surface that reaches for `update` directly is one that will quietly leave
/// a garment of your own out — the wall did exactly that, filtering on `update != nil`.
extension SavedItem {
    /// A garment of your own: a photograph and the scan's reading, with no product behind it.
    var isOwnGarment: Bool { update == nil && ownPhotoFile != nil }

    /// Whether there is anything behind this save at all — a product, or a photograph of your
    /// own. The wall leaves out a save that has neither, which is a row whose product went.
    var hasSubject: Bool { update != nil || isOwnGarment }

    /// The photograph, resolved against the store this save lives in. Nil for a row with no
    /// context, which is a row on its way out.
    var ownPhotoURL: URL? {
        guard let ownPhotoFile, let directory = OwnPhotos.directory(of: self) else { return nil }
        return directory.appending(path: ownPhotoFile)
    }

    var ownCutoutURL: URL? {
        guard let ownCutoutFile, let directory = OwnPhotos.directory(of: self) else { return nil }
        return directory.appending(path: ownCutoutFile)
    }

    /// Whether there is anything to draw — what every surface made of photographs (the fit
    /// tray, the suggestions, "wear it with") asks before offering a save at all.
    var hasPhotograph: Bool {
        if let update { return update.hasPhotograph }
        return ownPhotoFile != nil
    }

    /// What the wall and the tray print under the photograph.
    var displayTitle: String {
        update?.title ?? ownTitle ?? ownType?.capitalized ?? "Saved item"
    }

    /// The key `Pairing` matches a scored garment back on: the product's where there is one,
    /// the save's own where there is not.
    var pairingID: String { update?.pairingID ?? "own:\(id.uuidString)" }

    /// One id per garment for `FitSuggestions.key`: the product for a catalogue save — a
    /// proposal is keyed on its products, so a borrowed piece keeps its key once kept — and
    /// the save itself for a garment of your own, which has no product to be keyed on.
    var garmentKey: UUID { update?.id ?? id }

    /// This save in the terms `Pairing` reasons about, or nil when there is nothing to reason
    /// about. A garment of your own is read off the scan: the slot the photograph showed, the
    /// colours the model named — a reading of the photograph, which is what `ImageTagger`
    /// measures on a catalogue shot, so it is scored the same way.
    var garment: Garment? {
        if let update { return update.garment }
        guard isOwnGarment else { return nil }
        return OwnGarment.garment(
            id: pairingID,
            title: ownTitle,
            type: ownType,
            slot: ownSlot,
            colours: ownColours,
            material: ownMaterial,
            pattern: ownPattern,
            style: ownStyle
        )
    }

    /// Every word the scan said about it, for search and the taste reading's text fallback.
    var ownWords: [String] {
        [ownTitle, ownType, ownMaterial, ownPattern].compactMap { $0 } + ownColours + ownStyle
    }
}
