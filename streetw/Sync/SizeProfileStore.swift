// SizeProfileStore.swift
// Persistence for the user's sizes. UserDefaults rather than SwiftData — it's a single
// small value, and keeping it out of the schema avoids a migration for a settings blob.

import Foundation
import StreetwCore
import SwiftUI

@MainActor
@Observable
final class SizeProfileStore {
    private static let key = "sizeProfile"

    var profile: SizeProfile {
        didSet { save() }
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(SizeProfile.self, from: data) {
            profile = decoded
        } else {
            profile = SizeProfile()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func toggleApparel(_ size: String) {
        if profile.apparel.contains(size) {
            profile.apparel.remove(size)
        } else {
            profile.apparel.insert(size)
        }
    }

    func toggleShoe(_ size: String) {
        if profile.shoe.contains(size) {
            profile.shoe.remove(size)
        } else {
            profile.shoe.insert(size)
        }
    }

    /// Display preference only — stored sizes stay canonically US, so switching scales
    /// never rewrites the profile or needs re-sending to the server.
    func setShoeScale(_ scale: SizeScale) {
        profile.shoeScale = scale
    }

    func setGender(_ gender: GenderPreference) {
        profile.gender = gender
    }
}
