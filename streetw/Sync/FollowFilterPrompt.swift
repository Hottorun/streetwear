// FollowFilterPrompt.swift
// "What do you want to see from them?" — asked once after every new follow, wherever it was made.
//
// A follow is made from eight places — the add-brand search, a site check, a brand page, a
// Discover card, a Shop result, a recommendation, a saved item's brand, and (from Phase 5)
// the share sheet — and each of them is on a different screen, often a sheet that closes the
// moment the follow lands. So the question is not asked by any of them. Each one calls
// `ask(brandID:)` and the answer is drawn by whichever host is on top (`followFilterHost()`):
// the root, You, the add-brand sheet. A queue rather than a flag, because a share-sheet batch
// can follow three shops at once and each deserves its own question.
//
// **For the share sheet's code:** the extension cannot draw this — it holds no store and the
// filter is set on the server — so the app asks on the next foreground. Call
// `session.followPrompt.ask(brandID:)` (or `@Environment(FollowFilterPrompt.self)`) with the
// brand's server id or its local `Brand.id`, after the follow exists; either resolves. The
// queue is kept in `UserDefaults` per profile, so a question asked just before the app is
// killed is still asked on the next launch, and a brand that has since been unfollowed is
// dropped without a word.
//
// Skipping is always fine, and leaves *All* — which is what a follow was before this existed.
// The starter pack does not ask: a dozen dialogs in a row is not a welcome.

import Foundation
import Observation
import StreetwCore
import SwiftData

@MainActor
@Observable
final class FollowFilterPrompt {
    /// Brands waiting to be asked about, oldest first — local or server ids.
    private(set) var queue: [UUID] {
        didSet { UserDefaults.standard.set(queue.map(\.uuidString), forKey: scope.key(Self.queueKey)) }
    }

    /// Site checks somebody said "watch when ready" to. The follow is made on the server once
    /// the check finishes — with the app closed, as often as not — so the question waits for
    /// the next foreground that finds the check settled (`resolveChecks`).
    private(set) var checks: [UUID] {
        didSet { UserDefaults.standard.set(checks.map(\.uuidString), forKey: scope.key(Self.checksKey)) }
    }

    /// The hosts on screen, in the order they appeared. The last one draws the question,
    /// because a sheet cannot be presented from under another one.
    private(set) var hosts: [UUID] = []

    private let scope: ProfileScope

    static let queueKey = "followFilterPrompts"
    static let checksKey = "followFilterChecks"

    init(scope: ProfileScope) {
        self.scope = scope
        let defaults = UserDefaults.standard
        queue = (defaults.stringArray(forKey: scope.key(Self.queueKey)) ?? []).compactMap(UUID.init(uuidString:))
        checks = (defaults.stringArray(forKey: scope.key(Self.checksKey)) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// The next brand to ask about.
    var head: UUID? { queue.first }

    /// The host that should draw the question now.
    var topHost: UUID? { hosts.last }

    /// Asks what to see from a brand just followed — by its server id or its local id.
    func ask(brandID: UUID) {
        guard !queue.contains(brandID) else { return }
        queue.append(brandID)
    }

    /// Remembers a check whose follow will be made later, on the server.
    func expect(check id: UUID) {
        guard !checks.contains(id) else { return }
        checks.append(id)
    }

    /// The question for this brand has been answered, skipped, or cannot be asked.
    func finish(_ brandID: UUID) {
        queue.removeAll { $0 == brandID }
    }

    /// Asks about every remembered check that has become a follow, and forgets the ones that
    /// never will — refused, or gone. A check the server cannot be asked about now stays.
    func resolveChecks(using remote: RemoteSync) async {
        for id in checks {
            guard let check = try? await remote.check(id: id) else { continue }
            switch check.status {
            case .checking:
                continue
            case .ready where check.isWatching:
                if let brandID = check.brand?.id { ask(brandID: brandID) }
                checks.removeAll { $0 == id }
            default:
                checks.removeAll { $0 == id }
            }
        }
    }

    // MARK: - Hosts

    func enter(_ host: UUID) {
        hosts.removeAll { $0 == host }
        hosts.append(host)
    }

    func leave(_ host: UUID) {
        hosts.removeAll { $0 == host }
    }

    /// The followed brand an id names, local or server — nil once it is not followed here.
    static func brand(_ id: UUID, in context: ModelContext) -> Brand? {
        var descriptor = FetchDescriptor<Brand>(
            predicate: #Predicate { ($0.id == id || $0.remoteID == id) && $0.followed }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
