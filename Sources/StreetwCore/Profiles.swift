// Profiles.swift
// The few things about profiles that both ends must agree on.
//
// A profile is a person on somebody's account — one server user each — and the rules about
// them are mostly the server's and the app's own. What lives here is what would silently stop
// matching if each end kept its own copy: the header that says which profile a request acts
// for, the reason a refusal is recognised by, how a name is cleaned, and how an alert for
// somebody else is labelled. The server labels its pushes and the app labels its local alerts
// with the same function, so "For Anna: …" cannot read two ways on one lock screen. See
// `docs/profiles.md`.

import Foundation

public enum Profiles {
    /// How many profiles one account may hold, the holder's own included. Every one is
    /// another recipient the notifier fans out over and another name printed on alerts, so
    /// the bound is part of the design rather than a guard against abuse alone.
    public static let maxPerAccount = 6
}

/// Which profile a request acts for.
///
/// Absent, a request acts for the device's own user — which is every request an older client
/// makes, every request from a device with no account, and every request the holder's profile
/// makes. Present, it must name a user on the device's account.
public enum ProfileHeader {
    public static let name = "X-Profile-ID"

    /// The reason the server gives when the header names a profile the device may not act
    /// for. The app falls back to the holder on exactly this, and not on any other 403: an
    /// edge or a firewall says 403 too, and abandoning a profile on one of those would be the
    /// wrong repair for a problem that has nothing to do with profiles.
    public static let refusal = "That profile is not on this device's account."
}

/// A profile as its account sees it.
public struct ProfileDTO: Codable, Sendable, Hashable, Identifiable {
    /// The profile's server user id — what `ProfileHeader` carries.
    public var id: UUID
    /// Nil for the holder until they name themselves; the app says "You". Every other profile
    /// has one, because it is printed on that profile's alerts.
    public var name: String?
    /// The account's own profile: the first user, the one sign-in made, and the one that
    /// cannot be deleted without deleting the account.
    public var isHolder: Bool
    public var alertsEnabled: Bool
    public var createdAt: Date?

    public init(id: UUID, name: String?, isHolder: Bool, alertsEnabled: Bool, createdAt: Date?) {
        self.id = id
        self.name = name
        self.isHolder = isHolder
        self.alertsEnabled = alertsEnabled
        self.createdAt = createdAt
    }
}

/// `POST /v1/account/profiles` — a name and nothing else. Sizes, follows and alerts are set
/// from inside the profile, the same way the holder's were.
public struct CreateProfile: Codable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// `PATCH /v1/account/profiles/:id`. Only what was sent changes.
public struct UpdateProfile: Codable, Sendable {
    public var name: String?
    public var alertsEnabled: Bool?

    public init(name: String? = nil, alertsEnabled: Bool? = nil) {
        self.name = name
        self.alertsEnabled = alertsEnabled
    }
}

public enum ProfileNaming {
    /// Long enough for a first name and an initial, short enough that "For …:" leaves most
    /// of a lock-screen line for what actually happened.
    public static let maxLength = 24

    /// A name fit to store and print, or nil when nothing is left.
    ///
    /// Runs of whitespace — newlines included — collapse to one space, because a name is
    /// printed inline at the start of an alert and a pasted line break would push the news
    /// onto a line the lock screen cuts off. Truncated rather than refused: refusing would be
    /// a form error about a field with an obvious fix.
    public static func clean(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        guard joined.count > maxLength else { return joined }
        return String(joined.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }
}

public enum ProfileAlert {
    /// "For Anna: Back in M — Nathan Cargo Pant".
    ///
    /// On the body, not the title: the title is the brand, and a lock screen of several
    /// profiles' alerts should still read brand by brand. Only ever applied to a profile that
    /// is not the holder's — the holder's alerts read exactly as they did before profiles.
    public static func labelled(_ body: String, for name: String) -> String {
        "For \(name): \(body)"
    }
}
