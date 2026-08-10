// BrandDetailView.swift
// One brand: links, your rating, recent updates, and what you've saved from it.

import StreetwCore
import SwiftData
import SwiftUI

struct BrandDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    @Bindable var brand: Brand

    private var recent: [BrandUpdate] { brand.recentUpdates(limit: 20) }

    private var savedFromBrand: [BrandUpdate] {
        brand.updates
            .filter { !$0.saves.isEmpty }
            .sorted { ($0.save?.savedAt ?? .distantPast) > ($1.save?.savedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            if brand.isLockedForDrop {
                Section {
                    Label(
                        "The storefront is locked right now — usually a sign a release is close.",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                }
            }

            Section {
                HStack(spacing: 12) {
                    if let url = brand.websiteURL {
                        Link(destination: url) {
                            Label("Website", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                    }
                    if let url = brand.instagramURL {
                        Link(destination: url) {
                            Label("Instagram", systemImage: "camera")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.subheadline)
            }

            Section("My take") {
                TextField("Style, in your words", text: styleBinding, axis: .vertical)
                RatingPicker(rating: $brand.myRating)
                Toggle("Following", isOn: $brand.followed)
                    .onChange(of: brand.followed) { _, following in
                        guard settings.isConfigured, let id = brand.remoteID else { return }
                        Task {
                            // The server decides what gets polled, so following has to
                            // be recorded there, not just flagged locally.
                            if following {
                                try? await remote.follow(brandID: id)
                            } else {
                                await remote.unfollow(brand)
                            }
                        }
                    }
            }

            Section("Recent") {
                if recent.isEmpty {
                    Text(brand.lastSyncedAt == nil ? "Not checked yet." : "Nothing found yet.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    UpdateCarousel(updates: recent)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }

            if !savedFromBrand.isEmpty {
                Section("My favourites") {
                    UpdateCarousel(updates: savedFromBrand, width: 110)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }

            Section("Sources") {
                ForEach(brand.sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        SourceRow(source: source)
                        if let error = source.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            if source.failureCount > 1 {
                                Text("Failed \(source.failureCount)× — backing off before retrying.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let date = brand.lastSyncedAt {
                    LabeledContent("Last checked", value: date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(brand.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if engine.isSyncing || remote.isSyncing {
                    ProgressView()
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                }
            }
        }
        .refreshable { await refresh() }
        .onDisappear {
            brand.lastOpenedAt = Date()
            try? context.save()
        }
    }

    /// In server mode the phone never polls storefronts itself.
    private func refresh() async {
        if settings.isConfigured {
            await remote.sync(sizes: sizes.profile)
        } else {
            await engine.sync(brands: [brand])
        }
    }

    private var styleBinding: Binding<String> {
        Binding(
            get: { brand.styleDescription ?? "" },
            set: { brand.styleDescription = $0.isEmpty ? nil : $0 }
        )
    }
}

struct RatingPicker: View {
    @Binding var rating: Int?

    var body: some View {
        HStack {
            Text("My rating")
            Spacer()
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        rating = (rating == value) ? nil : value
                    } label: {
                        Image(systemName: (rating ?? 0) >= value ? "star.fill" : "star")
                            .foregroundStyle((rating ?? 0) >= value ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
