// FitRender.swift
// Flattening a fit to one picture, without giving up the fit.
//
// Both artefacts are kept and they answer different questions. The **structure** — which
// saved items, where — is what keeps a fit editable, keeps it a list of things you own,
// and is the only reason a restock in one of its pieces could ever be worth telling you
// about. The **render** is what a card can draw in a scrolling row without laying out a
// dozen images, and what could be shared later.
//
// Neither substitutes for the other: a render alone is a screenshot of an outfit, and a
// structure alone means every card in the Style tab composes a canvas to draw a thumbnail.

import Foundation
import OSLog
import StreetwCore
import SwiftUI

enum FitRender {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "fits")

    /// Beside the cutouts, and for the same reason: regenerating is not free, and a
    /// thumbnail that disappears under storage pressure looks like a lost outfit.
    ///
    /// Path arithmetic is `nonisolated`; only the drawing below needs the main actor, and
    /// `Fit.renderURL` is read from wherever a card happens to be laid out.
    nonisolated static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "fits", directoryHint: .isDirectory)
    }

    nonisolated static func url(for name: String) -> URL {
        directory.appending(path: name)
    }

    nonisolated static func name(for id: UUID) -> String { "\(id.uuidString).png" }

    /// Decodes everything the canvas will need before anything tries to draw it.
    ///
    /// `ImageRenderer` produces one frame synchronously and gives an async load no chance
    /// to finish, so a canvas of `CachedImage`s renders as a stack of empty tiles — which
    /// is precisely what the first saved fit came out as. Items with a cutout need nothing
    /// (a local file decodes inline); the rest have to be in the decoded cache *before*
    /// the render, at the same width `FitPieceImage` will ask for.
    static func warm(_ fit: Fit) async {
        for entry in fit.placed where entry.item.update?.cutoutFile == nil {
            guard let url = entry.item.update?.primaryImageURL else { continue }
            _ = try? await ImageLoader.shared.load(
                ImageRendition.sized(url, width: FitPieceImage.drawnWidth)
            )
        }
    }

    /// Draws the canvas off-screen and writes it out. Returns the filename, or nil if
    /// rendering failed — in which case the card falls back to drawing the live surface,
    /// which is what it does for fits made before renders existed.
    ///
    /// Call `warm` first. Rendering without it is not an error and produces a valid PNG;
    /// it is just a picture of empty tiles.
    @MainActor
    @discardableResult
    static func write(_ fit: Fit, side: CGFloat = 900) -> String? {
        let renderer = ImageRenderer(
            content: FitCanvasSurface(fit: fit, isEditing: false)
                .frame(width: side, height: side)
                .background(Color.paper)
        )
        // Rendered at 1×, not the screen's scale: `side` is already the pixel count wanted,
        // and multiplying by 3 on a Pro would write a 2700px PNG for a 168pt card.
        renderer.scale = 1

        guard let image = renderer.uiImage, let data = image.pngData() else {
            log.error("could not render fit \(fit.id, privacy: .public)")
            return nil
        }
        let name = name(for: fit.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: name), options: .atomic)
            return name
        } catch {
            log.error("could not write fit render: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }
}
