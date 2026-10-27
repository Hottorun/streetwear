// ShareQuestions.swift
// Every question a share raises, kept until it is answered.
//
// "Sometimes I share and then a while later I go to the app and the dialog that should allow
// us to get notified about a product is gone." It was gone because it was never kept. A share
// is filed on the next foreground and the question it raised — this one's sold out, want to
// know when it's back? — was a sheet bound to an in-memory property on `PushRoute`. Anything
// that stopped the sheet appearing lost it for good: another sheet already up (the You page, a
// product page), the app killed or suspended before anyone looked, a profile switch rebuilding
// the root. The inbox file had already been deleted, so there was nothing left to ask from.
//
// So the questions are a queue in the profile's own `UserDefaults` (they name rows in that
// profile's store), written **before** the inbox file is removed, and a question leaves only
// when its sheet was actually on screen and then went away — answered, cancelled or swiped
// down, all of which are somebody having seen it. A presentation that silently failed is asked
// again on the next foreground (`ShareQuestionHost`).
//
// The queue also holds the one thing a share asks the app to *do* rather than to ask: follow
// a shop (`Follow`), which needs the network and may take several foregrounds when the site
// has to be checked first. See `ShareFollows`.

import Foundation
import Observation
import OSLog
import StreetwCore

@MainActor
@Observable
final class ShareQuestions {
    private static let log = Logger(subsystem: "com.kern.functional.streetw", category: "share")

    struct Question: Codable, Hashable, Identifiable {
        enum Kind: String, Codable {
            /// Shared in, and every size is gone. The watch editor, with the headline that says so.
            case soldOut
            /// "Notify me" was chosen in the sheet on a page that listed no sizes.
            case pickSize
        }

        var id: UUID
        var kind: Kind
        /// The row it is about — `BrandUpdate.externalID` in this profile's store.
        var externalID: String
        /// The colour chosen in the sheet, pre-selected in the editor.
        var color: String?
        var askedAt: Date

        var headline: String {
            switch kind {
            case .soldOut: "This one's sold out. Want to know when it's back?"
            case .pickSize: "Which size should Dropwall watch?"
            }
        }
    }

    /// "Follow this shop", chosen in the share sheet.
    struct Follow: Codable, Hashable, Identifiable {
        var id: UUID
        var url: URL
        /// What the page called the shop, for the log and for a brand nobody has named yet.
        var name: String?
        /// A site check the server is watching until it is ready (`POST /v1/brands/checks…`).
        var checkID: UUID?
        var sharedAt: Date
        /// Failed tries, so a shop that cannot be reached is not tried on every foreground forever.
        var attempts: Int = 0
    }

    /// Bumped on every change, so the host re-reads the queue.
    private(set) var revision = 0

    static let questionsKey = "shareQuestions"
    static let followsKey = "shareFollows"

    // MARK: - Questions

    func questions(for scope: ProfileScope) -> [Question] {
        Self.read(scope.key(Self.questionsKey))
    }

    /// Asks once per row and kind: draining the same share twice — a kill between the store
    /// write and the inbox delete — must not ask twice.
    func ask(_ kind: Question.Kind, about externalID: String, color: String? = nil, for scope: ProfileScope) {
        var list = questions(for: scope)
        guard !list.contains(where: { $0.externalID == externalID }) else { return }
        list.append(Question(id: UUID(), kind: kind, externalID: externalID, color: color, askedAt: Date()))
        write(list, key: scope.key(Self.questionsKey))
        Self.log.info("asking \(kind.rawValue, privacy: .public) about \(externalID, privacy: .public)")
    }

    func resolve(_ id: UUID, for scope: ProfileScope) {
        let list = questions(for: scope)
        guard list.contains(where: { $0.id == id }) else { return }
        write(list.filter { $0.id != id }, key: scope.key(Self.questionsKey))
    }

    // MARK: - Follows

    func follows(for scope: ProfileScope) -> [Follow] {
        Self.read(scope.key(Self.followsKey))
    }

    func follow(_ url: URL, named name: String?, sharedAt: Date, for scope: ProfileScope) {
        var list = follows(for: scope)
        let domain = Self.domain(of: url)
        guard !list.contains(where: { Self.domain(of: $0.url) == domain }) else { return }
        list.append(Follow(id: UUID(), url: url, name: name, sharedAt: sharedAt))
        write(list, key: scope.key(Self.followsKey))
        Self.log.info("will follow \(url.absoluteString, privacy: .public)")
    }

    func update(_ follow: Follow, for scope: ProfileScope) {
        var list = follows(for: scope)
        guard let index = list.firstIndex(where: { $0.id == follow.id }) else { return }
        list[index] = follow
        write(list, key: scope.key(Self.followsKey))
    }

    func finish(_ follow: Follow, for scope: ProfileScope) {
        write(follows(for: scope).filter { $0.id != follow.id }, key: scope.key(Self.followsKey))
    }

    /// Two shares of one shop are one follow, whichever of its hosts each came from.
    private static func domain(of url: URL) -> String {
        BrandDiscovery.registrableDomain(of: url.host() ?? url.absoluteString)
    }

    // MARK: - Storage

    private func write<T: Encodable>(_ list: [T], key: String) {
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
        revision += 1
    }

    /// One element at a time, so an entry a later build wrote in a shape this one cannot read
    /// costs that entry and not the whole queue.
    private static func read<T: Decodable>(_ key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([Lenient<T>].self, from: data)
        else { return [] }
        return raw.compactMap(\.value)
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}
