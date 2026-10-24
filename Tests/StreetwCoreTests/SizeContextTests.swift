import Foundation
import Testing

@testable import StreetwCore

// The contexts the tests read in, named for the garment rather than spelled out each time.
private let sneaker = SizeContext(garment: .footwear)
private let trousers = SizeContext(garment: .bottoms)
private let womensTrousers = SizeContext(garment: .bottoms, cut: .womens)
private let dress = SizeContext(garment: .upper, cut: .womens)
private let unlabelledTop = SizeContext(garment: .upper)
private let mensJacket = SizeContext(garment: .upper, cut: .mens)
private let blazer = SizeContext(garment: .upper, isTailored: true)
private let mensInchRun = SizeContext(garment: .upper, cut: .mens, runScale: .us)
private let mensEuropeanRun = SizeContext(garment: .upper, cut: .mens, runScale: .eu)
private let cap = SizeContext(garment: .headwear)
private let kidsTop = SizeContext(garment: .upper, cut: .kids)

@Suite("Size context")
struct SizeContextDerivationTests {
    private func context(
        _ title: String,
        productType: String? = nil,
        tags: [String] = [],
        gender: Gender = .unknown,
        sizes: [String] = []
    ) -> SizeContext {
        SizeContext.of(gender: gender, title: title, productType: productType, tags: tags, sizes: sizes)
    }

    @Test("The slot decides the garment")
    func slotDecides() {
        #expect(context("Air Max 90 Sneaker").garment == .footwear)
        #expect(context("Loose Denim Jeans").garment == .bottoms)
        #expect(context("Heavyweight Hoodie").garment == .upper)
        #expect(context("Wool Overcoat").garment == .upper)
        #expect(context("Logo Beanie").garment == .headwear)
    }

    /// `GarmentClassifier` places neither a dress nor a suit, and leaving them unplaced was
    /// the bug: an unplaced product's numbers are read as shoes.
    @Test("A dress and a suit are placed although no slot holds them")
    func dressesAndSuitsArePlaced() {
        let slip = context("Satin Slip Dress")
        #expect(slip.garment == .upper)
        #expect(slip.cut == .womens)

        let suit = context("Wool Suit")
        #expect(suit.garment == .upper)
        #expect(suit.isTailored)

        #expect(context("Linen Jumpsuit").cut == .womens)
        #expect(context("Midi", productType: "Dresses").cut == .womens)
    }

    /// The head noun is last: a "shirt dress" is a dress and a "dress shirt" a man's shirt,
    /// sized by the collar. Reading the second as womenswear would put a 15.5 collar on the
    /// dress ladder.
    @Test("A dress shirt is not a dress, and a shirt dress is")
    func headNoun() {
        #expect(context("Oxford Dress Shirt", gender: .mens).cut == .mens)
        #expect(context("Cotton Shirt Dress").cut == .womens)
        #expect(context("Leather Dress Shoes").garment == .footwear)
        #expect(context("Leather Dress Shoes").cut == .unspecified)
    }

    @Test("Blazers and sport coats are tailoring; track suits and boiler suits are not")
    func tailoringWords() {
        #expect(context("Double Breasted Blazer").isTailored)
        #expect(context("Tweed Sport Coat").isTailored)
        #expect(context("Two-Piece Suit").isTailored)
        #expect(!context("Nylon Track Suit").isTailored)
        #expect(!context("Canvas Boiler Suit").isTailored)
        #expect(!context("Fleece Tracksuit").isTailored)
    }

    /// Bras are sized band-and-cup, and that ladder is later work. Until then a bra's
    /// "34L" must not land on the suit ladder, so the whole product reads as before.
    @Test("A bra reads as an unplaced product")
    func brasAreLeftAlone() {
        #expect(context("Lace Bralette Top", gender: .womens) == .unknown)
        #expect(context("Sports Bra") == .unknown)
    }

    @Test("A product nothing places is the unknown context")
    func unknownStaysUnknown() {
        #expect(context("Gift Card") == .unknown)
        #expect(context("Leather Belt") == .unknown)
    }

    /// A girl's dress is sized by age, so the dress words do not make it womenswear.
    @Test("A child's dress keeps the kids cut")
    func kidsDress() {
        #expect(context("Girls Party Dress", gender: .kids).cut == .kids)
    }

