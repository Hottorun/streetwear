// ImageTagger.swift
// Reading a saved thing off its photograph instead of off its title.
//
// `StyleProfile` used to work by looking for the word "black" in a product name. That
// is fine until a brand calls something "Triple White" (which is a colourway, not a
// colour), or "Nocturne", or names it after a person — and it can never say anything
// about an item shared in from a page with a two-word title. The photograph, meanwhile,
// is unambiguous.
//
// Two things are extracted, and only two, because they are the two the profile actually
// uses:
//
// - **Dominant colour**, by downsampling to a thumbnail and voting — excluding the
//   seamless white or black sweep every storefront shoots on, which would otherwise win
//   every vote.
// - **Categories**, from Vision's own on-device classifier. No model file, no download,
//   and its taxonomy already contains the clothing terms we care about.
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

    /// Small enough that the vote is cheap, big enough that trim and panels still carry
    /// weight. The garment is what we want, not a perfect average.
    private static let sampleSize = 48

    /// Analyses saved items that haven't been looked at yet. Bounded per pass so opening
    /// the collection never stalls behind a backlog.
    static func analyzePending(in context: ModelContext, limit: Int = 12) async {
        let saves = (try? context.fetch(FetchDescriptor<SavedItem>())) ?? []
        let pending = saves
            .compactMap(\.update)
            .filter { $0.analyzedAt == nil && $0.primaryImageURL != nil }
            .prefix(limit)
        guard !pending.isEmpty else { return }

        for update in pending {
            guard let url = update.primaryImageURL else { continue }
            guard let image = await load(url) else {
                // Mark it anyway. A dead image URL will never resolve, and retrying it
                // on every launch is a permanent background cost for nothing.
                update.analyzedAt = Date()
                continue
            }
            // Free: the image is already decoded, and the wall would otherwise be
            // guessing tile heights from a hash of the item id.
            if image.size.height > 0 {
                update.imageAspect = Double(image.size.width / image.size.height)
            }
            if let color = dominantColor(in: image) {
                update.visionColor = color.name
            }
            update.visionCategories = await categories(in: image)
            update.analyzedAt = Date()
        }
        try? context.save()
        log.info("tagged \(pending.count) saved items")
    }

    // MARK: - Colour

    /// The most common non-backdrop colour, by quantised vote.
    ///
    /// A mean would produce mud: averaging a black jacket against a white sweep gives
    /// grey, which is a colour neither present nor useful. Voting on coarse buckets
    /// keeps the answer to something that is actually in the picture.
    static func dominantColor(in image: UIImage) -> NamedColor? {
        guard let pixels = downsample(image, to: sampleSize) else { return nil }

        let garment = pixels.filter { !ColorNamer.isLikelyBackdrop(red: $0.r, green: $0.g, blue: $0.b) }

        // A white shirt on a white sweep leaves almost nothing behind once the backdrop
        // is removed, and what does survive is shadow and stitching — which would name
        // the garment "Grey". Below a useful remainder, vote over everything instead and
        // let it say "White", which is the true answer for exactly these items.
        let voting = Double(garment.count) / Double(max(pixels.count, 1)) < 0.08 ? pixels : garment

        var votes: [String: (count: Int, confidence: Double)] = [:]
        for pixel in voting {
            let named = ColorNamer.name(red: pixel.r, green: pixel.g, blue: pixel.b)
            let existing = votes[named.name] ?? (0, 0)
            votes[named.name] = (existing.count + 1, max(existing.confidence, named.confidence))
        }

        guard let winner = votes.max(by: { $0.value.count < $1.value.count }) else { return nil }
        return NamedColor(name: winner.key, confidence: winner.value.confidence)
    }

    private struct Pixel {
        var r: Double
        var g: Double
        var b: Double
    }

    /// How much of the frame to keep, measured from the centre.
    ///
    /// Excluding the backdrop by colour alone is not enough: a seamless sweep is 70–85%
    /// of a product shot, and the near-white penumbra that survives a colour test still
    /// outvotes the garment. Measured on real Kith and BBC shots, every item came back
    /// "White" — including a black-and-grey Air Jordan. Product photography is reliably
    /// centred, so cropping to the middle is what actually puts the garment in the
    /// majority.
    private static let centreCrop = 0.55

    /// Redraws the image tiny and reads the raw bytes back. Cheaper and far more
    /// predictable than sampling the full-size image.
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
        let bytesPerRow = side * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: side * side * bytesPerPixel)

        guard let context = CGContext(
            data: &buffer,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var pixels: [Pixel] = []
        pixels.reserveCapacity(side * side)
        for index in stride(from: 0, to: buffer.count, by: bytesPerPixel) {
            // Fully transparent pixels are padding, not colour.
            guard buffer[index + 3] > 8 else { continue }
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
