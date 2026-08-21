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

        /// Whether the step is tall enough to need scrolling rather than sitting as one
        /// block above centre.
        ///
        /// Sizes joined the brand list here when the waist ladder was added: three chip
        /// rows and a header no longer clear the action bar on a small phone at large
        /// type, and a step whose last row is clipped is one somebody cannot complete —
        /// on the screen that decides whether the first sync is any use to them.
        var scrolls: Bool { self == .brands || self == .sizes }
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
                if step.scrolls {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header
                            currentStep
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    // One anchor, not two.
                    //
                    // The title used to be a large navigation title *and* the content was
                    // centred in what was left, which produced a heading pinned to the top
                    // and a block of controls floating in the middle with a screen's worth
                    // of nothing between them. The title is now part of the content, so
                    // the whole step reads as a single object — and it sits above centre
                    // rather than on it, because a page that starts in the middle of the
                    // screen looks like it failed to load.
                    VStack(alignment: .leading, spacing: 34) {
                        // Capped, not free. An uncapped spacer centres the block and
                        // leaves a quarter of the screen empty above the step marker,
                        // which reads as a page that hasn't finished loading. Slack
                        // belongs at the bottom, above the button, where empty space is
                        // unremarkable.
                        Spacer(minLength: 0).frame(maxHeight: 64)
                        header
                        currentStep
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.paper)
            .safeAreaInset(edge: .bottom) { actions }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Every step is skippable. The brand step is the only one where
                    // skipping leaves the app genuinely empty, and that is the user's
                    // call to make.
                    Button(step == .alerts ? "Not now" : "Skip") { advance(skipping: true) }
                        .disabled(isAdding)
                        .font(.data(12))
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

    /// Step marker, title and blurb as one block — the thing the page is about, set once.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "STEP \(step.rawValue + 1) OF \(Step.allCases.count)")
            Text(title)
                .font(.editorial(30))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(blurb)
                .font(.editorial(16))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
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
            "Four things that are easy to miss."
        case .alerts:
            "A drop resolves in minutes. streetw can tell you the moment one of your brands releases something or restocks in your size."
        }
    }

    /// The features that are otherwise invisible. The share extension especially: it lives
    /// outside the app entirely, so nothing in the interface can hint that it exists.
    ///
    /// One line each, set at a readable size. The first version explained each feature in
    /// two or three sentences of 11pt monospace — a wall of small text on the screen where
    /// someone is least invested in reading. A person skims this once; it has to be
    /// glanceable, and what it really needs to do is tell them these things *exist*.
    private var howItWorksStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach([
                ("bookmark", "Save what you like", "Swipe a card left to file it, right to clear it."),
                ("square.and.arrow.up", "Share links in", "From Safari, Instagram, anywhere."),
                ("square.grid.2x2", "Build boards and fits", "Group what you keep into outfits."),
                ("bell", "Watch a sold-out size", "Get told the moment it's back.")
            ], id: \.1) { symbol, heading, detail in
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.ink)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(heading)
                            .font(.editorial(18))
                            .foregroundStyle(Color.ink)
                        Text(detail)
                            .font(.editorial(14))
                            .foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// The three ladders, in the same order and the same shapes Settings uses.
    ///
    /// Waist is asked here rather than left to be discovered later, because this step
    /// exists for one reason — the very first sync is what fills the feed, and a profile
    /// set afterwards can't retroactively rule anything in it. Bottoms are a large share of
    /// what these brands make, so a first run that only asks for a letter and a shoe size
    /// leaves the feature switched off across all of it.
    private var sizeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            SizeChipRow(
                title: "Clothing",
                options: SizeProfile.apparelOptions.map { (display: $0, stored: $0) },
                isSelected: { sizes.profile.apparel.contains($0) },
                toggle: sizes.toggleApparel
            )
            SizeChipRow(
                title: "Waist",
                options: SizeProfile.waistOptions.map { (display: $0, stored: $0) },
                isSelected: { sizes.profile.waist.contains($0) },
                toggle: sizes.toggleWaist
            )
            SizeChipRow(
                title: "Shoes",
                options: SizeProfile.shoeOptions(in: sizes.profile.shoeScale),
                isSelected: { sizes.profile.shoe.contains($0) },
                toggle: sizes.toggleShoe,
                accessory: {
                    // `WordPicker`, not a system `.segmented` — this was the last place in
                    // the app still drawing one, and a stock control on the first screen a
                    // person ever sees sets the wrong expectation for every screen after.
                    AnyView(
                        WordPicker(
                            options: SizeScale.allCases.map { ($0.label, $0) },
                            selection: sizes.profile.shoeScale,
                            select: sizes.setShoeScale
                        )
                    )
                }
            )

            // Nothing here is required, and the step is skippable — but somebody who fills
            // in one ladder and not the others should know that the empty ones are not a
            // filter they have accidentally left on.
            DataLabel(text: "A LADDER YOU LEAVE EMPTY SIMPLY DOESN'T FILTER")
                .padding(.top, 2)
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
                // The starter pack's own label is not sent: the catalogue is global and the
                // server takes a brand's name from its storefront. Ours would be one more
                // client's opinion, and the shop's own is better.
                _ = try? await remote.addBrand(
                    url: brand.domain,
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
