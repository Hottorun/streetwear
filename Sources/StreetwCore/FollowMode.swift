// FollowMode.swift
// How much of a followed brand reaches somebody — the feed and the alerts, never the watching.

import Foundation

/// What a follow lets through.
///
/// **A follow does two jobs and only one of them is about being told things.** It is what
/// gets watched, and it is a statement of taste: the brands somebody follows are where the
/// recommendations look and where search will shop. Following H&M the way you follow Kith
/// would bury the feed in daily arrivals, so before this the only way to have H&M shape
/// your taste was to put up with it in your feed — or to "mute" it, which was a flag on the
/// phone that the server had never heard of. The push was composed, sent and delivered, and
/// then dropped by the app in the foreground only; in the background iOS showed it anyway.
///
/// So the mode lives on the server, beside the follow, because `Notifier` is what has to
/// know it. The phone mirrors it, and decides the feed with the same predicate.
///
/// Three modes, and the rule between them is one function, `admits`:
///
/// - **Everything** — today's behaviour, and the default for every follow that does not say
///   otherwise. That includes every follow the 1.0 app makes, which has no way to say.
/// - **Sales only** — markdowns, and later a brand-wide sale; nothing else reaches the feed
///   or the lock screen. For the huge catalogue somebody follows to watch prices.
/// - **Quiet** — nothing reaches the feed or the lock screen at all. The brand is still
///   followed: still polled, still on the brand list and its own page, still counted by the
///   recommendations and (later) searched.
///
/// **A stock watch ignores all three.** It is the one alert somebody asked for by name,
/// about one product in one size, and a mode is a statement about the brand's *volume*.
/// Quieting a brand you have a watch on must not swallow the restock you set it for.
public enum FollowMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case everything
    case salesOnly = "sales"
    case quiet

    public var id: String { rawValue }

    /// Lenient, for the reason `BrandCheck.Status` is: a mode a newer server learns must not
    /// fail to decode on an older client and take the whole follow list down with it.
    ///
    /// An unknown mode reads as `.everything` rather than `.quiet`, because the failure this
    /// project cannot afford is a real drop that never reaches anybody. Showing too much from
    /// one brand until the app updates is a nuisance; showing nothing is a broken follow.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FollowMode(rawValue: raw) ?? .everything
    }

    /// Reads a stored or transmitted value the same lenient way the decoder does.
    public init(lenient raw: String?) {
        self = raw.flatMap(FollowMode.init(rawValue:)) ?? .everything
    }

    /// **Whether an event of this kind reaches somebody who follows the brand this way.**
    ///
    /// The one rule, asked by the feed on the phone (in both modes) and by `Notifier` on the
    /// server. It is a *filter*, never a promotion: a push still needs
    /// `Notifier.isWorthWaking` as well, so *Sales only* sends nothing a markdown would not
    /// have sent under *Everything* — today that is nothing, because a markdown is not
    /// sudden. What it changes is that the brand's daily arrivals stop reaching the feed and
    /// the lock screen; what sales are worth a buzz is `UpdateKind`'s question.
    ///
    /// What *Sales only* lets through is `UpdateKind.isSale`, not a list here — so a new
    /// sale kind is one case in one switch and both ends pick it up.
    public func admits(_ kind: UpdateKind) -> Bool {
        switch self {
        case .everything: true
        case .salesOnly: kind.isSale
        case .quiet: false
        }
    }
}
