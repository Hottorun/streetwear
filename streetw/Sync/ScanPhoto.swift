// ScanPhoto.swift
// Getting one photograph of one garment ready to be read: upright, small, cut out where it
// can be, and a JPEG under the size the server takes.
//
// **Only this photograph is sent, and only once** (`docs/ai.md`, *The scan*). It is cut out on
// the phone first where `Cutout` succeeds, so the model is shown the garment rather than the
// changing-room mirror behind it — and so less of somebody's bedroom leaves the phone. Vision
// does not run in the Simulator; there `Seamless` lifts a garment shot on a flat sweep and
// anything else is sent as it was taken, which is the fallback on a device too.

import Foundation
import OSLog
import StreetwCore
import UIKit

enum ScanPhoto {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "scan")

    struct Prepared {
        /// Upright, at most `AIScan.maxEdge` on its long side, opaque.
        var photo: UIImage
        /// The garment lifted off it, or nil.
        var cutout: UIImage?
        /// What is sent: the cutout on white where there is one, else the photograph.
        var upload: Data
    }

    static func prepare(_ image: UIImage) async -> Prepared? {
        let photo = upright(image, maxEdge: CGFloat(AIScan.maxEdge))
        // **A written file is the only proof of a lift.** `Lift.mask` is also the source's own
        // outline when the source carries an alpha channel, and a renderer's image carries one
        // even when it is drawn opaque — so reading the mask kept the whole photograph, backdrop
        // and all, as the "cutout". The file is read back and removed at once: nothing is kept
        // until somebody chooses to keep it, and then it goes beside the store (`OwnPhotos`).
        let name = "scan-\(UUID().uuidString).png"
        let lift = await Cutout.make(from: photo, named: name)
        var cutout: UIImage?
        if lift.file != nil {
            // Read into memory before the file goes; a lazily decoded image would draw nothing.
            cutout = (try? Data(contentsOf: Cutout.url(for: name))).flatMap(UIImage.init(data:))
            Cutout.remove(name)
        }
        let sent = cutout.map { onWhite($0, maxEdge: CGFloat(AIScan.maxEdge)) } ?? photo
        guard let upload = jpeg(sent) else { return nil }
        // Which photograph left the phone is worth being able to tell afterwards: a lift that
        // kept its backdrop and one that found nothing look alike on screen.
        log.notice("""
            scan prepared: photo \(Int(photo.size.width), privacy: .public)×\(Int(photo.size.height), privacy: .public), \
            cutout \(cutout.map { "\(Int($0.size.width))×\(Int($0.size.height)) alpha \($0.cgImage?.alphaInfo.rawValue ?? 0)" } ?? "none", privacy: .public), \
            sent \(upload.count, privacy: .public) bytes
            """)
        return Prepared(photo: photo, cutout: cutout, upload: upload)
    }

    /// Drawn through a renderer rather than trusted as it came: a camera photograph carries
    /// its orientation as metadata, and a model shown it sideways reads a sideways garment.
    private static func upright(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// A cutout on white, with a margin, because a JPEG has no transparency and black is what
    /// an alpha channel flattens to — a dark garment would vanish into it.
    private static func onWhite(_ cutout: UIImage, maxEdge: CGFloat) -> UIImage {
        let margin = max(cutout.size.width, cutout.size.height) * 0.06
        let canvas = CGSize(width: cutout.size.width + margin * 2, height: cutout.size.height + margin * 2)
        let longest = max(canvas.width, canvas.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let size = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            cutout.draw(in: CGRect(
                x: margin * scale,
                y: margin * scale,
                width: cutout.size.width * scale,
                height: cutout.size.height * scale
            ))
        }
    }

    /// The best quality under the limit. A 1024px garment at 0.8 is a few hundred kilobytes, so
    /// the loop is a guard rather than the common path.
    private static func jpeg(_ image: UIImage) -> Data? {
        for quality in [0.8, 0.7, 0.6, 0.5, 0.4] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= AIScan.maxBytes {
                return data
            }
        }
        return nil
    }
}
