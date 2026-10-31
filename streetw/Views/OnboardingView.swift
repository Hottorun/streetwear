// OnboardingView.swift
// The first run: four cards on what the app does, then four steps.
//
// **The cards first** (`TourCards`): watch your shops, follow only what you want, save from
// anywhere, search or scan. Each is a picture of the app and one sentence — they replace a "How
// it works" step of grey text, one line of which described a swipe the app no longer has.
//
// A watcher with nothing to watch is a dead end: the old empty state told you to paste a
// website, which assumes you already know which sites are worth pasting. So the first run
// then asks the four things that make the app work at all, in the order they start paying off:
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
// Every step is skippable and everything set here is editable later, on You. Each says one
// line; what a setting does in detail is behind its ⓘ, as on You (`CLAUDE.md`, *Copy*).

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
    /// **Any kind of clothing, menswear and womenswear in equal number.** The pack was ten
    /// streetwear labels, nine of them cut for men, which told everybody else on the first
    /// screen that the app was not for them — while the app itself watches any shop with a
    /// website and reads dress and suit sizes as carefully as sneakers. So: six womenswear
    /// shops and six menswear or unisex, alternating so neither reads as the section after
    /// the other; tailoring and fast fashion beside the labels that sell out; and still the
    /// cases that show what the app is for — a Friday drop, a shock drop, a weekly programme,
    /// and a shop whose daily arrivals are best followed for its sales.
    ///
    /// Every one serves a public Shopify catalogue, checked when it was added, so the first
    /// sync fills the feed in seconds. The notes are measured off each catalogue's own
    /// publication dates in October 2026, not taken from the brands' marketing: a note is a
    /// claim, and it is on the first screen anybody sees.
    static let brands: [StarterBrand] = [
        StarterBrand(name: "Kith", domain: "kith.com", note: "Weekly Monday programme"),
        StarterBrand(name: "Staud", domain: "staud.clothing", note: "Dresses and bags, new in most weeks"),
        StarterBrand(name: "Aimé Leon Dore", domain: "aimeleondore.com", note: "Seasonal, sells out fast"),
        StarterBrand(name: "Faithfull the Brand", domain: "faithfullthebrand.com", note: "A new collection about once a month"),
        StarterBrand(name: "Drake's", domain: "drakes.com", note: "Tailoring, ties and knitwear"),
        StarterBrand(name: "Rixo", domain: "rixo.co.uk", note: "Printed dresses, new pieces every week"),
        StarterBrand(name: "Carhartt WIP", domain: "carhartt-wip.com", note: "Broad catalogue, regular restocks"),
        StarterBrand(name: "With Jean", domain: "withjean.com", note: "A new edit every few weeks"),
        StarterBrand(name: "Palace", domain: "palaceskateboards.com", note: "Friday drops, gone in minutes"),
        StarterBrand(name: "Princess Polly", domain: "us.princesspolly.com", note: "New arrivals every day"),
        StarterBrand(name: "Corteiz", domain: "crtz.xyz", note: "Unannounced — the shock-drop case"),
        StarterBrand(name: "Fashion Nova", domain: "fashionnova.com", note: "Hundreds of new pieces a week — follow it for sales")
    ]
}

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    /// - Parameter mayLatch: whether the caller should record that the starter pack has
    ///   been offered. False when the brand step *failed* rather than being declined —
    ///   `didOfferStarterPack` is permanent, so latching on a server outage put the pack
    ///   out of reach for the life of the install and left typing brand names by hand as
    ///   the only route back in.
    let onFinish: (_ mayLatch: Bool) -> Void

    private enum Step: Int, CaseIterable {
        /// The four cards. Not numbered: they are a picture of the app, not a question.
        case tour
        case sizes
        case gender
        case brands
        case alerts

        /// The setup steps, which are numbered — everything after the cards.
        static let numbered = allCases.filter { $0 != .tour }

        /// Whether the step is tall enough to need scrolling rather than sitting as one
        /// block above centre.
        ///
        /// Sizes joined the brand list here when the waist ladder was added: three chip
        /// rows and a header no longer clear the action bar on a small phone at large
        /// type, and a step whose last row is clipped is one somebody cannot complete —
        /// on the screen that decides whether the first sync is any use to them.
        var scrolls: Bool { self == .brands || self == .sizes }
    }

    @State private var step: Step = .tour
    @State private var tourPage = 0
    @State private var selected: Set<String> = []
    @State private var isAdding = false
    @State private var progress: String?

    /// What went wrong the last time the brand step was run, printed under the action bar.
    /// Cleared on the next attempt, so a retry that works takes the line away.
    @State private var addFailure: String?

    /// Sticky for the run: whether adding brands has failed at any point. It decides
    /// `mayLatch`, so somebody who gives up on a broken server is offered the pack again on
    /// the next launch rather than being locked out of it.
    @State private var didFailToAdd = false

    /// Whether the alerts prompt came back a no.
    ///
    /// iOS asks once and never again, so a denial here is the end of the road as far as the
    /// app is concerned — and the step used to swallow it silently and dismiss, leaving
    /// somebody who tapped the wrong button with no alerts and no idea that is what had
    /// happened. Saying so, once, and naming the one route back is the whole of the fix.
    @State private var alertsDenied = false

    private var chosen: [StarterBrand] {
        StarterPack.brands.filter { selected.contains($0.domain) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if step == .tour {
                    TourCards(page: $tourPage)
                } else if step.scrolls {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header
                            currentStep
                        }
                        .padding(.top, 8)
                        // Ten, not thirty-two: the fade above the action bar is inside the
                        // `safeAreaInset` and so already insets this content by its own
                        // height. Left at 32 the sizes step gained 22pt and pushed its
                        // closing line — "A LADDER YOU LEAVE EMPTY SIMPLY DOESN'T FILTER" —
                        // off the bottom of a step that had just been made to fit exactly.
                        .padding(.bottom, 10)
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
                    Button(step == .alerts ? "Not now" : "Skip") {
                        if step == .tour { step = .sizes } else { advance(skipping: true) }
                    }
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
        case .tour: ""
        case .sizes: "Your sizes"
        case .gender: "What to show"
        case .brands: "Your shops"
        case .alerts: "Drop alerts"
        }
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case .tour: EmptyView()
        case .sizes: sizeStep
        case .gender: genderStep
        case .brands: brandStep
        case .alerts: alertStep
        }
    }

    // MARK: - Steps

    /// Step marker, title and blurb as one block — the thing the page is about, set once.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoteLine(text: "Step \((Step.numbered.firstIndex(of: step) ?? 0) + 1) of \(Step.numbered.count)")
            HStack(alignment: .center, spacing: 2) {
                Text(title)
                    .font(.editorial(30))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let info { InfoButton(note: info) }
            }
            Text(blurb)
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }

    /// One line each: what the step is for, never how it works.
    private var blurb: String {
        switch step {
        case .tour: ""
        case .sizes: "So Dropwall can say what's buyable in your size."
        case .gender: "Narrow the feed to what you'd wear."
        case .brands: "Pick a few to start. Add any shop later."
        case .alerts: "Know the moment your shops drop, restock or go on sale."
        }
    }

    /// The same ⓘ as on You, where the step is a setting You has too.
    private var info: InfoNote? {
        switch step {
        case .sizes: SizeProfileSection.sizesInfo
        case .gender: SizeProfileSection.genderInfo
        default: nil
        }
    }

    /// The ladders, in the same order and the same shapes Settings uses.
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
                            options: SizeScale.shoeScales.map { ($0.label, $0) },
                            selection: sizes.profile.shoeScale,
                            select: sizes.setShoeScale
                        )
                    )
                }
            )

            // Asked here for the reason the waist is: a woman who enters only a shoe size
            // on this screen has every dress in her first sync read on no ladder of hers.
            DressAndSuitRows()

            // Somebody who fills in one ladder and not the others should know that the empty
            // ones are not a filter left on — said behind the header's ⓘ (`sizesInfo`).
        }
        .padding(.horizontal, 20)
    }

    private var genderStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(GenderPreference.allCases) { preference in
                choice(
                    label: preference.label,
                    detail: preference.detail,
                    isOn: sizes.profile.gender == preference
                ) {
                    sizes.setGender(preference)
                }
            }
        }
        .padding(.horizontal, 20)
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
                ("bolt.fill", "New drops"),
                ("tag.fill", "Sales"),
                ("arrow.clockwise", "Back in your size"),
                ("lock.fill", "A storefront locking — a drop is minutes away")
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

            if alertsDenied {
                // iOS asks once, so the one way back is named — and opened, rather than described.
                VStack(alignment: .leading, spacing: 10) {
                    NoteLine(text: "Alerts are off, and iOS asks only once.", color: .signal)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link(destination: url) {
                            NotificationsSection.SettingsAction(title: "Turn on in Settings")
                        }
                    }
                }
                .padding(.top, 4)
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
                    NoteLine(text: detail)
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
                    NoteLine(text: brand.note)
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
        VStack(spacing: 0) {
            // **A short paper fade, so the list visibly passes under the bar rather than
            // being sliced by nothing.** The bar's background is `Color.paper` and so is the
            // page, so there was no edge anywhere: on the brand step the eighth row —
            // "REPRESENT / SCHEDULED SEASONAL DROPS" — was cut mid-descender by an invisible
            // boundary, which reads as a clipped layout rather than as content that scrolls.
            // Inside the `safeAreaInset` on purpose: its height insets the scroll content
            // too, so at the foot of the list the last row sits *above* the fade and only
            // rows actually moving past it are faded.
            LinearGradient(
                colors: [Color.paper.opacity(0), Color.paper],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 22)
            .allowsHitTesting(false)

            actionControls
        }
        .background(Color.paper)
    }

    private var actionControls: some View {
        VStack(spacing: 10) {
            if step == .tour {
                TourDots(page: tourPage)
                    .padding(.bottom, 8)
            }
            if let progress {
                NoteLine(text: progress)
            }
            // Above the button that caused it, and only ever visible on the step it belongs
            // to. The first run is the one place where a silent failure is indistinguishable
            // from the app simply having nothing.
            if let addFailure, step == .brands, progress == nil {
                Text(addFailure)
                    .font(.editorial(14))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.signal).frame(width: 2).offset(x: -10)
                    }
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
        case .tour: tourPage < TourCards.count - 1 ? "Next" : "Set up"
        case .sizes, .gender: "Continue"
        case .brands:
            if selected.isEmpty {
                "Choose at least one"
            } else if addFailure != nil {
                "Try again"
            } else {
                "Watch \(selected.count) \(selected.count == 1 ? "brand" : "brands")"
            }
        case .alerts: alertsDenied ? "Done" : "Turn on alerts"
        }
    }

    private var isPrimaryDisabled: Bool {
        step == .brands && selected.isEmpty
    }

    // MARK: - Flow

    private func advance(skipping: Bool) {
        switch step {
        case .tour:
            if tourPage < TourCards.count - 1 {
                withAnimation { tourPage += 1 }
            } else {
                step = .sizes
            }
        case .sizes:
            step = .gender
        case .gender:
            step = .brands
            // **The profile is finished here, so it goes to the server here.**
            //
            // It used to travel only as a side effect of `addBrand`, which meant skipping
            // the brand step left the server holding the empty profile it was registered
            // with — for as long as it took the next sync to clear its throttle. Restock
            // targeting is what that profile is *for*, so it was off in exactly that window.
            // `ensureRegistered` rather than `pushSizes`: on a first run the launch sync may
            // not have issued a token yet, and `pushSizes` is a silent no-op without one.
            if settings.isConfigured {
                let profile = sizes.profile
                Task { try? await remote.ensureRegistered(sizes: profile) }
            }
        case .brands:
            if skipping {
                step = .alerts
            } else {
                Task { await add() }
            }
        case .alerts:
            if skipping || alertsDenied {
                onFinish(!didFailToAdd)
            } else {
                Task {
                    // Prompts, and registers for a token on success. A denial here is
                    // final as far as iOS is concerned, which is why this is the last
                    // thing asked rather than the first — and why it is said out loud
                    // rather than dismissed over. The button becomes "Done" and the next
                    // press finishes.
                    if await PushAuthorization.request() {
                        onFinish(!didFailToAdd)
                    } else {
                        alertsDenied = true
                    }
                }
            }
        }
    }

    /// Runs the same path the add-brand flow runs — server-side when one is configured,
    /// on-device otherwise — one brand at a time so each site is probed politely and the
    /// user can see it happening.
    ///
    /// **It reports, and it does not advance on nothing.** Every add used to be wrapped in a
    /// `try?` and the step moved on regardless, so with the server down the whole first run
    /// was five "Checking…" labels, how-it-works, the permission prompt, and a feed reading
    /// "Nothing on watch yet" — no error at any point, and the pack unreachable forever
    /// after because `didOfferStarterPack` had latched on the way out.
    private func add() async {
        isAdding = true
        addFailure = nil
        var added = 0
        var failure: String?
        defer { isAdding = false }

        for brand in chosen {
            progress = "Checking \(brand.name)…"
            if settings.isConfigured {
                // The starter pack's own label is not sent: the catalogue is global and the
                // server takes a brand's name from its storefront. Ours would be one more
                // client's opinion, and the shop's own is better.
                do {
                    _ = try await remote.addBrand(
                        url: brand.domain,
                        instagram: nil,
                        sizes: sizes.profile,
                        // Bulk, and every one narrowable from its page later: a dozen
                        // questions in a row is not a welcome. See `FollowFilterPrompt`.
                        asks: false
                    )
                    added += 1
                } catch {
                    failure = failure ?? error.localizedDescription
                }
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
                added += 1
            }
        }

        progress = nil

        // Nothing was added, so there is nothing to move on to. Stay on the step, say what
        // happened, and let the same button be pressed again — the brand list is still
        // selected, so a retry is one tap. Skip is still in the toolbar for somebody who
        // would rather get on with it.
        guard added > 0 else {
            didFailToAdd = true
            addFailure = failure ?? "Couldn't reach those sites. Check your connection."
            return
        }

        // Some worked and some didn't: worth saying, but not worth blocking on.
        if let failure, added < chosen.count {
            didFailToAdd = true
            addFailure = "Added \(added) of \(chosen.count). \(failure)"
        }

        progress = "Fetching the first updates…"
        if settings.isConfigured { await remote.sync(sizes: sizes.profile) }
        progress = nil
        step = .alerts
    }
}
