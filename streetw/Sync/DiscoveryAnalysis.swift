// DiscoveryAnalysis.swift
// Reading the photograph of a garment nobody here has kept.
//
// `ImageTagger` runs over **saves**, and deliberately so: analysing a catalogue sweep would
// measure two hundred and fifty items nobody wanted. That leaves the discovery feed in a
// place nothing else in the app is — every card is a product with no cutout, no colour and
// no measured anything, and the two things this feed exists to do both need one:
//
// - the composite wants a *sticker*, because three raw product shots overlapping each other
//   is three white rectangles;
// - the pairing wants a *colour*, because `ColorHarmony` is most of what makes "goes with
//   your olive cargos" true rather than merely structural.
//
// So this is `ImageTagger`'s work, bounded to the cards actually on screen and written
// nowhere. Nothing here touches SwiftData — a discovery card has no row, which is the whole
// reason the feed cannot pollute the store.
//
// **Analysis sharpens what a card *says*. It must never change where a card *sits*.**
// Photographs arrive while somebody is scrolling, and a deck that re-ordered as they decoded
// would reorder under a thumb mid-read — the exact failure `FeedView` documents for a list
// whose key is computed from something that moves. `DiscoverDeck.rank` therefore reads none
// of this, and the ordering stays the one the text-only pass produced.

import Foundation
import OSLog
import StreetwCore
import SwiftUI

@MainActor
@Observable
final class DiscoveryAnalysis {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "discover")

    /// What one photograph turned out to be.
    struct Result {
        /// The garment lifted off its backdrop. Nil is ordinary and permanent for plenty of
        /// products: a flat-lay with no single subject, a busy lookbook frame — and *every*
        /// product in the Simulator, where Vision's subject lifting does not run at all.
        var sticker: UIImage?
        /// Colour, busyness, text coverage. The histogram half works everywhere; the Vision
        /// half is device-only.
        var reading: VisualReading.Reading?
    }

    private var results: [String: Result] = [:]
    /// In flight, so two cards scrolling past each other do not both fetch the same
    /// photograph — and so a card returned to is not re-analysed from scratch.
    private var working: Set<String> = []

    /// How wide the photograph is fetched to be measured.
    ///
    /// The same reasoning as `ImageTagger.measuredWidth`: everything downstream works far
    /// below this — `Histogram` samples a 48² grid, `Seamless` a 1200px canvas — and the cap
    /// is what protects against a host `ImageRendition` does not recognise. Palace ships
    /// 3200² PNGs, which decode to a 41MB bitmap.
    private static let measuredWidth = 1200

    func result(for id: String) -> Result? { results[id] }

    /// Measures one card, once.
    ///
    /// Called for the cards at and adjacent to the viewport, never for the whole page: this
    /// is a network fetch, a decode and two Vision requests, and a feed built to be scrolled
    /// would otherwise run it hundreds of times for cards nobody looked at.
    func analyse(_ card: DiscoverCard) async {
        let id = card.productExternalID
        guard results[id] == nil, !working.contains(id) else { return }
        working.insert(id)
        defer { working.remove(id) }

        let urls = card.imageURLs.compactMap(URL.init(string:))
        guard let lead = urls.first else { return }
        guard let first = await load(lead) else {
            // Nothing is written off. `ImageTagger` distinguishes a dead URL from a dead
            // network because it *stamps a version* and a mistake there is permanent; here
            // there is no row to stamp, so the honest thing is simply to leave it unmeasured
            // and let a later visit try again.
            return
        }

        // **The composite is measured on the packshot, not on the lead shot**, and they are
        // not always the same photograph. A brand's gallery order is a merchandising
        // decision: Stüssy publishes `_3, _4, _5, _1, _2` — four model shots and a packshot,
        // model first — so lifting the subject of the lead frame returns *a person*, and the
        // card would offer a whole model in trousers and boots as the thing that goes with
        // your jeans. `ProductShot` already answers exactly this question for the fit canvas.
        //
        // Note the card itself keeps showing the lead shot full-bleed. On a model is how the
        // brand wants the garment seen and it is the better photograph; this is only about
        // which frame gets *cut out*.
        let choice = await ProductShot.choose(
            first: ProductShot.Choice(url: lead, image: first),
            others: Array(urls.dropFirst()),
            load: { await self.load($0) }
        )

        let lift = await Cutout.make(
            from: choice.image,
            named: id,
            // Nothing on disk. A cutout file is keyed off an item id and lives as long as the
            // item does; a discovery card has neither, and writing one would leave a PNG per
            // garment scrolled past with nothing that would ever delete it.
            writeFile: false
        )
        // An interrupted lift is not a refusal — it is the question never having been put —
        // so it is left unrecorded and asked again if the card comes back.
        guard !lift.wasInterrupted else { return }

        let reading = await VisualReading.read(choice.image)
        results[id] = Result(
            sticker: lift.mask.map { UIImage(cgImage: $0) },
            reading: reading
        )
    }

    /// Warms the cards either side of the one being looked at.
    ///
    /// Detached rather than a structured child, for the reason `ImageGallery`'s prefetch is:
    /// started from a `.task`, a child is cancelled by the very scroll that makes the next
    /// card matter.
    nonisolated func warm(_ cards: [DiscoverCard]) {
        Task.detached { [weak self] in
            for card in cards {
                await self?.analyse(card)
            }
        }
    }

    private func load(_ url: URL) async -> UIImage? {
        do {
            var request = URLRequest(url: ImageRendition.sized(url, width: Self.measuredWidth))
            request.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            // Rasterised off the main thread. `UIImage(data:)` produces no pixels — it wraps a
            // data provider and the real decode happens inside the CoreAnimation commit, on
            // the main thread, at first draw.
            return ImageLoader.decoded(data, maxPixel: Self.measuredWidth)
        } catch {
            Self.log.info("discovery image failed: \(error.localizedDescription)")
            return nil
        }
    }
}
