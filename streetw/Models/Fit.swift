// Fit.swift
// An outfit: several saved things, worn together.
//
// The gap this fills is the difference between a collection and a wardrobe. Saving tells
// you what you like one item at a time; a fit is the first thing in the app that says
// something about how the pieces relate — and it is the only artefact here a person would
// actually want to look at again a month later.
//
// Deliberately built from `SavedItem` rather than from `BrandUpdate`. A fit is made of
// things you kept, so it inherits the collection's guarantees: nothing in a fit can be
// pruned out from under it, and removing a brand doesn't gut it.

import Foundation
import StreetwCore
import SwiftData
import SwiftUI
import UIKit

@Model
final class Fit {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var note: String?

    /// What the app saw in this outfit, in the words it used when it proposed it — "Red
    /// against neutrals", "Olive picked up twice". Nil for a fit arranged before this
    /// existed, or one whose pieces have not been analysed.
    ///
    /// **This is what a fit is called when nobody has named it.** The old `derivedName`
    /// joined the first three garment *titles*, which on a real collection produced two
    /// different outfits both reading "Kith Kids for Matthew Langille Puffer Vest - Polar
    /// ·…" — one long product name, truncated at the same point, saying nothing about
    /// either fit and not distinguishing them. `Outfit.score` already produces a sentence
    /// about the whole arrangement, it is short, and it differs between two fits that share
    /// a garment. Stored rather than derived on read, because `Outfit.score` classifies
    /// every piece and this is drawn once per card in a lazy grid.
    var verdict: String?

    /// Many-to-many: one saved item can appear in several fits, which is the whole point
    /// of owning a good pair of trousers.
    @Relationship(inverse: \SavedItem.fits)
    var items: [SavedItem] = []

    /// Where each piece sits on the canvas. Parallel to `items` by id rather than by
    /// index — the relationship's order is not guaranteed and an item can be removed from
    /// a fit, which would silently shift every placement after it.
    ///
    /// Stored as structure, not only as the flattened picture, and that is the point:
    /// a fit stays editable, stays a list of things you own, and stays machine-readable —
    /// which is what lets a restock in one of its pieces be worth telling you about.
    var placements: [FitPlacement] = []

    /// Filename of the flattened render, in `FitRender.directory`. Nil until the canvas
    /// has been saved once, and regenerated on every save.
    var renderFile: String?

    /// Boards are filters, and a fit is as fileable as anything else in the collection.
    /// Nullifies on delete for the same reason `SavedItem.board` does — removing a board
    /// must never take the things filed under it.
    var board: Board?

    /// The ground this fit is arranged on, as a **token** rather than a colour.
    ///
    /// Storing the hex would freeze the palette: re-tuning `bone` later would leave every
    /// existing fit on the old value with no way to tell which were deliberate. The same
    /// reasoning as everywhere else here — store the verdict, not the rendering of it.
    /// Nil means the default, which is what almost every fit will be.
    var backgroundName: String?

    /// Never nil, and an unrecognised token falls back rather than failing: a fit written by
    /// a build that knew a ground this one does not must still open.
    var ground: FitBackground {
        guard !isGone else { return .base }
        return backgroundName.flatMap(FitBackground.init(rawValue:)) ?? .base
    }

    init(name: String = "", items: [SavedItem] = [], verdict: String? = nil) {
        self.id = UUID()
        self.name = name
        self.items = items
        self.createdAt = Date()
        self.verdict = verdict
    }

    /// The items in the order a fit is read — head down — rather than the order they
    /// happened to be added in.
    var ordered: [SavedItem] {
        guard !isGone else { return [] }
        return items.sorted { wornOver($0.update, $1.update, tieBreak: $0.id.uuidString < $1.id.uuidString) }
    }

    /// Whether this row has been deleted out from under whatever is still drawing it.
    ///
    /// **Reading any property of a deleted `@Model` traps**, and a fit is deleted from a
    /// context menu on the very card that draws it: `context.delete` invalidates the query,
    /// SwiftUI re-renders, and the card — still in the view tree for one pass, because a
    /// `LazyHStack` tears down on its own schedule — reached `placements` and took the app
    /// down with `_assertionFailure`. Seen live on the Style tab.
    ///
    /// So the two accessors a card actually draws answer *emptily* for a row that is on its
    /// way out, and `FitCard` skips it altogether. `isDeleted` alone is not enough — a model
    /// whose context has gone answers false to it and still traps — so both are asked.
    var isGone: Bool { isDeleted || modelContext == nil }

    var renderURL: URL? {
        renderFile.map { FitRender.url(for: $0) }
    }

