// StyleView.swift
// Your style profile, derived from what you've saved.

import StreetwCore
import SwiftData
import SwiftUI

struct StyleView: View {
    @Query private var saves: [SavedItem]

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
        }
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