    /// The two men's systems print the same numbers for different people. A run is printed
    /// in one of them, and its ends say which.
    @Test("A man's run of bare numbers says which system it is in")
    func runScale() {
        #expect(context("Wool Blazer", gender: .mens, sizes: ["36", "38", "40", "42", "44"]).runScale == .us)
        #expect(context("Wool Blazer", gender: .mens, sizes: ["46", "48", "50", "52", "54"]).runScale == .eu)
        #expect(context("Wool Blazer", gender: .mens, sizes: ["42", "44", "46", "48"]).runScale == nil)
        #expect(context("Wool Blazer", gender: .mens, sizes: ["S", "M", "L"]).runScale == nil)
    }
}

/// The collisions the roadmap names, in both directions: each string read on each garment.
@Suite("Sizes read by garment")
struct SizesByGarmentTests {
    private func read(_ raw: String, _ context: SizeContext) -> NormalizedSize? {
        SizeNormalizer.normalize(raw, in: context)
    }

    @Test("A bare 38 is a shoe on a shoe, a waist on trousers and a French 38 on a dress")
    func thirtyEight() {
        #expect(read("38", sneaker)?.kind == .shoe)
        #expect(read("38", sneaker)?.isConverted == true)
        #expect(read("38", trousers)?.kind == .waist)
        #expect(read("38", trousers)?.token == "38")
        #expect(read("38", dress)?.kind == .dress)
        #expect(read("38", dress)?.token == "6")
        #expect(read("38", dress)?.label == "38")
    }

    /// The live bug: a US dress size read as a US shoe size, so a shoe profile claimed it.
    @Test("A US dress size is not a shoe size")
    func dressSizeIsNotAShoe() {
        for raw in ["4", "6", "8", "10", "12", "14", "16", "18"] {
            #expect(read(raw, dress)?.kind == .dress, "\(raw) on a dress")
            #expect(read(raw, dress)?.token == raw)
            #expect(read(raw, sneaker)?.kind == .shoe, "\(raw) on a sneaker")
        }
    }

    @Test("A UK 10 is a UK 10 dress on a dress and a UK 10 shoe on a shoe")
    func ukTen() {
        #expect(read("UK 10", dress)?.kind == .dress)
        #expect(read("UK 10", dress)?.token == "6")
        #expect(read("UK 10", dress)?.label == "10")
        #expect(read("UK 10", sneaker)?.kind == .shoe)
        #expect(read("UK 10", sneaker)?.token == "11")
        #expect(read("UK 10", womensTrousers)?.token == "6")
    }

    @Test("A bare 34 is a waist on trousers and a French 34 on a dress")
    func thirtyFour() {
        #expect(read("34", trousers)?.kind == .waist)
        #expect(read("36", trousers)?.kind == .waist)
        #expect(read("34", dress)?.kind == .dress)
        #expect(read("34", dress)?.token == "2")
        #expect(read("36", dress)?.token == "4")
    }

    /// The bare band stops at 37 only because a bare 38 might be a European shoe, and no
    /// shoe is printed on a pair of trousers.
    @Test("On trousers a bare number is a waist across the whole range")
    func fullWaistRange() {
        for raw in ["38", "40", "42", "44"] {
            #expect(read(raw, trousers)?.kind == .waist, "\(raw) on trousers")
        }
        #expect(read("32R", trousers)?.token == "32")
        #expect(read("34 Long", trousers)?.token == "34")
        #expect(read("UK 32", trousers)?.kind == .waist)
    }

    @Test("A European 37–46 on a shoe is a shoe, and on a dress a dress")
    func europeanShoesAndDresses() {
        #expect(read("EU 37", sneaker)?.kind == .shoe)
        #expect(read("EU 44", sneaker)?.token == "10")
        #expect(read("44", sneaker)?.token == "10", "a bare 44 on a sneaker can only be European")
        #expect(read("EU 38", dress)?.token == "6")
        #expect(read("EU 46", dress)?.token == "14")
        #expect(read("FR 38", dress)?.token == "6", "FR is the European ladder")
    }