    /// Which garments this fit is made of, as one comparable key.
    ///
    /// Read by `FitSuggestions.build` so a proposal that has already been kept stops being
    /// offered — keeping one is what turns it from a suggestion into a record, and until
    /// this both cards stayed on the row after being kept and a second tap wrote a duplicate
    /// outfit. On the *products*, not on the saves: keeping a proposal mints a `SavedItem`
    /// for anything borrowed from the catalogue, so a save-based key would never match the
    /// proposal it came from.
    ///
    /// Nil for a row on its way out — reading any property of a deleted `@Model` traps, and
    /// this is called from a derivation that runs on the same pass as a delete.
    var wardrobeKey: String? {
        guard !isGone else { return nil }
        return FitSuggestions.key(ofProducts: items.compactMap { $0.update?.id })
    }

    /// The stored render, decoded — what a share sheet or a card actually hands over.
    ///
    /// An outfit is the most shareable thing in this app and the picture of it already
    /// existed, written on every save and drawn by every card; nothing could get it out.
    /// Reading the file rather than re-rendering keeps sharing free and guarantees what
    /// leaves is exactly what the collection shows.
    @MainActor
    var renderImage: UIImage? {
        LocalImage.load(renderURL)
    }

    /// The canvas, in draw order. Anything placed but no longer in `items` is dropped —
    /// un-saving something leaves the fits it was in rather than rewriting them, so a
    /// stale placement is expected rather than a bug.
    var placed: [(item: SavedItem, placement: FitPlacement)] {
        guard !isGone else { return [] }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return placements
            .compactMap { placement in byID[placement.itemID].map { (item: $0, placement: placement) } }
            .sorted { $0.placement.z < $1.placement.z }
    }

    /// What it is, when it has no name yet.
    ///
    /// The outfit's own verdict first — see `verdict` for why the garment titles it replaced
    /// were the wrong thing to print. Then the brands in it, which are short and differ
    /// between two fits sharing a garment. Titles are gone entirely: the one thing a name
    /// under a picture must do is tell two cards apart, and a 60-character product name
    /// truncated to the width of a card does the opposite.
    var derivedName: String {
        guard !isGone else { return "" }
        if let verdict, !verdict.isEmpty { return verdict }
        let brands = ordered.compactMap { $0.update?.brand?.name }
        var seen = Set<String>()
        let distinct = brands.filter { seen.insert($0).inserted }
        guard !distinct.isEmpty else { return "Empty fit" }
        return distinct.prefix(3).joined(separator: " · ")
    }

    var displayName: String {
        guard !isGone else { return "" }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? derivedName : name
    }
}

/// What a fit is laid out on.
///
/// **Fixed colours, never adaptive, and that is the whole point of the type.** A canvas is not
/// chrome — it is the ground a collage is composed against, and it belongs to the fit rather
/// than to the phone. `FitCanvas` used adaptive `Color.paper`, so an outfit arranged in the
/// afternoon was a different picture at night, and worse: `FitRender` baked that appearance
/// into the PNG, so a fit rendered after dark carried a near-black ground **permanently**,
/// including into a share sheet. Same fact as `Color.sweep` — a garment photographed on white
/// does not invert, so what it sits on must not either.
///
/// The base is the app's own paper tone and always will be; the rest are quiet grounds for the
/// times a black jacket needs something other than off-white behind it, or somebody just wants
/// this fit to look like something. Deliberately a short list rather than a colour wheel: the
/// app is achromatic apart from one accent, and a picker with sixteen million answers in it is
/// a decision nobody asked to make.
/// **Plus one you choose yourself.** The short list above is the argument for restraint and
/// it stands — it is what the picker leads with, and it is what almost every fit will use.
/// What it cannot do is the one thing somebody occasionally actually wants: a fit built
/// around a specific garment, on a ground picked to sit against *that* garment. Seven
/// answers is a curated palette; seven answers and no way past them is a palette that has
/// started saying no.
///
/// The custom case is a hex, and it is the **one** place in this file that stores a rendering
/// rather than a verdict. That is deliberate and it is the only honest option: the reason a
/// token is stored for `bone` is so re-tuning the palette later reaches every fit that chose
/// it, and there is no palette behind a colour somebody mixed by hand — the hex *is* the
/// decision. It round-trips through `rawValue` like any other case, so nothing downstream
/// knows the difference, and an unparseable string still falls back to `base` rather than
/// failing, which is what lets a fit written by a newer build open here.
enum FitBackground: Hashable, Identifiable, Sendable {
    /// The default, matching `Color.paper` in its light appearance.
    case bone
    case chalk
    /// The studio sweep a garment is photographed on — see `Color.sweep`.
    case sweep
    case clay
    case sage
    case mist
    case slate
    /// A colour chosen by hand, as `#rrggbb`.
    case custom(String)

    static let base: FitBackground = .bone

