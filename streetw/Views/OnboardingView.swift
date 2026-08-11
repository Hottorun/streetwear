// OnboardingView.swift
// The first screen, and the answer to the emptiest problem in the app.
//
// A watcher with nothing to watch is a dead end: the old empty state told you to paste a
// website, which assumes you already know which sites are worth pasting. A starter pack
// turns the first run into two taps and gives the feed something to show immediately.
//
// The list is deliberately a plain, editable set of domains rather than anything remote.
// These are public storefronts; picking one just runs the same discovery the add-brand
// flow runs, so nothing here is privileged or hard-coded beyond the suggestion itself.

import StreetwCore
import SwiftData
import SwiftUI

struct StarterBrand: Identifiable, Hashable {
    var name: String
    var domain: String
    /// One line on why it's here. Doubles as the reason a person would pick it, which is
    /// more useful than a category label.
    var note: String

    var id: String { domain }
}

enum StarterPack {
    /// Chosen to span the range rather than to rank: a couple of the obvious ones, some
    /// that drop unpredictably, and some whose whole appeal is that they sell out.
    static let brands: [StarterBrand] = [
        StarterBrand(name: "Kith", domain: "kith.com", note: "Weekly Monday programme"),
        StarterBrand(name: "Aimé Leon Dore", domain: "aimeleondore.com", note: "Seasonal, sells out fast"),
        StarterBrand(name: "Stüssy", domain: "stussy.com", note: "Steady drops, deep archive"),
        StarterBrand(name: "Billionaire Boys Club", domain: "bbcicecream.com", note: "Frequent restocks"),
        StarterBrand(name: "Noah", domain: "noahny.com", note: "Small runs, quiet releases"),
        StarterBrand(name: "Awake NY", domain: "awakeny.com", note: "Limited, collab-heavy"),
        StarterBrand(name: "Carhartt WIP", domain: "carhartt-wip.com", note: "Broad catalogue, regular restocks"),
        StarterBrand(name: "Represent", domain: "representclo.com", note: "Scheduled seasonal drops"),
        StarterBrand(name: "Palace", domain: "palaceskateboards.com", note: "Friday drops, gone in minutes"),
        StarterBrand(name: "Corteiz", domain: "crtz.xyz", note: "Unannounced — the shock-drop case")
    ]
}

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let onFinish: () -> Void

    @State private var selected: Set<String> = []
    @State private var isAdding = false
    @State private var progress: String?

    private var chosen: [StarterBrand] {
        StarterPack.brands.filter { selected.contains($0.domain) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    masthead
                    ForEach(StarterPack.brands) { brand in
                        row(for: brand)
                    }
                }
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("Start watching")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { onFinish() }
                        .disabled(isAdding)
                }
            }
        }
        .tint(.ink)
        .interactiveDismissDisabled(isAdding)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick a few brands and streetw watches their catalogs for drops, restocks and the moment a storefront locks down.")
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
            DataLabel(text: "YOU CAN ADD OR REMOVE ANY OF THESE LATER")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    private func row(for brand: StarterBrand) -> some View {
        let isOn = selected.contains(brand.domain)
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                if isOn { selected.remove(brand.domain) } else { selected.insert(brand.domain) }
            }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Wordmark(name: brand.name, size: 14)
                    DataLabel(text: brand.note.uppercased(), size: 10)
                }
                Spacer(minLength: 8)
                // A rule rather than a tick: the same mark the size run uses for "this
                // one is yours", so selection reads consistently across the app.
                Rectangle()
                    .fill(isOn ? Color.signal : Color.hairline)
                    .frame(width: 22, height: isOn ? 3 : 1)
            }
            .padding(.vertical, 15)
            .padding(.horizontal, 20)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
        .disabled(isAdding)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let progress {
                DataLabel(text: progress.uppercased())
            }
            Button {
                Task { await add() }
            } label: {
                Text(selected.isEmpty ? "Choose at least one" : "Watch \(selected.count) \(selected.count == 1 ? "brand" : "brands")")
                    .font(.wordmark(13))
                    .tracking(1.2)
                    .foregroundStyle(Color.paper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(selected.isEmpty ? Color.muted : Color.ink)
            }
            .buttonStyle(.borderless)
            .disabled(selected.isEmpty || isAdding)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .background(Color.paper)
    }

    /// Runs the same path the add-brand flow runs — server-side when one is configured,
    /// on-device otherwise — one brand at a time so each site is probed politely and the
    /// user can see it happening.
    private func add() async {
        isAdding = true
        defer { isAdding = false }

        for brand in chosen {
            progress = "Checking \(brand.name)"
            if settings.isConfigured {
                _ = try? await remote.addBrand(
                    url: brand.domain,
                    name: brand.name,
                    instagram: nil,
                    sizes: sizes.profile
                )
            } else {
                let found = await BrandDiscovery.discover(website: brand.domain, instagramHandle: nil)
                let model = Brand(name: brand.name, websiteURL: BrandDiscovery.normalizedURL(brand.domain))
                model.sources = found.sources
                model.logoURLString = found.logoURL?.absoluteString
                // The user picked this name from a list, so it isn't our guess to
                // overwrite on the first sync.
                model.usesGeneratedName = false
                context.insert(model)
                try? context.save()
                await engine.sync(brands: [model])
            }
        }

        progress = "Fetching first updates"
        if settings.isConfigured { await remote.sync(sizes: sizes.profile) }
        onFinish()
    }
}
