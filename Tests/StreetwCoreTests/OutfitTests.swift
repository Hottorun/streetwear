import Foundation
import Testing

@testable import StreetwCore

/// The rules that only exist across a whole outfit — see `Outfit`. Every one of them was
/// written against a real collection that the pairwise scoring had already passed.
@Suite("Outfit")
struct OutfitTests {
    private func garment(
        _ title: String,
        color: String? = nil,
        secondary: String? = nil,
        busyness: Double = 0,
        silhouette: String? = nil,
        id: String? = nil
    ) -> Garment {
        Garment(
            id: id ?? title,
            title: title,
            color: color,
            secondaryColor: secondary,
            busyness: busyness,
            silhouette: silhouette
        )
    }

    // MARK: - Structure

    @Test("Two things in one position is not an outfit")
    func doubleBookedIsRefused() {
        let verdict = Outfit.score([
            garment("Cargo Pant", color: "Black"),
            garment("Denim Jean", color: "Black"),
            garment("Cotton Tee", color: "White")
        ])
        #expect(verdict.isRefused)
    }

    /// The one same-slot pair that is how clothes are actually worn.
    @Test("A hoodie with a tee under it is two tops and is allowed")
    func layeredTopsAreAllowed() {
        let verdict = Outfit.score([
            garment("Zip Hoodie", color: "Black"),
            garment("Cotton Tee", color: "White"),
            garment("Cargo Pant", color: "Charcoal")
        ])
        #expect(!verdict.isRefused)
    }

    /// A tracksuit is a top and a bottom in one row. Putting another hoodie with it was the
    /// proposal that made the suggestion row look broken on a real wardrobe.
    @Test("A set is not combined with another top")
    func setRefusesASecondTop() {
        let verdict = Outfit.score([
            garment("Corteiz Tracksuit", color: "Black"),
            garment("Zip Hoodie", color: "Black")
        ])
        #expect(verdict.isRefused)
    }

    @Test("A set takes shoes and a cap perfectly happily")
    func setAcceptsAccompaniment() {
        let verdict = Outfit.score([
            garment("Corteiz Tracksuit", color: "Black"),
            garment("Runner Sneaker", color: "White")
        ])
        #expect(!verdict.isRefused)
    }

    /// A set occupies both positions on its own, which is what `Garment.isSet` means — so
    /// the `count >= 2` guard was refusing the one proposal a wardrobe of one tracksuit and
    /// some tees can make, and `FitSuggestions`'s sets branch says in as many words that it
    /// exists so such a wardrobe "still produces its proposal".
    @Test("A set on its own is already an outfit")
    func aLoneSetIsAnOutfit() {
        let verdict = Outfit.score([garment("Corteiz Tracksuit", color: "Black")])
        #expect(!verdict.isRefused)
    }

    /// …and a single garment that is *not* a set still is not an outfit.
    @Test("A single ordinary garment is not an outfit")
    func aLoneGarmentIsNot() {
        #expect(Outfit.score([garment("Cotton Tee", color: "White")]).isRefused)
    }

    /// `Pairing`'s gate turns down two inessential garments because pairing them answers
    /// nothing — a fair answer to that question and the wrong one here, where
    /// `isDoubleBooked` has just decided several accessories are what people wear.
    @Test("A cap and a tote inside a fit do not refuse the whole outfit")
    func twoAccessoriesDoNotRefuse() {
        let verdict = Outfit.score([
            garment("Cotton Tee", color: "White"),
            garment("Cargo Pant", color: "Black"),
            garment("Six Panel Cap", color: "Black"),
            garment("Canvas Tote Bag", color: "Black")
        ])
        // Pinned, because the test only means anything if these two really are the
        // inessential pair `Pairing` refuses — a classifier change that made either of them
        // `.unknown` would leave it passing for a different reason.
        #expect(garment("Six Panel Cap").slot == .headwear)
        #expect(garment("Canvas Tote Bag").slot == .accessory)
        #expect(!verdict.isRefused)
    }

    // MARK: - Colour across the whole thing

    /// The correction this file exists for. `ColorHarmony` rates two identical colours above
    /// a colour against a neutral, so on a wardrobe that is mostly black the all-black fit
    /// outranked every fit with anything in it — and the row showed six of them.
    @Test("A single colour among neutrals beats an entirely neutral fit")
    func focalColourOutranksMonochrome() {
        let monochrome = Outfit.score([
            garment("Cotton Tee", color: "Black"),
            garment("Cargo Pant", color: "Black"),
            garment("Runner Sneaker", color: "Black")
        ])
        let focal = Outfit.score([
            garment("Cotton Tee", color: "Burgundy"),
            garment("Cargo Pant", color: "Black"),
            garment("Runner Sneaker", color: "Black")
        ])
        #expect(focal.score > monochrome.score)
        #expect(focal.reason == "Burgundy against neutrals")
    }

