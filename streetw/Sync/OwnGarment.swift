// OwnGarment.swift
// A garment you photographed: the files it is drawn from, the terms `Pairing` reads it in, and
// the one moment it becomes a save.
//
// **The photograph is the reader's and stays on the phone.** It is sent once, to be read
// (`POST /v1/ai/scan`), and never stored by the server; what is kept is kept here, beside the
// store it belongs to — so it is partitioned by profile exactly as the save is, and goes with
// the store when a profile or an account is removed. See `docs/ai.md` and `docs/collection.md`.

import Foundation
import OSLog
import StreetwCore
import SwiftData
import UIKit

/// Where a store's own photographs live: a directory beside the store file, named after it.
///
/// **Named with the store's file name as its prefix** — `default.store-photos` — because that
/// is the rule `ProfileStores.remove` deletes by: every file in the directory starting with the
/// store's name, which takes `-wal` and `-shm` with the store and now takes this with them too.
/// An account's directory is removed whole, so nothing is left behind on either path.
enum OwnPhotos {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "scan")

    static func directory(forStore storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appending(path: storeURL.lastPathComponent + "-photos", directoryHint: .isDirectory)
    }

    /// Resolved from the container the context belongs to rather than from the current
    /// profile: a save is drawn by the store it is in, and a view from the session being left
    /// can still draw for a pass after a switch.
    static func directory(in context: ModelContext) -> URL? {
        context.container.configurations.first.map { directory(forStore: $0.url) }
    }

    static func directory(of save: SavedItem) -> URL? {
        guard !save.isGone, let context = save.modelContext else { return nil }
        return directory(in: context)
    }

    static func photoName(for id: UUID) -> String { "\(id.uuidString).jpg" }
    static func cutoutName(for id: UUID) -> String { "\(id.uuidString)-cutout.png" }

    /// Writes the photograph — and the lift, where there was one — for a save about to exist.
    /// Returns the two names, or nil when the photograph could not be written, in which case
    /// no save should be made: a garment of your own with no photograph is nothing at all.
    static func write(_ scan: ScannedGarment, as id: UUID, in context: ModelContext) -> (photo: String, cutout: String?)? {
        guard let directory = directory(in: context),
              let jpeg = scan.photo.jpegData(compressionQuality: 0.85)
        else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let photo = photoName(for: id)
            try jpeg.write(to: directory.appending(path: photo), options: .atomic)
            var cutout: String?
            if let png = scan.cutout?.pngData() {
                let name = cutoutName(for: id)
                try png.write(to: directory.appending(path: name), options: .atomic)
                cutout = name
            }
            return (photo, cutout)
        } catch {
            log.error("could not write an own photograph: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes a save's own files and forgets the decoded copies. Called before the save is,
    /// while it still has a context to resolve the directory from.
    static func remove(for save: SavedItem) {
        guard save.isOwnGarment else { return }
        for url in [save.ownPhotoURL, save.ownCutoutURL].compactMap({ $0 }) {
            LocalImage.forget(url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The photograph as the fit judge is sent it: the JPEG already on disk, which was written
    /// at the scan's size and is under `AIScan.maxBytes` by a wide margin. Nil when it is not.
    static func upload(for save: SavedItem) -> Data? {
        guard let url = save.ownPhotoURL,
              let data = try? Data(contentsOf: url),
              data.count <= AIScan.maxBytes
        else { return nil }
        return data
    }
}

/// One photographed garment, read and not yet kept.
///
/// Held in memory between the reading and a choice. **Nothing is written until somebody
/// chooses** — "does it go with my wardrobe" is asked in a shop about something not bought, and
/// asking must not put it in the collection; only *Add to my wardrobe*, or saving a fit that
/// was built around it, makes it a save.
struct ScannedGarment: Identifiable {
    let id = UUID()
    /// The photograph, upright and at the scan's size.
    let photo: UIImage
    /// The garment lifted off it, when `Cutout` found one — never in the Simulator, where
    /// Vision does not run, unless `Seamless` recognised a studio sweep.
    let cutout: UIImage?
    let reading: AIScanReading

    var pairingID: String { "scan:\(id.uuidString)" }

    var aspect: Double? {
        photo.size.height > 0 ? Double(photo.size.width / photo.size.height) : nil
    }

    var garment: Garment {
        OwnGarment.garment(
            id: pairingID,
            title: reading.description,
            type: reading.type,
            slot: reading.slot,
            colours: reading.colours,
            material: reading.material,
            pattern: reading.pattern,
            style: reading.style
        )
    }

    /// Makes this a save: the files beside the store, the reading on the row. Returns nil when
    /// the photograph could not be written.
    @discardableResult
    func save(as type: SavedItem.SaveType, in context: ModelContext) -> SavedItem? {
        let save = SavedItem(update: nil, type: type)
        guard let files = OwnPhotos.write(self, as: save.id, in: context) else { return nil }
        save.ownPhotoFile = files.photo
        save.ownCutoutFile = files.cutout
        save.ownAspect = aspect
        save.ownTitle = reading.description
        save.ownType = reading.type
        save.ownSlot = reading.slot
        save.ownColours = reading.colours
        save.ownMaterial = reading.material
        save.ownPattern = reading.pattern
        save.ownStyle = reading.style
        save.ownSearchText = reading.searchText
        context.insert(save)
        try? context.save()
        UsageCounts.record(.saveAdded)
        return save
    }
}

enum OwnGarment {
    /// A garment of your own in `Pairing`'s terms, from what the scan said.
    ///
    /// The slot is the one the model read off the photograph, which beats what the classifier
    /// could make of three words of its own; the colours are canonicalised so `ColorHarmony`
    /// reads them, and one it does not know is dropped rather than guessed — a nil colour
    /// scores neutral, which is the rule for anything unmeasured. Nothing is measured for
    /// busyness or text, so those rules fall silent, as they do for an unanalysed save.
    static func garment(
        id: String,
        title: String?,
        type: String?,
        slot: String?,
        colours: [String],
        material: String?,
        pattern: String?,
        style: [String]
    ) -> Garment {
        let named = colours.compactMap(ColorHarmony.canonicalName(of:))
        return Garment(
            id: id,
            title: type ?? title ?? "",
            productType: type,
            tags: style + [material, pattern].compactMap { $0 },
            color: named.first,
            secondaryColor: named.dropFirst().first,
            slot: slot.flatMap(GarmentSlot.init(rawValue:))
        )
    }
}