    /// The curated grounds, in the order the picker prints them. Not `allCases` — the custom
    /// one has no fixed value to enumerate — and every caller wants exactly this list.
    static let presets: [FitBackground] = [.bone, .chalk, .sweep, .clay, .sage, .mist, .slate]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bone: "Bone"
        case .chalk: "Chalk"
        case .sweep: "Sweep"
        case .clay: "Clay"
        case .sage: "Sage"
        case .mist: "Mist"
        case .slate: "Slate"
        case .custom(let hex): hex.uppercased()
        }
    }

    var color: Color {
        switch self {
        case .bone: Color(uiColor: UIColor(red: 0.980, green: 0.980, blue: 0.969, alpha: 1))
        case .chalk: Color(uiColor: UIColor(red: 1, green: 1, blue: 1, alpha: 1))
        case .sweep: Color(uiColor: UIColor(red: 0.957, green: 0.953, blue: 0.933, alpha: 1))
        case .clay: Color(uiColor: UIColor(red: 0.906, green: 0.871, blue: 0.824, alpha: 1))
        case .sage: Color(uiColor: UIColor(red: 0.863, green: 0.886, blue: 0.839, alpha: 1))
        case .mist: Color(uiColor: UIColor(red: 0.867, green: 0.886, blue: 0.902, alpha: 1))
        case .slate: Color(uiColor: UIColor(red: 0.192, green: 0.196, blue: 0.188, alpha: 1))
        case .custom(let hex): Color(uiColor: Self.uiColor(fromHex: hex) ?? .white)
        }
    }

    /// Type and chrome drawn **on** this ground. Fixed for the same reason the ground is: an
    /// adaptive ink over a ground that cannot invert is invisible half the time.
    ///
    /// For a chosen colour it is **measured** rather than looked up, because the whole point
    /// of the case is that the value was not known in advance — and the empty-canvas
    /// invitation is drawn in this, so getting it wrong means an invisible instruction on a
    /// blank screen. The threshold is perceived luminance, not brightness: pure yellow and
    /// pure blue have the same HSB brightness and need opposite ink.
    var ink: Color {
        switch self {
        case .slate: return Color(uiColor: UIColor(red: 0.961, green: 0.961, blue: 0.941, alpha: 1))
        case .custom(let hex):
            guard let colour = Self.uiColor(fromHex: hex) else { return Self.darkInk }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            return luminance < 0.55 ? Self.lightInk : Self.darkInk
        default: return Self.darkInk
        }
    }

    private static let darkInk = Color(uiColor: UIColor(red: 0.078, green: 0.078, blue: 0.059, alpha: 1))
    private static let lightInk = Color(uiColor: UIColor(red: 0.961, green: 0.961, blue: 0.941, alpha: 1))

    // MARK: - Stored form

    var rawValue: String {
        switch self {
        case .bone: "bone"
        case .chalk: "chalk"
        case .sweep: "sweep"
        case .clay: "clay"
        case .sage: "sage"
        case .mist: "mist"
        case .slate: "slate"
        case .custom(let hex): hex
        }
    }

    /// Fails only on a string that is neither a known token nor a hex, and `Fit.ground`
    /// treats that as the default — a fit written by a build that knew a ground this one does
    /// not must still open.
    init?(rawValue: String) {
        if let preset = Self.presets.first(where: { $0.rawValue == rawValue }) {
            self = preset
            return
        }
        guard let normalised = Self.normalisedHex(rawValue) else { return nil }
        self = .custom(normalised)
    }

    /// `#rrggbb`, lowercased, or nil. Accepts a bare six digits as well as a leading hash,
    /// since a stored value written by hand elsewhere should still open.
    private static func normalisedHex(_ raw: String) -> String? {
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6,
              digits.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return "#" + digits.lowercased()
    }

    private static func uiColor(fromHex hex: String) -> UIColor? {
        guard let normalised = normalisedHex(hex),
              let value = UInt32(normalised.dropFirst(), radix: 16)
        else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The ground for a colour somebody mixed, or the nearest preset when it *is* one —
    /// so choosing bone out of the wheel selects the bone swatch rather than minting a
    /// second, identical-looking ground beside it.
    static func chosen(_ color: Color) -> FitBackground {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let hex = String(
            format: "#%02x%02x%02x",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
        for preset in presets {
            var pr: CGFloat = 0, pg: CGFloat = 0, pb: CGFloat = 0, pa: CGFloat = 0
            UIColor(preset.color).getRed(&pr, green: &pg, blue: &pb, alpha: &pa)
            if abs(pr - red) < 0.004, abs(pg - green) < 0.004, abs(pb - blue) < 0.004 {
                return preset
            }
        }
        return .custom(hex)
    }
}

/// One garment's position on a fit's canvas.
///
/// Normalised, not in points: the canvas is drawn at whatever width the device gives it,
/// and storing pixel coordinates would scrunch every fit made on a Pro Max when opened on
/// a mini. `x`/`y` are the centre of the piece as a fraction of the canvas, and `scale` is
/// relative to a nominal tile — so a fit is resolution-independent and renders identically
/// at thumbnail size.
struct FitPlacement: Codable, Hashable, Sendable, Identifiable {
    var itemID: UUID
    var x: Double
    var y: Double
    var scale: Double
    /// Radians. Free rotation, because snapping is what makes a collage feel like a form.
    var rotation: Double
    /// Draw order. Sparse and ever-increasing rather than a compacted 0..<n, so bringing
    /// one piece to the front is a single write instead of renumbering the whole canvas.
    var z: Int

    var id: UUID { itemID }

    init(
        itemID: UUID,
        x: Double = 0.5,
        y: Double = 0.5,
        scale: Double = 1,
        rotation: Double = 0,
        z: Int = 0
    ) {
        self.itemID = itemID
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
        self.z = z
    }

    /// Lenient by hand, and it has to be.
    ///
    /// SwiftData decodes a Codable stored in a `@Model` with an internal `try!`, so a
    /// field added here after a store was written is not a migration problem — it is a
    /// crash on launch for anyone holding the older data. Only `itemID` is required;
    /// everything else falls back to the middle of the canvas at natural size, which is
    /// exactly where a freshly dropped piece would land anyway.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(UUID.self, forKey: .itemID)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        z = try container.decodeIfPresent(Int.self, forKey: .z) ?? 0
    }
}