    @Test("Past three colours an outfit stops reading as chosen")
    func tooManyColoursIsMarkedDown() {
        let busy = Outfit.score([
            garment("Cotton Tee", color: "Orange"),
            garment("Cargo Pant", color: "Green"),
            garment("Runner Sneaker", color: "Purple")
        ])
        let quiet = Outfit.score([
            garment("Cotton Tee", color: "Orange"),
            garment("Cargo Pant", color: "Black"),
            garment("Runner Sneaker", color: "White")
        ])
        #expect(busy.score < quiet.score)
    }

    /// A colour worn twice is the oldest trick in dressing and is invisible pairwise, because
    /// the two pieces that echo each other are usually not the pair being scored.
    @Test("A colour picked up twice is noticed")
    func echoIsRewarded() {
        let verdict = Outfit.score([
            garment("Cotton Tee", color: "Black"),
            garment("Cargo Pant", color: "Black"),
            garment("Runner Sneaker", color: "Black", secondary: "Olive"),
            garment("Ripstop Cap", color: "Olive")
        ])
        #expect(verdict.reason == "Olive picked up twice")
    }

    /// Every rule here has to fall silent rather than score down when it has nothing to read:
    /// most wardrobes are half-unanalysed, and Vision does not run in the Simulator at all.
    @Test("An unmeasured wardrobe is not penalised for silence")
    func nothingMeasuredIsNotAPenalty() {
        let unmeasured = Outfit.score([
            garment("Cotton Tee"),
            garment("Cargo Pant"),
            garment("Runner Sneaker")
        ])
        #expect(!unmeasured.isRefused)
        #expect(unmeasured.score >= 0.4)
    }

    // MARK: - Loudness and layers

    @Test("Three loud pieces score below one")
    func statementsCompete() {
        let one = Outfit.score([
            garment("Cotton Tee", color: "Black", busyness: 0.9),
            garment("Cargo Pant", color: "Black"),
            garment("Runner Sneaker", color: "Black")
        ])
        let three = Outfit.score([
            garment("Cotton Tee", color: "Black", busyness: 0.9),
            garment("Cargo Pant", color: "Black", busyness: 0.9),
            garment("Runner Sneaker", color: "Black", busyness: 0.9)
        ])
        #expect(three.score < one.score)
    }

    @Test("A hoodie with nothing under it scores below the same fit with a tee")
    func missingBaseLayerIsMarkedDown() {
        let bare = Outfit.score([
            garment("Zip Hoodie", color: "Black"),
            garment("Cargo Pant", color: "Charcoal")
        ])
        let layered = Outfit.score([
            garment("Zip Hoodie", color: "Black"),
            garment("Cotton Tee", color: "White"),
            garment("Cargo Pant", color: "Charcoal")
        ])
        #expect(layered.score > bare.score)
    }
}

/// Volume balance — the one rule of dressing that is close to universal and that the app can
/// actually measure, off the silhouette `Silhouette` reads from the cutout mask.
@Suite("Volume")
struct VolumeTests {
    private func top(_ silhouette: String?) -> Garment {
        Garment(id: "top", title: "Cotton Tee", color: "Black", silhouette: silhouette)
    }

    private func bottom(_ silhouette: String?) -> Garment {
        Garment(id: "bottom", title: "Cargo Pant", color: "Black", silhouette: silhouette)
    }

    @Test("A boxy top with a tapered leg is the balance")
    func boxyOverTaperedIsBalanced() {
        let verdict = Pairing.score(top("Boxy"), with: bottom("Tapered"))
        #expect(verdict.reason == "Volume up top")
    }

    @Test("A close top with a wide leg is the same balance the other way round")
    func longlineOverWideIsBalanced() {
        let verdict = Pairing.score(top("Longline"), with: bottom("Wide"))
        #expect(verdict.reason == "Volume on the leg")
    }

    /// **Volume on volume is not marked down**, and this test is the one guarding against
    /// the rule every styling guide states next. An oversized hoodie over an oversized leg is
    /// the house style here — measured against a real collection, the penalty version marked
    /// down a boxy zip hoodie with wide pleated sweatpants, which is the outfit that wardrobe
    /// exists to produce. Same reasoning that keeps a formality rule out of `Pairing`.
    @Test("Oversized on oversized is not penalised — it is the house style")
    func wideOnWideIsNotPenalised() {
        let matched = Pairing.score(top("Boxy"), with: bottom("Wide"))
        let unmeasured = Pairing.score(top(nil), with: bottom(nil))
        #expect(matched.score == unmeasured.score)
    }

    /// `SilhouetteBands` refuses to answer far more often than it answers, so an unmeasured
    /// pair must score exactly as it did before this rule existed.
    @Test("An unmeasured outline says nothing either way")
    func unmeasuredSaysNothing() {
        let unmeasured = Pairing.score(top(nil), with: bottom(nil))
        let half = Pairing.score(top("Boxy"), with: bottom(nil))
        #expect(unmeasured.score == half.score)
    }
}
