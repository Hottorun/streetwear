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
    ///
    /// **2 is a repair, exactly as `Cutout.version` 2 is**, and for the same fault:
    /// `ImageTagger` stamped this alongside the cutout on any failure to fetch the
    /// photograph, transient ones included, so rows exist at version 1 with no colour, no
    /// busyness, no silhouette and nothing that will ever ask again. Those items are
    /// invisible to the style reading and to every fit suggestion.
    ///
    /// **3 travels with `Cutout.version` 3, and it has to.** The silhouette is measured by
    /// `Silhouette` but stamped under *this* version, and its only input is the mask
    /// `Cutout` produces — so a revision that changes which lifts are accepted changes the
    /// answer here too. `ImageTagger` runs the lift when either is due and writes the
    /// silhouette only when the reading is, so bumping the cutout alone would re-cut every
    /// sticker and leave every shape measured against the mask that was just replaced.
    ///
    /// **4 travels with `Cutout.version` 4 for that same reason**, and independently earns
    /// it: the cancellations that wrote off the cutouts took the whole reading with them —
    /// the log's "no text pass", "no feature print" and "no human detection available" are
    /// all this file's requests being cancelled — and every one of those rows was stamped
    /// at 3 holding none of it. A row with no colour is not merely missing a swatch: it is
    /// unscoreable by `ColorHarmony`, so it can never be chosen into a fit and never
    /// offered as a candidate.
    /// **5 is a re-naming, not a re-measurement.** `ColorNamer` was reading a black garment
    /// under cool light as **Navy** — HSB saturation divides by brightness, so three
    /// hundredths between the channels is a quarter of a "saturation" once the pixel is dark.
    /// Measured on a real collection it named sixteen of twenty-eight garments navy,
    /// including one titled "washed black". The pixels stored are fine; the word derived from
    /// them was wrong, and nothing re-derives a word — so every row needs one more look.
    ///
    /// **6 is the same kind of thing, on the other side of the same band.** The dark branch
    /// named three arcs of the hue circle and let everything else fall through to "Black", so
    /// a chocolate brown, a dark teal, a dark purple and a dark orange were all filed as
    /// black — with a cliff at `brightness == 0.22` where one notch brighter answered
    /// "Brown". A stored verdict from the older rules is worse than none, because nothing
    /// would ever revisit it: the swatch on the card, the facet counts in `StyleProfile` and
    /// every pairing `ColorHarmony` scores are all read off that one word.
    static let version = 6

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
        guard let decoded = fingerprint(one) else { return nil }
        return distance(decoded, other)
    }

    /// Decodes a stored fingerprint once, for a caller comparing one subject against many.
    ///
    /// `distance(_:_:)` decodes **both** sides, and the ranking that uses it holds one side
    /// fixed — so scoring a product against a few hundred candidates decoded the subject's
    /// own two-kilobyte plist a few hundred times. Splitting the decode out is free and
    /// removes it from the loop.
    static func fingerprint(_ data: Data?) -> FeaturePrintObservation? {
        guard let data else { return nil }
        return try? PropertyListDecoder().decode(FeaturePrintObservation.self, from: data)
    }

    static func distance(_ one: FeaturePrintObservation, _ other: Data?) -> Double? {
        guard let other = fingerprint(other) else { return nil }
        return try? one.distance(to: other)
    }
}
