// Histogram.swift
// The garment's pixels, downsampled once and then asked several questions.
//
// This is `ImageTagger`'s old `downsample` plus `dominantColor`, lifted out and made to
// earn more from the same work. The sampling and the centre crop are unchanged and the
// reasoning behind both is unchanged — a seamless sweep is 70–85% of a product shot, so a
// mean produces mud and an uncropped vote produces "White" for a black Air Jordan.
//
// What is new is that one pass now answers four questions instead of one. The second
// colour, the busyness, the lightness and the saturation are all properties of a
// distribution that was being built, read once for its maximum, and thrown away.

import CoreGraphics
import Foundation
import StreetwCore
import UIKit

struct Histogram {
    /// Small enough that the vote is cheap, big enough that trim and panels still carry
    /// weight. The garment is what we want, not a perfect average.
    private static let sampleSize = 48

    /// How much of the frame to keep, measured from the centre.
    ///
    /// Excluding the backdrop by colour alone is not enough: the near-white penumbra that
    /// survives a colour test still outvotes the garment. Product photography is reliably
    /// centred, so cropping to the middle is what actually puts the garment in the
    /// majority. Measured on real Kith and BBC shots.
    private static let centreCrop = 0.55

    struct Pixel {
        var r: Double
        var g: Double
        var b: Double

        var lightness: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

        /// HSV saturation: distance from grey, normalised by brightness. A dark navy and a
        /// bright navy are equally colourful, which is the property wanted here — this is
        /// asking "does this person wear colour", not "how bright is this photograph".
        var saturation: Double {
            let high = max(r, g, b), low = min(r, g, b)
            guard high > 0.01 else { return 0 }
            return (high - low) / high
        }
    }

    /// Every sampled pixel, and the subset that is not studio backdrop.
    private let all: [Pixel]
    private let garment: [Pixel]

    /// The pixels the measurements should speak for.
    ///
    /// A white shirt on a white sweep leaves almost nothing behind once the backdrop is
    /// removed, and what survives is shadow and stitching — which names the garment "Grey".
    /// Below a useful remainder, fall back to the whole frame and let it say "White", which
    /// is the true answer for exactly those items.
    private var voting: [Pixel] {
        Double(garment.count) / Double(max(all.count, 1)) < 0.08 ? all : garment
    }

    init?(image: UIImage) {
        guard let sampled = Self.downsample(image, to: Self.sampleSize) else { return nil }
        all = sampled
        garment = sampled.filter { !ColorNamer.isLikelyBackdrop(red: $0.r, green: $0.g, blue: $0.b) }
    }

    // MARK: - Colour

    /// The one or two colours worth naming.
    ///
    /// A mean would produce mud: averaging a black jacket against a white sweep gives grey,
    /// which is a colour neither present nor useful. Voting on coarse buckets keeps the
    /// answer to something actually in the picture.
    ///
    /// The runner-up has to *earn* its place. Most garments are one colour, and a second
    /// name on every row would say "Black · Grey" about a plain black hoodie whose only
    /// grey is its own shadow — so an accent is reported only when it holds a real share of
    /// the vote, and never when it is the same name as the winner.
    func palette() -> (dominant: String?, secondary: String?) {
        let pixels = voting
        guard !pixels.isEmpty else { return (nil, nil) }

        var votes: [String: Int] = [:]
        for pixel in pixels {
            votes[ColorNamer.name(red: pixel.r, green: pixel.g, blue: pixel.b).name, default: 0] += 1
        }

        let ranked = votes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let winner = ranked.first else { return (nil, nil) }

        let accent = ranked.dropFirst().first
        let share = accent.map { Double($0.value) / Double(pixels.count) } ?? 0
        return (winner.key, share >= Self.minimumAccentShare ? accent?.key : nil)
    }

    /// A fifth of the garment. Below that it is trim, a shadow, or the edge of a print, and
    /// naming it as a second colour overstates what is there.
    private static let minimumAccentShare = 0.2

    // MARK: - Register

    var lightness: Double {
        let pixels = voting
        guard !pixels.isEmpty else { return 0 }
        return pixels.reduce(0) { $0 + $1.lightness } / Double(pixels.count)
    }

    var saturation: Double {
        let pixels = voting
        guard !pixels.isEmpty else { return 0 }
        return pixels.reduce(0) { $0 + $1.saturation } / Double(pixels.count)
    }

