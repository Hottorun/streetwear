// BrandDetailView.swift
// One brand: its mark, what it has been doing, what you kept from it, and how we watch it.
//
// This was the last screen in the app still built out of a stock `List` — grey grouped
// sections, `.bordered` buttons, a system toggle, `LabeledContent`. Every other surface is
// paper, serif headings and mono data labels, so opening a brand fell out of the app and
// into Settings.app for a moment. The information was right; none of the presentation was.
//
// What it is now, in reading order:
//
// - **The brand.** Its own mark at a size worth looking at, its name set as a wordmark,
//   and the one urgent fact — a locked storefront — in the accent, because that is the
//   signal people open this page hoping to see.
// - **A line of counts.** Drops, unseen, kept. Printed as data, not badged: this is a page
//   about a brand, not an inbox to clear.
// - **Recent, and yours.** The two carousels, which were the only part already in the
//   app's voice.
// - **The machinery**, last and quietest: which sources we poll, what they last said, when
//   they last ran. Worth having and never worth leading with.
//
// Following moved to the bottom and became a word rather than a switch. It is a decision
// you make once, and a toggle at the top of a page invites fiddling with it.

import StreetwCore
import SwiftData
import SwiftUI

struct BrandDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    @Bindable var brand: Brand

    /// Filtered like every other browsing list. "Kept from here" below it deliberately is
    /// not: those are things you chose, and hiding one because it doesn't match a setting
    /// you changed afterwards would be the app editing your own collection.
    private var recent: [BrandUpdate] {
        let profile = sizes.profile
        return brand.recentUpdates(limit: 60).filter { $0.passes(profile) }.prefix(20).map { $0 }
    }

    private var savedFromBrand: [BrandUpdate] {
        brand.updates
            .filter { !$0.saves.isEmpty }
            .sorted { ($0.save?.savedAt ?? .distantPast) > ($1.save?.savedAt ?? .distantPast) }
    }

    private var automatic: [BrandSource] {
        brand.sources.filter { $0.kind.isAutomatic }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                masthead
                if brand.isLockedForDrop { lockNotice }
                counts
                links

                if recent.isEmpty {
                    nothingYet
                } else {
                    section("Recent", "\(recent.count) MOST RECENT") {
                        UpdateCarousel(updates: recent)
                    }
                }

                if !savedFromBrand.isEmpty {
                    section("Kept from here", "\(savedFromBrand.count) IN YOUR COLLECTION") {
                        UpdateCarousel(updates: savedFromBrand, width: 110)
                    }
                }

                sources
                followingRow
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle(brand.name)
        .toolbarTitleDisplayMode(.inline)
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

    // MARK: - Sections

    /// The mark at 64pt rather than the 44 the list row uses. On a page *about* one brand,
    /// its own logo is the most useful thing on screen and the cheapest to give room to.
    private var masthead: some View {
        HStack(alignment: .center, spacing: 16) {
            BrandMonogram(name: brand.name, logoURL: brand.logoURL, size: 64)

            VStack(alignment: .leading, spacing: 6) {
                Wordmark(name: brand.name, size: 17)
                if let host = brand.websiteURL?.host()?.replacingOccurrences(of: "www.", with: "") {
                    DataLabel(text: host.uppercased(), size: 10)
                }
                DataLabel(
                    text: brand.lastSyncedAt.map { "CHECKED \(Stamp.short($0).uppercased())" }
                        ?? "NOT CHECKED YET",
                    size: 9
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    /// The one thing on this page allowed to be loud. A storefront going dark usually means
    /// minutes, not hours.
    private var lockNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.signal)
            Text("Storefront is locked — usually a release is close.")
                .font(.editorial(14))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wash)
        .overlay(alignment: .leading) { Rectangle().fill(Color.signal).frame(width: 2) }
        .padding(.horizontal, 20)
    }

    private var counts: some View {
        HStack(alignment: .top, spacing: 0) {
            count(brand.updates.count, "DROPS SEEN")
            count(brand.unseenCount, "UNREAD", accent: brand.unseenCount > 0)
            count(savedFromBrand.count, "KEPT")
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .top) { Rule().padding(.horizontal, 20) }
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
    }

    private func count(_ value: Int, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.data(20, .medium))
                .foregroundStyle(accent ? Color.signal : Color.ink)
            DataLabel(text: label, size: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var links: some View {
        let destinations: [(label: String, symbol: String, url: URL)] = [
            brand.websiteURL.map { ("SHOP", "arrow.up.right", $0) },
            brand.instagramURL.map { ("INSTAGRAM", "arrow.up.right", $0) }
        ].compactMap { $0 }

        if !destinations.isEmpty {
            HStack(spacing: 10) {
                ForEach(destinations, id: \.label) { destination in
                    Button { openURL(destination.url) } label: {
                        HStack(spacing: 6) {
                            Text(destination.label)
                                .font(.data(11, .semibold))
                                .tracking(1.1)
                            Image(systemName: destination.symbol)
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay { Rectangle().stroke(Color.hairline, lineWidth: 1) }
                    }
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
    }

    private var nothingYet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(brand.lastSyncedAt == nil ? "Not checked yet" : "Nothing found yet")
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
            Text(
                automatic.isEmpty
                    ? "Nothing on this site can be watched automatically — it's here as a link."
                    : "streetw is watching \(automatic.map { $0.kind.label.lowercased() }.joined(separator: " and ")). New drops will appear here."
            )
            .font(.editorial(14))
            .foregroundStyle(Color.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }

    /// Last, and deliberately dry. This is the only place a source's error is visible, so
    /// it has to be legible — but nobody opens a brand page to read about a sitemap.
    private var sources: some View {
        section("How it's watched", "\(brand.sources.count) \(brand.sources.count == 1 ? "SOURCE" : "SOURCES")") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(brand.sources) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text(source.kind.label.uppercased())
                                .font(.data(11, .medium))
                                .foregroundStyle(source.kind.isAutomatic ? Color.ink : Color.muted)
                            Spacer(minLength: 8)
                            DataLabel(
                                text: source.lastError != nil
                                    ? "FAILING"
                                    : (source.kind.isAutomatic ? "WATCHING" : "LINK ONLY"),
                                size: 9,
                                color: source.lastError != nil ? .signal : .muted
                            )
                        }

                        Text(source.url.absoluteString)
                            .font(.data(10))
                            .foregroundStyle(Color.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let error = source.lastError {
                            Text(
                                source.failureCount > 1
                                    ? "\(error) — failed \(source.failureCount)×, backing off."
                                    : error
                            )
                            .font(.data(10))
                            .foregroundStyle(Color.signal)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Rule() }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// Words, not switches. These are rare, deliberate and reversible — and a toggle at the
    /// top of the page made them the most prominent controls on a screen that is about
    /// looking at clothes.
    ///
    /// **Two rows, because they were one and it was the wrong one.** "Stop following"
    /// carried a `bell.slash` — the universal mute icon — so the app was already offering
    /// this and then doing something much more drastic. A brand that posts forty times a
    /// week is not one you want to stop watching; it is one you want to stop being woken
    /// by, and until now the only way to get quiet was to delete it from your feed.
    private var followingRow: some View {
        VStack(spacing: 0) {
            if brand.followed {
                actionRow(
                    title: brand.isMuted ? "Unmute" : "Mute alerts",
                    detail: brand.isMuted ? "SILENT · STILL IN YOUR FEED" : nil,
                    symbol: brand.isMuted ? "bell" : "bell.slash",
                    isEmphasised: brand.isMuted
                ) {
                    brand.isMuted.toggle()
                    try? context.save()
                }
            }

            actionRow(
                title: brand.followed ? "Stop following" : "Follow again",
                detail: nil,
                // Not a bell. Unfollowing removes the brand from the feed entirely, and
                // borrowing the mute icon for it is what made the two indistinguishable.
                symbol: brand.followed ? "minus.circle" : "plus.circle",
                isEmphasised: !brand.followed
            ) {
                brand.followed.toggle()
                try? context.save()
                syncFollowState()
            }
        }
        .overlay(alignment: .top) { Rule().padding(.horizontal, 20) }
    }

    private func actionRow(
        title: String,
        detail: String?,
        symbol: String,
        isEmphasised: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.data(12, .medium))
                        .foregroundStyle(isEmphasised ? Color.ink : Color.muted)
                    if let detail { DataLabel(text: detail, size: 9) }
                }
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isEmphasised ? Color.ink : Color.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }

    private func section(
        _ title: String,
        _ detail: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.editorial(19))
                    .foregroundStyle(Color.ink)
                DataLabel(text: detail)
            }
            .padding(.horizontal, 20)

            content()
        }
    }

    // MARK: - Actions

    /// The server decides what gets polled, so following has to be recorded there, not
    /// just flagged locally.
    private func syncFollowState() {
        guard settings.isConfigured, let id = brand.remoteID else { return }
        let following = brand.followed
        Task {
            if following {
                try? await remote.follow(brandID: id)
            } else {
                await remote.unfollow(brand)
            }
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
}