extension SavedItem {
    /// Which part of an outfit this occupies, read off the catalogue text.
    ///
    /// Computed rather than stored: it depends only on fields that never change after the
    /// item is saved, and a stored copy would go stale the moment the classifier improves
    /// — the same trap `BrandUpdate.gender` needed a version number to escape, but without
    /// the cost, because nothing filters on this at feed scale.
    var slot: GarmentSlot {
        guard let update else { return .unknown }
        return GarmentClassifier.classify(
            title: update.title,
            productType: update.productType,
            tags: update.tags,
            visionCategories: update.visionCategories
        )
    }
}

/// A fit the app proposes, assembled from things already saved.
///
/// Not stored — recomputed from the wardrobe each time, because it is a *suggestion*
/// rather than a record. The moment someone keeps one it becomes a real `Fit` and stops
/// being regenerated.
/// One garment in a proposal, which may or may not be yours.
///
/// A suggestion used to be `[SavedItem]` — strictly things already kept — and that made the
/// row useless in the case it should have been best at: a wardrobe with four tops and no
/// trousers got nothing at all, when "here is a bottom that would work with these" is the
/// most useful sentence the app could say. So a piece is now a `BrandUpdate` plus an
/// *optional* save, and `isOwned` is the difference.
///
/// The save is what carries the personal side — the note, the board, the size you own — so
/// keeping it rather than reaching through `update.saves` matters: a proposal built from a
/// catalogue row must not silently adopt somebody's note by matching on the product.
struct FitPiece: Identifiable, Hashable {
    var update: BrandUpdate
    /// The save this stands for, when it is something already kept. Nil means the app is
    /// suggesting a garment you do not have.
    var save: SavedItem?

    var isOwned: Bool { save != nil }
    var slot: GarmentSlot { save?.slot ?? update.garmentSlot }

    /// Identity is the save where there is one and the product otherwise, so a proposal
    /// does not change id the moment the same garment is kept.
    var id: String { save?.id.uuidString ?? update.id.uuidString }

