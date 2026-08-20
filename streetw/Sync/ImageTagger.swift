// ImageTagger.swift
// Reading a saved thing off its photograph instead of off its title.
//
// `StyleProfile` used to work by looking for the word "black" in a product name. That
// is fine until a brand calls something "Triple White" (which is a colourway, not a
// colour), or "Nocturne", or names it after a person — and it can never say anything
// about an item shared in from a page with a two-word title. The photograph, meanwhile,
// is unambiguous.
//
// This file decides what is due, drains the backlog and writes the answers down. The
// measuring itself lives next door — `Histogram` for anything read off the distribution of
// pixels, `VisualReading` for the Vision requests, `Silhouette` for the outline, `Cutout`
// for the sticker.
//
// What is extracted:
//
// - **Categories**, from Vision's own on-device classifier. No model file, no download,
//   and its taxonomy already contains the clothing terms we care about.
// - **The cutout**, because the photograph is decoded here anyway and the fit canvas must
//   not stall lifting a garment the first time it is dragged.
// - **The deeper read** — two colours, busyness, text coverage, tonal register, a
//   perceptual fingerprint and the silhouette. See `VisualReading`.
//
// Each has its own "is this due" test, and there are now three. They were added at
// different times and the store outlives all of them, so a single `analyzedAt` cannot speak
// for a field that did not exist when the row was stamped — see `Cutout.version` and
// `VisualReading.version`.
//
// Only saved items are analysed. Running this over a 250-item catalogue sweep would burn
// battery to describe things nobody kept.

import CoreImage
import Foundation
import OSLog
import StreetwCore
import SwiftData
import UIKit
import Vision