    @Test("An Italian size is its own ladder for dresses")
    func italian() {
        #expect(read("IT 40", dress)?.kind == .dress)
        #expect(read("IT 40", dress)?.token == "4")
        #expect(read("IT 42", unlabelledTop)?.token == "6")
        #expect(read("IT 42", sneaker)?.kind == .shoe, "an Italian shoe is a European one")
    }

    /// "EU 48" is a women's 16 and a men's 38 chest at once. The cut decides, and a garment
    /// that names itself tailoring decides it for the suit.
    @Test("EU 48 and EU 50 are suits on a men's jacket, not size 14 sneakers")
    func europeanSuits() {
        #expect(read("EU 48", mensJacket)?.kind == .suit)
        #expect(read("EU 48", mensJacket)?.token == "38")
        #expect(read("EU 50", mensJacket)?.token == "40")
        #expect(read("EU 50", mensJacket)?.label == "50")
        #expect(read("IT 52", mensJacket)?.token == "42")
        #expect(read("EU 48", dress)?.token == "16")
        #expect(read("EU 48", blazer)?.token == "38")
        #expect(read("EU 48", unlabelledTop)?.kind == .other, "both readings exist and nothing settles it")
        #expect(read("EU 38", unlabelledTop)?.kind == .dress, "below the men's ladder there is only one reading")
    }

    @Test("A chest with a length is tailoring", arguments: [
        ("38R", "38R"), ("40L", "40L"), ("42S", "42S"),
        ("40 Regular", "40R"), ("40 Long", "40L"), ("38 Short", "38S"), ("44 Reg", "44R")
    ])
    func suffixedChests(raw: String, token: String) {
        let size = read(raw, mensJacket)
        #expect(size?.kind == .suit)
        #expect(size?.token == token)
        #expect(read(raw, unlabelledTop)?.token == token, "a length is unmistakable without a gender")
    }

    @Test("A women's size with a length keeps the size")
    func womensLength() {
        #expect(read("10 Long", dress)?.kind == .dress)
        #expect(read("10 Long", dress)?.token == "10")
    }

    /// A UK and US chest never meets a women's UK size, so a code settles the ladder.
    @Test("UK and US codes settle the ladder on an unlabelled top")
    func codesSettle() {
        #expect(read("UK 10", unlabelledTop)?.kind == .dress)
        #expect(read("UK 40", unlabelledTop)?.kind == .suit)
        #expect(read("US 4", unlabelledTop)?.kind == .dress)
    }

    /// Japanese brands size 0–5 and European ones 44–56; an unlabelled bare number on a top
    /// is any of three things, so it is none of them.
    @Test("A bare number on an unlabelled top is nobody's size", arguments: ["2", "4", "38", "40", "48"])
    func unlabelledBareStaysOther(raw: String) {
        #expect(read(raw, unlabelledTop)?.kind == .other)
    }

    /// The dress ladder is women's. A men's "UK 10" or "EU 38" is a collar or a mistake.
    @Test("A men's top never reads the dress ladder")
    func mensNeverDress() {
        #expect(read("UK 10", mensJacket)?.kind == .other)
        #expect(read("EU 38", mensJacket)?.kind == .other)
        #expect(read("4", mensJacket)?.kind == .other)
    }

    /// The YoungLA lesson: reading the ends of a run and not its middle is worse than reading
    /// none of it. So a man's bare numbers are read only when the run has said which system.
    @Test("A man's bare numbers are read whole or not at all")
    func mensRunWholeOrNothing() {
        #expect(read("44", mensInchRun)?.token == "44")
        #expect(read("38", mensInchRun)?.token == "38")
        #expect(read("44", mensEuropeanRun)?.token == "34")
        #expect(read("50", mensEuropeanRun)?.token == "40")
        #expect(read("50", mensEuropeanRun)?.label == "50")
        for raw in ["42", "44", "46", "48"] {
            #expect(read(raw, mensJacket)?.kind == .other, "\(raw) with no run to settle it")
        }
    }

    @Test("Bra sizes stay unread everywhere", arguments: ["34B", "32DD", "36C"])
    func braSizes(raw: String) {
        for context in [sneaker, trousers, dress, unlabelledTop, mensJacket, blazer, SizeContext.unknown] {
            #expect(read(raw, context)?.kind == .other, "\(raw) in \(context)")
        }
    }

