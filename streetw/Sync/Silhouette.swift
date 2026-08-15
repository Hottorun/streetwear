// Silhouette.swift
// Reading a garment's shape off its outline.
//
// `Cutout` produces a mask so a fit reads as an outfit, and then discards everything about
// it except the picture. But the mask *is* the garment's shape, and shape is the one thing
// the catalogue text is worst at: a brand writes "relaxed" on everything, "oversized" on
// half of it, and nothing at all on the rest.
//
// The measurement has to survive the fact that brands shoot at different distances, so it
// is deliberately built from **ratios within the outline** rather than from anything
// absolute:
//
// - **Breadth** — the widest row divided by the height. Says baggy from slim.
// - **Taper** — the hem's width divided by the widest row. Says a wide leg from a tapered
//   one, and a boxy top from a fitted one.
//
// Both are scale-free: doubling the garment in frame changes neither. What they cannot
// survive is a garment that is not laid out the way its category usually is — a jacket
// photographed folded reads as boxy whatever it is — which is why this refuses to answer
// far more often than it answers, and why the labels are coarse.
//
// **A shape is only reported for a slot where it means something.** "Wide" said about a
// beanie is noise; the useful answers are about tops, bottoms and outerwear, which is also
// where the vocabulary people actually use ("boxy", "baggy", "cropped") lives.

import CoreGraphics
import Foundation
import OSLog
import StreetwCore
import UIKit