    static func == (lhs: FitPiece, rhs: FitPiece) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SuggestedFit: Identifiable, Hashable {
    var items: [FitPiece]

    /// The pieces this proposal is asking you to acquire. Empty for a fit made entirely of
    /// things you already own, which stays the common case.
    var unowned: [FitPiece] { items.filter { !$0.isOwned } }

    /// Why this pairing, in the four words that fit under a card.
    ///
    /// Not decoration. A suggestion nobody can account for is indistinguishable from a
    /// random pair, which is exactly what the row felt like when it was proposing on slot
    /// and date alone — so the thing that scores a fit also has to say what it saw. Nil
    /// when the wardrobe has not been analysed yet and there is genuinely nothing to say.
    var reason: String?

    /// Stable across recomputation so SwiftUI doesn't animate a reshuffle on every render.
    var id: String { items.map(\.id).sorted().joined() }

    /// The garments in this proposal, as a key that survives keeping it.
    ///
    /// **Not `id`.** A `FitPiece`'s identity is its save where it has one and its product
    /// otherwise — so a proposal containing something borrowed from the catalogue changes id
    /// the moment it is kept, which is exactly the moment we want to recognise it by. The
    /// products behind it do not change, so they are what the comparison is made of.
    var wardrobeKey: String { FitSuggestions.key(ofProducts: items.map(\.update.id)) }

    var ordered: [FitPiece] {
        items.sorted { wornOver($0.update, $1.update, tieBreak: $0.id < $1.id) }
    }
}

/// Whether `first` is worn over `second` — the order a fit is read and drawn in.
///
/// `GarmentSlot.stackOrder` alone was enough until a fit could hold **two tops**: a hoodie
/// now brings a tee with it, and the two tie on that key. A tie is resolved in whatever
/// order the array happened to be in, so the base layer could be drawn on top of the thing
/// meant to cover it — which on a collage is not a subtle mistake.
/// - Parameter tieBreak: what to fall back on when the two are indistinguishable by
///   position and layer. Passed in rather than read here because a `SuggestedFit` is keyed
///   on its pieces and a stored `Fit` on its saves, and the arrangement has to be stable
///   across relaunches either way.
private func wornOver(_ first: BrandUpdate?, _ second: BrandUpdate?, tieBreak: @autoclosure () -> Bool) -> Bool {
    let firstSlot = first?.garmentSlot ?? .unknown
    let secondSlot = second?.garmentSlot ?? .unknown
    if firstSlot.stackOrder != secondSlot.stackOrder {
        return firstSlot.stackOrder < secondSlot.stackOrder
    }
    // Mid layers first, so they are drawn over the base layer they cover.
    let firstIsMid = first?.garment.layer == .mid
    let secondIsMid = second?.garment.layer == .mid
    if firstIsMid != secondIsMid { return firstIsMid }
    return tieBreak()
}


enum FitSuggestions {
    /// Composes outfits from saved items, one garment per position on the body.
    ///
    /// The rules are deliberately dull, because a recommender that is clever and wrong is
    /// worse than one that is obvious and right:
    ///
    /// - **One item per slot**, and never two of the same — two pairs of trousers is not
    ///   a fit. The single exception is the layered pair this engine is meant to build: a
    ///   hoodie with a tee under it is two tops and is how a hoodie is worn.
    /// - **A top and a bottom are required.** Outerwear and footwear are added when the
    ///   wardrobe has them; a proposal of just a jacket is not an outfit. A **set** — a
    ///   tracksuit, a co-ord — is both halves at once and is proposed on its own terms.
    /// - **Nothing unplaceable is ever used.** An item the classifier couldn't read would
    ///   appear in a slot it may not belong to, which reads as a bug rather than a
    ///   suggestion.
    /// - **Deterministic.** Seeded by nothing but the wardrobe itself, so the same saves
    ///   produce the same fits and the section doesn't reshuffle every time it is drawn.
    /// - **It looks at the clothes, and at the whole outfit.** Every structural rule above
    ///   can be satisfied by something obviously wrong to anyone with eyes, so `Outfit`
    ///   scores the finished proposal — colours across all of it, how many pieces are
    ///   shouting, whether anything is repeated, whether the proportions balance — and
    ///   hands back the line that says why. Where nothing has been analysed yet every rule
    ///   in it falls silent and the order is what it always was.
    ///
    /// **The row is spread, not merely sorted.** Ranking alone produced six proposals built
    /// from the same two or three garments, because a wardrobe that is mostly dark scores its
    /// dark combinations highest and there is nothing in a sort that notices it is printing
    /// the same shirt six times. See `spread`.
    ///
    /// - Parameter statement: what the wearer has written about how they dress, where they
    ///   have written anything. It reorders and can rescue a pair the colour rules would
    ///   have refused; it never proposes a fit the structural rules rejected.
    /// - Parameter candidates: catalogue products, from brands already followed, offered
    ///   **only for slots the wardrobe cannot fill at all**. See `gapPieces`.
    /// - Parameter kept: the fits that already exist, so a proposal somebody has taken stops
    ///   being made. Keeping one is supposed to end its regeneration — the row is derived
    ///   from the wardrobe and a kept fit is a record rather than a proposal — and nothing
    ///   was doing it: both cards stayed on the row after being kept, and tapping either
    ///   again wrote a second outfit holding the same clothes.
    static func build(
        from saves: [SavedItem],
        candidates: [BrandUpdate] = [],
        limit: Int = 6,
        statement: StyleStatement = StyleStatement(),
        kept: [Fit] = []
    ) -> [SuggestedFit] {
        var bySlot: [GarmentSlot: [FitPiece]] = [:]
        var sets: [FitPiece] = []

        // A suggestion is looked at before it is read, and a piece with no photograph
        // renders as a blank rectangle — so a proposal containing one looks broken however
        // good the pairing is. `ColorHarmony` can't speak for it either: the dominant
        // colour comes from the photograph.
        for save in saves where save.update?.imageURLStrings.isEmpty == false {
            let slot = save.slot
            guard slot != .unknown, GarmentSlot.essential.contains(slot),
                  let update = save.update
            else { continue }
            let piece = FitPiece(update: update, save: save)
            // A set is held aside rather than filed under the half its title happens to
            // name. Left in the pool it would be combined with a second top or a second
            // bottom, which is precisely the proposal that made the row look broken.
            if update.garment.isSet {
                sets.append(piece)
            } else {
                bySlot[slot, default: []].append(piece)
            }
        }

        // Newest first within each slot, so a fit is built from what someone is currently
        // into rather than from whatever they saved a year ago.
        for slot in bySlot.keys {
            bySlot[slot]?.sort { ($0.save?.savedAt ?? .distantPast) > ($1.save?.savedAt ?? .distantPast) }
        }
        sets.sort { ($0.save?.savedAt ?? .distantPast) > ($1.save?.savedAt ?? .distantPast) }

        // **Only where the wardrobe is genuinely empty.** See `gapPieces` for why this is a
        // gap-filler rather than a general source of pieces.
        for (slot, pieces) in gapPieces(from: candidates, missing: bySlot) {
            bySlot[slot] = pieces
        }

        let outerwear = bySlot[.outerwear] ?? []
        let footwear = bySlot[.footwear] ?? []
        let allTops = bySlot[.top] ?? []
        let bottoms = bySlot[.bottom] ?? []

        // Every garment in the wardrobe, in the terms the scoring reasons about, built
        // **once**. `BrandUpdate.garment` runs the slot and layer classifiers and builds a
        // vocabulary set, and the search below asks about the same pieces hundreds of times
        // — so constructing one per comparison was most of the cost of this function and the
        // reason the cross product had to be walked diagonally rather than properly.
        var garments: [String: Garment] = [:]
        for piece in allTops + bottoms + outerwear + footwear + sets {
            garments[piece.id] = piece.update.garment
        }
        func garment(_ piece: FitPiece) -> Garment { garments[piece.id] ?? piece.update.garment }

        var proposals: [(fit: SuggestedFit, score: Double)] = []
        var seen: Set<String> = []

        func admit(_ items: [FitPiece]) {
            let verdict = Outfit.score(items.map(garment), statement: statement)
            guard !verdict.isRefused else { return }
            let fit = SuggestedFit(items: items, reason: verdict.reason)
            guard seen.insert(fit.id).inserted else { return }
            proposals.append((fit, verdict.score))
        }

        // A set is the whole body already: it takes shoes, a cap and a jacket and nothing
        // else. Offered first so that a wardrobe holding one still produces its proposal
        // even when the cross product below fills the row.
        for piece in sets.prefix(perSlotCandidates) {
            var items = [piece]
            var chosen = [garment(piece)]
            if let shoe = accompaniment(to: chosen, from: footwear, statement: statement, garment: garment) {
                items.append(shoe)
                chosen.append(garment(shoe))
            }
            if let coat = accompaniment(to: chosen, from: outerwear, statement: statement, garment: garment) {
                items.append(coat)
            }
            admit(items)
        }

        guard !allTops.isEmpty, !bottoms.isEmpty else {
            return spread(proposals, limit: limit)
        }

        // **The whole cross product of a bounded pool**, rather than a diagonal walk of an
        // unbounded one. The diagonal was there to vary both axes early while only visiting
        // `max(tops, bottoms) * 2` combinations, which is cheap and *systematically* narrow:
        // it can only ever produce pairs whose indices agree modulo the list lengths, so most
        // of a wardrobe's combinations were never considered at all. With the garments built
        // once above, sixty-four combinations cost less than the sixteen used to.
        let topPool = Array(allTops.prefix(searchWidth))
        let bottomPool = Array(bottoms.prefix(searchWidth))

        for top in topPool {
            for bottom in bottomPool {
                let topGarment = garment(top)
                let bottomGarment = garment(bottom)

                var items = [top, bottom]
                var chosen = [topGarment, bottomGarment]

                // **The shoes and the jacket are chosen, not counted to.** They used to be
                // appended by `index % count` — an arithmetic accident of position in a list
                // sorted by date — so half of a four-piece proposal had been reasoned about
                // and half had not.
                if let shoe = accompaniment(to: chosen, from: footwear, statement: statement, garment: garment) {
                    items.append(shoe)
                    chosen.append(garment(shoe))
                }
                if let coat = accompaniment(to: chosen, from: outerwear, statement: statement, garment: garment) {
                    items.append(coat)
                    chosen.append(garment(coat))
                }

                // **Nothing that needs something under it goes out without one.**
                //
                // `GarmentSlot` files a t-shirt and a hoodie in the same box, which is right
                // for "what kind of thing is this" and wrong here — so one-top-per-slot
                // happily proposed a hoodie and trousers with nothing underneath, or a jacket
                // over a hoodie over bare skin. Nobody dresses like that, and a suggestion
                // that does reads as the app not knowing what clothes are.
                //
                // **A wardrobe with no base layer in it still gets suggestions**: the rule
                // completes a fit, it must not delete one. Somebody who has kept three
                // hoodies and no t-shirt would otherwise open this row to nothing at all.
                if chosen.contains(where: \.needsBaseLayer),
                   !chosen.contains(where: { $0.slot == .top && $0.layer == .base }) {
                    let bases = topPool.filter {
                        $0.id != top.id && garment($0).layer == .base
                    }
                    if let base = accompaniment(to: chosen, from: bases, statement: statement, garment: garment) {
                        items.append(base)
                    }
                }

                admit(items)
            }
        }

        // Anything already kept is not a proposal any more. Compared on the *products* in
        // it rather than on the proposal's id, which changes the moment a borrowed garment
        // is saved — see `SuggestedFit.wardrobeKey`. Filtered here rather than before the
        // search, so a kept fit still contributes to the spread's sense of what has been
        // shown and the row does not simply promote a near-copy of it.
        let taken = Set(kept.compactMap(\.wardrobeKey))
        let offered = taken.isEmpty
            ? proposals
            : proposals.filter { !taken.contains($0.fit.wardrobeKey) }

        return spread(offered, limit: limit)
    }

