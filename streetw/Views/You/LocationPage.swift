// LocationPage.swift
// Choosing the country somebody shops in, pushed from You › Location.
//
// Every country a phone can name, not only the ones a brand has a shop in: which those are
// changes brand by brand and month by month, and a list that offered only them would be the
// app's rollout plan dressed as a setting. The section above says what the choice changes,
// and a country no brand runs a shop for is simply the main shop everywhere — the same
// answer as before the setting existed.
//
// Set as type like every page here — paper, serif, mono, rules — not a stock `List`.

import StreetwCore
import SwiftUI

struct LocationPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationSetting.self) private var location: LocationSetting
    @Environment(RemoteSync.self) private var remote: RemoteSync

    @State private var query = ""

    var body: some View {
        let matches = Self.matching(query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // The phone's own region first, so going back to following the phone is one
                // tap rather than a search for your own country.
                if query.isEmpty, let phone = LocationSetting.phoneRegion {
                    row(code: phone, note: "THIS PHONE'S REGION", isChosen: location.followsPhone)
                        .padding(.bottom, 24)
                }
                ForEach(matches, id: \.code) { country in
                    row(code: country.code, note: nil, isChosen: !location.followsPhone && location.country == country.code)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle("Location")
        .toolbarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Country")
    }

    private func row(code: String, note: String?, isChosen: Bool) -> some View {
        Button {
            choose(code)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(LocationSetting.name(of: code))
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                if let note { DataLabel(text: note, size: 9) }
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rule() }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func choose(_ code: String) {
        let before = location.country
        location.choose(code)
        if location.country != before {
            // The server decides which shop each brand's feed comes from, so it has to hear
            // this — and the follow list comes back with each brand's shop re-chosen.
            Task { await remote.pushCountry() }
        }
        dismiss()
    }

    /// By name, in the reader's language, or by code — "gb" finds the United Kingdom.
    private static func matching(_ query: String) -> [(code: String, name: String)] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return LocationSetting.countries }
        return LocationSetting.countries.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.code.caseInsensitiveCompare(needle) == .orderedSame
        }
    }
}
