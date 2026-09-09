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

/// The other question, and the one the feed actually asks: **is this a release**, judged by
/// the stock in it rather than by its name.
///
/// Every case here is measured. Each row is a real collection, its real publication date,
/// and how many of its real members were shelved within thirty days of it — read off the
/// live storefronts on the evening the feed announced four rails as drops.
@Suite("Release announcements")
struct ReleaseAnnouncementTests {
    private let announced = Date(timeIntervalSince1970: 1_788_000_000)

    /// `fresh` of `total` members shelved with the collection.
    private func members(fresh: Int, of total: Int) -> [Date] {
        let recent = announced.addingTimeInterval(-5 * 86_400)
        let old = announced.addingTimeInterval(-200 * 86_400)
        return (0..<total).map { $0 < fresh ? recent : old }
    }

    @Test(
        "Rails measured on live storefronts are refused",
        arguments: [
            // Fear of God — 5 pieces, the newest shelved 54 days before the page.
            (name: "All Mens Denim Bottoms", fresh: 0, total: 5),
            // Corteiz — 6 colourways of one hat, the newest 102 days before.
            (name: "ISLAND PUFF PRINT TRUCKER HAT", fresh: 0, total: 6),
            // Episodes Project — a theme-editor menu placeholder holding the shop.
            (name: "custom link", fresh: 7, total: 65)
        ]
    )
    func railsAreRefused(row: (name: String, fresh: Int, total: Int)) {
        #expect(
            !Release.isAnnouncement(
                publishedAt: announced,
                members: members(fresh: row.fresh, of: row.total)
            ),
            "announced a rail: \(row.name)"
        )
    }

    @Test(
        "Releases measured on live storefronts are admitted",
        arguments: [
            // BBC's Yankees womenswear edit — the one the title vocabulary would refuse,
            // since "edit" and "women" both read as navigation. 43%.
            (name: "The Women's Edit: New York Yankees | Billionaire Boys Club", fresh: 10, total: 23),
            // Amiri's bag launch: the page went up six days after the bags did.
            (name: "BABY BISCOTTO BAG", fresh: 4, total: 4),
            (name: "AUTUMN-WINTER 2026 MENSWEAR", fresh: 21, total: 35)
        ]
    )
    func releasesAreAdmitted(row: (name: String, fresh: Int, total: Int)) {
        #expect(
            Release.isAnnouncement(
                publishedAt: announced,
                members: members(fresh: row.fresh, of: row.total)
            ),
            "refused a real release: \(row.name)"
        )
    }

    /// An empty answer is not an empty collection — it is a storefront that did not reply,
    /// and the caller announces those rather than losing a drop to one failed request.
    @Test("Nothing to read is not a release")
    func emptyIsRefused() {
        #expect(!Release.isAnnouncement(publishedAt: announced, members: []))
    }

    /// A collection page routinely goes up after the garments, and occasionally before —
    /// Amiri's bags were on sale six days early, and pieces get added once a page exists.
    @Test("Contemporary runs both ways")
    func windowIsTwoSided() {
        let justAfter = [announced.addingTimeInterval(86_400)]
        #expect(Release.isAnnouncement(publishedAt: announced, members: justAfter))

        let longBefore = [announced.addingTimeInterval(-90 * 86_400)]
        #expect(!Release.isAnnouncement(publishedAt: announced, members: longBefore))
    }
}