    /// One key for a set of products, used to recognise the same outfit twice.
    ///
    /// Order-independent and duplicate-tolerant, because "the same fit" is a question about
    /// which clothes are in it and nothing else.
    static func key(ofProducts ids: [UUID]) -> String {
        Set(ids.map(\.uuidString)).sorted().joined(separator: "|")
    }

    /// How many tops and how many bottoms are considered. Bounds the search at
    /// `searchWidth²` proposals; past that the extra combinations are drawn from clothes
    /// somebody saved long enough ago that the row should not be leading with them.
    private static let searchWidth = 8

    /// Picks the row so that it shows a **wardrobe**, not one garment six ways.
    ///
    /// Sorting alone is not enough and the reason is structural rather than a tuning
    /// problem. Scores cluster — most of a streetwear wardrobe is black, `ColorHarmony`
    /// rates black-on-black at 0.9, and every proposal containing the one shirt that scores
    /// well therefore scores well — so the top six by score were routinely six fits built
    /// from the same two or three pieces. On a real collection the same zip hoodie appeared
    /// in all of them.
    ///
    /// So the row is filled **one card at a time, each chosen against what is already in
    /// it**: the best-scoring proposal that repeats the least and, above all, shares nothing
    /// with the card immediately before it. Selection and ordering are the same pass, because
    /// doing them separately is what produced a row whose *first three* cards were all built
    /// on the one pair of blue jeans — every constraint was satisfied and the only part
    /// anybody sees without scrolling was still the same fit three times.
    ///
    /// Deterministic, with no randomness: the input is sorted by score with the id as
    /// tie-break, and ties in the cost below fall back to that order. Same property
    /// `Discovery.order` holds and for the same reason — scrolling back must show the same
    /// cards.
    private static func spread(
        _ ranked: [(fit: SuggestedFit, score: Double)],
        limit: Int
    ) -> [SuggestedFit] {
        var remaining = ranked
            .sorted { $0.score == $1.score ? $0.fit.id < $1.fit.id : $0.score > $1.score }
            .map(\.fit)

        var chosen: [SuggestedFit] = []
        var used: [String: Int] = [:]

        while chosen.count < limit, !remaining.isEmpty {
            let previous = Set(chosen.last?.items.map(\.id) ?? [])

            // The cost of showing this fit next. Sharing a garment with the card *beside* it
            // is weighted far above showing one that appeared earlier in the row, because
            // adjacency is what reads as the app repeating itself — two cards apart, the same
            // trousers are just a wardrobe with one pair of trousers in it, which is the
            // truth.
            var best = 0
            var bestCost = Int.max
            for (index, fit) in remaining.enumerated() {
                let ids = fit.items.map(\.id)
                let adjacent = ids.filter(previous.contains).count
                let repeats = ids.reduce(0) { $0 + (used[$1] ?? 0) }
                let cost = adjacent * adjacencyWeight + repeats
                if cost < bestCost {
                    bestCost = cost
                    best = index
                }
            }

            let fit = remaining.remove(at: best)
            chosen.append(fit)
            for id in fit.items.map(\.id) { used[id, default: 0] += 1 }
        }
        return chosen
    }