    @Test("A cap's number is a hat size, which no ladder holds")
    func capsAreNotShoes() {
        #expect(read("7", cap)?.kind == .other)
        #expect(read("7 1/4", cap)?.kind == .other)
        #expect(read("M", cap)?.kind == .apparel)
    }

    @Test("A child's number is an age")
    func kidsAreAges() {
        #expect(read("8", kidsTop)?.kind == .other)
        #expect(read("8", SizeContext(garment: .bottoms, cut: .kids))?.kind == .other)
        // Youth sneaker sizes are the men's numbers, and adults with small feet buy them.
        #expect(read("5.5", SizeContext(garment: .footwear, cut: .kids))?.kind == .shoe)
    }

    /// Letters are read before the context is consulted, which is what lets a caller skip
    /// building one for a run with no numbers in it.
    @Test("Letters and one-size read the same on every garment")
    func lettersAreContextFree() {
        for context in [sneaker, trousers, dress, mensJacket, cap, kidsTop, SizeContext.unknown] {
            #expect(read("Medium", context)?.token == "M")
            #expect(read("One Size", context)?.kind == .oneSize)
            #expect(read("Petite Small", context)?.kind == .other)
        }
        #expect(!SizeContext.matters(for: ["S", "M", "XL", "One Size"]))
        #expect(SizeContext.matters(for: ["S", "M", "38"]))
    }

    /// The other direction of every case above: with no garment to go on, nothing changed.
    /// These are the readings the roadmap calls a live bug, kept exactly as they were
    /// because a product nobody can place has no better answer.
    @Test("Unplaced, every string reads as it did before contexts existed", arguments: [
        ("4", SizeKind.shoe, "4"), ("10", .shoe, "10"), ("UK 10", .shoe, "11"),
        ("34", .waist, "34"), ("36", .waist, "36"), ("38", .other, "38"),
        ("EU 44", .shoe, "10"), ("EU 48", .shoe, "13"), ("IT 40", .other, "IT 40"),
        ("38R", .other, "38R"), ("40 Regular", .other, "40 REGULAR"),
        ("34B", .other, "34B"), ("32DD", .other, "32DD"), ("M", .apparel, "M")
    ])
    func unknownUnchanged(raw: String, kind: SizeKind, token: String) {
        let size = SizeNormalizer.normalize(raw)
        #expect(size?.kind == kind, "\(raw)")
        #expect(size?.token == token, "\(raw)")
        #expect(SizeNormalizer.normalize(raw, in: .unknown) == size)
    }

    /// Converting both sides of "EU 41" and "EU 41.5" lands them on one US size; a run keyed
    /// on that printed one of them and dropped the other.
    @Test("Two sizes that convert to one token keep their own labels")
    func labelsStayDistinct() {
        let small = read("EU 41", sneaker)
        let half = read("EU 41.5", sneaker)
        #expect(small?.token == half?.token)
        #expect(small?.label == "41")
        #expect(half?.label == "41.5")
        #expect(read("Medium", sneaker)?.label == "M")
    }
}

@Suite("Dress and suit ladders")
struct DressAndSuitLadderTests {
    @Test("The dress table is fixed offsets from US", arguments: [
        (SizeScale.uk, 10.0, 6.0), (.uk, 4, 0), (.uk, 32, 28), (.uk, 2, -2),
        (.eu, 38, 6), (.eu, 32, 0), (.eu, 60, 28), (.eu, 30, -2),
        (.it, 42, 6), (.it, 36, 0), (.it, 64, 28), (.it, 34, -2),
        (.us, 6, 6)
    ])
    func dressTable(scale: SizeScale, value: Double, us: Double) {
        #expect(DressSizes.toUS(value, from: scale) == us)
        #expect(DressSizes.fromUS(us, to: scale) == value)
    }

    /// Odd US numbers are the juniors' ladder, cut for a different body.
    @Test("Odd, fractional and out-of-range numbers are not dress sizes", arguments: [
        (SizeScale.us, 5.0), (.us, 30), (.us, 6.5), (.uk, 0), (.uk, 34), (.eu, 28), (.eu, 39), (.it, 32)
    ])
    func dressRefusals(scale: SizeScale, value: Double) {
        #expect(DressSizes.toUS(value, from: scale) == nil)
    }