enum Silhouette {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "silhouette")

    /// The buffer this works in. The outline needs far less resolution than the sticker —
    /// this is measuring proportions, not edges — and 256 keeps the row scan trivial.
    private static let workingSide = 256

    /// A row must be at least this share of the widest row to count as part of the garment
    /// body. Below it we are looking at a drawstring, a hanger loop or the anti-aliased tip
    /// of a sleeve, and letting those set the extent makes every garment "Long".
    private static let bodyThreshold = 0.25

    /// The share of the outline's height treated as the hem, measured from the bottom.
    private static let hemBand = 0.15

    /// What the outline turned out to be, or nil when it refused to answer.
    ///
    /// Nil is the ordinary case in a great many situations and every one of them is
    /// legitimate: no cutout was produced (Vision does not run in the Simulator and
    /// `Seamless` declines on anything but a flat sweep), the photograph is a lookbook shot
    /// with no single garment in it, or the slot is one where shape says nothing.
    static func measure(_ image: CGImage, slot: GarmentSlot) -> String? {
        guard SilhouetteBands.speaks(for: slot) else { return nil }
        guard let mask = Mask(image, side: workingSide) else { return nil }
        guard let widths = mask.bodyWidths(threshold: bodyThreshold), widths.count > 8 else {
            return nil
        }
        guard Self.isPlausibleOutline(widths) else { return nil }

        let height = Double(widths.count)
        let widest = Double(widths.max() ?? 0)
        guard widest > 0 else { return nil }

        let breadth = widest / height
        let hemRows = max(Int(height * hemBand), 1)
        let hem = Double(widths.suffix(hemRows).reduce(0, +)) / Double(hemRows)
        let taper = hem / widest
        let bodyBreadth = hem / height

        // Logged because the bands were set from measurements of a real wardrobe rather
        // than from intuition, and the next person to adjust them will want the same
        // numbers rather than a fresh guess. It is also the only way to see this working:
        // the whole path is device-only, so no test can reach it.
        log.info(
            """
            silhouette \(slot.rawValue, privacy: .public): \
            breadth \(breadth, format: .fixed(precision: 2)) \
            taper \(taper, format: .fixed(precision: 2)) \
            body \(bodyBreadth, format: .fixed(precision: 2))
            """
        )

        // The bands live in `StreetwCore` beside the classifier whose slots they read.
        // Measuring needs CoreGraphics and cannot go there; judging is pure arithmetic,
        // is the part with an opinion in it, and is the only part testable without a
        // photograph — which matters, because Vision produces no mask in the Simulator and
        // this function can therefore never run in a test at all.
        return SilhouetteBands.label(
            breadth: breadth,
            taper: taper,
            bodyBreadth: bodyBreadth,
            slot: slot
        )
    }

    /// Whether these row widths describe a garment rather than a rectangle.
    ///
    /// **The check this file was missing, and the one that matters most.** A garment has a
    /// shape: shoulders against a hem, a waist against an ankle, a sleeve against a cuff.
    /// A frame with its corners shaved does not, and it will happily yield a breadth and a
    /// taper that read like measurements and mean nothing.
    ///
    /// It was not hypothetical. Against a real collection every measured item came back
    /// with a taper of 0.95 to 0.99 — including trousers, whose hems cannot possibly be as
    /// wide as their widest point — because Vision's subject lift does not run in the
    /// Simulator, `Seamless` had declined on all but one photograph, and what was being
    /// measured was therefore the original image. Refusing here is the honest answer: a
    /// silhouette we cannot see is not a silhouette we should name.
    /// Measured across the **middle** of the outline, not across all of it.
    ///
    /// Checking every row was not enough and the logs said so. A photograph with softened
    /// corners narrows sharply in its first and last few rows and is a perfect rectangle in
    /// between, so it passed a whole-outline check while still reporting a top as wider
    /// than it was tall. The middle is where a garment's own shape lives — chest against
    /// hem, hip against ankle — and it is exactly where a frame has none.
    private static func isPlausibleOutline(_ widths: [Int]) -> Bool {
        let trim = Int(Double(widths.count) * 0.1)
        let middle = widths.dropFirst(trim).dropLast(trim)
        guard let widest = middle.max(), let narrowest = middle.min(), widest > 0 else {
            return false
        }
        return Double(narrowest) / Double(widest) <= variation
    }

    /// How much the outline must narrow somewhere along its body. Even a boxy tee draws in
    /// at the shoulders relative to its sleeves, and every trouser has a waistband
    /// narrower than its hips; a frame does neither.
    private static let variation = 0.85

    /// The alpha channel of a lifted image, as a grid that can be scanned by row.
    private struct Mask {
        private let alpha: [UInt8]
        let width: Int
        let height: Int

        init?(_ cgImage: CGImage, side: Int) {
            let scale = min(1, Double(side) / Double(max(cgImage.width, cgImage.height)))
            width = max(Int((Double(cgImage.width) * scale).rounded()), 1)
            height = max(Int((Double(cgImage.height) * scale).rounded()), 1)

            var buffer = [UInt8](repeating: 0, count: width * height)
            // Alpha only — there is no colour question here, and an 8-bit single-channel
            // context is a quarter of the memory and the only channel being read.
            guard let context = CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return nil }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            alpha = buffer

            // An image with no transparency at all is not a cutout — it is the original,
            // and its "outline" is the rectangle of the frame. Measuring that would report
            // the aspect ratio of the photograph as the shape of the garment, which is the
            // exact wrong answer confidently delivered.
            //
            // The threshold was 0.97 and that was far too generous. Measured against a real
            // collection, every item came back with a taper between 0.95 and 0.99 — a hem
            // as wide as the widest row, on trousers, which cannot happen. What was
            // actually being measured was a frame with its corners shaved. An outline has
            // to be substantially smaller than its own bounding box before it is an outline
            // at all; `isPlausibleOutline` then checks that it has a shape as well.
            let opaque = buffer.count { $0 > 24 }
            guard Double(opaque) / Double(buffer.count) < 0.85 else { return nil }
        }

        /// The width of every row belonging to the garment's body, top to bottom.
        ///
        /// Rows narrower than `threshold` of the widest are trimmed from **both ends**
        /// rather than filtered throughout: a hood's drawstring or a hanger loop sits above
        /// the garment and would otherwise add height that belongs to nothing, while a gap
        /// in the middle of a garment — between two legs, say — is genuinely part of it.
        func bodyWidths(threshold: Double) -> [Int]? {
            var rows: [Int] = []
            rows.reserveCapacity(height)
            for y in 0..<height {
                var minX = -1, maxX = -1
                for x in 0..<width where alpha[y * width + x] > 24 {
                    if minX < 0 { minX = x }
                    maxX = x
                }
                rows.append(maxX >= minX && minX >= 0 ? maxX - minX + 1 : 0)
            }

            guard let widest = rows.max(), widest > 0 else { return nil }
            let floor = Double(widest) * threshold
            guard let first = rows.firstIndex(where: { Double($0) >= floor }),
                  let last = rows.lastIndex(where: { Double($0) >= floor }),
                  last > first
            else { return nil }

            return Array(rows[first...last])
        }
    }
}