    // MARK: - Busyness

    /// How much is going on, 0…1 — colour variety and edge density, averaged.
    ///
    /// Two halves because each is wrong on its own. **Variety** alone calls a smooth
    /// two-tone gradient busy; **edges** alone calls a heavily creased plain shirt busy.
    /// A garment scores high here when it is both multi-coloured *and* structured, which is
    /// what a print, a graphic or a colourblock panel actually is.
    ///
    /// Note what this deliberately is not: a claim that there is a print. A four-panel
    /// colourblock jacket scores high with no print on it at all, and that is correct for
    /// the thing this feeds — whether two pieces argue when worn together.
    var busyness: Double {
        let pixels = voting
        guard pixels.count > 16 else { return 0 }

        // Variety: how much of the vote sits outside the winning bucket. A plain garment
        // puts nearly everything in one; a print spreads.
        var votes: [String: Int] = [:]
        for pixel in pixels {
            votes[ColorNamer.name(red: pixel.r, green: pixel.g, blue: pixel.b).name, default: 0] += 1
        }
        let top = votes.values.max() ?? pixels.count
        let variety = 1 - Double(top) / Double(pixels.count)

        return min(max((variety + edgeDensity) / 2, 0), 1)
    }

    /// The share of neighbouring pairs that differ sharply, over the full sampled grid.
    ///
    /// Measured on `all` rather than on the garment subset on purpose: the subset is not a
    /// rectangle, so it has no neighbours to speak of. The garment/backdrop boundary
    /// contributes a fixed handful of edges to every product shot, which is a constant this
    /// does not need to remove because the number is only ever compared against other
    /// product shots.
    private var edgeDensity: Double {
        let side = Self.sampleSize
        guard all.count == side * side else { return 0 }

        var sharp = 0, total = 0
        for y in 0..<side {
            for x in 0..<side {
                let here = all[y * side + x]
                if x + 1 < side {
                    total += 1
                    if here.difference(from: all[y * side + x + 1]) > Self.edgeThreshold { sharp += 1 }
                }
                if y + 1 < side {
                    total += 1
                    if here.difference(from: all[(y + 1) * side + x]) > Self.edgeThreshold { sharp += 1 }
                }
            }
        }
        guard total > 0 else { return 0 }
        // Even a busy garment only steps hard across a minority of neighbours at this
        // sampling, so the raw share bunches near zero and would never separate anything.
        // Scaled so the range that actually occurs uses the range that is reported.
        return min(Double(sharp) / Double(total) * 4, 1)
    }

    /// Far enough apart to be a boundary rather than a fold or a gradient.
    private static let edgeThreshold = 0.22

    // MARK: - Sampling

    /// Redraws the image tiny and reads the raw bytes back. Cheaper and far more
    /// predictable than sampling the full-size image.
    ///
    /// The grid is returned **whole**, including fully transparent pixels as black — the
    /// edge pass needs a rectangle it can index by row and column, and dropping pixels
    /// would silently shift every neighbour. Transparency is excluded from the colour vote
    /// instead, by `ColorNamer.isLikelyBackdrop` never being asked about it: an alpha of
    /// zero reads as black, which is a real colour, so it is filtered here by carrying the
    /// alpha through.
    private static func downsample(_ image: UIImage, to side: Int) -> [Pixel]? {
        guard var cgImage = image.cgImage else { return nil }

        let width = Double(cgImage.width)
        let height = Double(cgImage.height)
        let crop = CGRect(
            x: width * (1 - centreCrop) / 2,
            y: height * (1 - centreCrop) / 2,
            width: width * centreCrop,
            height: height * centreCrop
        )
        if let cropped = cgImage.cropping(to: crop) { cgImage = cropped }

        let bytesPerPixel = 4
        var buffer = [UInt8](repeating: 0, count: side * side * bytesPerPixel)

        guard let context = CGContext(
            data: &buffer,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var pixels: [Pixel] = []
        pixels.reserveCapacity(side * side)
        for index in stride(from: 0, to: buffer.count, by: bytesPerPixel) {
            pixels.append(
                Pixel(
                    r: Double(buffer[index]) / 255,
                    g: Double(buffer[index + 1]) / 255,
                    b: Double(buffer[index + 2]) / 255
                )
            )
        }
        return pixels
    }
}

extension Histogram.Pixel {
    func difference(from other: Histogram.Pixel) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
