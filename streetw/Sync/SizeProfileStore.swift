// SizeProfileStore.swift
// Persistence for the user's sizes. UserDefaults rather than SwiftData — it's a single
// small value, and keeping it out of the schema avoids a migration for a settings blob.

import Foundation
import StreetwCore
import SwiftUI

@MainActor
@Observable
final class SizeProfileStore {
    /// Whose sizes: the holder's under the key 1.0 wrote, a profile's under its own. See
    /// `ProfileScope.key`.
    private let key: String

    var profile: SizeProfile {
        didSet { save() }
    }

    init(scope: ProfileScope = .holder) {
        key = scope.key("sizeProfile")
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SizeProfile.self, from: data) {
            profile = decoded
        } else {
            profile = SizeProfile()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func toggleApparel(_ size: String) {
        if profile.apparel.contains(size) {
            profile.apparel.remove(size)
        } else {
            profile.apparel.insert(size)
        }
    }

    func toggleWaist(_ size: String) {
        if profile.waist.contains(size) {
            profile.waist.remove(size)
        } else {
            profile.waist.insert(size)
        }
    }

    func toggleShoe(_ size: String) {
        if profile.shoe.contains(size) {
            profile.shoe.remove(size)
        } else {
            profile.shoe.insert(size)
        }
    }

    func toggleDress(_ size: String) {
        if profile.dress.contains(size) {
            profile.dress.remove(size)
        } else {
            profile.dress.insert(size)
        }
    }

    func toggleSuit(_ chest: String) {
        if profile.suit.contains(chest) {
            profile.suit.remove(chest)
        } else {
            profile.suit.insert(chest)
        }
    }

    func toggleSuitLength(_ length: String) {
        if profile.suitLength.contains(length) {
            profile.suitLength.remove(length)
        } else {
            profile.suitLength.insert(length)
        }
    }

    /// Display preference only — stored sizes stay canonically US, so switching scales
    /// never rewrites the profile or needs re-sending to the server.
    func setShoeScale(_ scale: SizeScale) {
        profile.shoeScale = scale
    }

    /// Display only, like the shoe scale: the ladder is stored in US whatever it is read in.
    func setDressScale(_ scale: SizeScale) {
        profile.dressScale = scale
    }

    /// Display only: the ladder is stored as chest inches whatever it is read in.
    func setSuitScale(_ scale: SizeScale) {
        profile.suitScale = scale
    }

    func setGender(_ gender: GenderPreference) {
        profile.gender = gender
    }
}