    /// Staud and Ulla Johnson both run 00–16. Read as a number, "00" is 0, so the run
    /// printed one of the two and a profile of 0 claimed both.
    @Test("00 is its own rung, below 0")
    func doubleZero() {
        let doubleZero = SizeNormalizer.normalize("00", in: dress)
        #expect(doubleZero?.kind == .dress)
        #expect(doubleZero?.token == "00")
        #expect(doubleZero?.label == "00")
        #expect(SizeNormalizer.normalize("0", in: dress)?.token == "0")
        #expect(SizeNormalizer.normalize("UK 2", in: dress)?.token == "00")
        #expect(SizeNormalizer.normalize("EU 30", in: dress)?.token == "00")
        #expect(SizeNormalizer.normalize("00", in: sneaker)?.kind == .other)
        #expect(SizeNormalizer.normalize("05", in: dress)?.kind == .other, "no other leading zero is a number")

        var mine = SizeProfile()
        mine.dress = ["00"]
        #expect(mine.claims("00", in: dress))
        #expect(!mine.claims("0", in: dress))
        #expect(mine.claims("UK 2", in: dress))
        #expect(SizeProfile.dressOptions.first == "00")
        #expect(SizeProfile.dressOptions(in: .eu).first?.display == "30")
    }

    @Test("A European or Italian jacket is the chest plus ten")
    func suitTable() {
        #expect(SuitSizes.chest(48, from: .eu) == 38)
        #expect(SuitSizes.chest(50, from: .it) == 40)
        #expect(SuitSizes.chest(40, from: .uk) == 40)
        #expect(SuitSizes.chest(49, from: .eu) == nil, "the European ladder is even")
        #expect(SuitSizes.chest(42, from: .eu) == nil, "below the European ladder")
        #expect(SuitSizes.fromChest(40, to: .eu) == 50)
        #expect(SuitSizes.fromChest(40, to: .us) == 40)
    }

    @Test("The pickers print each ladder in the chosen scale and store it canonically")
    func pickerOptions() {
        let uk = SizeProfile.dressOptions(in: .uk)
        #expect(uk.first?.display == "2")
        #expect(uk.first?.stored == "00")
        #expect(uk.first { $0.stored == "0" }?.display == "4")
        #expect(SizeProfile.dressOptions(in: .eu).first { $0.stored == "6" }?.display == "38")
        #expect(SizeProfile.dressOptions(in: .it).first { $0.stored == "6" }?.display == "42")
        #expect(SizeProfile.suitOptions(in: .eu).first { $0.stored == "40" }?.display == "50")
        #expect(SizeProfile.dressOptions == SizeProfile.dressOptions(in: .us).map(\.stored))
        #expect(SizeProfile.suitOptions == SizeProfile.suitOptions(in: .us).map(\.stored))
    }
}

@Suite("Matching the new ladders")
struct NewLadderMatchingTests {
    private func profile(
        shoe: [String] = [],
        dress: [String] = [],
        suit: [String] = [],
        suitLength: [String] = []
    ) -> SizeProfile {
        var p = SizeProfile()
        p.shoe = Set(shoe)
        p.dress = Set(dress)
        p.suit = Set(suit)
        p.suitLength = Set(suitLength)
        return p
    }

    /// The live bug, end to end. A woman entered a shoe size; a dress in her shoe number
    /// was ruled as hers, and one in her dress size was not.
    @Test("A shoe size says nothing about a dress")
    func shoeProfileOnADress() {
        let shoesOnly = profile(shoe: ["8"])
        #expect(!shoesOnly.claims("8", in: dress), "a US 8 dress is not a US 8 shoe")
        #expect(shoesOnly.matches("8", in: dress), "and an unfilled dress ladder hides nothing")
        #expect(shoesOnly.matches("UK 12", in: dress))
        #expect(shoesOnly.claims("8", in: sneaker))
        // The old reading, unchanged where nothing is known about the garment.
        #expect(shoesOnly.claims("8", in: .unknown))
    }

    @Test("A native US dress size matches exactly")
    func nativeDressIsExact() {
        let mine = profile(dress: ["6"])
        #expect(mine.claims("6", in: dress))
        #expect(!mine.claims("8", in: dress))
        #expect(!mine.claims("4", in: dress))
        #expect(!mine.matches("8", in: dress))
    }

