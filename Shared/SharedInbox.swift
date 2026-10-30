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
// The extension still fetches nothing. It stores the URL, the share sheet's title and —
// since contract 2 — what Safari had already loaded (`SharedPage`), plus whatever was chosen in
// the sheet: boards, a watch, or following the shop instead. Fetching anything is the app's
// job: an extension is memory limited, and a share sheet that spins is one people stop using.
//
// **Lenient and versioned.** Every field after `sharedAt` is optional and decodes as absent
// from a file an older extension wrote, and the app reads a file an extension of *any* age
// wrote — the two ship together, but a file can wait in the inbox across an update. See
// docs/share-extension.md.

import Foundation
import StreetwCore

/// A link the user sent to Dropwall from somewhere else.
struct SharedSave: Codable, Sendable, Hashable {
    /// The shape this file was written in. Absent is 1: a URL, a title and a profile.
    static let currentVersion = 2

    var url: URL
    var title: String?
    var sharedAt: Date
    /// The store that was current when this was shared — `ProfileScope.home`: a profile's
    /// server user id, or the account's id for the holder of an Apple ID that has a store of
    /// its own — or nil for `default.store`, which is every share an older extension wrote.
    /// Optional, so those still decode. The app files a share only into this store, and never
    /// while it belongs to an account that is not signed in. See `docs/profiles.md`.
    var profileID: UUID?

    var version: Int?
    /// What the page Safari had loaded says about itself. Nil when the share came from an
    /// app that handed over an address alone.
    var page: SharedPage?
    /// False while the sheet is still open: the file is written the moment the sheet appears,
    /// so nothing is lost if it is killed, and rewritten with each choice until Done. Absent
    /// (every older file) means finished. See `SharedInbox.isSettled`.
    var isComplete: Bool?
    /// What the sheet decided the page is. Absent on older files, which were all saves.
    var role: PageRole?
    /// Boards chosen in the sheet, by `Board.id`. One deleted since is ignored.
    var boardIDs: [UUID]?
    /// Boards named in the sheet's "New board…", created on import.
    var newBoards: [String]?
    /// Follow the shop instead of saving the page. A shop page with this set saves nothing.
    var follow: Bool?
    /// A stock watch to set once the save has landed.
    var notify: SharedNotify?

    init(url: URL, title: String? = nil, sharedAt: Date = Date(), profileID: UUID? = nil) {
        self.url = url
        self.title = title
        self.sharedAt = sharedAt
        self.profileID = profileID
    }

    /// Only the address and the date are required. Everything else is `try?`, so a value a
    /// later extension writes in a shape this build cannot read — a role it has never heard
    /// of — costs that one field, not the file: `pending()` deletes a file that will not
    /// decode, and that file is somebody's save.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        sharedAt = try c.decode(Date.self, forKey: .sharedAt)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        profileID = try? c.decodeIfPresent(UUID.self, forKey: .profileID)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        page = try? c.decodeIfPresent(SharedPage.self, forKey: .page)
        isComplete = try? c.decodeIfPresent(Bool.self, forKey: .isComplete)
        role = try? c.decodeIfPresent(PageRole.self, forKey: .role)
        boardIDs = try? c.decodeIfPresent([UUID].self, forKey: .boardIDs)
        newBoards = try? c.decodeIfPresent([String].self, forKey: .newBoards)
        follow = try? c.decodeIfPresent(Bool.self, forKey: .follow)
        notify = try? c.decodeIfPresent(SharedNotify.self, forKey: .notify)
    }

    /// Whether the app saves anything for this share. A shop page somebody chose to follow
    /// saves nothing: a homepage on the wall is a junk card, and the follow is what was meant.
    var savesPage: Bool { !(role == .shop && follow == true) }
}

/// The page as Safari had loaded it, from `ReadPage.js`. Raw on purpose: parsing is
/// `ProductPage` and `PageMetadataParser`, the same code that reads a page the app fetched.
struct SharedPage: Codable, Sendable, Hashable {
    var url: URL?
    var title: String?
    var canonical: String?
    /// `og:*`, `product:*`, `twitter:*` and `description`, keys lowered.
    var meta: [String: String]
    /// Each `application/ld+json` block's text, size-capped by the script.
    var jsonLD: [String]
    /// The largest pictures drawn on the page, largest first.
    var images: [String]

    init(
        url: URL? = nil,
        title: String? = nil,
        canonical: String? = nil,
        meta: [String: String] = [:],
        jsonLD: [String] = [],
        images: [String] = []
    ) {
        self.url = url
        self.title = title
        self.canonical = canonical
        self.meta = meta
        self.jsonLD = jsonLD
        self.images = images
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(URL.self, forKey: .url)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        canonical = try? c.decodeIfPresent(String.self, forKey: .canonical)
        meta = (try? c.decodeIfPresent([String: String].self, forKey: .meta)) ?? [:]
        jsonLD = (try? c.decodeIfPresent([String].self, forKey: .jsonLD)) ?? []
        images = (try? c.decodeIfPresent([String].self, forKey: .images)) ?? []
    }

    /// The tags, read the way a fetched page's are.
    func metadata(base: URL) -> PageMetadata {
        PageMetadataParser.parse(tags: meta, title: title, canonical: canonical, base: base)
    }

    /// The product the page describes, by the same parser the app's own fetch uses.
    func product(base: URL) -> ProductPage? {
        ProductPage.parse(jsonLD: jsonLD, metadata: metadata(base: base), base: base)
    }

    /// The pictures drawn on the page, as addresses — what a shop that builds its gallery with
    /// a script has and its markup does not.
    var imageURLs: [String] {
        images.filter { URL(string: $0)?.scheme == "https" }
    }
}