    /// How much heavier a garment shared with the *neighbouring* card counts than one shown
    /// earlier in the row. Large enough that a fit with any overlap is passed over while any
    /// fit without one remains, and small enough that a wardrobe holding a single pair of
    /// shoes still fills the row rather than stopping at one card.
    private static let adjacencyWeight = 100

    /// Catalogue products for the slots the wardrobe cannot fill at all.
    ///
    /// **A gap-filler, deliberately, and not a general source of pieces.** The row is
    /// called "From your wardrobe" and its value is that it is *yours*; a version that
    /// mixed shop stock into every proposal would turn the one screen about what you own
    /// into a storefront, which is the criticism the Style tab already answered once by
    /// moving Discover below the reading of your own collection.
    ///
    /// What it fixes is the opposite case, where the row was worst exactly when it should
    /// have been best: four tops and no trousers produced *nothing at all*, when "here is a
    /// bottom that would work with these" is the most useful sentence the app can say. The
    /// wardrobe gaps are already computed and printed one section further down.
    ///
    /// Only ever from brands already followed — these are rows the poller has synced, so
    /// nothing here is fetched to build a suggestion — and only ones carrying a photograph
    /// and a colour. **The colour requirement is the point**: `visionColor` is written by
    /// `ImageTagger`, which by design runs over saves alone, so an unmeasured product
    /// scores neutral against everything and would be picked on recency. That is precisely
    /// the "randomly thrown together" failure the scoring exists to prevent, so a candidate
    /// that has not been looked at is not offered. `FitCandidates` is what arranges for a
    /// bounded few to have been.
    private static func gapPieces(
        from candidates: [BrandUpdate],
        missing bySlot: [GarmentSlot: [FitPiece]]
    ) -> [GarmentSlot: [FitPiece]] {
        guard !candidates.isEmpty else { return [:] }
        var filled: [GarmentSlot: [FitPiece]] = [:]
        for candidate in candidates {
            let slot = candidate.garmentSlot
            guard slot != .unknown, GarmentSlot.essential.contains(slot),
                  bySlot[slot]?.isEmpty != false,
                  !candidate.imageURLStrings.isEmpty,
                  candidate.visionColor != nil
            else { continue }
            filled[slot, default: []].append(FitPiece(update: candidate, save: nil))
        }
        // Newest first, matching how the wardrobe's own pieces are ordered, and capped so a
        // brand that published two hundred products in one sweep cannot own the whole slot.
        for slot in filled.keys {
            filled[slot] = Array(
                (filled[slot] ?? [])
                    .sorted { ($0.update.publishedAt ?? .distantPast) > ($1.update.publishedAt ?? .distantPast) }
                    .prefix(perSlotCandidates)
            )
        }
        return filled
    }