    /// Tables disagree by a rung — a German "EUR 38" is a US 8 where a French 38 is a 6 —
    /// so a converted size matches within one, and no further.
    @Test("A converted dress size matches within one rung")
    func convertedDressIsTolerant() {
        let mine = profile(dress: ["6"])
        #expect(mine.claims("EU 38", in: dress), "EU 38 is US 6 exactly")
        #expect(mine.claims("EU 40", in: dress), "a German 40 is a US 6")
        #expect(mine.claims("EU 36", in: dress), "one rung the other way")
        #expect(!mine.claims("EU 42", in: dress), "two rungs is another body")
        #expect(mine.claims("UK 10", in: dress))
        #expect(mine.claims("38", in: dress), "a bare French size is a conversion too")
        #expect(!mine.matches("EU 44", in: dress))
    }

    /// The tables agree, so there is nothing to absorb — and a jacket two inches off does
    /// not button.
    @Test("A converted chest matches exactly")
    func suitIsExact() {
        let mine = profile(suit: ["40"])
        #expect(mine.claims("EU 50", in: mensJacket))
        #expect(!mine.claims("EU 48", in: mensJacket))
        #expect(!mine.claims("EU 52", in: mensJacket))
        #expect(mine.claims("40R", in: mensJacket))
        #expect(mine.claims("40", in: mensInchRun))
    }

    @Test("A length narrows only when both sides have one")
    func suitLengths() {
        let regular = profile(suit: ["40"], suitLength: ["R"])
        #expect(regular.claims("40R", in: mensJacket))
        #expect(regular.claims("40 Regular", in: mensJacket))
        #expect(!regular.claims("40L", in: mensJacket))
        #expect(!regular.matches("40L", in: mensJacket))
        #expect(regular.claims("EU 50", in: mensJacket), "a run with no lengths is one jacket per chest")

        let anyLength = profile(suit: ["40"])
        #expect(anyLength.claims("40L", in: mensJacket))
        #expect(anyLength.claims("40S", in: mensJacket))
    }

    @Test("A length on its own is not a profile")
    func lengthAloneIsEmpty() {
        let lengthOnly = profile(suitLength: ["R"])
        #expect(lengthOnly.isEmpty)
        #expect(lengthOnly.matches("40L", in: mensJacket))
        #expect(!lengthOnly.claims("40R", in: mensJacket))
    }

    /// Each ladder filters only once filled in — one `isEmpty ||` per ladder.
    @Test("An unfilled dress or suit ladder hides nothing")
    func laddersAreIndependent() {
        let dressOnly = profile(dress: ["6"])
        #expect(dressOnly.matches("EU 50", in: mensJacket))
        #expect(dressOnly.matches("9", in: sneaker))
        #expect(dressOnly.matches("32", in: trousers))
        #expect(!dressOnly.claims("EU 50", in: mensJacket))

        let suitOnly = profile(suit: ["40"])
        #expect(suitOnly.matches("UK 10", in: dress))
        #expect(suitOnly.matches("9", in: sneaker))
        #expect(!suitOnly.claims("UK 10", in: dress))
    }

    @Test("An unread size is never hidden and never claimed")
    func unreadIsPermissive() {
        let mine = profile(dress: ["6"], suit: ["40"])
        for raw in ["34B", "2", "48"] {
            #expect(mine.matches(raw, in: unlabelledTop))
            #expect(!mine.claims(raw, in: unlabelledTop))
        }
    }

    @Test("The summary names the new ladders in their own scales")
    func summary() {
        var p = profile(dress: ["4", "6"], suit: ["40", "42"], suitLength: ["R", "L"])
        #expect(p.summary == "Dress US 4, 6 · Suit 40, 42 R/L")
        p.dressScale = .uk
        p.suitScale = .eu
        #expect(p.summary == "Dress UK 8, 10 · Suit EU 50, 52 R/L")
        #expect(p.dress == ["4", "6"], "changing scale must not rewrite storage")
    }
}

