import Testing

@testable import StreetwCore

@Suite("Colour harmony")
struct ColorHarmonyTests {
    /// Most streetwear is black, grey, cream or denim, so the neutral rule is the common
    /// case and not the escape hatch. If it ever stops holding, the suggestion row empties
    /// out for almost everybody.
    @Test("A neutral goes with anything", arguments: [
        ("Black", "Orange"), ("Grey", "Burgundy"), ("Cream", "Teal"),
        ("Navy", "Olive"), ("Brown", "Green"), ("Black", "White")
    ])
    func neutralsPairWithEverything(first: String, second: String) {
        #expect(!ColorHarmony.isClash(first, second))
        #expect(ColorHarmony.score(first, second).reason != nil)
    }

    /// The one thing this exists to keep out of a suggestion: two saturated colours from
    /// the awkward middle of the wheel, which is a structurally perfect outfit and
    /// obviously wrong to look at.
    @Test("Two saturated colours from the awkward middle are refused", arguments: [
        ("Orange", "Purple"), ("Red", "Green"), ("Pink", "Olive"), ("Green", "Burgundy")
    ])
    func clashingChromaticsAreRefused(first: String, second: String) {
        #expect(ColorHarmony.isClash(first, second))
    }

    /// Adjacent reads as a gradient and opposite reads as deliberate. Neither is the
    /// failure being guarded against, and suppressing them would leave only monochrome.
    /// Blue with yellow and blue with orange are complementary and among the most-worn
    /// combinations there are — refusing those would be the rule failing, not working.
    @Test("Adjacent and opposite hues both survive", arguments: [
        ("Red", "Orange"), ("Green", "Forest"), ("Blue", "Teal"), ("Blue", "Purple"),
        ("Blue", "Orange"), ("Yellow", "Blue"), ("Red", "Teal")
    ])
    func adjacentAndOppositeSurvive(first: String, second: String) {
        #expect(!ColorHarmony.isClash(first, second))
    }

    @Test("One colour worn twice is a decision")
    func monochromeScoresWell() {
        #expect(ColorHarmony.score("Green", "Green").score > 0.8)
        #expect(ColorHarmony.score("Black", "Black").reason == "All black")
    }

    /// An unanalysed wardrobe must not have its suggestions suppressed. Nothing has been
    /// looked at yet, which is not the same as having looked and disapproved — and the
    /// simulator cannot run Vision at all, so this is the state the whole row is in there.
    @Test("An unknown or missing colour is never a clash", arguments: [
        (nil, "Orange"), ("Orange", nil), (nil, nil), ("Chartreuse", "Orange")
    ])
    func unknownColoursDoNotSuppress(first: String?, second: String?) {
        #expect(!ColorHarmony.isClash(first, second))
        #expect(ColorHarmony.score(first, second).reason == nil)
    }

    /// The wheel wraps: burgundy at 350 and red at 0 are ten degrees apart, not 350.
    @Test("Hue distance wraps around the wheel")
    func wheelWraps() {
        #expect(!ColorHarmony.isClash("Burgundy", "Red"))
    }
}
