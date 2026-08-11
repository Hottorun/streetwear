// SharedInbox.swift
// The hand-off between the share extension and the app.
//
// **This file belongs to both targets.** The extension writes, the app drains.
//
// One file per shared item rather than a single JSON array, because two processes are
// involved: the extension can be writing while the app is draining, and a read-modify-
// write on a shared array loses saves whenever those overlap. A uniquely-named file is
// created in one step and deleted in one step, so there is no window to lose anything in.
//
// The extension deliberately stores only the URL and whatever title the share sheet
// supplied. Fetching the page to find its image is the app's job: an extension is memory
// limited and expected to return immediately, and a share that spins is a share people
// stop using.

import Foundation

/// A link the user sent to streetw from somewhere else.
struct SharedSave: Codable, Sendable, Hashable {
    var url: URL
    var title: String?
    var sharedAt: Date

    init(url: URL, title: String? = nil, sharedAt: Date = Date()) {
        self.url = url
        self.title = title
        self.sharedAt = sharedAt
    }
}

enum SharedInbox {
    /// Must match the App Group capability on *both* targets. A mismatch is silent:
    /// the container URL comes back nil and every share vanishes without an error.
    static let appGroupID = "group.com.kern.functional.streetw"

    private static var directory: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return nil }
        return container.appendingPathComponent("inbox", isDirectory: true)
    }

    /// Called from the extension. Returns false when the App Group isn't reachable, so
    /// the extension can tell the user rather than silently dropping the save.
    @discardableResult
    static func append(_ save: SharedSave) -> Bool {
        guard let directory else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(UUID().uuidString).json")
            try JSONEncoder().encode(save).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Everything waiting to be filed, each paired with the file it came from.
    ///
    /// Reading and deleting are deliberately separate: the app enriches each save with a
    /// network fetch before storing it, and if it were killed part-way through — or the
    /// fetch simply never returned — a read-and-delete would have already thrown the
    /// user's save away. Nothing is removed until it is safely in the store.
    ///
    /// A file that fails to decode is dropped here and now, because it can never
    /// succeed and would otherwise be retried on every launch forever.
    static func pending() -> [(id: URL, save: SharedSave)] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              )
        else { return [] }

        var items: [(id: URL, save: SharedSave)] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let save = try? JSONDecoder().decode(SharedSave.self, from: data)
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            items.append((file, save))
        }
        return items.sorted { $0.save.sharedAt < $1.save.sharedAt }
    }

    /// Called once a save is committed to the store.
    static func remove(_ id: URL) {
        try? FileManager.default.removeItem(at: id)
    }

    /// Whether the App Group is wired up at all. Used to show an honest error in the
    /// extension instead of a success animation over a dropped save.
    static var isAvailable: Bool { directory != nil }
}
