// OnboardingView.swift
// The first run, in four steps.
//
// A watcher with nothing to watch is a dead end: the old empty state told you to paste a
// website, which assumes you already know which sites are worth pasting. So the first run
// asks the four things that make the app work at all, in the order they start paying off:
//
// 1. **Sizes** — before brands, because the very first sync is what fills the feed, and a
//    profile set afterwards can't retroactively highlight anything in it.
// 2. **What to show** — same reason, and it is one tap.
// 3. **Brands** — the expensive step, and the one that needs the two answers above to
//    already be on the server: `addBrand` sends the profile with it.
// 4. **Alerts** — last, deliberately. A push prompt before the user has seen a single
//    product is a request to trust something they haven't been shown, and a denial is
//    permanent: iOS never asks again. Asking after they have picked brands means the
//    question is "do you want to know when *these* drop", which is a question with an
//    obvious answer.
//
// Every step is skippable and everything set here is editable later in Settings.

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

    private enum Step: Int, CaseIterable {
        case sizes
        case gender
        case brands
        /// Placed *after* brands on purpose. It explains saving, boards, sharing in and
        /// watching — none of which mean anything until there is something to do them to,
        /// and all of which are otherwise undiscoverable: the share extension in
        /// particular lives entirely outside the app and nothing in the UI hints it
        /// exists. It also covers the wait while the first sync runs.
        case howItWorks
        case alerts

        /// Everything except the brand list is short enough to sit centred; the brand
        /// list is a scroller.
        var isList: Bool { self == .brands }
    }

    @State private var step: Step = .sizes
    @State private var selected: Set<String> = []
    @State private var isAdding = false
    @State private var progress: String?

    private var chosen: [StarterBrand] {
        StarterPack.brands.filter { selected.contains($0.domain) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if step.isList {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            masthead
                            brandStep
                        }
                        .padding(.bottom, 32)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    // Balanced rather than top-aligned. Every step used to stack its
                    // content under the title and leave the bottom two-thirds of the
                    // screen empty, which made a two-line question look like a page that
                    // had failed to load.
                    VStack(alignment: .leading, spacing: 30) {
                        Spacer(minLength: 8)
                        masthead
                        currentStep
                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.paper)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Every step is skippable. The brand step is the only one where
                    // skipping leaves the app genuinely empty, and that is the user's
                    // call to make.
                    Button(step == .alerts ? "Not now" : "Skip") { advance(skipping: true) }
                        .disabled(isAdding)
                }
            }
        }
        .tint(.ink)
        .interactiveDismissDisabled(true)
    }

    private var title: String {
        switch step {
        case .sizes: "Your sizes"
        case .gender: "What to show"
        case .brands: "Start watching"
        case .howItWorks: "How it works"
        case .alerts: "Drop alerts"
        }
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case .sizes: sizeStep
        case .gender: genderStep
        case .brands: brandStep
        case .howItWorks: howItWorksStep
        case .alerts: alertStep
        }
    }

    // MARK: - Steps

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(blurb)
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            DataLabel(text: "STEP \(step.rawValue + 1) OF \(Step.allCases.count) · CHANGE ANY OF THIS LATER IN SETTINGS")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, step.isList ? 24 : 0)
    }

    private var blurb: String {
        switch step {
        case .sizes:
            "Tell streetw what you wear and it can say which drops are actually buyable in your size — and tell you when something comes back in it."
        case .gender:
            "Narrow the feed to what you'd actually wear."
        case .brands:
            "Pick a few brands and streetw watches their catalogs for drops, restocks and the moment a storefront locks down."
        case .howItWorks:
            "Four things worth knowing."
        case .alerts:
            "A drop resolves in minutes. streetw can tell you the moment one of your brands releases something or restocks in your size."
        }
    }

    /// The features that are otherwise invisible. The share extension especially: it lives
    /// outside the app entirely, so nothing in the interface can hint that it exists.
    private var howItWorksStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach([
                (
                    "bookmark",
                    "Save what you like",
                    "Tap the bookmark on anything in the feed. Swipe a card left to file it, right to clear it."
                ),
                (
                    "square.grid.2x2",
                    "Group saves into boards and fits",
                    "Boards are filters, not folders — one thing can sit on several. Fits are outfits built from what you've kept."
                ),
                (
                    "square.and.arrow.up",
                    "Share anything into streetw",
                    "Found something in Safari or Instagram? Share it to streetw and it lands in your collection with its price and photo."
                ),
                (
                    "bell",
                    "Watch a sold-out size",
                    "Open a product, pick your size and colour, and streetw tells you the moment it comes back."
                )
            ], id: \.1) { symbol, heading, detail in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.ink)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(heading)
                            .font(.editorial(16))
                            .foregroundStyle(Color.ink)
                        Text(detail)
                            .font(.data(11))
                            .foregroundStyle(Color.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var sizeStep: some View {
        @Bindable var store = sizes
        return VStack(alignment: .leading, spacing: 22) {
            SizeChipRow(
                title: "Clothing",
                options: SizeProfile.apparelOptions.map { (display: $0, stored: $0) },
                isSelected: { sizes.profile.apparel.contains($0) },
                toggle: sizes.toggleApparel
            )
            SizeChipRow(
                title: "Shoes",
                options: SizeProfile.shoeOptions(in: sizes.profile.shoeScale),
                isSelected: { sizes.profile.shoe.contains($0) },
                toggle: sizes.toggleShoe,
                accessory: {
                    AnyView(
                        Picker("Scale", selection: Binding(
                            get: { sizes.profile.shoeScale },
                            set: { sizes.setShoeScale($0) }
                        )) {
                            ForEach(SizeScale.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 132)
                    )
                }
            )
        }
        .padding(.horizontal, 20)
    }

    private var genderStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(GenderPreference.allCases) { preference in
                choice(
                    label: preference.label,
                    detail: detail(for: preference),
                    isOn: sizes.profile.gender == preference
                ) {
                    sizes.setGender(preference)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func detail(for preference: GenderPreference) -> String {
        switch preference {
        case .everything: "Menswear, womenswear and kids"
        case .mens: "Hides womenswear and kids"
        case .womens: "Hides menswear and kids"
        }
    }

    private var brandStep: some View {
        VStack(spacing: 0) {
            ForEach(StarterPack.brands) { brand in
                row(for: brand)
            }
        }
    }

    private var alertStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([
                ("bolt.fill", "A brand you follow drops something new"),
                ("arrow.clockwise", "Something comes back in your size"),
                ("lock.fill", "A storefront locks down — usually minutes before a release")
            ], id: \.1) { symbol, line in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.signal)
                        .frame(width: 18)
                    Text(line)
                        .font(.editorial(15))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        }
        .padding(.horizontal, 20)
    }

    // MARK: - Pieces

    private func choice(
        label: String,
        detail: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.editorial(17))
                        .foregroundStyle(Color.ink)
                    DataLabel(text: detail.uppercased(), size: 10)
                }
                Spacer(minLength: 8)
                Rectangle()
                    .fill(isOn ? Color.signal : Color.hairline)
                    .frame(width: 22, height: isOn ? 3 : 1)
            }
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .bottom) { Rule() }
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
                advance(skipping: false)
            } label: {
                Text(primaryLabel)
                    .font(.wordmark(13))
                    .tracking(1.2)
                    .foregroundStyle(Color.paper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isPrimaryDisabled ? Color.muted : Color.ink)
            }
            .buttonStyle(.borderless)
            .disabled(isPrimaryDisabled || isAdding)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .background(Color.paper)
    }

    private var primaryLabel: String {
        switch step {
        case .sizes, .gender, .howItWorks: "Continue"
        case .brands:
            selected.isEmpty
                ? "Choose at least one"
                : "Watch \(selected.count) \(selected.count == 1 ? "brand" : "brands")"
        case .alerts: "Turn on alerts"
        }
    }

    private var isPrimaryDisabled: Bool {
        step == .brands && selected.isEmpty
    }

    // MARK: - Flow

    private func advance(skipping: Bool) {
        switch step {
        case .sizes:
            step = .gender
        case .gender:
            step = .brands
        case .brands:
            if skipping {
                step = .howItWorks
            } else {
                Task { await add() }
            }
        case .howItWorks:
            step = .alerts
        case .alerts:
            if skipping {
                onFinish()
            } else {
                Task {
                    // Prompts, and registers for a token on success. A denial here is
                    // final as far as iOS is concerned, which is why this is the last
                    // thing asked rather than the first.
                    await PushAuthorization.request()
                    onFinish()
                }
            }
        }
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
        progress = nil
        step = .howItWorks
    }
}
