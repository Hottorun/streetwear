import Foundation
import Testing

@testable import StreetwCore

@Suite("Re-shelving")
struct ReshelvingTests {
    private func product(
        createdDaysBeforePublication: Double?,
        isAvailable: Bool?
    ) -> FetchedItem {
        let published = Date()
        return FetchedItem(
            externalID: "shopify:1",
            title: "Nike Air Max 1",
            publishedAt: published,
            createdAt: createdDaysBeforePublication.map {
                published.addingTimeInterval(-$0 * 86_400)
            },
            kind: .product,
            isAvailable: isAvailable
        )
    }

    @Test("A product created days before it drops is a drop")
    func launchesAreUntouched() {
        #expect(Reshelving.firstSighting(of: product(createdDaysBeforePublication: 0, isAvailable: true)) == .product)
        #expect(Reshelving.firstSighting(of: product(createdDaysBeforePublication: 3, isAvailable: false)) == .product)
        // Sat on for a season and then launched — still a launch, and the sold-out reading
        // here is a drop that went instantly, which is news of the highest order.
        #expect(Reshelving.firstSighting(of: product(createdDaysBeforePublication: 60, isAvailable: false)) == .product)
    }

    /// The reported bug, in one assertion: Kith's re-merchandising sweeps restamp
    /// `published_at` on stock that is years old and entirely gone, and it arrived as a
    /// page of new clothes that were all sold out.
    @Test("Year-old stock with nothing to buy says nothing at all")
    func soldOutReshelvingIsSilent() {
        #expect(Reshelving.firstSighting(of: product(createdDaysBeforePublication: 1_015, isAvailable: false)) == nil)
    }

    /// …but it is not simply suppressed. Back on the shelf and buyable is a restock, which
    /// is both true and the thing somebody would want to hear.
    @Test("Re-shelved and buyable is a restock, not a drop")
    func availableReshelvingIsARestock() {
        #expect(Reshelving.firstSighting(of: product(createdDaysBeforePublication: 1_015, isAvailable: true)) == .restock)
    }

    /// Only Shopify publishes a creation date. "We don't know" must never suppress an
    /// event, or a sitemap brand would go quiet for reasons nobody could see.
    @Test("An unknown creation date is a launch")
    func unknownCreationIsALaunch() {
        #expect(Reshelving.firstSighting(of: product(createdDaysBeforePublication: nil, isAvailable: false)) == .product)
        #expect(!Reshelving.isReshelved(createdAt: nil, publishedAt: Date()))
    }

    /// A source with no variants at all reports nil availability. Treated as buyable: the
    /// only thing a firmer reading would buy is hiding something on a guess.
    @Test("Unknown availability is not treated as sold out")
    func unknownAvailabilityIsNotSoldOut() {
        #expect(Reshelving.firstSighting(of: product(createdDaysBeforePublication: 1_015, isAvailable: nil)) == .restock)
    }
}