    /// How many unowned products may stand for one empty slot. Small on purpose: this is a
    /// suggestion about clothes you own, with a hole filled in, not a shop.
    private static let perSlotCandidates = 6

    /// The best of `options` to put with a fit already decided, or nil when the slot is
    /// empty or nothing in it works.
    ///
    /// Scored against **every** piece already in the fit and taking the worst of those
    /// scores, not the average: a jacket that goes with the trousers and fights the top is
    /// not a good jacket for this outfit, and averaging lets one strong agreement hide one
    /// real clash. An outright clash with any piece is refused outright, unless the wearer
    /// has named that pairing themselves — the same override the top-and-bottom rule allows,
    /// because an app that refuses the outfit its user described is arguing with them.
    ///
    /// Returning nil is a real answer and a common one. A three-piece fit that works beats a
    /// four-piece fit with a wrong shoe in it, and the slot was optional to begin with.
    private static func accompaniment(
        to chosen: [Garment],
        from options: [FitPiece],
        statement: StyleStatement,
        garment: (FitPiece) -> Garment
    ) -> FitPiece? {
        var best: (item: FitPiece, score: Double)?
        for option in options {
            let candidate = garment(option)
            var worst = Double.greatestFiniteMagnitude
            var refused = false
            for piece in chosen {
                let stated = statement.statedPairing(between: piece, and: candidate)
                if !stated, ColorHarmony.isClash(piece.color, candidate.color) {
                    refused = true
                    break
                }
                // **A layered pair is the one same-slot combination that is an outfit**, and
                // this function could not admit one — which made the base-layer branch above
                // it dead code. The branch only runs when the chosen top is a `.mid`, so the
                // first comparison here was always top-against-top, `Pairing`'s slot gate
                // refused it, and every candidate came back nil. So the app went on proposing
                // a full-zip hoodie over bare skin while `Outfit.score` charged −0.12 for
                // exactly that — a penalty on proposals the engine had no way to avoid.
                // `Outfit.swift` says in as many words that both build sites need this guard;
                // `FitStudio.best` had it and this did not.
                //
                // Skipped from the *gate*, not from the judging: two tops still have to agree
                // on colour, and a clashing layer is refused above like any other pair.
                if Outfit.isLayeredPair(piece, candidate) {
                    worst = min(worst, ColorHarmony.score(piece.color, candidate.color).score)
                    continue
                }
                let verdict = Pairing.score(piece, with: candidate, statement: statement)
                // A refusal is a refusal — a set already occupying this position, a seasonal
                // mismatch — and it used to be read as a score of zero, which merely made
                // the option unlikely rather than impossible.
                if verdict.isRefused {
                    refused = true
                    break
                }
                worst = min(worst, verdict.score)
            }
            guard !refused, worst < .greatestFiniteMagnitude else { continue }
            // Ties broken on the id so the row does not reshuffle between renders — the
            // property the whole of `build` is written around, and the common case on a
            // wardrobe nothing has been measured in yet.
            if let current = best,
               current.score > worst || (current.score == worst && current.item.id <= option.id) {
                continue
            }
            best = (option, worst)
        }
        return best?.item
    }
}
