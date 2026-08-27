import Foundation
import Testing

@testable import StreetwCore

/// Every title in this suite is real, taken from a live poll of Kith, Stüssy, Palace,
/// Billionaire Boys Club, Gymshark and Allbirds — 826 collection rows, of which a handful
/// were releases and the rest were furniture. That is the point of the suite: the vocabulary
/// was read off the data rather than guessed at, and a regression here is a card announcing
/// a shoe size as the season's drop.
@Suite("Release detection")
struct ReleaseTests {
    @Test(
        "A named season or year is a release",
        arguments: [
            "&Kin Fall 2026",
            "&Kin Fall 2026",
            "Stüssy Fall '26 Collection",
            "Icecream Fall 2026",
            "Billionaire Boys Club Fall 2026",
            "&Kin Spring 2025",
            "&Kin Summer 2024",
            "2025 BMW XM by Kith",
            "FW26 Delivery One",
            "Palace Ultimo 2025"
        ]
    )
    func realReleasesAreAdmitted(title: String) {
        #expect(Release.isRelease(title: title), "refused a real release: \(title)")
    }

    /// The expensive direction. Every one of these is a real row from `/collections.json`,
    /// and every one of them would be a full-screen card announcing a shop filter as a drop.
    @Test(
        "Shop navigation is refused",
        arguments: [
            // Size rails — the largest group by far.
            "10", "10.5", "12C", "1Y", "2T", "36.5", "0-6M", "1.5Y", "2/3", "0/1",
            // Price and discount rails.
            "$50 & Under", "10% OFF GYMSHARK SALE", "20% off Select Styles",
            "30% Off Tree Runner Go & Tree Gliders",
            // Designers a multi-brand shop stocks, which are not that shop's own releases.
            "1017 ALYX 9SM", "16Arlington", "032c", "19-69", "1017 Alyx 9SM Women",
            // Plain navigation.
            "All Products", "Back in Stock", "New Arrivals", "Shop All", "Accessories",
            "1013 Test Collection", "OFF-PALETTE WOMENS",
            // Named seasons that are still rails, which is why navigation is checked first.
            "Fall 2025 Sale", "Spring Archive", "Summer 2024 Final Sale",
            // Gift guides and promotions. Every one of these is real and every one passed
            // the season test before the vocabulary was widened to catch it.
            "Her Holiday Must-Haves", "His Holiday Must-Haves",
            "It's Summer Gifting Season", "BOGO15 Collection Q3 2023"
        ]
    )
    func navigationIsRefused(title: String) {
        #expect(!Release.isRelease(title: title), "admitted navigation as a release: \(title)")
    }

    /// The documented, accepted loss. A slogan capsule with no date in it is refused, and
    /// that is the cheaper mistake — the garments still reach the feed on their own.
    @Test("A release with no season or year in its name is refused, deliberately")
    func undatedCapsulesAreRefused() {
        #expect(!Release.isRelease(title: "ALWAYS DO WHAT YOU SHOULD DO"))
        #expect(!Release.isRelease(title: "&Kin Tee"))
    }

    @Test("Nothing at all is not a release")
    func emptyIsRefused() {
        #expect(!Release.isRelease(title: ""))
        #expect(!Release.isRelease(title: "   "))
        #expect(!Release.isRelease(title: "—"))
    }

    /// A four-digit number is only a year when it could be one. Both of these carry four
    /// digits and neither is a date.
    @Test("Four digits are not automatically a year")
    func implausibleYearsAreRefused() {
        #expect(!Release.isRelease(title: "1013 Capsule"))
        #expect(!Release.isRelease(title: "1017 Nine"))
        #expect(Release.isRelease(title: "2026 Capsule"))
    }

    @Test("Season codes are read in both the joined and split forms")
    func seasonCodes() {
        #expect(Release.isRelease(title: "FW26 Delivery Two"))
        #expect(Release.isRelease(title: "SS26 Lookbook"))
        #expect(Release.isRelease(title: "Palace FW 26"))
    }

    // MARK: - Finding the contents

    /// A release names itself and does not list itself, so the title's distinctive words are
    /// the only thread back to the garments. Brands tag their seasons, which is what makes
    /// this work at all.
    @Test("Distinctive words skip the words every collection shares")
    func distinctiveWords() {
        let words = Release.distinctiveWords(in: "&Kin Fall 2026 Collection")
        #expect(words.contains("fall"))
        #expect(words.contains("2026"))
        #expect(!words.contains("collection"), "every release says 'collection'")

        // Short connective words carry no signal and would match everything.
        #expect(!Release.distinctiveWords(in: "Kith for The New York Mets").contains("for"))

        // A number is always distinctive, however short.
        #expect(Release.distinctiveWords(in: "Vol 2").contains("2"))
    }
}
