// ProductShot.swift
// Which of a product's photographs is a photograph *of the product*.
//
// A storefront publishes eight to twelve shots of a garment and the app has always taken
// the first one for everything it measures. That is fine for a brand whose gallery leads
// with a packshot and wrong for one that leads with a lookbook — and the ordering is not a
// convention, it is a merchandising decision that differs per brand and sometimes per
// product. Stüssy publishes its gallery in the order `_3, _4, _5, _1, _2`: four model shots
// and one packshot, with a model first.
//
// The consequence was visible on the fit canvas. `Cutout` did exactly what it is supposed
// to do and lifted the *subject* of the first photograph, which was a person — so a saved
// Stüssy shirt arrived on the canvas as a whole model in trousers and boots, next to
// garments that had been cut out properly. It is not only the canvas: the dominant colour
// was being read off a lookbook background, and `Silhouette` was measuring the outline of a
// human being and filing it as the shape of a shirt.
//
// The signal is the obvious one and it turns out to be clean: **a packshot has nobody in
// it.** Measured against a real Stüssy gallery, Vision's human-rectangle detector finds a
// person in four of the five images and none in the fifth, and the fifth is the packshot.
//
// Two properties this deliberately has:
//
// - **It only ever reorders, never removes.** Every photograph is still saved, still shown
//   in the gallery, still swipeable. This picks which one gets *measured*.
// - **It costs nothing on the common case.** A brand that leads with a packshot — most of
//   them — is answered by one detection on an image that was already decoded, and no
//   further photograph is fetched at all.

import Foundation
import OSLog
import UIKit
import Vision

enum ProductShot {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "shot")

    /// How many photographs past the first are worth trying.
    ///
    /// Bounded because each one is a fetch and a decode of a 2000–3000px original, and the
    /// packshot is near the front when there is one — Stüssy's is the second image of five.
    /// A gallery that is models all the way down is a real thing (a lookbook-only product),
    /// and for that the honest answer is the first photograph, not the ninth.
    static let extraCandidates = 5

    struct Choice {
        var url: URL
        var image: UIImage
    }

    /// The photograph to measure.
    ///
    /// - Parameters:
    ///   - first: the product's lead photograph, already loaded — this is the one the rest
    ///     of the app treats as primary, and the one returned whenever nothing better is
    ///     found.
    ///   - others: the remaining photographs, in published order.
    ///   - load: how to fetch one. Injected so the caller keeps ownership of what a failed
    ///     fetch *means* — see `ImageTagger.load`, where the difference between a dead URL
    ///     and a dead network decides whether an item is written off.
    static func choose(
        first: Choice,
        others: [URL],
        load: (URL) async -> UIImage?
    ) async -> Choice {
        // Nothing to choose between.
        guard !others.isEmpty else { return first }

        // The fast path, and the common one: the lead photograph is already a packshot, so
        // no other image is fetched. This is also the path taken whenever detection is
        // unavailable, which is the correct fallback — an app that cannot tell picks the
        // photograph the brand put first.
        guard await hasPerson(first.image) else { return first }

        for url in others.prefix(extraCandidates) {
            guard let image = await load(url) else { continue }
            if await hasPerson(image) { continue }
            log.info("using a later photograph as the packshot")
            return Choice(url: url, image: image)
        }

        // Every photograph has somebody in it. That is a lookbook-only product and the lead
        // shot is as good an answer as exists.
        return first
    }

    /// Whether there is a person in the frame.
    ///
    /// Returns **false** when detection fails for any reason — no hardware, an unsupported
    /// image, a Simulator that will not run the request. That is deliberate: a false here
    /// means "keep the photograph the brand put first", which is exactly the behaviour this
    /// file replaces, so an environment that cannot answer degrades to the old one rather
    /// than wandering through the gallery picking arbitrarily.
    private static func hasPerson(_ image: UIImage) async -> Bool {
        guard let cgImage = image.cgImage else { return false }
        do {
            let request = DetectHumanRectanglesRequest()
            return try await !request.perform(on: cgImage).isEmpty
        } catch {
            log.info("no human detection available: \(error.localizedDescription)")
            return false
        }
    }
}