@Suite("Size profile storage and wire")
struct SizeProfileStorageTests {
    /// Every phone that ran 1.0 holds a profile written before these ladders existed, in
    /// UserDefaults. A non-optional decode of a missing key throws, and the store then falls
    /// back to an empty profile — every size somebody set, gone on update.
    @Test("A profile stored before the dress and suit ladders still decodes")
    func decodesOlderProfile() throws {
        let stored = #"{"apparel":["M"],"shoe":["9"],"waist":["32"],"shoeScale":"eu","gender":"womens"}"#
        let decoded = try JSONDecoder().decode(SizeProfile.self, from: Data(stored.utf8))

        #expect(decoded.apparel == ["M"])
        #expect(decoded.shoe == ["9"])
        #expect(decoded.waist == ["32"])
        #expect(decoded.shoeScale == .eu)
        #expect(decoded.gender == .womens)
        #expect(decoded.dress.isEmpty)
        #expect(decoded.dressScale == .us)
        #expect(decoded.suit.isEmpty)
        #expect(decoded.suitLength.isEmpty)
        #expect(decoded.suitScale == .us)
    }

    @Test("The new ladders round-trip through storage")
    func roundTrips() throws {
        var p = SizeProfile()
        p.dress = ["6"]
        p.dressScale = .it
        p.suit = ["40"]
        p.suitLength = ["R"]
        p.suitScale = .eu
        let decoded = try JSONDecoder().decode(SizeProfile.self, from: JSONEncoder().encode(p))
        #expect(decoded == p)
    }

    @Test("The payload carries the new ladders and gives them back")
    func payloadRoundTrip() {
        var p = SizeProfile()
        p.apparel = ["M"]
        p.dress = ["4", "6"]
        p.suit = ["40"]
        p.suitLength = ["R"]
        let back = SizePayload(p).asProfile
        #expect(back.dress == p.dress)
        #expect(back.suit == p.suit)
        #expect(back.suitLength == p.suitLength)
        #expect(back.apparel == p.apparel)
    }

    /// The 1.0 app sends none of these fields, and its body must still decode — to empty
    /// ladders, which filter nothing.
    @Test("A payload from the 1.0 app decodes to empty new ladders")
    func olderPayload() throws {
        let body = #"{"apparel":["M"],"shoe":["9"],"waist":["32"],"gender":"mens"}"#
        let payload = try JSONDecoder().decode(SizePayload.self, from: Data(body.utf8))
        #expect(payload.dress == nil)
        let profile = payload.asProfile
        #expect(profile.dress.isEmpty)
        #expect(profile.suit.isEmpty)
        #expect(profile.suitLength.isEmpty)
        #expect(profile.waist == ["32"])
    }

    /// A token that is not on the ladder is dropped rather than kept as `.other` — the
    /// older ladders keep it, and that is how a bare "44" came to mark every unreadable
    /// size in the app as somebody's.
    @Test("The payload canonicalises strictly")
    func strictCanonicalisation() {
        let payload = SizePayload(
            apparel: [],
            shoe: [],
            dress: ["UK 10", "XL", "5", "6"],
            suit: ["40R", "EU 52", "huge"],
            suitLength: ["regular", "Long", "tall"]
        )
        let profile = payload.asProfile
        #expect(profile.dress == ["6"])
        #expect(profile.suit == ["40", "42"])
        #expect(profile.suitLength == ["R", "L"])
    }
}

@Suite("Watches read sizes in the product's context")
struct WatchContextTests {
    private func variant(_ size: String, available: Bool = true) -> VariantInfo {
        VariantInfo(id: size, title: size, available: available, size: size)
    }

    @Test("A watch on 40R is a watch on 40 Regular, and not on 40 Long")
    func tailoredWatch() {
        let watch = WatchTarget(size: "40R")
        #expect(watch.matches(variant("40 Regular"), in: mensJacket))
        #expect(!watch.matches(variant("40L"), in: mensJacket))
    }

    /// Both convert to a US 8, and the watch fired on the wrong one.
    @Test("A watch on EU 41.5 does not fire when EU 41 comes back")
    func convertedSizesStayApart() {
        let watch = WatchTarget(size: "41.5")
        #expect(!watch.isSatisfied(by: [variant("41")], in: sneaker))
        #expect(watch.isSatisfied(by: [variant("41.5")], in: sneaker))
        #expect(!WatchTarget(size: "EU 41.5").matches(variant("EU 41"), in: .unknown))
    }
}
