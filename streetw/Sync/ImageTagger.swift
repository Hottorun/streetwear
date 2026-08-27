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

    /// The drain in flight, if there is one.
    ///
    /// **The pass used to cancel itself, and this is what stopped it.** It is started from
    /// `.task(id: ImageTagger.backlog(in: saves))` — a key that is deliberately the amount
    /// of outstanding work, so that a photograph arriving later is itself the trigger. But
    /// the pass *resolves* items and saves, which invalidates the `@Query` behind `saves`,
    /// which recomputes the key, which makes SwiftUI cancel the running task and start a
    /// new one. Every batch tore down its own successor.
    ///
    /// On device that is not a slow loop, it is a broken feature: the four Vision requests
    /// are the thing in flight when the cancellation lands, so the log fills with
    /// `GenerateForegroundInstanceMaskRequest was cancelled`, no subject is ever lifted,
    /// `Seamless` is handed a photograph it correctly refuses, and — before the change
    /// below — the row was stamped at the current version on the way out. One item per
    /// restart, written off permanently, on the pass whose entire job is the cutout.
    ///
    /// Holding the task here does two things. A re-fired `.task` returns immediately
    /// instead of starting a second drain over the same rows, and the work itself lives in
    /// an unstructured task, so it is not a child of the view's and view churn cannot
    /// cancel it. The same reasoning `ImageGallery` already applies to its prefetch.
    private static var drain: Task<Void, Never>?

    /// How many photographs the pass still has to get through, for anything that wants to
    /// say so on screen. Nil when nothing is running.
    ///
    /// The analysis is the slowest visible thing the app does — four Vision requests and a
    /// decode per garment — and it was entirely silent, so a collection whose tiles were
    /// drawn to a guessed aspect and whose canvas had no stickers looked broken rather than
    /// busy. See `AnalysisProgress`.
    static let progress = AnalysisProgress()

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
        // Already draining: the caller's key changed underneath a pass that is handling
        // exactly these rows. Awaiting it rather than returning outright keeps the calling
        // `.task` alive for as long as there is work, which is what the progress line reads.
        if let drain {
            await drain.value
            return
        }
        let task = Task { @MainActor in await drainBacklog(in: context, limit: limit) }
        drain = task
        await task.value
        drain = nil
    }

    private static func drainBacklog(in context: ModelContext, limit: Int) async {
        // **The queue is worked out once, not once per batch.**
        //
        // `analyzeBatch` used to fetch the entire `SavedItem` table itself, fault every
        // save's `update`, filter, and then take twelve — and the loop below calls it until
        // the backlog drains. On a collection of two hundred that is seventeen full table
        // scans and roughly `N²/limit` relationship faults to do `N` items of work, all on
        // the main actor.
        //
        // Nothing is lost by hoisting it: the pass only ever *removes* rows from this list
        // by satisfying them, and a save made while it runs is picked up by the `.task(id:)`
        // key that started it in the first place.
        var queue = pending(in: context)
        progress.begin(queue.count)
        defer { progress.finish() }
        while !Task.isCancelled, !queue.isEmpty {
            let batch = Array(queue.prefix(limit))
            // **Counts items *resolved*, not items looked at.** An item whose photograph
            // could not be fetched this minute stays pending on purpose (see `load`), so
            // counting attempts would spin this loop forever against an offline network,
            // re-requesting the same twelve URLs as fast as they can fail.
            _ = await analyzeBatch(batch, in: context)
            queue.removeFirst(batch.count)
            progress.advance(to: queue.count)
        }
    }

    /// Measures a specific, caller-chosen set of products.
    ///
    /// The one way into this pass that is not driven by the saved backlog, and it exists for
    /// `FitCandidates`: a catalogue product has never been looked at, so it has no colour,
    /// so it cannot be scored into a fit. The caller is responsible for the bound — running
    /// this over a poll's 250 products is exactly what the file header forbids, and nothing
    /// here will stop you.
    ///
    /// Deliberately *not* routed through `drain`. That guards the backlog, which is a
    /// self-refreshing queue this is not part of, and blocking on a long drain to measure
    /// six products would leave the suggestion row empty for the length of it.
    static func analyze(_ updates: [BrandUpdate], in context: ModelContext) async {
        _ = await analyzeBatch(updates, in: context)
    }

    /// Everything saved that has work outstanding, newest first.
    private static func pending(in context: ModelContext) -> [BrandUpdate] {
        let saves = (try? context.fetch(
            FetchDescriptor<SavedItem>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        )) ?? []
        // Two independent reasons to look at a photograph, and they have to be tracked
        // separately. `analyzedAt` is stamped once and forever; the cutout arrived later
        // and carries its own version, so everything saved before it existed is still due
        // even though it was analysed long ago. Filtering on `analyzedAt` alone is what
        // left the canvas with no stickers at all on an established collection.
        return saves.compactMap(\.update).filter(\.needsAnalysis)
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
        saves.count { $0.update?.needsAnalysis == true }
    }

    /// One batch. Returns how many were resolved.
    private static func analyzeBatch(_ pending: [BrandUpdate], in context: ModelContext) async -> Int {
        guard !pending.isEmpty else { return 0 }

        var cut = 0
        var resolved = 0
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

            // **A photograph that did not answer is not a photograph that never will.**
            //
            // This used to write the item off on *any* failure to load: stamp `analyzedAt`,
            // both versions and `analyzedImageURL`, and move on. The reasoning — a dead URL
            // must not be retried forever — is right about a 404 and wrong about everything
            // else, and everything else is the common case: a phone that was offline for
            // the second the pass ran, a CDN timing out, a rate limit. One such moment
            // permanently cost that item its cutout, its colours, its silhouette and its
            // measured aspect, with every version field current so nothing would ever look
            // again. On the fit canvas that is a garment drawn as a raw product shot — a
            // white rectangle on the canvas, next to pieces that lifted fine.
            //
            // So a definitive answer is written off and an inconclusive one is left pending.
            let loaded = await load(url)
            guard case .image(let lead) = loaded else {
                if case .gone = loaded {
                    // Recording *which* URL failed is what lets a repaired row through
                    // later without reopening this one — see `analyzedImageURL`.
                    update.analyzedAt = Date()
                    update.analyzedImageURL = url.absoluteString
                    update.cutoutVersion = Cutout.version
                    update.visionVersion = VisualReading.version
                    resolved += 1
                }
                continue
            }

            // **Everything below measures the packshot, not necessarily the lead shot.**
            //
            // A brand that leads its gallery with a lookbook — Stüssy publishes four model
            // shots and one packshot, model first — was having its *model* measured: the
            // cutout lifted a person, `Silhouette` recorded a human outline as the shape of
            // a shirt, and the dominant colour came off a lookbook background. See
            // `ProductShot`. `analyzedImageURL` is still stamped with the **lead** URL
            // below, because that field's job is to notice the gallery being replaced.
            let shot = await ProductShot.choose(
                first: ProductShot.Choice(url: url, image: lead),
                others: Array(update.imageURLs.dropFirst()),
                load: { candidate in
                    if case .image(let image) = await load(candidate) { image } else { nil }
                }
            )
            let image = shot.image
            update.packshotURLString = shot.url.absoluteString

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
                // disk with no row pointing at it — and `Cutout.remove` is also what drops
                // the decoded copy, or the canvas draws the previous revision's sticker for
                // the rest of the session however good the new one is.
                //
                // Removed by the name this pass is about to write rather than by the stored
                // one. They are the same string whenever a sticker is recorded, and when the
                // row says nil the file can still be there — a lift that found nothing last
                // time round leaves exactly that orphan.
                let name = Cutout.name(for: update.id)
                if needsCutout { Cutout.remove(name) }
                // `writeFile` only when the sticker is actually due. When this is running for
                // the reading alone the mask is all that is wanted, and encoding a
                // full-resolution RGBA PNG to overwrite a current file with its own contents
                // is the most expensive no-op in the pass.
                let lift = await Cutout.make(from: image, named: name, writeFile: needsCutout)
                // Interrupted rather than answered: leave every stamp alone and leave the
                // row due. Stamping here is what turned one cancelled pass into a garment
                // with no cutout for as long as it exists — see `Cutout.Lift.wasInterrupted`.
                // Not counted as resolved either, or the drain loop would step over it.
                if lift.wasInterrupted { continue }
                if needsCutout {
                    update.cutoutFile = lift.file
                    update.cutoutVersion = Cutout.version
                    if lift.file != nil { cut += 1 }
                }
                if needsReading, let mask = lift.mask {
                    update.visionSilhouette = await Silhouette.measure(mask, slot: update.garmentSlot)
                }
            }

            // Last, and only once everything above has had its turn: a row stamped before
            // its measurements are written would be skipped on the next pass holding none
            // of them.
            if needsReading { update.visionVersion = VisualReading.version }
            update.analyzedImageURL = url.absoluteString
            resolved += 1
        }
        try? context.save()
        log.info("looked at \(pending.count) saved items, resolved \(resolved), lifted \(cut)")
        return resolved
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

    /// What came back, and — crucially — whether asking again could ever change it.
    ///
    /// The distinction is the whole point: a caller that treats every failure as permanent
    /// writes an item off for being offline for one second. See the use site.
    private enum Load {
        case image(UIImage)
        /// The host answered and what it said is not a picture: a 404, a removed asset, a
        /// format nothing here can decode. Asking again gets the same answer.
        case gone
        /// Nothing usable came back *this time* — no network, a timeout, a 5xx, a rate
        /// limit. Temporary by definition, so the item stays due.
        case unavailable
    }

    /// How wide a photograph is worth fetching *to be measured*.
    ///
    /// Everything downstream works far below this already — `Histogram` samples a 48² grid,
    /// `Silhouette` a 256px outline, `Seamless` a 1200px canvas — and the cutout's largest
    /// consumer is `FitPieceImage` at `drawnWidth` points. So a full-resolution original buys
    /// nothing and costs on every axis at once: the download, the decode, and every Vision
    /// request in the pass, which are all proportional to the pixels handed to them.
    ///
    /// Matching `FitPieceImage.drawnWidth` is deliberate rather than a coincidence of
    /// numbers. It resolves to the same rendition the canvas asks the CDN for, so the two
    /// share a `URLCache` entry instead of pulling one photograph twice at two sizes.
    private static let measuredWidth = FitPieceImage.drawnWidth

    private static func load(_ url: URL) async -> Load {
        do {
            // Asked for at the size it will be used at. `sized` leaves an unrecognised host
            // alone, which is exactly the class of host that ships 3200² PNGs — so the cap
            // in `decode` is what protects those, and the two work as a pair.
            var request = URLRequest(url: ImageRendition.sized(url, width: measuredWidth))
            request.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                // 429 and 5xx are the CDN asking to be left alone for a moment, which is
                // the opposite of a reason to give up on the item forever.
                if http.statusCode == 429 || http.statusCode >= 500 { return .unavailable }
                if http.statusCode >= 400 { return .gone }
            }
            // A 200 carrying something that will not decode is a genuine dead end: an
            // error page served as HTML, or a format this OS has no decoder for.
            //
            // Decoded through `ImageLoader` rather than `UIImage(data:)`, which is the same
            // correction the feed already made and this pass never got. `UIImage(data:)`
            // produces **no pixels** — it wraps a data provider, and the rasterisation is
            // deferred to whoever first asks for `cgImage`. Here that is `Histogram`, called
            // from a `@MainActor` type: the whole multi-megapixel decode landed on the main
            // thread, twelve times a batch, in a loop that drains the entire backlog.
            return ImageLoader
                .decoded(data, maxPixel: ImageRendition.pixels(for: measuredWidth))
                .map(Load.image) ?? .gone
        } catch {
            return .unavailable
        }
    }
}
