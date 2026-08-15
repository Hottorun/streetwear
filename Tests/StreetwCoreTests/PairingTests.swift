import Foundation
import Testing

@testable import StreetwCore

@Suite("Pairing")
struct PairingTests {
    private func garment(_ title: String, color: String? = nil, id: String? = nil) -> Garment {
        Garment(id: id ?? title, title: title, color: color)
    }

    @Test("Two of the same slot is never an outfit")
    func sameSlotIsRefused() {
        let verdict = Pairing.score(garment("Cargo Pant"), with: garment("Denim Jean"))
        #expect(verdict.isRefused)
    }

    /// `.unknown` is the classifier declining to answer and is a large share of most
    /// catalogues. Pairing against it would be a guess wearing the clothes of a suggestion.
    @Test("An unplaceable garment is never proposed")
    func unknownSlotIsRefused() {
        #expect(Pairing.score(garment("Nocturne"), with: garment("Cargo Pant")).isRefused)
    }

    @Test("A top and a bottom is the ordinary case")
    func complementarySlotsPass() {
        let verdict = Pairing.score(garment("Boxy Tee"), with: garment("Cargo Pant"))
        #expect(!verdict.isRefused)
    }

    /// The one pairing that is wrong in every subculture, which is exactly why it is safe
    /// to encode — unlike formality, which in streetwear is not a rule at all.
    @Test("A parka does not go with swim shorts")
    func seasonalMismatchIsRefused() {
        #expect(Pairing.score(garment("Down Puffer Jacket"), with: garment("Swim Shorts")).isRefused)
        #expect(Pairing.score(garment("Shearling Coat"), with: garment("Boardshorts")).isRefused)
    }

    /// The narrowing that the failing version of the test above bought, pinned so it stays:
    /// a fabric is not a season. Wool and linen turn up all year, a tank is a base layer,
    /// and mesh is what a basketball jersey is made of — each of them was refusing pairings
    /// nobody would object to.
    @Test("A fabric is not a season")
    func fabricIsNotSeasonal() {
        #expect(!Pairing.score(garment("Wool Coat"), with: garment("Mesh Shorts")).isRefused)
        #expect(!Pairing.score(garment("Linen Shirt"), with: garment("Fleece Pants")).isRefused)
    }

    /// The deliberate omission, pinned so nobody "fixes" it back in: a blazer with track
    /// pants is the house style, not a mistake.
    @Test("Dressy with sporty is not a mistake here")
    func formalityIsNotPenalised() {
        #expect(!Pairing.score(garment("Wool Blazer"), with: garment("Track Pants")).isRefused)
        #expect(!Pairing.score(garment("Oxford Shirt"), with: garment("Mesh Shorts")).isRefused)
    }

    /// Found by the test above: a blazer resolved to `.unknown`, so it could never appear
    /// in a fit, be suggested against anything, or count as the wardrobe's outerwear.
    @Test("Outerwear the classifier used to miss", arguments: [
        "Wool Blazer", "Corduroy Overshirt", "Quilted Shacket", "Varsity Jacket"
    ])
    func placesOuterwear(title: String) {
        #expect(GarmentClassifier.classify(title: title) == .outerwear)
    }

    /// Read off a real wardrobe rather than guessed at. Three of eleven saved items on the
    /// test device resolved to `.unknown` — invisible to fits, to pairings and to the
    /// wardrobe's own slot counts — and two of them were ordinary clothes: Palace names its
    /// hoodies "P3 HOOD", and "fleece" was in no list at all.
    @Test("Clothes a real wardrobe had that the classifier didn't", arguments: [
        ("RUBBED P3 HOOD THE DEEP GREEN", GarmentSlot.top),
        ("INDOOR FUNNEL FLEECE ORANGE", GarmentSlot.top),
        ("3M CORDURA SMALL CROSS BODY UTILITY BLACK", GarmentSlot.unknown),
        ("3M CORDURA CROSSBODY BLACK", GarmentSlot.accessory)
    ])
    func placesRealWardrobe(title: String, slot: GarmentSlot) {
        #expect(GarmentClassifier.classify(title: title) == slot)
    }

    /// The ordering that keeps the addition safe: a fleece *jacket* is still outerwear,
    /// because the table is walked in slot order and outerwear is checked before tops.
    @Test("A fleece jacket is outerwear, a fleece is a top")
    func outerwearStillWinsTheCompound() {
        #expect(GarmentClassifier.classify(title: "Polar Fleece Jacket") == .outerwear)
        #expect(GarmentClassifier.classify(title: "Funnel Neck Fleece") == .top)
    }

