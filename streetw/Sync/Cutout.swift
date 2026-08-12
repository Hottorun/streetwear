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
    static let version = 1

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
    static func make(from image: UIImage, named name: String) async -> String? {
        guard let cgImage = image.cgImage else {
            log.info("no cgImage for \(name, privacy: .public)")
            return nil
        }

        if let lifted = await subject(in: cgImage, named: name) {
            return write(lifted, named: name)
        }
        if let trimmed = Seamless.lift(cgImage) {
            log.info("backdrop removed for \(name, privacy: .public)")
            return write(trimmed, named: name)
        }
        return nil
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
            // Every instance, cropped to what was kept. A jacket photographed with its
            // belt detached is two instances and both are the garment; cropping afterwards
            // is what stops a sticker carrying half a frame of transparent margin around
            // it, which on a canvas reads as an item you can't line up.
            let masked = try observation.generateMaskedImage(
                for: observation.allInstances,
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

    /// Writes a lifted image out as PNG, returning the filename.
    private static func write(_ image: CIImage, named name: String) -> String? {
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

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// A stable, filesystem-safe name so a re-run overwrites rather than accumulating.
    static func name(for id: UUID) -> String { "\(id.uuidString).png" }

    /// PNG, and it has to stay that way — JPEG would flatten the transparency into black
    /// and every sticker would arrive as a silhouette.
    private static func encode(_ ciImage: CIImage) -> Data? {
        let context = CIContext()
        guard let colorSpace = ciImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return context.pngRepresentation(
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
