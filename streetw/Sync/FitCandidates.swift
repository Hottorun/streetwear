// Catalogue products offered to fill a hole in the wardrobe.
//
// `FitSuggestions` composes outfits from things you kept, which leaves it useless in the
// one case it should be best at: four tops and no trousers produces nothing at all, when
// "here is a bottom that would work with these" is the most useful sentence the app can
// say. This finds the products that could stand in, from brands already followed.
//
// Two constraints shape the whole file.
//
// **It must not subscribe a view to the catalogue.** `BrandUpdate` is every product ever
// synced — hundreds per brand — and an unpredicated `@Query` over it would rebuild the
// Style tab on every poll. So this is a bounded `FetchDescriptor` asked once from a
// `.task`, exactly as the performance notes in CLAUDE.md prescribe.
//
// **A candidate has to have been looked at.** `visionColor` is written by `ImageTagger`,
// which by design runs over saved items alone, so a catalogue product has no measured
// colour — and `ColorHarmony` scores an absent colour as neutral, meaning an unmeasured
// candidate would be chosen on recency. That is the "randomly thrown together" failure the
// scoring exists to prevent, arriving through a new door. So the pool is measured before it
// is offered, and the measuring is deliberately tiny: a few products per empty slot, once,
// against the 250-per-sweep the analysis pass is explicitly forbidden from touching.

import Foundation
import OSLog
import StreetwCore
import SwiftData

@MainActor
enum FitCandidates {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "tagging")

    /// How many products are considered per empty slot before measuring. Larger than the
    /// number that will be offered, so the colour pass has something to choose between
    /// rather than ratifying whatever was newest.
    private static let considered = 8

    /// How far back into the catalogue to look at all. A bound on the fetch rather than on
    /// the answer: the store holds 400 products per brand and this only ever needs a
    /// handful, so reading the newest few hundred across all brands is generous.
    private static let window = 400

    /// Products that could fill `gaps`, measured and ready to be scored.
    ///
    /// Returns nothing when the wardrobe has no gaps, which is the common case and costs
    /// one cheap check rather than a fetch.
    static func pool(for gaps: Set<GarmentSlot>, in context: ModelContext) async -> [BrandUpdate] {
        guard !gaps.isEmpty else { return [] }

        // **No predicate on the photographs, and that is not a style preference.**
        //
        // This read `#Predicate { !$0.imageURLStrings.isEmpty }`, which looks like every
        // other narrowing in the app and is not one: `imageURLStrings` is a `[String]`
        // *attribute*, stored as a blob, and CoreData has no SQL for `isEmpty` over one — so
        // the fetch threw `NSInvalidArgumentException` out of `NSSQLGenerator` and took the
        // app down. (A relationship is different: `!$0.saves.isEmpty` compiles to a count and
        // is what `SharedSaveImporter` uses.) The crash was invisible for as long as it was,
        // because this whole function returns early unless an essential slot is *completely*
        // empty — so it fired the day somebody's wardrobe lost a slot, on the Style tab, with
        // nothing on screen to connect the two.
        //
        // The window is the bound instead, and the photograph is checked in Swift below.
        var descriptor = FetchDescriptor<BrandUpdate>(
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = window
        guard let recent = try? context.fetch(descriptor) else { return [] }

        // Classify in memory and take a few per gap. Bounded twice — by the fetch above and
        // by `considered` here — so the measuring below can never run away.
        var bySlot: [GarmentSlot: [BrandUpdate]] = [:]
        for update in recent {
            guard !update.imageURLStrings.isEmpty else { continue }
            let slot = update.garmentSlot
            guard gaps.contains(slot), (bySlot[slot]?.count ?? 0) < considered else { continue }
            bySlot[slot, default: []].append(update)
        }
        let chosen = bySlot.values.flatMap { $0 }
        guard !chosen.isEmpty else { return [] }

        // Measure the ones that have not been. This is the whole reason a candidate can be
        // scored on colour at all rather than on the order it was published in.
        let unmeasured = chosen.filter { $0.visionColor == nil }
        if !unmeasured.isEmpty {
            log.info("measuring \(unmeasured.count) fit candidates across \(gaps.count) empty slots")
            await ImageTagger.analyze(unmeasured, in: context)
        }

        // Only what actually came back with a colour. A product whose photograph would not
        // download, or whose read was interrupted, is simply not offered this time round —
        // it stays unmeasured and is picked up on a later pass, the same rule the saved
        // backlog follows.
        return chosen.filter { $0.visionColor != nil }
    }

    /// Which essential slots the wardrobe cannot fill at all.
    ///
    /// Deliberately "none at all" rather than "few": this is a gap-filler, and a wardrobe
    /// that has two pairs of trousers does not need the app shopping for a third.
    static func gaps(in saves: [SavedItem]) -> Set<GarmentSlot> {
        var owned: Set<GarmentSlot> = []
        for save in saves where save.update?.imageURLStrings.isEmpty == false {
            owned.insert(save.slot)
        }
        return Set(GarmentSlot.essential).subtracting(owned)
    }
}
