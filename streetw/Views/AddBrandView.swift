// AddBrandView.swift
// Finding a brand, in one field.
//
// The old flow was a form: website, name, Instagram handle, a free-text style note, and a
// "check site" button you had to know to press. Every field was asked of every user, and
// almost all of it was work the server had already done for somebody else — the catalog is
// **global**, so the second person to add Kith should not be filling in a form about Kith.
//
// So: one search box that takes a name *or* a pasted link, matched against the shared
// catalog first. A hit is one tap to follow, with the sources already known. A miss falls
// through to the only case that genuinely needs input — a brand nobody has added yet —
// where we probe the site and ask for a name if the site doesn't announce one.

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
    @Environment(BrandSuggestions.self) private var suggestions: BrandSuggestions

    @Query private var followed: [Brand]

    @State private var query = ""
    @State private var results: [BrandDTO] = []
    @State private var isSearching = false
    @State private var searchError: String?
    /// The brand currently being followed, so its row can show progress rather than the
    /// whole list going blank.
    @State private var pending: UUID?

    /// Set once a search has come back empty and the query looks like a site we could
    /// actually probe. This is the "nobody has added this yet" path.
    @State private var newBrand: NewBrandDraft?

    var body: some View {
        NavigationStack {
            Group {
                if let newBrand {
                    NewBrandView(draft: newBrand) { dismiss() }
                } else {
                    searchResults
                }
            }
            .background(Color.paper)
            .navigationTitle("Add a brand")
            .toolbarTitleDisplayMode(.inlineLarge)
            // An icon in the trailing slot, not a titled `.cancellationAction`.
            //
            // With a search field in the bar, iOS has nowhere to put a leading text button
            // and folds it into an overflow menu — so the screen shipped with a "···" whose
            // entire contents was one item called Cancel. A menu wrapping a single action
            // is worse than the action, and this is a sheet: the gesture to leave is a
            // swipe, and the control is a close button.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if newBrand == nil {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    } else {
                        Button("Back", systemImage: "chevron.left") { newBrand = nil }
                    }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Brand name or website"
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) { Task { await search() } }
            // Keyed on the token, not fired bare: `/v1/brands/popular` is authenticated,
            // a `.task` runs once per appearance, and a 401 swallowed by `try?` would
            // leave this screen looking exactly as empty as it did before.
            .task(id: settings.token) { await suggestions.loadIfNeeded() }
            // Debounced rather than per-keystroke: this hits the network, and a search
            // that fires on every letter of "aimeleondore" is twelve requests for one
            // answer.
            .task(id: query) {
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                await search()
            }
        }
        .tint(.ink)
    }

    // MARK: - Results

    @ViewBuilder
    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isSearching && results.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        DataLabel(text: "SEARCHING")
                    }
                    .padding(20)
                } else if let searchError {
                    EditorialEmptyState(title: "Couldn't search", action: searchError.uppercased())
                        .frame(minHeight: 220)
                } else if results.isEmpty && !trimmed.isEmpty {
                    notFound
                } else if results.isEmpty {
                    // Not a blank page with a blank field on it.
                    //
                    // This screen opened onto an empty state and an empty search box, and
                    // then waited — which asks somebody to already know the name of a brand
                    // they have come here to find. The catalog is global and
                    // `/v1/brands/popular` is already loaded elsewhere in the app, so the
                    // obvious thing to put here is what other people watch. Typing replaces
                    // it the moment there is anything to replace it with.
                    startingPoints
                } else {
                    ForEach(results) { dto in
                        resultRow(dto)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    /// What to show before anything has been typed.
    @ViewBuilder
    private var startingPoints: some View {
        let unfollowed = suggestions.brands.filter { item in
            guard let id = item.brand.id else { return false }
            return !followed.contains { $0.remoteID == id }
        }

        if unfollowed.isEmpty {
            EditorialEmptyState(
                title: "Search for a brand",
                action: "TYPE A NAME, OR PASTE A LINK TO ITS SITE"
            )
            .frame(minHeight: 260)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or start here")
                        .font(.editorial(19))
                        .foregroundStyle(Color.ink)
                    DataLabel(text: "ALREADY IN THE CATALOG · TYPE TO SEARCH IT ALL")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)

                ForEach(unfollowed) { item in
                    resultRow(item.brand)
                }
            }
        }
    }

    private func resultRow(_ dto: BrandDTO) -> some View {
        let alreadyFollowed = dto.id.map { id in followed.contains { $0.remoteID == id } } ?? false

        return HStack(spacing: 14) {
            BrandMonogram(name: dto.name, logoURL: dto.logoURL.flatMap(URL.init(string:)))

            VStack(alignment: .leading, spacing: 5) {
                Wordmark(name: dto.name, size: 14)
                DataLabel(text: dto.slug.uppercased(), size: 10)
            }

            Spacer(minLength: 8)

            if pending == dto.id {
                ProgressView()
            } else if alreadyFollowed {
                DataLabel(text: "FOLLOWING", size: 10)
            } else {
                Button("Follow") { Task { await follow(dto) } }
                    .font(.data(11, .semibold))
                    .foregroundStyle(Color.paper)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.ink)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
    }

    /// Nothing in the catalog. Offer to add it only when the query could plausibly be a
    /// site — searching "hoodie" should not invite you to create a brand called hoodie.
    @ViewBuilder
    private var notFound: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Says what was actually searched. The first version read "Nobody's watching
            // X yet", which describes *follows* — but this searches the catalog, so it
            // claimed something it hadn't checked and read as a bug whenever the real
            // cause was that the search never ran.
            Text("No brand called “\(trimmed)” in the catalog yet.")
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            if looksLikeSite {
                Text("Add it and streetw will work out what its site publishes — the catalog, a feed, or the page itself.")
                    .font(.editorial(14))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    newBrand = NewBrandDraft(url: trimmed)
                } label: {
                    Text("CHECK THIS SITE")
                        .font(.data(12, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.ink)
                }
                .buttonStyle(.borderless)
            } else {
                Text("Paste a link to the brand's website and streetw can add it.")
                    .font(.editorial(14))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A dot and no spaces. Deliberately loose — `BrandDiscovery.normalizedURL` is the
    /// real arbiter and it runs on the next screen.
    private var looksLikeSite: Bool {
        trimmed.contains(".") && !trimmed.contains(" ")
    }

    // MARK: - Actions

    private func search() async {
        let term = trimmed
        guard !term.isEmpty else { return }
        // Without a server there is no shared catalog to search. Reported rather than
        // silently returning nothing: an empty result is indistinguishable from "we
        // looked and it isn't there", which is how a connection problem ends up reading
        // as a missing brand.
        guard settings.isConfigured else {
            results = []
            searchError = "Not connected to the streetw catalog."
            return
        }

        isSearching = true
        searchError = nil
        defer { isSearching = false }

        do {
            let found = try await remote.searchBrands(term)
            guard term == trimmed else { return } // a newer keystroke won
            results = found
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func follow(_ dto: BrandDTO) async {
        pending = dto.id
        defer { pending = nil }
        do {
            try await remote.followExisting(dto, sizes: sizes.profile)
            await remote.sync(sizes: sizes.profile)
            dismiss()
        } catch {
            searchError = error.localizedDescription
        }
    }
}

/// The one case that still needs input: a site nobody has added.
struct NewBrandDraft: Identifiable, Hashable {
    var url: String
    var id: String { url }
}

/// Probe the site, show what can be watched, confirm the name.
///
/// Only ever reached when the catalog had no match, which makes it the rare path rather
/// than the default one — and it asks for exactly one thing the machine can't determine:
/// what the brand is called, when its own site doesn't say.
struct NewBrandView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let draft: NewBrandDraft
    let onDone: () -> Void

    @State private var name = ""
    @State private var instagram = ""
    @State private var probed: BrandProbe?
    @State private var discovered: DiscoveredSources?
    @State private var isProbing = true
    @State private var isSaving = false
    @State private var failure: String?

    private var watchable: [(label: String, url: String, isAutomatic: Bool)] {
        if let probed {
            return probed.sources.map { ($0.label, $0.url, $0.isAutomatic) }
        }
        if let discovered {
            return discovered.sources.map { ($0.kind.label, $0.url.absoluteString, $0.kind.isAutomatic) }
        }
        return []
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isProbing
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    DataLabel(text: "SITE")
                    Text(draft.url)
                        .font(.data(13))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if isProbing {
                    HStack(spacing: 10) {
                        ProgressView()
                        DataLabel(text: "CHECKING WHAT THIS SITE PUBLISHES")
                    }
                } else {
                    watchableSection
                }

                VStack(alignment: .leading, spacing: 8) {
                    DataLabel(text: "NAME")
                    TextField("What the brand is called", text: $name)
                        .font(.editorial(17))
                        .foregroundStyle(Color.ink)
                    Rule()
                }

                VStack(alignment: .leading, spacing: 8) {
                    DataLabel(text: "INSTAGRAM · OPTIONAL")
                    TextField("@handle", text: $instagram)
                        .font(.editorial(17))
                        .foregroundStyle(Color.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Rule()
                    // Stated because it is a deliberate limitation people ask about, not
                    // an oversight.
                    Text("Saved as a link, never scraped — Instagram's terms don't allow aggregating profiles.")
                        .font(.data(10))
                        .foregroundStyle(Color.muted)
                }

                if let failure {
                    Text(failure)
                        .font(.data(11))
                        .foregroundStyle(Color.signal)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button { Task { await save() } } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(.paper)
                    } else {
                        Text("START WATCHING")
                            .font(.data(12, .semibold))
                            .tracking(1.1)
                    }
                }
                .foregroundStyle(Color.paper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(canSave ? Color.ink : Color.muted)
            }
            .buttonStyle(.borderless)
            .disabled(!canSave || isSaving)
            .padding(20)
        }
        .task { await probe() }
    }

    @ViewBuilder
    private var watchableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "WHAT WE CAN WATCH")
            if watchable.isEmpty {
                Text("Nothing automatic found. You can still add it and open it yourself.")
                    .font(.editorial(14))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(watchable, id: \.url) { source in
                    HStack(spacing: 10) {
                        Text(source.label.uppercased())
                            .font(.data(11, .medium))
                            .foregroundStyle(source.isAutomatic ? Color.ink : Color.muted)
                        Spacer(minLength: 8)
                        if !source.isAutomatic {
                            DataLabel(text: "LINK ONLY", size: 9)
                        }
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rule() }
                }
            }
        }
    }

    private func probe() async {
        isProbing = true
        defer { isProbing = false }

        if settings.isConfigured {
            // The server does the fetching, so the phone never sidesteps the shared
            // politeness budget.
            let result = try? await remote.probe(url: draft.url)
            probed = result
            if name.isEmpty, let suggested = result?.suggestedName { name = suggested }
        } else {
            let found = await BrandDiscovery.discover(website: draft.url, instagramHandle: nil)
            discovered = found
            if name.isEmpty, let suggested = found.suggestedName { name = suggested }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let typed = name.trimmingCharacters(in: .whitespaces)
        let handle = instagram.trimmingCharacters(in: .whitespaces)

        if settings.isConfigured {
            do {
                _ = try await remote.addBrand(
                    url: draft.url,
                    name: typed,
                    instagram: handle.isEmpty ? nil : handle,
                    sizes: sizes.profile
                )
                await remote.sync(sizes: sizes.profile)
                onDone()
            } catch {
                failure = error.localizedDescription
            }
            return
        }

        let brand = Brand(
            name: typed,
            websiteURL: BrandDiscovery.normalizedURL(draft.url),
            instagramHandle: BrandDiscovery.normalizedHandle(handle)
        )
        brand.sources = discovered?.sources ?? []
        brand.logoURLString = discovered?.logoURL?.absoluteString
        // Only let the first sync overwrite the name if the user kept our guess.
        brand.usesGeneratedName = (typed == discovered?.suggestedName)
        context.insert(brand)
        try? context.save()

        // First sync establishes the baseline so the feed isn't flooded on day one.
        await engine.sync(brands: [brand])
        onDone()
    }
}

struct SourceRow: View {
    let source: BrandSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.symbol)
                .frame(width: 22)
                .foregroundStyle(source.kind.isAutomatic ? Color.ink : Color.muted)
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
