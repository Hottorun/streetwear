// StyleView.swift
// Your style profile, derived from what you've saved.

import StreetwCore
import SwiftData
import SwiftUI

struct StyleView: View {
    @Query private var saves: [SavedItem]
    @State private var isShowingSettings = false

    private var profile: StyleProfile { StyleProfile.build(from: saves) }

    var body: some View {
        NavigationStack {
            List {
                SizeProfileSection()

                if profile.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No profile yet",
                            systemImage: "chart.pie",
                            description: Text("Save things you like and streetw starts working out your colours, categories and silhouettes.")
                        )
                    }
                } else {
                    Section {
                        Text("Built from \(profile.totalSaves) saved \(profile.totalSaves == 1 ? "item" : "items").")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    FacetSection(title: "Colours", facets: profile.colors)
                    FacetSection(title: "Categories", facets: profile.categories)
                    FacetSection(title: "Silhouettes", facets: profile.silhouettes)
                    FacetSection(title: "Brands", facets: profile.brands)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .navigationTitle("Style")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
            }
            .sheet(isPresented: $isShowingSettings) { SettingsSheet() }
        }
    }
}

/// Plumbing, kept off the Style page itself but not out of reach.
///
/// Both of these were on Style and were removed for being noise on a page about
/// clothes. They still have to exist somewhere: without the alerts row iOS never issues
/// a device token, so the entire push pipeline has nothing to deliver to — the server
/// can be perfectly configured and still be silent.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NotificationsSection()
                ServerSettingsSection()
            }
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.ink)
    }
}

struct FacetSection: View {
    let title: String
    let facets: [StyleFacet]

    var body: some View {
        if !facets.isEmpty {
            Section(title) {
                ForEach(facets.prefix(6)) { facet in
                    FacetRow(facet: facet)
                }
            }
        }
    }
}

struct FacetRow: View {
    let facet: StyleFacet

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(facet.label).font(.subheadline)
                Spacer()
                Text(facet.share.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: facet.share)
                .tint(.accentColor)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    StyleView()
        .modelContainer(PreviewData.container)
}
