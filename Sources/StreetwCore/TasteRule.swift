// TasteRule.swift
// Which saves the app may learn somebody's taste from, and how loudly each one speaks.
//
// Everything that infers taste reads the collection — the reading on the Style tab, the
// brand recommendations, the Discover ranking, the fit suggestions — and until this rule
// existed each of them read *all* of it. That is wrong in two ordinary ways. A board of
// things kept for somebody else ("for my partner", "gift ideas") is not a statement about the
// person keeping it, and taught every one of those engines the wrong thing for as long as it
// existed; and a person is not one taste — "suits" and "streetwear" are the same wardrobe in
// two moods, and the only way to ask for the other one was to save enough of it that the
// arithmetic noticed.
//
// So a board says how it counts (`TasteMode`), a save can opt out on its own, and this file
// is the **one** place that turns those settings into an answer. It is in `StreetwCore` and
// pure, rather than in the app beside the models it reads, for two reasons: it is the part
// with an opinion in it and the only part testable without a store, and every consumer must
// get the same answer about the same save — a reading on one tab built from a different set
// than the ranking on the next is exactly the drift that makes a count look broken.

import Foundation

/// How a board's saves count towards the wearer's taste.
///
/// Stored on the board as its raw value, and read back leniently: a mode this build does not
/// know is `.counts`, which is what every board was before modes existed.
public enum TasteMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// The default. A board is a filter over the collection and says nothing about taste
    /// either way, so its saves count exactly as they would if it did not exist.
    case counts
    /// "Doesn't count." What is on it is not the wearer's taste — kept for somebody else, or
    /// for a reason that has nothing to do with liking it.
    case ignored
    /// "Inspire me from this." The board is the mood: while it is set, everything that ranks
    /// by taste leans towards what is on it.
    case mood
}

public enum TasteRule {
    /// What one save is to the taste engines.
    public enum Role: Sendable, Equatable {
        /// Left out of every reading of taste.
        case ignored
        /// Counts, at ordinary weight.
        case counts
        /// On the mood board: counts, and is leant towards.
        case mood
    }

    /// **The rule.** Every consumer that asks whether a save says something about the wearer
    /// asks this, through the app's `TasteScope`.
    ///
    /// - Parameters:
    ///   - isExcluded: the save's own "don't use for my taste".
    ///   - boards: the modes of the boards it is filed on. `.counts` boards may be left out by
    ///     the caller — they change nothing — which is what lets the app build this from the
    ///     handful of boards that have a setting rather than by walking every save's boards.
    ///
    /// Three precedences, and each is a decision:
    ///
    /// - **The save's own exclusion beats everything.** It is the most specific statement
    ///   anybody can make about one garment, and a board setting is a statement about a group.
    /// - **The mood beats a board that doesn't count.** A save that is on "for my partner" *and*
    ///   on the board somebody has just asked to be inspired by was put on the second one on
    ///   purpose, and that is the current intent.
    /// - **A board that doesn't count beats the default.** `.counts` is not a statement at all —
    ///   it is what every board is until somebody says otherwise — so it cannot outvote one.
    public static func role(isExcluded: Bool, boards: Set<TasteMode>) -> Role {
        if isExcluded { return .ignored }
        if boards.contains(.mood) { return .mood }
        if boards.contains(.ignored) { return .ignored }
        return .counts
    }

    /// How much each save weighs in a taste vector, parallel to `roles`.
    ///
    /// An ignored save weighs nothing and an ordinary one weighs one. **The mood carries at
    /// least half of the whole**, however small the board is beside the rest: each mood save
    /// weighs `max(1, ordinary / mood)`, so the board together weighs as much as everything
    /// else together. A plain multiplier would not survive real collections — six suits on a
    /// board against two hundred streetwear saves is a rounding error at three times the
    /// weight, which is a mood that does nothing. And it is a lean rather than a replacement:
    /// the rest of the collection is still half the vector, because "in the mood for suits" is
    /// still the same person.
    public static func weights(_ roles: [Role]) -> [Double] {
        let ordinary = roles.count { $0 == .counts }
        let mood = roles.count { $0 == .mood }
        let moodWeight = mood == 0 ? 0 : max(1, Double(ordinary) / Double(mood))
        return roles.map { role in
            switch role {
            case .ignored: 0
            case .counts: 1
            case .mood: moodWeight
            }
        }
    }
}
