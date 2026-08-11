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
    /// Returns nil whenever Vision found no foreground — which is a real outcome, not an
    /// error. A flat-lay of six things, a lookbook photograph of a street, a size chart:
    /// there is no single subject to lift and the honest answer is to keep using the
    /// original. Callers must therefore treat a missing cutout as normal.
    static func make(from image: UIImage, named name: String) async -> String? {
        guard let cgImage = image.cgImage else { return nil }

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
            else { return nil }
            // Every instance, cropped to what was kept. A jacket photographed with its
            // belt detached is two instances and both are the garment; cropping afterwards
            // is what stops a sticker carrying half a frame of transparent margin around
            // it, which on a canvas reads as an item you can't line up.
            let masked = try observation.generateMaskedImage(
                for: observation.allInstances,
                imageFrom: handler,
                croppedToInstancesExtent: true
            )

            guard let png = encode(masked) else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url(for: name), options: .atomic)
            return name
        } catch {
            // Expected on some hardware and in some simulators. A fit built from the
            // original photographs still works — it just looks like a mood board.
            log.info("no cutout for \(name, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// A stable, filesystem-safe name so a re-run overwrites rather than accumulating.
    static func name(for id: UUID) -> String { "\(id.uuidString).png" }

    /// The mask comes back as a `CVPixelBuffer` with an alpha channel, and it has to stay
    /// that way — JPEG would flatten the transparency into black and every sticker would
    /// arrive as a silhouette.
    private static func encode(_ buffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
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
