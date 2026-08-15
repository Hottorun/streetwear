import Foundation
import Testing

@testable import StreetwCore

@Suite("Silhouette bands")
struct SilhouetteBandsTests {
    /// The whole reason bottoms are measured at the hem rather than on their proportions: a
    /// wide leg and a tapered one have nearly identical overall dimensions and differ
    /// entirely in what happens at the ankle.
    private func label(
        breadth: Double = 0.5,
        taper: Double = 0.8,
        body: Double = 0.75,
        slot: GarmentSlot
    ) -> String? {
        SilhouetteBands.label(breadth: breadth, taper: taper, bodyBreadth: body, slot: slot)
    }

    @Test("A leg is read at the hem")
    func bottomsAreReadAtTheHem() {
        #expect(label(breadth: 0.45, taper: 0.95, slot: .bottom) == "Wide")
        #expect(label(breadth: 0.45, taper: 0.5, slot: .bottom) == "Tapered")
    }

    @Test("A narrow trouser that doesn't taper is slim")
    func narrowStraightIsSlim() {
        #expect(label(breadth: 0.26, taper: 0.8, slot: .bottom) == "Slim")
    }

    @Test("Tops are read on the body, not the wingspan")
    func topsAreReadOnTheBody() {
        #expect(label(body: 0.9, slot: .top) == "Boxy")
        #expect(label(body: 0.5, slot: .top) == "Longline")
        #expect(label(body: 0.9, slot: .outerwear) == "Boxy")
    }

    /// The wrong answer that produced this input. A top laid flat has its sleeves out, so
    /// the widest row is the sleeve span — read on that, a funnel-neck fleece and a hoodie
    /// both came back "Cropped". A wide wingspan over an ordinary body says nothing.
    @Test("A wide sleeve span is not a shape")
    func sleeveSpanIsNotAShape() {
        #expect(label(breadth: 1.2, body: 0.75, slot: .top) == nil)
    }

    /// Nothing wearable is this shape, and a real collection produced exactly this: tops
    /// measured 1.29 times wider at the hem than they were long. That is a photograph being
    /// measured, not a garment.
    @Test("An impossible shape is refused rather than named")
    func impossibleShapesAreRefused() {
        #expect(label(body: 1.29, slot: .top) == nil)
        #expect(label(body: 1.29, slot: .outerwear) == nil)
        #expect(label(breadth: 0.9, taper: 0.98, body: 0.9, slot: .bottom) == nil)
        // …while a genuinely boxy top, which comes close to square, still gets its word.
        #expect(label(body: 0.95, slot: .top) == "Boxy")
    }

    /// The property that matters most. Most garments are unremarkable in shape, and a
    /// profile that labels all of them "Regular" has said nothing while looking like it
    /// said something.
    @Test("The middle of every band says nothing")
    func theMiddleDeclines() {
        #expect(label(breadth: 0.35, taper: 0.75, slot: .bottom) == nil)
        #expect(label(body: 0.75, slot: .top) == nil)
    }

    /// A shoe has a perfectly good outline and its shape is a fact about shoes rather than
    /// about the person wearing them.
    @Test("Slots where shape says nothing about taste are refused", arguments: [
        GarmentSlot.footwear, .headwear, .accessory, .unknown
    ])
    func silentSlots(slot: GarmentSlot) {
        #expect(!SilhouetteBands.speaks(for: slot))
        #expect(label(breadth: 1.2, taper: 0.4, body: 0.95, slot: slot) == nil)
    }
}