    @Test("Clashing colours are refused")
    func colourClashIsRefused() {
        let verdict = Pairing.score(
            garment("Boxy Tee", color: "Orange"),
            with: garment("Cargo Pant", color: "Purple")
        )
        #expect(verdict.isRefused)
    }

    /// Nothing analysed yet is not the same as having looked and disapproved — and Vision
    /// does not run in the Simulator at all, so this is the common case in development.
    @Test("An unmeasured colour scores neutral, not badly")
    func missingColourIsNeutral() {
        let verdict = Pairing.score(garment("Boxy Tee"), with: garment("Cargo Pant"))
        #expect(!verdict.isRefused)
        #expect(verdict.reason == nil)
    }

    /// The measured reading outranks the word list, and has to: the vocabulary was always a
    /// stand-in for looking. A plain black hoodie whose title happens to say "Print Studios"
    /// is not a loud piece, and an all-over paisley named "Nocturne" is.
    @Test("A measured photograph beats the word that stood in for it")
    func measurementOutranksVocabulary() {
        let namedButPlain = Garment(id: "a", title: "Print Studios Hoodie", busyness: 0.05)
        let unnamedButLoud = Garment(id: "b", title: "Nocturne Shirt", busyness: 0.9)
        #expect(!namedButPlain.isStatement)
        #expect(unnamedButLoud.isStatement)
    }

    /// A chest wordmark competes for the same attention as a print, which is the only thing
    /// this is used to decide — and it is the reading no title could ever have supplied.
    @Test("Lettering counts as loud")
    func textCountsAsStatement() {
        #expect(Garment(id: "a", title: "Boxy Tee", textCoverage: 0.2).isStatement)
        #expect(!Garment(id: "b", title: "Boxy Tee", textCoverage: 0.01).isStatement)
    }

    /// Nothing measured is not the same as measured and quiet. A product nobody has saved
    /// has never been through `ImageTagger`, and that is most of the catalogue — so the
    /// words have to keep working there.
    @Test("An unmeasured garment still falls back to its words")
    func unmeasuredFallsBackToWords() {
        #expect(Garment(id: "a", title: "Camo Cargo Pant").isStatement)
        #expect(!Garment(id: "b", title: "Cargo Pant").isStatement)
    }

    @Test("An accent that clashes is a penalty, never a veto")
    func clashingAccentIsPenalisedNotRefused() {
        let plain = Pairing.score(
            Garment(id: "a", title: "Boxy Tee", color: "Black"),
            with: Garment(id: "b", title: "Cargo Pant", color: "Olive")
        )
        let accented = Pairing.score(
            Garment(id: "a", title: "Boxy Tee", color: "Black", secondaryColor: "Purple"),
            with: Garment(id: "b", title: "Cargo Pant", color: "Orange")
        )
        #expect(accented.score < plain.score)
        #expect(!accented.isRefused, "an accent is the smaller part of the garment")
    }

    @Test("Two loud prints rank below one")
    func printOnPrintIsPenalised() {
        let quiet = Pairing.score(
            garment("Graphic Tee", color: "Black"),
            with: garment("Cargo Pant", color: "Black")
        )
        let loud = Pairing.score(
            garment("Graphic Tee", color: "Black"),
            with: garment("Camo Cargo Pant", color: "Black")
        )
        #expect(loud.score < quiet.score)
        // Penalised, never vetoed: print on print is a real thing people wear.
        #expect(!loud.isRefused)
    }

    @Test("Outerwear over a top says so when the colours had nothing to add")
    func layeringCarriesItsOwnReason() {
        let verdict = Pairing.score(garment("Shell Jacket"), with: garment("Boxy Tee"))
        #expect(verdict.reason == "Layers over it")
    }

    @Test("The wardrobe's answers are ranked, and stable between renders")
    func bestIsRankedAndDeterministic() {
        let subject = garment("Boxy Tee", color: "Black", id: "subject")
        let wardrobe = [
            garment("Cargo Pant", color: "Purple", id: "a"),
            garment("Denim Jean", color: "Orange", id: "b"),
            garment("Shell Jacket", color: "Black", id: "c"),
            garment("Boxy Tee", color: "White", id: "subject")  // itself, by id
        ]
        let first = Pairing.best(for: subject, from: wardrobe, limit: 4)
        let second = Pairing.best(for: subject, from: wardrobe, limit: 4)

        #expect(first.map(\.garment.id) == second.map(\.garment.id), "a redraw must not reshuffle")
        #expect(!first.map(\.garment.id).contains("subject"), "never itself")
        #expect(first.first?.garment.id == "c", "black on black outranks black on a colour")
    }
}