@MainActor
enum ImageTagger {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "tagging")

    /// Analyses saved items with work outstanding — never analysed, or holding a cutout or
    /// a reading from an older revision.
    ///
    /// Drains the backlog in batches rather than stopping after one. The batch is what
    /// keeps the collection responsive — results are written and drawn after each — but
    /// stopping there left everything past the first dozen unanalysed until the person
    /// happened to save something else, because the view only re-runs this when the count
    /// changes. That is now visible rather than academic: the wall sizes each tile from
    /// the measured aspect, so an unmeasured item is drawn to a guess.
    static func analyzePending(in context: ModelContext, limit: Int = 12) async {
        while !Task.isCancelled {
            let analyzed = await analyzeBatch(in: context, limit: limit)
            if analyzed < limit { return }
        }
    }

    /// How many saved items currently have work outstanding.
    ///
    /// Exists to be a `.task(id:)` key. The screens that run this pass used to key it on
    /// `saves.count`, which fires when something is kept and at no other time — but a
    /// photograph can arrive long after the save does. `SharedSaveImporter.repair` finds a
    /// shared link in the catalogue on some later foreground and fills in the real images,
    /// and the count has not moved, so nothing looks at them until the person happens to
    /// save something else. Keying on the backlog instead means new work *is* the trigger,
    /// and the pass settling back to zero is what stops it.
    static func backlog(in saves: [SavedItem]) -> Int {
        saves.count { save in
            guard let update = save.update, update.primaryImageURL != nil else { return false }
            return update.analyzedAt == nil || update.hasUnreadPhotograph
                || update.needsCutout || update.needsVisualReading
        }
    }

    /// One batch. Returns how many were looked at, so the caller knows whether the
    /// backlog is drained.
    private static func analyzeBatch(in context: ModelContext, limit: Int) async -> Int {
        let saves = (try? context.fetch(FetchDescriptor<SavedItem>())) ?? []
        // Two independent reasons to look at a photograph, and they have to be tracked
        // separately. `analyzedAt` is stamped once and forever; the cutout arrived later
        // and carries its own version, so everything saved before it existed is still due
        // even though it was analysed long ago. Filtering on `analyzedAt` alone is what
        // left the canvas with no stickers at all on an established collection.
        let pending = saves
            .compactMap(\.update)
            .filter {
                $0.primaryImageURL != nil
                    && ($0.analyzedAt == nil || $0.hasUnreadPhotograph
                        || $0.needsCutout || $0.needsVisualReading)
            }
            .prefix(limit)
        guard !pending.isEmpty else { return 0 }

        var cut = 0
        for update in pending {
            guard let url = update.primaryImageURL else { continue }
            // A photograph nobody has looked at makes all three due again, whatever the
            // stamps say. This is what rescues a link shared from Safari: it lands with an
            // Open Graph image or none, gets analysed (or written off) against that, and
            // then `SharedSaveImporter.repair` swaps in the catalogue's real photographs —
            // at which point every version field is already current and, without this, the
            // save would never be measured at all. See `analyzedImageURL`.
            let isNewPhotograph = update.hasUnreadPhotograph
            let needsTags = update.analyzedAt == nil || isNewPhotograph
            let needsCutout = update.needsCutout || isNewPhotograph
            let needsReading = update.needsVisualReading || isNewPhotograph

            guard let image = await load(url) else {
                // Mark it anyway, on every count. A dead image URL will never resolve, and
                // retrying it on every launch is a permanent background cost for nothing.
                // Recording *which* URL failed is what lets a repaired row through later
                // without reopening this one.
                update.analyzedAt = Date()
                update.analyzedImageURL = url.absoluteString
                update.cutoutVersion = Cutout.version
                update.visionVersion = VisualReading.version
                continue
            }

            if needsTags {
                // Free: the image is already decoded, and the wall would otherwise be
                // guessing tile heights from a hash of the item id.
                if image.size.height > 0 {
                    update.imageAspect = Double(image.size.width / image.size.height)
                }
                update.visionCategories = await categories(in: image)
                update.analyzedAt = Date()
            }

            if needsReading {
                // The deeper read: the second colour, how busy it is, how much text is on
                // it, how dark and how colourful, and a perceptual fingerprint. All of it
                // off pixels already in memory.
                //
                // `visionColor` is written from here too, and not under `needsTags`. The
                // two used to be one step, but the histogram behind them is now shared —
                // and a row analysed by an older build has a colour and needs everything
                // else, so gating the colour on `analyzedAt` would re-measure the
                // distribution and then throw the winner away.
                let reading = await VisualReading.read(image)
                update.visionColor = reading.color ?? update.visionColor
                update.visionSecondaryColor = reading.secondaryColor
                update.visionBusyness = reading.busyness
                update.visionLightness = reading.lightness
                update.visionSaturation = reading.saturation
                update.visionTextCoverage = reading.textCoverage
                update.visionFeaturePrint = reading.featurePrint ?? update.visionFeaturePrint
            }

            if needsCutout || needsReading {
                // Also free, in the sense that matters: the photograph is already decoded
                // and this pass is already running. Cutting on demand instead would mean
                // the fit canvas stalls the first time each garment is dragged onto it.
                //
                // Run when *either* is due, because the lift and the silhouette read the
                // same mask and neither is worth a second decode of the other's work.
                //
                // The old file goes first: the name is derived from the item id, so a lift
                // that now finds nothing would otherwise leave last revision's sticker on
                // disk with no row pointing at it.
                if needsCutout, let stale = update.cutoutFile { Cutout.remove(stale) }
                let lift = await Cutout.make(from: image, named: Cutout.name(for: update.id))
                if needsCutout {
                    update.cutoutFile = lift.file
                    update.cutoutVersion = Cutout.version
                    if lift.file != nil { cut += 1 }
                }
                if needsReading, let mask = lift.mask {
                    update.visionSilhouette = Silhouette.measure(mask, slot: update.garmentSlot)
                }
            }

            // Last, and only once everything above has had its turn: a row stamped before
            // its measurements are written would be skipped on the next pass holding none
            // of them.
            if needsReading { update.visionVersion = VisualReading.version }
            update.analyzedImageURL = url.absoluteString
        }
        try? context.save()
        log.info("looked at \(pending.count) saved items, lifted \(cut)")
        return pending.count
    }

    // MARK: - Categories

    /// Vision's built-in taxonomy, narrowed to terms about clothing.
    ///
    /// The classifier happily returns "outdoor", "person" and "still_life" for a product
    /// shot; those are true and useless. Only labels a wardrobe would recognise are kept.
    private static func categories(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }

        do {
            var request = ClassifyImageRequest()
            request.cropAndScaleAction = .scaleToFill
            let observations = try await request.perform(on: cgImage)

            return observations
                .filter { $0.confidence > 0.15 }
                .compactMap { Self.wardrobeTerms[$0.identifier.lowercased()] }
                .reduce(into: [String]()) { unique, label in
                    if !unique.contains(label) { unique.append(label) }
                }
                .prefix(3)
                .map { $0 }
        } catch {
            log.error("classification failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Vision's identifiers mapped onto the categories `StyleProfile` already speaks.
    /// Anything not in here is discarded rather than shown raw — "clothing" as a facet
    /// tells the user nothing they didn't know.
    private static let wardrobeTerms: [String: String] = [
        "t_shirt": "T-shirts", "tee_shirt": "T-shirts", "shirt": "Shirts",
        "dress_shirt": "Shirts", "polo_shirt": "Shirts",
        "hoodie": "Hoodies", "hood": "Hoodies",
        "sweatshirt": "Sweats", "sweater": "Knitwear", "cardigan": "Knitwear",
        "knitwear": "Knitwear", "jersey": "Knitwear",
        "jacket": "Jackets", "coat": "Outerwear", "outerwear": "Outerwear",
        "parka": "Outerwear", "raincoat": "Outerwear", "vest": "Outerwear",
        "trousers": "Pants", "pants": "Pants", "jeans": "Denim", "denim": "Denim",
        "shorts": "Shorts", "skirt": "Skirts",
        "shoe": "Footwear", "sneaker": "Sneakers", "running_shoe": "Sneakers",
        "athletic_shoe": "Sneakers", "boot": "Footwear", "sandal": "Footwear",
        "hat": "Headwear", "cap": "Headwear", "baseball_cap": "Headwear",
        "beanie": "Headwear", "knit_cap": "Headwear",
        "bag": "Bags", "backpack": "Bags", "handbag": "Bags", "tote": "Bags",
        "sunglasses": "Accessories", "watch": "Accessories", "belt": "Accessories",
        "scarf": "Accessories", "glove": "Accessories", "sock": "Accessories"
    ]

    // MARK: - Loading

    /// Goes through the shared cache the feed already fills, so an item saved from the
    /// feed is usually analysed without a second download.
    private static func load(_ url: URL) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
