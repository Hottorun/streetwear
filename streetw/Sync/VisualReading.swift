// VisualReading.swift
// Everything the photograph itself can be asked, in one pass.
//
// `ImageTagger` was reading two things off a product shot — a dominant colour and Vision's
// category labels — and both answer questions the *title* could mostly have answered too.
// The picture knows a great deal more than that, and all of it was going unasked while the
// bytes sat decoded in memory:
//
// - **A second colour.** A garment is rarely one colour and the collection was recording it
//   as if it were.
// - **How busy it is.** Colour variety and edge density inside the garment. This is what
//   makes two loud pieces argue, and no tag anywhere says it.
// - **How much text is on it.** The single most defining axis in streetwear taste and the
//   one no amount of catalogue parsing can reach — a brand does not file a hoodie under
//   "logo-heavy", but the wordmark is right there across the chest.
// - **Its shape**, from the cutout mask that `Cutout` already produces and then threw away.
// - **Its tonal register** — how dark, how colourful. Two numbers that fall straight out of
//   the histogram the colour vote already builds, and together they separate two wardrobes
//   that a list of colour names would call identical.
// - **A perceptual fingerprint**, so two garments can be compared on how they *look*.
//
// Split out from `ImageTagger` because the two do different jobs: this measures, that one
// decides what is due, persists it and drains the backlog. Nothing here touches SwiftData.
//
// **None of it leaves the device**, and none of it needs a model file: every request here
// ships with the OS. Note that Vision's classifier and subject lift both fail outright in
// the Simulator ("Failed to create espresso context"), so a development build gets the
// histogram measurements and nothing else — that is expected, not a bug.

import CoreImage
import Foundation
import OSLog
import UIKit
import Vision

enum VisualReading {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "vision")

    /// Bump whenever any measurement below changes, so rows carrying an older answer get
    /// one more look. See `BrandUpdate.visionVersion`.
    static let version = 1

    /// What one photograph turned out to be. Every field is optional or zero-defaulted,
    /// because each measurement can decline independently and a partial reading is worth
    /// keeping — the histogram works everywhere, and the Vision requests do not.
    struct Reading {
        var color: String?
        var secondaryColor: String?
        var busyness: Double = 0
        var lightness: Double = 0
        var saturation: Double = 0
        var textCoverage: Double = 0
        var featurePrint: Data?
    }

    /// Everything measurable from the pixels, minus the silhouette — which needs the
    /// cutout mask and is therefore taken separately, once the lift has happened.
    static func read(_ image: UIImage) async -> Reading {
        var reading = Reading()

        if let pixels = Histogram(image: image) {
            let palette = pixels.palette()
            reading.color = palette.dominant
            reading.secondaryColor = palette.secondary
            reading.busyness = pixels.busyness
            reading.lightness = pixels.lightness
            reading.saturation = pixels.saturation
        }

        guard let cgImage = image.cgImage else { return reading }
        reading.textCoverage = await textCoverage(in: cgImage)
        reading.featurePrint = await featurePrint(of: cgImage)
        return reading
    }

    // MARK: - Text on the garment

    /// How much of the frame is covered by legible text, 0…1.
    ///
    /// **Area, not word count.** A hoodie with `PALACE` across the whole chest and a tee
    /// with a 4pt care label both recognise one string, and they are opposite garments. The
    /// bounding boxes are normalised, so summing their areas is the measure that
    /// distinguishes them.
    ///
    /// Two guards make this a garment reading rather than an OCR dump. The confidence floor
    /// keeps out the phantom strings the recogniser finds in fabric texture and stitching;
    /// and a box taller than a third of the frame is not lettering on a garment, it is the
    /// recogniser having read the whole photograph as a sign.
    private static func textCoverage(in cgImage: CGImage) async -> Double {
        do {
            var request = RecognizeTextRequest()
            // Fast, not accurate. This does not care *what* the garment says — only how
            // much of it is saying something — and the accurate path costs several times as
            // much for a transcript nobody reads.
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            // Lettering, not labelling. A care label, a size tab and a barcode are all text
            // and none of them are a graphic; the request's own height floor discards them
            // before any work is done on them, which is cheaper and more honest than
            // recognising them and then throwing the result away.
            request.minimumTextHeightFraction = 0.03

            let observations = try await request.perform(on: cgImage)
            var covered = 0.0
            for observation in observations where observation.confidence > 0.3 {
                let box = observation.boundingBox
                // A box taller than a third of the frame is not lettering on a garment, it
                // is the recogniser having read the whole photograph as a sign.
                guard box.height < 0.34 else { continue }
                covered += Double(box.height * box.width)
            }
            // Overlapping boxes can sum past 1 on a dense graphic; the number is a register
            // rather than a measurement, so it is clamped instead of being resolved.
            return min(covered, 1)
        } catch {
            log.info("no text pass: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Perceptual fingerprint

    /// Vision's own embedding of the photograph, as bytes to store.
    ///
    /// Roughly two kilobytes and compared with `distance(to:)`, which is why it is worth
    /// keeping per item: "more like this" has only ever matched *words*, so it cannot see
    /// that two jackets resemble each other and can be fooled by two unrelated products
    /// both tagged "cotton".
    ///
    /// The **whole observation** is archived, not its `data` vector. There is no
    /// initialiser that takes the raw bytes back — the vector alone does not say how many
    /// elements it holds or of what type — so storing it would be storing something that
    /// can never be read. `FeaturePrintObservation` is `Codable`, and a binary property
    /// list is the compact way to write one.
    private static func featurePrint(of cgImage: CGImage) async -> Data? {
        do {
            let request = GenerateImageFeaturePrintRequest()
            let observation = try await request.perform(on: cgImage)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try encoder.encode(observation)
        } catch {
            log.info("no feature print: \(error.localizedDescription)")
            return nil
        }
    }

    /// How far apart two stored fingerprints are, or nil when either is missing or the two
    /// cannot be compared.
    ///
    /// Nil rather than a large distance: "we cannot compare these" and "these look nothing
    /// alike" are different answers, and a caller that ranks on the second would quietly
    /// sink every unanalysed item to the bottom of its list — which, on a collection where
    /// the pass has not finished draining, is most of it.
    static func distance(_ one: Data?, _ other: Data?) -> Double? {
        guard let one, let other else { return nil }
        do {
            let decoder = PropertyListDecoder()
            let a = try decoder.decode(FeaturePrintObservation.self, from: one)
            let b = try decoder.decode(FeaturePrintObservation.self, from: other)
            return try a.distance(to: b)
        } catch {
            return nil
        }
    }
}
