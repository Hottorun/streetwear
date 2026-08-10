// AddBrandView.swift
// Type a website, let discovery work out what's watchable, then save.

import StreetwCore
import SwiftData
import SwiftUI

struct AddBrandView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    @State private var name = ""
    @State private var website = ""
    @State private var instagram = ""
    @State private var styleDescription = ""

    @State private var discovery: DiscoveredSources?
    @State private var probed: BrandProbe?
    @State private var isDiscovering = false
    @State private var didProbe = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Brand") {
                    TextField("Website", text: $website)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(probe)

                    TextField("Name", text: $name)

                    TextField("Instagram handle", text: $instagram)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Style, in your words", text: $styleDescription, axis: .vertical)
                } footer: {
                    Text("e.g. \"graphic, colourful streetwear\"")
                }

                Section("What we can watch") {
                    if isDiscovering {
                        HStack {
                            ProgressView()
                            Text("Checking the site…").foregroundStyle(.secondary)
                        }
                    } else if let probed {
                        if probed.sources.isEmpty {
                            Text("Nothing automatic found. You can still add it and open it manually.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(probed.sources) { source in
                                ProbeSourceRow(source: source)
                            }
                        }
                    } else if let discovery {
                        if discovery.sources.isEmpty {
                            Text("Nothing automatic found. You can still add it and open it manually.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(discovery.sources) { source in
                                SourceRow(source: source)
                            }
                        }
                    } else {
                        Button("Check site", systemImage: "magnifyingglass", action: probe)
                            .disabled(website.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    Label(
                        "Instagram is saved as a link, not scraped — its terms don't allow aggregating profiles, and unofficial endpoints break constantly.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add brand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!canSave)
                }
            }
        }
    }

    private func probe() {
        guard !isDiscovering else { return }
        isDiscovering = true

        Task {
            // With a server, it does the probing — the phone must not fetch storefronts
            // directly or it sidesteps the shared politeness budget.
            if settings.isConfigured {
                let result = try? await remote.probe(url: website)
                await MainActor.run {
                    probed = result
                    if name.isEmpty, let suggested = result?.suggestedName { name = suggested }
                    isDiscovering = false
                    didProbe = true
                }
            } else {
                let found = await BrandDiscovery.discover(website: website, instagramHandle: instagram)
                await MainActor.run {
                    discovery = found
                    if name.isEmpty, let suggested = found.suggestedName { name = suggested }
                    isDiscovering = false
                    didProbe = true
                }
            }
        }
    }

    private func add() {
        // With a server, the brand is created there and watched centrally; the local
        // store is then filled by the next sync rather than by this device polling.
        if settings.isConfigured {
            let website = self.website
            let typed = name.trimmingCharacters(in: .whitespaces)
            let handle = instagram
            let profile = sizes.profile
            Task {
                _ = try? await remote.addBrand(
                    url: website,
                    name: typed.isEmpty ? nil : typed,
                    instagram: handle.isEmpty ? nil : handle,
                    sizes: profile
                )
                await remote.sync(sizes: profile)
            }
            dismiss()
            return
        }

        let typed = name.trimmingCharacters(in: .whitespaces)
        let brand = Brand(
            name: typed,
            websiteURL: BrandDiscovery.normalizedURL(website),
            instagramHandle: BrandDiscovery.normalizedHandle(instagram),
            styleDescription: styleDescription.isEmpty ? nil : styleDescription
        )
        brand.sources = discovery?.sources ?? []
        // Only let the first sync overwrite the name if the user kept our guess.
        brand.usesGeneratedName = (typed == discovery?.suggestedName)
        context.insert(brand)
        try? context.save()

        // First sync establishes the baseline so the feed isn't flooded on day one.
        Task { await engine.sync(brands: [brand]) }
        dismiss()
    }
}

/// Same row, for sources the *server* reported.
struct ProbeSourceRow: View {
    let source: BrandProbe.Source

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.symbol)
                .frame(width: 22)
                .foregroundStyle(source.isAutomatic ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.label).font(.subheadline)
                Text(source.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !source.isAutomatic {
                Text("Link only").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SourceRow: View {
    let source: BrandSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.symbol)
                .frame(width: 22)
                .foregroundStyle(source.kind.isAutomatic ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.kind.label).font(.subheadline)
                Text(source.url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !source.kind.isAutomatic {
                Text("Link only").font(.caption2).foregroundStyle(.secondary)
            }
            if let error = source.lastError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
    }
}

#Preview {
    AddBrandView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}
