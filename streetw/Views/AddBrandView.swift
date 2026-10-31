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

    /// What to put in the field when this is opened from somewhere that already knows what
    /// is being looked for — a saved link whose brand nobody follows, above all. Arriving at
    /// an empty search box having just tapped a name is being asked to type it out again.
    var prefill: String = ""

    @State private var query = ""
    @State private var results: [BrandDTO] = []
    @State private var isSearching = false
    @State private var searchError: String?
    /// A follow that failed, shown inline under the row it failed on. Separate from
    /// `searchError` because that one is a page state and this one must not be.
    @State private var followError: String?
    /// Which row the follow failed on, so the line appears under that one and not the list.
    @State private var failedToFollow: UUID?
    /// The brand currently being followed, so its row can show progress rather than the
    /// whole list going blank.
    @State private var pending: UUID?

    /// Set once a search has come back empty and the query looks like a site we could
    /// actually probe. This is the "nobody has added this yet" path.
    @State private var newBrand: NewBrandDraft?

    /// A brand this screen has just followed, being asked what to see from it — drawn here,
    /// pushed over the search, rather than by `FollowFilterPrompt` from under a closing sheet.
    @State private var askingAbout: Brand?

    var body: some View {
        NavigationStack {
            Group {
                if let newBrand {
                    NewBrandView(draft: newBrand) { brand in
                        if let brand { askingAbout = brand } else { dismiss() }
                    }
                } else {
                    searchResults
                }
            }
            .navigationDestination(item: $askingAbout) { brand in
                FollowFilterView(brand: brand, isNewFollow: true) { dismiss() }
                    .navigationBarBackButtonHidden()
                    .toolbar(.hidden, for: .navigationBar)
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
            // Seeded once, on appearance rather than in an initialiser, so `@State` still
            // owns the field afterwards — clearing it must not have the prefill reappear.
            // The debounced search below picks it up as though it had been typed.
            .onAppear { if query.isEmpty { query = prefill } }
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
                        NoteLine(text: "Searching…")
                    }
                    .padding(20)
                } else if let searchError {
                    EditorialEmptyState(title: "Couldn't search", action: searchError)
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
                        // Under the row it happened to, so it reads as "that one didn't
                        // work" rather than as the screen having failed. Only on the row in
                        // question — `pending` is nil again by the time this draws, so the
                        // id is compared against the one the failure was recorded for.
                        if let followError, failedToFollow == dto.id {
                            NoteLine(text: followError, color: .signal)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 14)
                        }
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
                    NoteLine(text: "Already in the catalogue.")
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
                DataLabel(text: dto.slug, size: 11)
            }

            Spacer(minLength: 8)

            if pending == dto.id {
                ProgressView()
            } else if alreadyFollowed {
                NoteLine(text: "Following", size: 15)
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
            Text("No brand called “\(trimmed)” in the catalogue yet.")
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            if looksLikeSite {
                Button {
                    newBrand = NewBrandDraft(url: trimmed)
                } label: {
                    Text("Check this site")
                        .font(.data(12, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.ink)
                }
                .buttonStyle(.borderless)
            } else {
                NoteLine(text: "Paste its website to add it.", size: 16)
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
            searchError = "Not connected to the Dropwall catalogue."
            return
        }

        isSearching = true
        searchError = nil
        defer { isSearching = false }

        do {
            let found = try await remote.searchBrands(term)
            guard term == trimmed else { return } // a newer keystroke won
            results = found
            // Counted once the answer is on screen, so a keystroke overtaken by the next one
            // is not a search anybody ran.
            UsageCounts.record(.brandSearch)
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func follow(_ dto: BrandDTO) async {
        pending = dto.id
        followError = nil
        failedToFollow = nil
        defer { pending = nil }
        do {
            try await remote.followExisting(dto, sizes: sizes.profile, asks: false)
            await remote.sync(sizes: sizes.profile)
            if let id = dto.id, let brand = FollowFilterPrompt.brand(id, in: context) {
                askingAbout = brand
            } else {
                dismiss()
            }
        } catch {
            // **Not `searchError`.** That one is rendered as a full-page "Couldn't search"
            // state, so a failed *follow* replaced the results list the person was looking
            // at — the search they had just run vanished, and the only way back was to type
            // it again. A follow that fails should leave the screen exactly as it was and
            // say so on the row it happened to.
            followError = error.localizedDescription
            failedToFollow = dto.id
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
    @Environment(FollowFilterPrompt.self) private var prompt: FollowFilterPrompt

    let draft: NewBrandDraft
    /// Finished: with the brand now followed, so the add-brand sheet can ask what to see from
    /// it, or nil when there is none yet — a watch the server keeps until its check settles.
    let onDone: (Brand?) -> Void

    @State private var instagram = ""
    /// The server's look at this site — see `BrandCheck`. Started on appearance and asked
    /// again until it settles, because a site that is not on Shopify can take longer to read
    /// than one request is allowed to wait.
    @State private var check: BrandCheck?
    @State private var discovered: DiscoveredSources?
    /// Standalone's answer to why a site cannot be watched; the server's is `check.refusal`.
    @State private var localRefusal: BrandCheck.Refusal?
    @State private var isProbing = true
    @State private var isSaving = false
    @State private var failure: String?

    /// Why the probe did not come back, when it did not.
    ///
    /// **A failed lookup has to say which failure it was.** `probed = try? await …` collapsed
    /// a 401, a timeout and a server mid-deploy into the same nil the server returns for a
    /// site that genuinely publishes nothing — and the screen then printed "Dropwall couldn't
    /// read anything from this site… It may be down, or blocking us" with START WATCHING
    /// disabled. Three sentences about a shop, none of them about the shop. `search()` two
    /// screens back already gets this right, which is where the shape came from.
    @State private var probeError: String?

    private var probed: BrandProbe? { check?.probe }

    private var isChecking: Bool { isProbing || check?.status == .checking }

    /// START WATCHING was pressed while the server was still looking. The server keeps the
    /// request with this screen closed, so all that is left here is to say so.
    private var isQueued: Bool { check?.status == .checking && check?.isWatching == true }

    private var watchable: [(label: String, url: String, isAutomatic: Bool)] {
        if let probed {
            return probed.sources.map { ($0.label, $0.url, $0.isAutomatic) }
        }
        if let discovered {
            return discovered.sources.map { ($0.kind.label, $0.url.absoluteString, $0.kind.isAutomatic) }
        }
        return []
    }

    /// Whether there is anything here to watch at all — see `DiscoveredSources.canMonitor`.
    ///
    /// A page watch counts. It says only "something changed", and that is worth having: on
    /// Supreme it reached its follower before the brand's own drop email. What this refuses
    /// is a site nothing could read — no catalogue, no feed, no sitemap and no page.
    private var canMonitor: Bool {
        if let probed { return probed.canMonitor }
        if let discovered { return discovered.canMonitor }
        return false
    }

    /// Pressable while the server is still looking: it then means "watch it as soon as you
    /// know you can", which is the one thing worth doing with a minute to wait.
    private var canSave: Bool {
        if let check, check.status == .checking { return true }
        return !isChecking && canMonitor
    }

    /// What this brand will be called, read off its own site.
    ///
    /// **Shown rather than asked.** The catalogue is global: whatever the first person to
    /// add a shop typed became its name for everybody who ever followed it, with no review
    /// step and no second person to correct it — a typo was permanent and anything worse was
    /// vandalism costing one tap. So the server now takes the name from the storefront's own
    /// `/meta.json`, `og:site_name` or `<title>` and ignores what the client sends. A text
    /// field here would be a control that quietly does nothing, which is worse than no
    /// control at all.
    private var declaredName: String {
        probed?.suggestedName
            ?? discovered?.suggestedName
            ?? BrandDiscovery.normalizedURL(draft.url)?.host()
            ?? draft.url
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

                if isChecking {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView()
                            NoteLine(text: "Checking the site…", size: 16, color: .ink)
                        }
                        // A shop off Shopify can take minutes, and nobody has to watch it.
                        NoteLine(text: isQueued
                            ? "Dropwall starts watching when it's done, and tells you."
                            : "This can take a few minutes. You don't have to wait.")
                    }
                } else if let probeError {
                    couldNotCheck(probeError)
                } else if canMonitor {
                    watchableSection
                } else {
                    cannotMonitor
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 2) {
                        DataLabel(text: "NAME")
                        InfoButton(note: Self.nameInfo)
                    }
                    Text(isChecking ? "…" : declaredName)
                        .font(.editorial(17))
                        .foregroundStyle(Color.ink)
                    Rule()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 2) {
                        DataLabel(text: "INSTAGRAM")
                        InfoButton(note: Self.instagramInfo)
                    }
                    TextField("@handle, if it has one", text: $instagram)
                        .font(.editorial(17))
                        .foregroundStyle(Color.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Rule()
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
            Button {
                if isQueued { onDone(nil) } else { Task { await save() } }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(.paper)
                    } else {
                        Text(isQueued ? "Done" : check?.status == .checking ? "Watch when ready" : "Start watching")
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
                NoteLine(text: "Nothing automatic — a link you open yourself.", color: .ink)
            } else {
                ForEach(watchable, id: \.url) { source in
                    HStack(spacing: 10) {
                        Text(source.label)
                            .font(.data(11, .medium))
                            .foregroundStyle(source.isAutomatic ? Color.ink : Color.muted)
                        Spacer(minLength: 8)
                        if !source.isAutomatic {
                            NoteLine(text: "Link only", size: 13)
                        }
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rule() }
                }
            }
        }
    }

    /// The refusal, said plainly and with the reason.
    ///
    /// Not an error — nothing went wrong and there is nothing to retry. The site simply does
    /// not publish anything a machine can read, which is a fact about the shop rather than a
    /// fault in the app, and saying so is more use than a brand page that stays empty
    /// forever without explaining itself.
    ///
    /// **Which refusal it is decides what to say** (`BrandCheck.Refusal`, `ShopRefusal`). A shop
    /// that turns machines away is not "down, or blocking us — try later": it will block us
    /// tomorrow too, and the thing that does work is saving from Safari, whose requests are
    /// the person's own. A brand that sells no clothes online has nothing to follow. Only the
    /// last is worth trying again. A server that predates the reason sends none, which is the
    /// generic copy this screen always printed.
    private var cannotMonitor: some View {
        let name = BrandDiscovery.normalizedURL(draft.url)?.host().flatMap(BrandNaming.hostName(of:))
            ?? declaredName
        return VStack(alignment: .leading, spacing: 10) {
            switch refusal {
            case .blocksReaders:
                Text("\(name) blocks automated readers.")
                    .font(.editorial(19))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Saving from Safari still works.")
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
                HStack(spacing: 14) {
                    NoteLine(text: "Share from Safari › Dropwall")
                    InfoButton(note: Self.blockedInfo, label: "WHY?")
                }
            case .sellsNoClothes:
                Text("\(name) doesn't sell clothes online.")
                    .font(.editorial(19))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                InfoButton(note: Self.noClothesInfo, label: "WHY?")
            case .nothingAnswered:
                Text("Nothing to watch here")
                    .font(.editorial(19))
                    .foregroundStyle(Color.ink)
                HStack(spacing: 14) {
                    NoteLine(text: "Worth trying again later.")
                    InfoButton(note: Self.nothingInfo, label: "WHY?")
                }
            }
        }
    }

    /// Why nothing here can be watched — the server's word, or the phone's own reading of
    /// the requests it made standalone.
    private var refusal: BrandCheck.Refusal {
        check?.refusal ?? localRefusal ?? .nothingAnswered
    }

    /// The other refusal, and the one that is about us rather than about the shop.
    ///
    /// It offers a retry and leaves the site's own verdict unstated, because we do not have
    /// one — claiming a storefront publishes nothing on the strength of a request that never
    /// arrived is the app blaming a brand for its own outage.
    private func couldNotCheck(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Couldn't check this site")
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
            // About us, not the shop — said so in as many words, because the alternative reads
            // as a verdict on the site.
            NoteLine(text: "Dropwall's server didn't answer — this says nothing about the site.", color: .ink)
            Text(reason)
                .font(.data(11))
                .foregroundStyle(Color.signal)
                .fixedSize(horizontal: false, vertical: true)
            Button { Task { await probe() } } label: {
                NotificationsSection.SettingsAction(title: "Try again")
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
    }

    static let nameInfo = InfoNote(
        title: "The name",
        lines: ["Taken from the site itself, so every brand is called the same thing for everyone."]
    )

    static let instagramInfo = InfoNote(
        title: "Instagram",
        lines: ["Saved as a link, never scraped — Instagram's terms don't allow aggregating profiles."]
    )

    static let blockedInfo = InfoNote(
        title: "Why it can't be followed",
        lines: [
            "Its site turns away programs like Dropwall's, so it can't be watched from here.",
            "Share a product from Safari and Dropwall saves it from your own browser."
        ]
    )

    static let noClothesInfo = InfoNote(
        title: "Nothing to follow",
        lines: ["Its own site sells no clothes — they're sold in its boutiques — so there's nothing here for a follow to watch."]
    )

    static let nothingInfo = InfoNote(
        title: "Nothing answered",
        lines: [
            "Dropwall couldn't read anything from this site — no catalogue, no feed, no sitemap, not even the page itself.",
            "It may be down."
        ]
    )

    private var handle: String? {
        let trimmed = instagram.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func probe() async {
        isProbing = true
        probeError = nil
        check = nil
        localRefusal = nil
        defer { isProbing = false }

        guard settings.isConfigured else {
            // The same two answers the server gives, from the same evidence: the curated list
            // before any request, and what each request came back with after. The log only
            // watches — nothing about the requests changes, and nothing is retried another way.
            if let host = BrandDiscovery.normalizedURL(draft.url)?.host(), ShopRefusal.sellsNoClothes(host: host) {
                discovered = DiscoveredSources()
                localRefusal = .sellsNoClothes
                return
            }
            let log = ProbeLog(wrapping: Net.live)
            let found = await BrandDiscovery.discover(website: draft.url, instagramHandle: nil, http: log)
            discovered = found
            localRefusal = found.canMonitor ? nil : ShopRefusal.classify(log.outcomes)
            return
        }

        // The server does the fetching, so the phone never sidesteps the shared politeness
        // budget.
        do {
            var current = try await remote.startCheck(url: draft.url)
            check = current
            isProbing = false
            // Ends with the screen: `.task` cancels, and the sleep throws. Eased off the longer
            // it runs — a storefront that tarpits can make a check take many minutes, and
            // asking every two seconds for all of them buys nothing.
            var interval: Double = 2
            while current.status == .checking {
                try await Task.sleep(for: .seconds(interval))
                current = try await remote.check(id: current.id)
                check = current
                interval = min(interval * 1.5, 15)
            }
            switch current.status {
            case .interrupted:
                probeError = "The check stopped — the server probably restarted."
            case .ready where current.isWatching:
                // Watched while it ran. Asking again is idempotent and waits for the server's
                // own settle, so the brand arrives now rather than on the next foreground.
                check = try await remote.watch(check: current.id, instagram: handle, sizes: sizes.profile, asks: false)
                await remote.sync(sizes: sizes.profile)
                onDone(followed(check?.brand))
            default:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            probeError = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if settings.isConfigured {
            guard let check else { return }
            do {
                let watched = try await remote.watch(check: check.id, instagram: handle, sizes: sizes.profile, asks: false)
                self.check = watched
                // While the check is still running the server holds the request and the
                // screen says so (`isQueued`); with a brand, this is the add it always was.
                if watched.brand != nil {
                    await remote.sync(sizes: sizes.profile)
                    onDone(followed(watched.brand))
                } else if watched.status == .checking {
                    // Asked on the foreground that finds the follow made.
                    prompt.expect(check: watched.id)
                }
            } catch {
                failure = error.localizedDescription
            }
            return
        }

        let brand = Brand(
            name: declaredName,
            websiteURL: BrandDiscovery.normalizedURL(draft.url),
            instagramHandle: BrandDiscovery.normalizedHandle(handle)
        )
        brand.sources = discovered?.sources ?? []
        brand.logoURLString = discovered?.logoURL?.absoluteString
        // Nothing was typed, so the first sync is always free to improve on the guess.
        brand.usesGeneratedName = true
        context.insert(brand)
        try? context.save()

        // First sync establishes the baseline so the feed isn't flooded on day one.
        await engine.sync(brands: [brand])
        onDone(brand)
    }

    /// The local row for a brand the server just followed.
    private func followed(_ dto: BrandDTO?) -> Brand? {
        dto?.id.flatMap { FollowFilterPrompt.brand($0, in: context) }
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
