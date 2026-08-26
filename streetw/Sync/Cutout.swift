// Cutout.swift
// Lifting a garment off its backdrop, so a fit reads as an outfit rather than a mood board.
//
// A canvas built from raw product shots is a wall of white rectangles overlapping each
// other. What makes an outfit look composed is that every piece is a *sticker* — the
// garment with its background gone — and that is the difference between the fit builder
// feeling like arranging clothes and feeling like arranging screenshots.
//
// Vision does this on device, with the same subject-lifting the Photos app uses. Nothing
// is uploaded, nothing costs anything, and streetwear is the easy case: a studio sweep
// behind a single centred object is exactly what the model is best at.
//
// Two decisions worth keeping:
//
// - **Cut once, on the way into the collection**, not every time an item is dragged onto a
//   canvas. `ImageTagger` already walks saved items and already decodes each photograph, so
//   the mask rides along in a pass that was happening anyway.
// - **The PNG is a file, not a column.** A cutout is a few hundred KB of RGBA and there is
//   one per saved item; SwiftData stores the *name* and the bytes live in Application
//   Support. The original URL is untouched, so the feed still shows the photograph as shot.

import CoreImage
import CoreVideo
import Foundation
import OSLog
import UIKit
import Vision

enum Cutout {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "cutout")

    /// Which revision of the lift produced a stored answer, for the same reason
    /// `GenderClassifier.version` exists: a `cutoutFile` of nil means both "there is no
    /// subject here" and "nobody has looked yet", and without a version stamp the second
    /// is indistinguishable from the first and is therefore never revisited. Everything
    /// saved before this file existed is stale at 0, which is exactly right.
    ///
    /// Bump it whenever the lift changes — a better mask on an item already marked
    /// subject-less would otherwise only ever reach items saved after the update.
    ///
    /// **2 is a repair, not a better lift.** `ImageTagger` used to stamp this on *any*
    /// failure to fetch the photograph, including being offline for the second the pass
    /// ran — so an unknown number of saved items are sitting at version 1 marked
    /// "subject-less" when nobody ever actually looked at them. Those are the pieces that
    /// draw as raw product shots on the fit canvas. Bumping makes every one of them due
    /// again, which is the only thing that heals a collection that already has them.
    ///
    /// It is also what re-picks *which photograph* gets lifted. Everything analysed before
    /// `ProductShot` existed was cut from the gallery's first image, which on a
    /// lookbook-first brand is a model — so those items hold a cutout of a person and
    /// nothing else would ever revisit them either.
    ///
    /// **3 is the verification gate.** Until it, a lift was written down the moment Vision
    /// returned *anything* — see `isSticker` and `substantialInstances` for the two ways
    /// that produced a "cutout" which is not one. Every item already carrying one of those
    /// is holding a bad sticker with a current version stamp, so nothing but a bump reaches
    /// them.
    static let version = 3

    /// Where the PNGs live. Application Support rather than Caches: re-cutting is not free,
    /// and a canvas whose stickers vanish under storage pressure would be worse than one
    /// that never had them.
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "cutouts", directoryHint: .isDirectory)
    }

    static func url(for name: String) -> URL {
        directory.appending(path: name)
    }

    /// The lifted subject, written to disk, with the file's name returned.
    ///
    /// Returns nil whenever there was nothing to lift — which is a real outcome, not an
    /// error. A flat-lay of six things, a lookbook photograph of a street, a size chart:
    /// there is no single subject and the honest answer is to keep using the original.
    /// Callers must therefore treat a missing cutout as normal.
    ///
    /// Two ways in, tried in order:
    ///
    /// 1. **Vision's subject lifting**, which is the good one — it understands what a
    ///    garment is and cuts around laces, straps and gaps in a chain.
    /// 2. **`Seamless`**, which just deletes a uniform studio backdrop. It cannot tell a
    ///    hoodie from a hubcap, so it only fires where the picture itself says the answer:
    ///    a flat, light, edge-to-edge sweep. That covers most of streetwear product
    ///    photography, and it is the difference between the canvas working and not working
    ///    at all — Vision produces nothing in the Simulator, so without this the whole
    ///    screen is un-buildable there.
    ///
    /// Note that a brand shipping transparent PNGs (Palace does) needs neither: the
    /// photograph is already a sticker, `Seamless` recognises the transparent border and
    /// declines, and `FitPieceImage` draws the original. Those items looked like the cutout
    /// was working long before any of this ran, which is exactly why brands that ship
    /// opaque JPEGs (Kith) read as broken by comparison.
    /// What a lift produced: the file to draw, and the mask it was cut from.
    ///
    /// The mask is handed back rather than only written because it answers a second
    /// question — `Silhouette` reads the garment's shape off exactly this outline, and
    /// re-decoding the PNG from disk to ask would be a second decode of something already
    /// in hand. Both halves are optional and independently so: a brand shipping transparent
    /// PNGs needs no lift at all and still has a perfectly good outline to measure.
    struct Lift {
        var file: String?
        var mask: CGImage?
    }

    /// - Parameter writeFile: whether the sticker is wanted on disk. False when the caller
    ///   only needs the mask — `ImageTagger` re-runs the lift whenever *either* the cutout
    ///   or the deeper reading is due, and encoding a full-resolution RGBA PNG for a row
    ///   whose sticker is already current is several hundred milliseconds spent to
    ///   overwrite a file with its own contents.
    static func make(from image: UIImage, named name: String, writeFile: Bool = true) async -> Lift {
        guard let cgImage = image.cgImage else {
            log.info("no cgImage for \(name, privacy: .public)")
            return Lift()
        }

        // **Vision first, but no longer on trust.** Both candidates go through the same
        // gate, and a refused Vision lift now falls through to `Seamless` instead of ending
        // the search — which until this it did, because "Vision returned something" was
        // read as "Vision returned a garment".
        if let lifted = await subject(in: cgImage, named: name),
           let raster = render(lifted),
           isSticker(raster, from: "vision", named: name) {
            return Lift(file: writeFile ? write(raster, named: name) : nil, mask: raster)
        }
        if let trimmed = Seamless.lift(cgImage),
           let raster = render(trimmed),
           isSticker(raster, from: "seamless", named: name) {
            log.info("backdrop removed for \(name, privacy: .public)")
            return Lift(file: writeFile ? write(raster, named: name) : nil, mask: raster)
        }
        // Nothing to lift, which is ordinary — but the photograph may have arrived already
        // cut out. Palace ships transparent PNGs, so those items have an outline worth
        // measuring even though every lift path correctly declined to touch them.
        return Lift(file: nil, mask: outline(of: cgImage))
    }

    /// A `CIImage` has no pixels until something renders it, and `Silhouette` reads bytes.
    private static func render(_ image: CIImage) -> CGImage? {
        shared.createCGImage(image, from: image.extent)
    }

    /// The original photograph, offered as an outline **only when it carries one**.
    ///
    /// `make` used to hand the untouched source back as the mask whenever nothing lifted,
    /// on the strength of one real case: a brand shipping transparent PNGs (Palace) needs no
    /// lift and still has a perfectly good outline. But that is the rare path. The common
    /// one is an ordinary opaque JPEG, and handing that over meant `Silhouette` opened a
    /// context and drew a 2000–3200px image — forcing its full decode — purely to reach its
    /// own "an image with no transparency is not a cutout" guard and refuse. One decode per
    /// saved item, for a refusal knowable from four bytes of metadata.
    private static func outline(of cgImage: CGImage) -> CGImage? {
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: nil
        default: cgImage
        }
    }

    /// Vision's answer, or nil for any reason at all — no subject, no hardware, no
    /// Simulator support. Every one of those means "try the backdrop instead".
    private static func subject(in cgImage: CGImage, named name: String) async -> CIImage? {
        do {
            // The handler has to be held: `generateMaskedImage` reads the source pixels
            // back out of the *same* handler that ran the request, so a throwaway
            // `request.perform(on:)` cannot produce an image.
            let handler = ImageRequestHandler(cgImage)
            let request = GenerateForegroundInstanceMaskRequest()
            // One observation or none — the request returns *all* foreground instances in
            // a single result, not one result per subject.
            guard let observation = try await handler.perform(request),
                  !observation.allInstances.isEmpty
            else {
                log.info("no foreground instances in \(name, privacy: .public)")
                return nil
            }

            let kept = substantialInstances(of: observation, named: name)
            guard !kept.isEmpty else { return nil }

            // The instances worth keeping, cropped to what was kept. A jacket photographed
            // with its belt detached is two instances and both are the garment; cropping
            // afterwards is what stops a sticker carrying half a frame of transparent margin
            // around it, which on a canvas reads as an item you can't line up.
            let masked = try observation.generateMaskedImage(
                for: kept,
                imageFrom: handler,
                croppedToInstancesExtent: true
            )
            return CIImage(cvPixelBuffer: masked)
        } catch {
            // Expected on some hardware and in every Simulator ("Failed to create espresso
            // context"). Not a failure worth reporting — it is the reason `Seamless` exists.
            log.info("no vision cutout for \(name, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Deciding whether a lift is a garment

    /// Which foreground instances are the product, and whether they add up to a subject at
    /// all. Empty means "refuse this lift".
    ///
    /// `allInstances` was taken wholesale, which is two separate mistakes.
    ///
    /// **A speck is an instance.** A hanger, a care tag, a folded price card, a hard shadow
    /// that reads as its own object: Vision returns each as a foreground instance, and
    /// including one drags the crop out to enclose it — so a hoodie arrives on the canvas as
    /// a hoodie in the corner of a much larger transparent rectangle with a grey dot in the
    /// opposite corner. Anything under a twentieth of the largest instance is dropped.
    ///
    /// **And "everything" is an instance.** On a busy or low-contrast photograph the model
    /// happily returns a foreground covering essentially the whole frame. That produced a
    /// sticker indistinguishable from the original product shot — and, because a file was
    /// written, it looked to every later pass like the lift had *worked*, so `Seamless`
    /// never got its turn and no version stamp ever came back to it.
    ///
    /// Measured on the mask Vision hands back at its own resolution, not on the full-size
    /// masked image, so this costs one small buffer per instance rather than a
    /// multi-megapixel render.
    private static func substantialInstances(
        of observation: InstanceMaskObservation,
        named name: String
    ) -> IndexSet {
        var shares: [(instance: Int, share: Double)] = []
        for instance in observation.allInstances {
            guard let mask = try? observation.generateMask(for: IndexSet(integer: instance)),
                  let share = coveredShare(of: mask)
            else { continue }
            shares.append((instance, share))
        }
        // Nothing could be measured — an unfamiliar buffer format, or a request that will
        // not produce per-instance masks. Degrade to what this did before rather than
        // refusing a lift that may well be fine.
        guard let largest = shares.map(\.share).max(), largest > 0 else {
            return observation.allInstances
        }

        var kept = IndexSet()
        var covered = 0.0
        for entry in shares where entry.share >= largest * instanceFloor {
            kept.insert(entry.instance)
            covered += entry.share
        }

        guard covered >= minSubjectShare, covered <= maxSubjectShare else {
            log.info(
                """
                refusing vision lift for \(name, privacy: .public): \
                subject covers \(covered, format: .fixed(precision: 3)) of the frame
                """
            )
            return IndexSet()
        }
        return kept
    }

    /// How much of a single-channel Vision mask is set, 0…1. Nil for a format this cannot
    /// read, which the caller treats as "no measurement" rather than as zero.
    private static func coveredShare(of buffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return nil }

        var set = 0
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width where row[x] > 127 { set += 1 }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
                for x in 0..<width where row[x] > 0.5 { set += 1 }
            }
        default:
            return nil
        }
        return Double(set) / Double(width * height)
    }

    /// Whether what came back is a garment lifted off something, or the photograph with its
    /// corners shaved.
    ///
    /// The test is the one `Silhouette.Mask` already applies before it will measure an
    /// outline, and the fact that the two disagreed is what this closes: a sticker could be
    /// refused as un-measurable — "an image with no transparency is not a cutout, it is the
    /// original" — and still be written to disk and drawn on the canvas. So the same
    /// question is now asked one step earlier, where it decides whether a file is written at
    /// all, and the bar is set a little looser than the silhouette's because a garment can
    /// legitimately be measurable-but-boxy (a folded stack, a flat-laid tee cropped tight)
    /// and still be a perfectly good sticker.
    ///
    /// Both paths go through it. `Seamless` has its own refusals, but they are about the
    /// *frame* — how much was erased — where this is about the sticker that came out.
    private static func isSticker(_ image: CGImage, from path: String, named name: String) -> Bool {
        guard let fill = opaqueShare(of: image) else { return false }
        guard fill >= minBoxFill, fill <= maxBoxFill else {
            log.info(
                """
                refusing \(path, privacy: .public) lift for \(name, privacy: .public): \
                fills \(fill, format: .fixed(precision: 3)) of its own box
                """
            )
            return false
        }
        return true
    }

    /// The share of a lifted image's own bounding box that is opaque, read at a size where
    /// counting is trivial. An image with no alpha channel at all comes back as 1.
    private static func opaqueShare(of image: CGImage) -> Double? {
        let scale = min(1, Double(gaugeSide) / Double(max(image.width, image.height)))
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)

        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double(buffer.count { $0 > 24 }) / Double(buffer.count)
    }

    /// An instance smaller than this share of the largest one is a prop, not the product.
    private static let instanceFloor = 0.05

    /// How much of the frame the kept instances must cover to be a subject. The ceiling is
    /// the load-bearing one: past it nothing has been lifted off anything.
    private static let minSubjectShare = 0.02
    private static let maxSubjectShare = 0.90

    /// How much of its own bounding box a sticker may fill. A garment cropped to its outline
    /// leaves real gaps — between a shoe's laces, under a sleeve, either side of a collar —
    /// and past this there are none, which means the outline is the frame.
    private static let minBoxFill = 0.02
    private static let maxBoxFill = 0.92

    /// The long edge the alpha gauge works at. This is counting a proportion, not finding an
    /// edge, so 160 is ample and keeps the check off a multi-megapixel buffer.
    private static let gaugeSide = 160

    /// Writes a lifted image out as PNG, returning the filename.
    private static func write(_ image: CGImage, named name: String) -> String? {
        guard let png = encode(image) else {
            log.error("cutout for \(name, privacy: .public) would not encode as PNG")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url(for: name), options: .atomic)
            return name
        } catch {
            log.error("could not write cutout: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes a sticker **and forgets the decoded copy of it**.
    ///
    /// The second half is the part that was missing, and it made a whole class of repair
    /// invisible. A cutout's filename is derived from the item's id, so re-cutting one
    /// overwrites the same path — and `LocalImage` is keyed on that path. So bumping
    /// `version` did everything it was supposed to (re-fetch, re-lift, write a better PNG)
    /// and the canvas went on drawing the *old* sticker out of the in-memory cache for the
    /// rest of the session. `FitRender.remove` had always got this right; this had not.
    @MainActor
    static func remove(_ name: String) {
        let file = url(for: name)
        LocalImage.forget(file)
        try? FileManager.default.removeItem(at: file)
    }

    /// A stable, filesystem-safe name so a re-run overwrites rather than accumulating.
    static func name(for id: UUID) -> String { "\(id.uuidString).png" }

    /// PNG, and it has to stay that way — JPEG would flatten the transparency into black
    /// and every sticker would arrive as a silhouette.
    /// One context for the whole pass, not one per image.
    ///
    /// A `CIContext` is expensive to build — it sets up a Metal command queue and its own
    /// caches — and this file was minting a fresh one twice per garment, once to rasterise
    /// the lift and once to encode it. Sharing it is also what lets those caches do
    /// anything at all: a context discarded after one image has nothing to remember.
    ///
    /// Safe to share: `CIContext` is documented as thread-safe, and the whole cutout pass
    /// runs off the main actor.
    private static let shared = CIContext()

    /// Encodes the **already rasterised** lift, rather than the recipe for it.
    ///
    /// This used to take the `CIImage` and let `pngRepresentation` render it, while
    /// `render` rendered the very same image again for the mask — two full rasterisations of
    /// one lift. There is now exactly one, and it is the buffer the plausibility gate has
    /// already read.
    private static func encode(_ image: CGImage) -> Data? {
        let ciImage = CIImage(cgImage: image)
        guard let colorSpace = ciImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return shared.pngRepresentation(
            of: ciImage,
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }
}

// MARK: - Deleting a studio backdrop

/// Removing the seamless sweep a product was shot on, when Vision won't.
///
/// This knows nothing about clothes. It cannot find a garment, and it must never pretend
/// to — every decision here is about refusing to run rather than about what to keep. What
/// it does know is the one situation streetwear product photography is almost always in: a
/// single object, centred, on a flat light sweep that runs to all four edges. In that
/// situation "the backdrop" is not a guess, it is the colour of the border.
///
/// Three refusals carry it, and they matter more than the fill:
///
/// - **The border must actually be uniform and light.** A lookbook shot on a street, a
///   flat-lay on a rug, a size chart: the border varies, and this returns nil rather than
///   punching a hole in a photograph.
/// - **An already-transparent border means the job is done.** A brand shipping cut-out
///   PNGs gets left alone.
/// - **The result has to be a plausible subject.** If the fill removed almost nothing, or
///   ate almost everything, the premise was wrong and the original is kept.
enum Seamless {
    /// The long edge of the buffer this works in. A cutout is drawn at ~400pt on a canvas,
    /// so 1200px is past the point of visible improvement, and it keeps the flood fill —
    /// which is one pass over every pixel — off a 3200² original.
    private static let workingSide = 1200

    /// How far a pixel may sit from the backdrop colour and still be backdrop. Generous
    /// enough to take the soft gradient at the bottom of a sweep, tight enough to keep a
    /// white shoe.
    private static let tolerance = 0.10

    /// How uniform the border has to be before the sweep is believable at all, and how
    /// light. Kith's is a flat 0.92 grey; a photograph of anything else is nowhere near.
    private static let maxBorderSpread = 0.05
    private static let minBorderLuminance = 0.72

    static func lift(_ cgImage: CGImage) -> CIImage? {
        guard var canvas = Canvas(cgImage, longEdge: workingSide) else { return nil }
        guard let backdrop = canvas.borderColour(spread: maxBorderSpread) else { return nil }
        guard backdrop.luminance >= minBorderLuminance else { return nil }

        let removed = canvas.eraseBackdrop(matching: backdrop, tolerance: tolerance)

        // Nothing came off (the premise was wrong), or nearly everything did (the "subject"
        // was the backdrop). Either way the photograph is better left as it was shot.
        let fraction = Double(removed) / Double(canvas.width * canvas.height)
        guard fraction > 0.05, fraction < 0.97 else { return nil }

        guard let bounds = canvas.opaqueBounds(), let output = canvas.image(cropped: bounds) else {
            return nil
        }
        return CIImage(cgImage: output)
    }

    /// An RGBA8 buffer that can be read, edited and handed back as an image.
    private struct Canvas {
        var pixels: [UInt8]
        let width: Int
        let height: Int

        init?(_ cgImage: CGImage, longEdge: Int) {
            let scale = min(1, Double(longEdge) / Double(max(cgImage.width, cgImage.height)))
            width = max(Int((Double(cgImage.width) * scale).rounded()), 1)
            height = max(Int((Double(cgImage.height) * scale).rounded()), 1)
            pixels = [UInt8](repeating: 0, count: width * height * 4)

            // Premultiplied would fold the backdrop into the colour channels of anything
            // partly transparent, which is precisely what the feathering below writes.
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        subscript(index: Int) -> RGB {
            RGB(
                r: Double(pixels[index * 4]) / 255,
                g: Double(pixels[index * 4 + 1]) / 255,
                b: Double(pixels[index * 4 + 2]) / 255
            )
        }

        private func alpha(_ index: Int) -> UInt8 { pixels[index * 4 + 3] }

        /// The mean colour of the one-pixel border, or nil when the border is not one
        /// colour — which is the whole test for "was this shot on a sweep".
        ///
        /// A border that is already transparent returns nil too: the photograph arrived
        /// cut out and there is nothing here to do.
        func borderColour(spread: Double) -> RGB? {
            var samples: [RGB] = []
            samples.reserveCapacity((width + height) * 2)
            for x in stride(from: 0, to: width, by: 2) {
                for y in [0, height - 1] {
                    let index = y * width + x
                    guard alpha(index) > 8 else { return nil }
                    samples.append(self[index])
                }
            }
            for y in stride(from: 0, to: height, by: 2) {
                for x in [0, width - 1] {
                    let index = y * width + x
                    guard alpha(index) > 8 else { return nil }
                    samples.append(self[index])
                }
            }
            guard !samples.isEmpty else { return nil }

            let mean = RGB(
                r: samples.reduce(0) { $0 + $1.r } / Double(samples.count),
                g: samples.reduce(0) { $0 + $1.g } / Double(samples.count),
                b: samples.reduce(0) { $0 + $1.b } / Double(samples.count)
            )
            // Worst case, not average: a border that is white on three sides and a doorway
            // on the fourth averages to something believable and is not a sweep.
            let worst = samples.map { $0.distance(to: mean) }.max() ?? 0
            return worst <= spread ? mean : nil
        }

        /// **The tolerance is measured against the border's colour and nothing else, and
        /// that is not a limitation to fix.**
        ///
        /// The obvious improvement is to also accept a pixel that is indistinguishable from
        /// the backdrop pixel it was reached *from* — a small per-step tolerance, so a sweep
        /// with a gradient in it (paper falls off towards the bottom of a frame) is followed
        /// rather than abandoned halfway. It was tried, at a step tolerance of 0.035, and
        /// measured against six real Kith product shots: it erases more (0.895 → 0.927 of the
        /// frame on one), and what it erases is **the garment**. A running shoe's white
        /// midsole is a couple of percent from Kith's `#EBEBEB` sweep and shades into it
        /// gradually, so the fill walks in off the backdrop and hollows the sole out; on a
        /// white sneaker it took most of the upper as well. The renders are unambiguous.
        ///
        /// This is the same fact the global-match warning below is about, arriving by a
        /// different route: any rule that lets the fill reach a light garment through a soft
        /// edge will eat light garments. A fixed distance from a known backdrop colour is the
        /// only test that cannot.
        ///
        /// Flood-fills transparency inwards from the edges. Deliberately *not* a global
        /// "every pixel near this colour" pass: the white square of a graphic print, or the
        /// gap between a shoe's laces, is the same colour as the sweep, and erasing those
        /// punches holes through the garment. Only backdrop the frame's edge can reach is
        /// backdrop. Returns how many pixels were erased.
        mutating func eraseBackdrop(matching backdrop: RGB, tolerance: Double) -> Int {
            var queue: [Int] = []
            var seen = [Bool](repeating: false, count: width * height)

            func consider(_ index: Int) {
                guard !seen[index] else { return }
                seen[index] = true
                guard self[index].distance(to: backdrop) <= tolerance else { return }
                queue.append(index)
            }

            for x in 0..<width {
                consider(x)
                consider((height - 1) * width + x)
            }
            for y in 0..<height {
                consider(y * width)
                consider(y * width + width - 1)
            }

            var erased = 0
            while let index = queue.popLast() {
                pixels[index * 4 + 3] = 0
                erased += 1

                let x = index % width, y = index / width
                if x > 0 { consider(index - 1) }
                if x < width - 1 { consider(index + 1) }
                if y > 0 { consider(index - width) }
                if y < height - 1 { consider(index + width) }
            }

            feather(against: backdrop, tolerance: tolerance)
            return erased
        }

        /// Softens the one-pixel rim left by a hard threshold.
        ///
        /// A binary fill stops at the first pixel that is a shade too dark, and those are
        /// the anti-aliased edge pixels of the garment — so the sticker carries a pale halo
        /// of the sweep it was cut from, which on a canvas is the tell that something was
        /// cut out badly. Grading the rim's alpha by how far it is from the backdrop turns
        /// that into an edge.
        private mutating func feather(against backdrop: RGB, tolerance: Double) {
            let ramp = tolerance * 2
            var edges: [(index: Int, alpha: UInt8)] = []

            for index in 0..<(width * height) where alpha(index) > 0 {
                let x = index % width, y = index / width
                let touchesGap =
                    (x > 0 && alpha(index - 1) == 0)
                    || (x < width - 1 && alpha(index + 1) == 0)
                    || (y > 0 && alpha(index - width) == 0)
                    || (y < height - 1 && alpha(index + width) == 0)
                guard touchesGap else { continue }

                let opacity = min(self[index].distance(to: backdrop) / ramp, 1)
                edges.append((index, UInt8(opacity * 255)))
            }
            // Applied afterwards so a softened pixel is not itself read as a gap by the
            // pixel beside it, which would eat inwards a row at a time.
            for edge in edges { pixels[edge.index * 4 + 3] = edge.alpha }
        }

        /// The box around everything still opaque, so the sticker doesn't carry a frame of
        /// empty margin — which on a canvas reads as an item that won't line up.
        func opaqueBounds() -> (x: Int, y: Int, width: Int, height: Int)? {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where alpha(y * width + x) > 12 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return (minX, minY, maxX - minX + 1, maxY - minY + 1)
        }

        func image(cropped bounds: (x: Int, y: Int, width: Int, height: Int)) -> CGImage? {
            var buffer = pixels
            guard let context = CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let whole = context.makeImage() else { return nil }

            return whole.cropping(
                to: CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
            )
        }
    }

    struct RGB {
        var r: Double
        var g: Double
        var b: Double

        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

        func distance(to other: RGB) -> Double {
            let dr = r - other.r, dg = g - other.g, db = b - other.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
    }
}