/// "Notify me", chosen in the sheet. Each size is one watch; none is any size.
struct SharedNotify: Codable, Sendable, Hashable {
    /// Labels as the page printed them.
    var sizes: [String]
    var color: String?
    /// The page listed no sizes, so the app asks which one once it knows the run.
    var askSize: Bool

    init(sizes: [String] = [], color: String? = nil, askSize: Bool = false) {
        self.sizes = sizes
        self.color = color
        self.askSize = askSize
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sizes = (try? c.decodeIfPresent([String].self, forKey: .sizes)) ?? []
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        askSize = (try? c.decodeIfPresent(Bool.self, forKey: .askSize)) ?? false
    }
}

/// What the app tells the sheet about the store a share will land in — written by the app,
/// read by the extension, one file per store (`SharedInbox.writeContext`). Only what the sheet
/// draws: the boards to offer, the sizes to pre-select, and the shops followed (to say "you
/// follow it", and whether a markdown on the save will be said).
struct SharedContext: Codable, Sendable, Hashable {
    static let currentVersion = 1

    struct Board: Codable, Sendable, Hashable, Identifiable {
        var id: UUID
        var name: String
    }

    var version: Int
    var boards: [Board]
    var sizes: SizeProfile
    /// Registrable domains (`BrandDiscovery.registrableDomain`) of every followed brand.
    var followedDomains: [String]
    /// `PriceAlerts.isEnabled`: whether a markdown on a save is said at all.
    var savedPriceDropAlerts: Bool

    init(boards: [Board], sizes: SizeProfile, followedDomains: [String], savedPriceDropAlerts: Bool) {
        self.version = Self.currentVersion
        self.boards = boards
        self.sizes = sizes
        self.followedDomains = followedDomains
        self.savedPriceDropAlerts = savedPriceDropAlerts
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        boards = (try? c.decodeIfPresent([Board].self, forKey: .boards)) ?? []
        sizes = (try? c.decodeIfPresent(SizeProfile.self, forKey: .sizes)) ?? SizeProfile()
        followedDomains = (try? c.decodeIfPresent([String].self, forKey: .followedDomains)) ?? []
        savedPriceDropAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .savedPriceDropAlerts)) ?? true
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

    /// Called from the extension, once when the sheet opens and again for every choice made in
    /// it. Returns the file, to be passed back as `file` for each rewrite — or nil when the App
    /// Group isn't reachable, so the extension can say so rather than silently dropping it.
    ///
    /// Rewriting one file is safe where a shared array was not: the extension is its only
    /// writer, the write is atomic, and the app does not take a file whose sheet is still open
    /// (`isSettled`).
    @discardableResult
    static func write(_ save: SharedSave, to file: URL? = nil) -> URL? {
        guard let directory else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = file ?? directory.appendingPathComponent("\(UUID().uuidString).json")
            try JSONEncoder().encode(save).write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// How long a sheet left open is waited for. Past it the share is filed as it stands: the
    /// sheet was killed, or put away without Done, and the save it already wrote must not wait
    /// forever. Measured from `sharedAt`, never from the file's own dates — the privacy
    /// manifest declares no file-timestamp reads.
    static let openSheetGrace: TimeInterval = 15 * 60

    /// Whether the app may file this share now.
    static func isSettled(_ save: SharedSave, now: Date = Date()) -> Bool {
        save.isComplete != false || now.timeIntervalSince(save.sharedAt) > openSheetGrace
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

    /// Drops every waiting share filed for one of `owners` — the stores of an account whose
    /// data is being removed from the phone — and what the sheet was told about those stores.
    /// Nil is the store the holder had before the field.
    static func discard(for owners: Set<UUID?>) {
        for item in pending() where owners.contains(item.save.profileID) {
            remove(item.id)
        }
        for owner in owners {
            if let file = contextFile(for: owner) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Whether the App Group is wired up at all. Used to show an honest error in the
    /// extension instead of a success animation over a dropped save.
    static var isAvailable: Bool { directory != nil }

    // MARK: - The current profile

    /// Which profile a share belongs to, written by the app on every switch and read by the
    /// extension at share time.
    ///
    /// **A file in the group container, not `UserDefaults(suiteName:)`.** The privacy manifest
    /// says no suite exists, and the container is already the one channel between the two
    /// targets. Absent or unreadable means the holder, which is every install before profiles.
    private static var profileFile: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("current-profile", isDirectory: false)
    }

    static func setCurrentProfile(_ id: UUID?) {
        guard let file = profileFile else { return }
        if let id {
            try? Data(id.uuidString.utf8).write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func currentProfile() -> UUID? {
        guard let file = profileFile, let data = try? Data(contentsOf: file) else { return nil }
        return UUID(uuidString: String(decoding: data, as: UTF8.self))
    }

    // MARK: - What the sheet is told

    /// One file per store, named by its `home` (`phone` for `default.store`), so a switch of
    /// profile can never show one person's boards in another's sheet.
    private static func contextFile(for home: UUID?) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("share-context", isDirectory: true)
            .appendingPathComponent("\(home?.uuidString ?? "phone").json", isDirectory: false)
    }

    /// Called by the app. Writes nothing when the file already says the same, so it can be
    /// called on every way out of the foreground without touching the disk for nothing.
    static func writeContext(_ context: SharedContext, for home: UUID?) {
        // Compared decoded, not as bytes: the sizes are sets, which encode in no fixed order.
        guard let file = contextFile(for: home), Self.context(for: home) != context,
              let data = try? JSONEncoder().encode(context)
        else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Read by the extension. Nil until the app has run once with this build — the sheet then
    /// offers no boards and pre-selects no sizes, and everything else works.
    static func context(for home: UUID?) -> SharedContext? {
        guard let file = contextFile(for: home), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SharedContext.self, from: data)
    }
}
