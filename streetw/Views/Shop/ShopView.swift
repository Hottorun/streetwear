// ShopView.swift
// The Shop tab: Discover with a search field on top.
//
// Three things on one page, in the order somebody arrives wanting them:
//
// - **A field that takes a description** — "a black suit under $400". It is read by a small
//   grammar (`ShopQuery`) — in server mode over every shop the server watches, as one list in
//   which your own shops are lifted (Phase 5), standalone over the products from your shops on
//   this phone (`ShopCatalogue`) — and the page says exactly which, from the answer: "IN EVERY
//   SHOP WE WATCH", with the count. The field itself never says AI, never says the web, and draws
//   a magnifying glass rather than a sparkle, because a sparkle is the platform's way of
//   promising a model.
//   Under the box it prints what it understood, as the style statement does, and when a search
//   comes back empty it says which constraint emptied it (`ShopSearch.Outcome`).
// - **Asking Dropwall**, beside it and never instead of it (`ShopAsk`): a row that says AI and
//   its price, which sends the description to the model, prints the model's reading through
//   the same `ShopQuery` line, and continues as a short thread of replies. Drawn only where the
//   server has a model (`AIStore`); standalone, never.
// - **Today's picks** while the field is empty — a few things from your shops, each with the
//   one sentence an archive can say about it and a photograph of your own piece beside it
//   (`DailyPicks`). This is the Style tab's "what's missing", moved to where it can be acted on.
// - **The Discover deck**, one row below the picks, unchanged — brands you don't follow yet.

import StreetwCore
import SwiftData
import SwiftUI

struct ShopView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(StyleStatementStore.self) private var statement: StyleStatementStore
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(SyncEngine.self) private var engine: SyncEngine
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(SaveConfirmation.self) private var confirmation: SaveConfirmation
    @Environment(AIStore.self) private var ai: AIStore

    /// The collection, for what you own and what is already kept. Unpredicated for the reason
    /// `GoesWith`'s is — the question is genuinely about everything saved — and harmless here
    /// because nothing in `body` walks it: the picks are derived in a `.task` keyed on a
    /// fingerprint of it (`PicksKey`), the way `DiscoverFeedView.DeckKey` does.
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    /// Only the boards with a taste setting — see `Board.shapingTaste`. Usually none.
    @Query(filter: Board.shapingTaste) private var tasteBoards: [Board]
    @Query private var dismissals: [BrandDismissal]

    @State private var catalogue = ShopCatalogue()

    @State private var text = ""
    @State private var cheaper = false
    @State private var formal = false
    @State private var inMySize = false
    /// The last search, and the query it answers. The reading under the field is printed from
    /// *this* query rather than from the text as it is typed, so the two always agree and the
    /// reading does not flicker word by word — `StyleStatementSection`'s reason for committing
    /// on blur, met here by settling instead.
    @State private var found = Found()

    @State private var picks: [ShopPick] = []
    @State private var picksSettled = false
    @State private var hasWardrobe = false
    /// Bumped by "not for me", which changes nothing else the picks are keyed on.
    @State private var refusals = 0
    /// The model's wording of the top few picks' reasons, by pick id — see `PickReasons`.
    @State private var worded: [String: String] = [:]

    @State private var fitting: ShopPick?
    @State private var isBrowsing = false
    @FocusState private var isWriting: Bool

    private struct Found {
        var query = ShopQuery()
        var result = ShopSearch.Result()
    }

    // MARK: - Server mode

    /// The server's answer for one scope — and, as a case of its own, that it gave none.
    /// "Couldn't ask" and "asked, nothing there" must never draw the same screen.
    private enum Answer {
        case idle
        case looking
        case failed(String)
        case answered(ProductSearchResponse)

        var response: ProductSearchResponse? {
            if case .answered(let response) = self { return response }
            return nil
        }
    }

    /// The last server search: the query and the reach the answer is for, and the answer.
    private struct Served {
        var query = ShopQuery()
        var reach = ShopAsk.Reach()
        var answer: Answer = .idle
    }

    @State private var served = Served()
    /// "More from my brands" and "Only my brands" — the two chips that change where the one
    /// list looks and how far your own shops are lifted in it. Cleared with the field, like the
    /// others; only one is ever on.
    @State private var moreFromMine = false
    @State private var onlyMine = false
    @State private var isShowingSort = false
    @State private var viewing: DiscoverCard?
    @State private var isLoadingMore = false

    // MARK: - Asking Dropwall

    /// The paid thread, when one is open. While it has a reading, that reading — not the
    /// field's text — is what the page searches and prints.
    @State private var ask = ShopAsk()
    /// The query the last answer from the model already holds results for, so the search the
    /// new reading sets off does not ask the server a second time for the same page.
    @State private var primed: ShopQuery?
    @State private var primedReach: ShopAsk.Reach?
    /// Where each of the thread's results sits once taste has ordered it, by product key —
    /// worked out once per change in a `.task`, never per body, and only ever appended to
    /// within one query, so a MORE page never moves what is already on screen.
    @State private var tasteRank: [String: Int] = [:]
    @State private var tasteRankQuery = ""
    /// A shop from the open web somebody wants to follow, by host — the ordinary site check.
    @State private var addingShop: AddingShop?

    private struct AddingShop: Identifiable {
        var host: String
        var id: String { host }
    }

    /// In server mode the field searches the catalogue the server holds; standalone, the
    /// products on this phone, exactly as before.
    private var isServer: Bool { settings.isConfigured }

    // MARK: - Keys

    /// When the store may have moved under the index: a sync landed, or the app came back.
    /// The catalogue's own stamp decides whether anything is actually re-read.
    private struct CatalogueKey: Equatable {
        var remote: Date?
        var local: Date?
        var isActive: Bool
        var gender: GenderPreference
    }

    private struct SearchKey: Equatable {
        var text: String
        var cheaper: Bool
        var formal: Bool
        var inMySize: Bool
        var catalogue: Int
        var profile: SizeProfile
        var server: Bool
        var token: String?
        var reach: ShopAsk.Reach
        /// The model's reading, while a thread has one.
        var asked: String?
    }

    private struct WordingKey: Equatable {
        var picks: [String]
        var day: String
        var isAvailable: Bool
    }

    /// What the thread's taste order is worked out again on.
    private struct TasteKey: Equatable {
        var query: String
        var hits: [String]
        var saves: Int
        var newestSave: Date?
        var statement: String
    }

    /// Everything the picks read, as scalars — nothing here classifies or faults a
    /// relationship, so evaluating it on every body costs a walk over the saves' own fields.
    private struct PicksKey: Equatable {
        var catalogue: Int
        var saves: Int
        var wardrobe: Int
        var newestSave: Date?
        var taste: TasteScope
        var statement: String
        var profile: SizeProfile
        var dismissals: Int
        var refusals: Int
        var day: String
    }

    private func picksKey(day: String) -> PicksKey {
        var wardrobe = 0
        var newest: Date?
        for save in saves {
            if save.type == .wardrobe { wardrobe += 1 }
            if newest.map({ save.savedAt > $0 }) ?? true { newest = save.savedAt }
        }
        return PicksKey(
            catalogue: catalogue.version,
            saves: saves.count,
            wardrobe: wardrobe,
            newestSave: newest,
            taste: TasteScope(boards: tasteBoards, saves: saves),
            statement: statement.statement.text,
            profile: sizes.profile,
            dismissals: dismissals.count,
            refusals: refusals,
            day: day
        )
    }

    private var isSearching: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the chips say the one list looks.
    private var reach: ShopAsk.Reach {
        onlyMine
            ? ShopAsk.Reach(scope: .followed, boost: nil)
            : ShopAsk.Reach(scope: .all, boost: moreFromMine ? .more : .standard)
    }

    // MARK: - Body

    var body: some View {
        // Read once per body: the day the picks belong to. `scenePhase` is read too, so coming
        // back to the app after midnight re-evaluates this and tomorrow's set arrives.
        let day = DailyPicks.day(of: Date())
        let profile = sizes.profile

        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        field
                        if isSearching {
                            if isServer {
                                serverResults(profile: profile)
                                // The open web: at the end of a thread's results, and on its
                                // own under a free search that found little. Always its own
                                // tap, at its own price.
                                if ai.offersWebSearch, ask.reading != nil || foundLittle {
                                    ShowMoreSection(ask: ask, query: served.query.text) { item in
                                        if let host = item.url.host() { addingShop = AddingShop(host: host) }
                                    }
                                }
                            } else {
                                results(profile: profile)
                            }
                        } else {
                            // Once, before the first search: what the field takes.
                            PaperTip(tip: ShopSearchTip(scans: ai.isAvailable))
                                .padding(.horizontal, 20)
                                .padding(.bottom, 22)
                            picksSection(day: day)
                            discoverEntry
                        }
                    }
                    // Clear of the floating tab bar, which covers the last eighty points.
                    .padding(.bottom, 110)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(Color.paper)
                .navigationTitle("Shop")
                .toolbarTitleDisplayMode(.inlineLarge)
                .youButton()
                .appDestinations()
            }
            .tint(.ink)
            .accessibilityHidden(isBrowsing)

            if isBrowsing {
                deck
            }
        }
        // The deck's foot is near-black and the tab bar takes its material from what is
        // behind it — the reason the old Discover tab set this. Only while it is open.
        .toolbarColorScheme(isBrowsing ? .dark : nil, for: .tabBar)
        .animation(.easeInOut(duration: 0.28), value: isBrowsing)
        .task(id: CatalogueKey(
            remote: remote.lastSyncedAt,
            local: engine.lastSyncedAt,
            isActive: scenePhase == .active,
            gender: profile.gender
        )) {
            await catalogue.refreshIfNeeded(in: context, profile: sizes.profile)
        }
        .task(id: SearchKey(
            text: text,
            cheaper: cheaper,
            formal: formal,
            inMySize: inMySize,
            catalogue: catalogue.version,
            profile: profile,
            server: isServer,
            // An authenticated route on first launch keys on the token — see `DiscoverFeedView`.
            token: settings.token,
            reach: reach,
            asked: ask.reading?.query
        )) {
            await search()
        }
        .task(id: tasteKey) {
            orderByTaste()
        }
        .task(id: picksKey(day: day)) {
            await choosePicks(day: day)
        }
        // After the set is chosen, and again once the server says whether it has a model.
        .task(id: WordingKey(picks: picks.map(\.id), day: day, isAvailable: ai.isAvailable)) {
            await wordPicks(day: day)
        }
        #if DEBUG
        // Screenshot affordance: `-shopQuery "<text>"` types a description into the field at
        // launch, so a search and its reading can be shot without driving the keyboard.
        .task {
            if text.isEmpty, let typed = UserDefaults.standard.string(forKey: "shopQuery"), !typed.isEmpty {
                text = typed
            }
        }
        #endif
        // A multi-line field so a long description wraps where it can be read, which makes
        // return a newline — so a newline is taken as "done", the way the keyboard's own
        // Search key reads.
        .onChange(of: text) { _, typed in
            // A thread is about the description that opened it: rewriting the description is
            // a new question, and the free search answers it until somebody asks again.
            if let opening = ask.opening, typed.trimmingCharacters(in: .whitespacesAndNewlines) != opening {
                ask.end()
            }
            guard typed.contains("\n") else { return }
            text = typed.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            isWriting = false
        }
        // Clearing the field clears what refined it: chips left on from a search about
        // trousers would silently narrow the next one about shoes.
        .onChange(of: isSearching) { _, searching in
            if !searching { cheaper = false; formal = false; inMySize = false; moreFromMine = false; onlyMine = false; ask.end() }
        }
        // "Follow this shop" on a page from the open web: the ordinary add flow, which searches
        // the catalogue first and only then checks the site.
        .sheet(item: $addingShop) { shop in
            AddBrandView(prefill: shop.host)
        }
        .sheet(item: $fitting) { pick in
            FitCanvas(fit: nil, starting: .around(.product(pick.update), anchor: pick.partner?.pairingID))
        }
        // A server result has no row on this phone and must not be given one to be looked at,
        // so it opens the page the deck's cards open — `DiscoverProductSheet`'s reason.
        .sheet(item: $viewing) { card in
            DiscoverProductSheet(
                card: card,
                isSaved: savedKeys.contains(card.productExternalID),
                onSave: { save(card) }
            )
        }
        .sheet(isPresented: $isShowingSort) {
            HowWeSortNote(answer: served.answer.response)
        }
    }

    // MARK: - The field

    /// The reader's own currency sign in the example, when it is one the grammar reads as a
    /// price (`Lexer.currencySymbols` in `ShopQuery.swift`); otherwise "$". A euro in front of
    /// somebody shopping in dollars reads as a shop in the wrong country, and an example that
    /// does not parse — "CHF400" would be a name — teaches the wrong thing.
    private static let promptCurrency: String = {
        guard let symbol = Locale.current.currencySymbol, symbol.count == 1,
              ["€", "$", "£", "¥"].contains(symbol) else { return "$" }
        return symbol
    }()

    /// The box, and nothing around it: what is being searched is said once, by the status line
    /// under it, from the answer (`statusLine`). The label above it and the scope line below it
    /// were two of the nine rows above the first product.
    private var field: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ink)
            TextField(
                "",
                text: $text,
                prompt: Text("A black suit under \(Self.promptCurrency)400").foregroundStyle(Color.muted),
                axis: .vertical
            )
            .font(.editorial(17))
            .foregroundStyle(Color.ink)
            .lineLimit(1...3)
            .focused($isWriting)
            .submitLabel(.search)
            // Shop names and model numbers are the words most worth typing and the ones
            // autocorrect is surest are mistakes.
            .autocorrectionDisabled()
            trailingControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .overlay(Rectangle().stroke(isWriting ? Color.ink : Color.hairline, lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    /// The controls at the field's trailing edge, in one row of their own. Anything else that
    /// belongs to the field — the scan's camera — goes in this row, after the clear button.
    private var trailingControls: some View {
        HStack(spacing: 12) {
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.muted)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear")
            }
            // The scan, with "find this" landing here — the reading's words become the
            // description, searched like anything typed. Draws nothing where AI is off.
            ScanButton(side: 28) { found in
                text = found
                isWriting = false
            }
        }
    }

    // MARK: - Above the results: one line, one row of chips

    /// **What was searched, in one sentence** — and, in a thread, that it was AI and what it
    /// cost. Printed from the answer, never from the chips, so the scope is always the one that
    /// was searched. How we sort is the ⓘ at its end; the × leaves a thread.
    ///
    /// This one line replaced four: the scope under the field, "ASKED DROPWALL · AI", the charge,
    /// and "18 MATCHES IN EVERY SHOP WE WATCH · HOW WE SORT".
    private func statusLine(_ sentence: String, sorts: Bool = false, isWorking: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if isWorking {
                ProgressView().controlSize(.mini).tint(.muted)
            }
            if sorts {
                // The sentence and its ⓘ are one control: the ⓘ is set inline, so it ends the
                // sentence on whichever line the sentence ends.
                Button { isShowingSort = true } label: {
                    (Text(sentence) + Text("  ") + Text(Image(systemName: "info.circle")))
                        .font(.editorial(15))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Shows how we sort")
            } else {
                Text(sentence)
                    .font(.editorial(15))
                    .foregroundStyle(isWorking ? Color.muted : Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if ask.isOpen {
                Button { ask.end() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.muted)
                        .frame(width: 30, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Leave the AI search")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// **One row of chips**: the offer to ask (server mode, where there is a model), the model's
    /// suggested replies while a thread is open, then the grammar's filters and the two that
    /// change where the one list looks. A suggestion that names a filter is left out — the
    /// filter is the same thing, free, and "Cheaper" appeared twice.
    ///
    /// The flags the words alone set are read off the text, so a chip can tell a word in the
    /// field from its own state — parsing is microseconds; it is the search that waits for the
    /// typing to settle.
    private var chips: some View {
        let typed = ShopQuery.parse(text)
        let filters = isServer
            ? ["Cheaper", "More formal", "In my size", "More from my brands", "Only my brands"]
            : ["Cheaper", "More formal", "In my size"]
        let suggestions = (ask.reading?.suggestions ?? []).filter { suggestion in
            !filters.contains { $0.caseInsensitiveCompare(suggestion.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if isServer, ai.isAvailable, !ask.isOpen {
                    AskChip {
                        let opening = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        isWriting = false
                        runAsk { await ask.ask(opening, inMySize: inMySize, reach: reach, via: ai) }
                    }
                }
                ForEach(suggestions, id: \.self) { suggestion in
                    SuggestionChip(title: suggestion) {
                        runAsk { await ask.reply(suggestion, inMySize: inMySize, reach: reach, via: ai) }
                    }
                    .disabled(ask.isAsking)
                }
                ShopChip(title: "Cheaper", isOn: cheaper || typed.cheaper, isTyped: typed.cheaper) { cheaper.toggle() }
                ShopChip(title: "More formal", isOn: formal || typed.formal, isTyped: typed.formal) { formal.toggle() }
                ShopChip(title: "In my size", isOn: inMySize || typed.inMySize, isTyped: typed.inMySize) { inMySize.toggle() }
                // Where the one list looks, server mode only: standalone searches nothing but
                // your shops already. One at a time — lifting your shops in a list of nothing
                // else would be a chip that does nothing.
                if isServer {
                    ShopChip(title: "More from my brands", isOn: moreFromMine) {
                        moreFromMine.toggle()
                        if moreFromMine { onlyMine = false }
                    }
                    ShopChip(title: "Only my brands", isOn: onlyMine) {
                        onlyMine.toggle()
                        if onlyMine { moreFromMine = false }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 14)
    }

    /// The thread's reply field, compact, only while a thread has a reading to reply to.
    @ViewBuilder
    private var replyField: some View {
        if ask.isOpen, ask.reading != nil {
            AskReplyField(ask: ask) { reply in
                runAsk { await ask.reply(reply, inMySize: inMySize, reach: reach, via: ai) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(profile: SizeProfile) -> some View {
        let query = found.query
        let result = found.result

        if catalogue.phase != .ready {
            statusLine("Reading your shops…", isWorking: true)
        } else if catalogue.shops == 0 {
            emptyState(title: "You don't follow any shops yet", action: "Follow one to search it.")
        } else if catalogue.index.listings.isEmpty {
            emptyState(title: "Nothing from your shops yet", action: "It arrives with the next sync.")
        } else if query.text.isEmpty {
            // Typed, not yet settled. The previous answer, if any, stays rather than blinking.
            statusLine("Looking…", isWorking: true)
        } else {
            switch result.outcome {
            case .found, .closest:
                statusLine(summary(total: result.total, shown: result.exact.count, isCapped: false, place: .phone))
            default:
                EmptyView()
            }
            chips
            readingNote(query: query, unknown: result.unknown, cheaperThan: result.cheaperThan, outcome: result.outcome, place: .phone)
            switch result.outcome {
            case .found, .closest:
                VStack(alignment: .leading, spacing: 0) {
                    grid(result.exact)
                    if !result.partial.isEmpty {
                        if !result.exact.isEmpty { partlyMatching }
                        grid(result.partial)
                    }
                }
            default:
                failure(result.outcome, query: query, profile: profile, place: .phone, searched: catalogue.shown)
            }
        }
    }

    /// Where a search looked, in the words the screen uses for it. Every line that names the
    /// scope reads it from here, so a server answer never says "on this phone" and the
    /// phone's never claims more than it holds.
    private enum Place {
        /// Standalone: the products from your shops on this phone.
        case phone
        /// Server mode, "Only my brands": every product the server holds for your shops.
        case yourShops
        /// Server mode: every shop the server watches, yours lifted.
        case everyShop

        init(_ scope: ProductSearchScope) {
            self = scope == .followed ? .yourShops : .everyShop
        }

        /// "in your shops", as a sentence's ending.
        var phrase: String {
            switch self {
            case .phone: "in your shops on this phone"
            case .yourShops: "in your shops"
            case .everyShop: "in every shop we watch"
            }
        }

        /// What a search that found no product saying the word looked through.
        func searched(_ count: Int) -> String {
            "\(count.formatted()) \(count == 1 ? "product" : "products") searched. Try another word."
        }
    }

    /// **What the grammar did, said only where it differs from what was typed** — a word no
    /// product carries, a bound read as a price, a size it does not read, and in a thread the
    /// model's own reading of the description. A reading that only repeats the field in capitals
    /// ("BLACK · TROUSERS · UNDER 200") said nothing, and was a row above the first product.
    @ViewBuilder
    private func readingNote(
        query: ShopQuery,
        unknown: [String],
        cheaperThan: Double?,
        outcome: ShopSearch.Outcome,
        place: Place,
        byMeaning: Bool = false
    ) -> some View {
        let lines = readingLines(query: query, unknown: unknown, cheaperThan: cheaperThan, outcome: outcome, byMeaning: byMeaning)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { NoteLine(text: $0) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    private func readingLines(
        query: ShopQuery,
        unknown: [String],
        cheaperThan: Double?,
        outcome: ShopSearch.Outcome,
        byMeaning: Bool
    ) -> [String] {
        var lines: [String] = []
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model's reading is what the page searched, so it is said whenever it is not the
        // description as typed.
        if let asked = ask.reading?.query, asked.caseInsensitiveCompare(typed) != .orderedSame {
            lines.append("Searched for “\(asked)”.")
        }
        // Set aside, and said: the search went on without these rather than returning nothing
        // because one word of a sentence is in no product title. Not when every word was
        // unknown — the empty state under this says exactly that, larger. Where the answer was
        // also compared by meaning, the word still shaped it, and "ignored" would be untrue.
        if !unknown.isEmpty, outcome != .notInYourShops(unknown) {
            let words = quoted(unknown)
            let pronoun = unknown.count == 1 ? "it" : "them"
            lines.append(byMeaning
                ? "Looked for \(words) by meaning: no product names \(pronoun)."
                : "Ignored \(words): no product mentions \(pronoun).")
        }
        if query.reading.contains("cheaper"), let middle = cheaperThan {
            lines.append("Cheaper means under \(ShopQuery.amount(middle)).")
        }
        if !query.ignored.isEmpty {
            lines.append("\(quoted(query.ignored)) isn't read — In my size is.")
        }
        return lines
    }

    /// Which constraint emptied the list — the same six answers wherever the search ran.
    @ViewBuilder
    private func failure(_ outcome: ShopSearch.Outcome, query: ShopQuery, profile: SizeProfile, place: Place, searched: Int) -> some View {
        switch outcome {
        case .found, .closest:
            EmptyView()
        case .nothingToSearch:
            emptyState(title: "Nothing to search for", action: "Name a garment, a colour or a price.")
        case .notInYourShops(let words):
            emptyState(title: "No \(quoted(words)) \(place.phrase)", action: place.searched(searched))
        case .allRuledOut(let words):
            emptyState(
                title: "Everything that matched is \(words.joined(separator: " or "))",
                action: "Take out \(words.map { "“no \($0)”" }.joined(separator: ", ")) to see them."
            )
        case .hiddenByFilter(let count):
            emptyState(
                title: "\(matches(count)), all hidden by your filter",
                action: "You're seeing \(profile.gender.label.lowercased()) only. Change it in You › Sizes."
            )
        case .outsidePrice(let count, let cheapest):
            emptyState(
                title: "\(matches(count)), none \(bound(of: query))",
                action: cheapest.map { "The cheapest is \(ShopQuery.amount($0))." } ?? "None of them has a price."
            )
        case .noSizes:
            emptyState(title: "Your sizes aren't set", action: "Add them in You › Sizes.")
        case .noneInYourSize(let count):
            emptyState(title: "\(matches(count)), none in your size today", action: "Turn off In my size to see them.")
        }
    }

    private var partlyMatching: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rule()
            NoteLine(text: "Also partly matching", size: 15, color: .ink)
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 16)
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 14, alignment: .top),
            GridItem(.flexible(), alignment: .top)
        ]
    }

    private func grid(_ hits: [ShopSearch.Hit]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
            ForEach(hits) { hit in
                if let update = catalogue.row(hit.id) {
                    ShopResultTile(
                        update: update,
                        matched: hit.isExact ? nil : hit.matched,
                        isAvailable: hit.listing.isAvailable
                    )
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// "18 matches in every shop we watch." — the count and the scope, as one sentence.
    private func summary(total: Int, shown: Int, isCapped: Bool, place: Place) -> String {
        guard shown > 0 else { return "Nothing has all of it, so the closest come first." }
        // "200+": the server's candidates reached their bound, so the count is a floor.
        let count = isCapped ? "\(total.formatted())+ matches" : (total == 1 ? "1 match" : "\(total.formatted()) matches")
        return "\(count) \(place.phrase)."
    }

    private func matches(_ count: Int) -> String {
        count == 1 ? "1 matches" : "\(count.formatted()) match"
    }

    private func quoted(_ words: [String]) -> String {
        words.map { "“\($0)”" }.joined(separator: " or ")
    }

    private func bound(of query: ShopQuery) -> String {
        switch (query.floor, query.ceiling) {
        case let (low?, high?): return "between \(ShopQuery.amount(low)) and \(ShopQuery.amount(high))"
        case let (nil, high?): return "under \(ShopQuery.amount(high))"
        case let (low?, nil): return "over \(ShopQuery.amount(low))"
        case (nil, nil): return "at that price"
        }
    }

    private func emptyState(title: String, action: String) -> some View {
        EditorialEmptyState(title: title, action: action)
            .padding(.top, 36)
            .padding(.bottom, 24)
    }

    private func reading(label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).tint(.muted)
            NoteLine(text: label)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// Runs the search the field and chips describe, once the typing has settled.
    private func search() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            found = Found()
            served = Served()
            return
        }
        // While a thread has a reading, the reading is the search: what the model understood,
        // in the grammar, which the server searches and the page prints exactly as if typed.
        let source = isServer ? (ask.reading?.query ?? trimmed) : trimmed
        // A pause before reading a sentence still being typed. A chip, or the index landing,
        // changes no text and answers at once.
        let answered = isServer ? served.query.text : found.query.text
        if answered != source {
            try? await Task.sleep(for: .milliseconds(isServer ? 400 : 250))
            guard !Task.isCancelled else { return }
        }
        let query = ShopQuery.parse(source).refined(cheaper: cheaper, formal: formal, inMySize: inMySize)
        if isServer {
            // The model's answer carried this page already.
            if let primed, primed == query, primedReach == reach {
                self.primed = nil
                self.primedReach = nil
                return
            }
            await searchServer(query)
            return
        }
        guard catalogue.phase == .ready else { return }
        let profile = sizes.profile
        let result = ShopSearch.run(
            query,
            in: catalogue.index,
            hasSizes: !profile.isEmpty,
            fits: { catalogue.fits($0, profile: profile) }
        )
        found = Found(query: query, result: result)
    }

    // MARK: - Searching on the server

    /// One list over every shop the server watches, your own lifted — or, with "Only my
    /// brands", your shops alone.
    ///
    /// The previous answer stays on screen while the next is asked for, the local search's
    /// rule, and a request that fails says it failed — never "no results", which would be a
    /// claim about the catalogue made by a search that did not run.
    private func searchServer(_ query: ShopQuery) async {
        if served.answer.response == nil { served.answer = .looking }
        let reach = reach
        let answer = await ask(query, reach: reach)
        guard !Task.isCancelled else { return }
        served = Served(query: query, reach: reach, answer: answer)
    }

    private func ask(_ query: ShopQuery, reach: ShopAsk.Reach, cursor: String? = nil) async -> Answer {
        do {
            // The text as typed, and the chips as their own flags: the server parses the text
            // with the same `ShopQuery`, so the words set the same flags there as here.
            let response = try await remote.searchProducts(
                query.text, scope: reach.scope, cheaper: cheaper, formal: formal, inMySize: inMySize,
                boost: reach.boost, meaning: true, cursor: cursor
            )
            return .answered(response)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The next page of exact matches, appended.
    private func loadMore() async {
        guard !isLoadingMore, let response = served.answer.response, let cursor = response.nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let query = served.query
        let reach = served.reach
        guard case .answered(let page) = await ask(query, reach: reach, cursor: cursor),
              served.query == query, served.reach == reach else { return }
        var merged = response
        merged.exact += page.exact
        merged.nextCursor = page.nextCursor
        served.answer = .answered(merged)
    }

    /// The catalogue had little to say — few results, or none — which is when the open web is
    /// offered without a thread having been asked first.
    private var foundLittle: Bool {
        guard ask.reading == nil, let response = served.answer.response, response.shops > 0 else { return false }
        switch response.outcome {
        case .found, .closest: return response.exact.count + response.partial.count < Self.littleBelow
        case .notInYourShops: return true
        default: return false
        }
    }

    /// Fewer results than this, and the open web is offered on its own. Under one screen of
    /// the grid: past that, the catalogue has answered.
    static let littleBelow = 6

    /// The server's answer, in the order the page reads: the model's reply, the one status line,
    /// the one chip row, the reply field, what the grammar did when it differs, and the results.
    @ViewBuilder
    private func serverResults(profile: SizeProfile) -> some View {
        if let reply = ask.reading?.reply, !reply.isEmpty, !ask.isAsking {
            Text(reply)
                .font(.editorial(17))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }

        if ask.isAsking {
            statusLine("Asking Dropwall's AI…", isWorking: true)
        } else if let refusal = ask.refusal {
            AIRefusalNotice(refusal: refusal) {
                runAsk { await ask.retry(inMySize: inMySize, reach: reach, via: ai) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }

        switch served.answer {
        case .idle, .looking:
            if !ask.isAsking {
                statusLine(onlyMine ? "Searching your shops…" : "Searching every shop we watch…", isWorking: true)
            }
            chips
        case .failed(let message):
            chips
            didNotRun(message)
        case .answered(let response):
            let place = Place(response.scope)
            if response.shops == 0 {
                chips
                // Only "Only my brands" can get here: every shop is never no shops.
                emptyState(title: "You don't follow any shops yet", action: "Turn off Only my brands to search every shop.")
            } else {
                if !ask.isAsking, [.found, .closest].contains(response.outcome) {
                    statusLine(threadSentence(response, place: place), sorts: true)
                }
                chips
                replyField
                readingNote(
                    query: served.query,
                    unknown: response.unknown,
                    cheaperThan: response.cheaperThan,
                    outcome: response.outcome,
                    place: place,
                    byMeaning: response.exact.contains { $0.byMeaning == true }
                )
                answered(response, place: place, profile: profile)
            }
        }
    }

    /// The status sentence for an answer: the count and the scope, and — when a thread asked
    /// for it — that it was AI and what this turn cost.
    private func threadSentence(_ response: ProductSearchResponse, place: Place) -> String {
        let exact = response.exact.count
        let found = summary(total: response.total, shown: exact, isCapped: response.isCapped, place: place)
        guard ask.reading != nil, let charge = ask.charge else { return found }
        let cost: String
        if charge.credits == 0 {
            cost = charge.balance == nil ? "at no charge" : "free, as a reply"
        } else {
            cost = "for " + AIStore.creditsLabel(charge.credits)
        }
        guard exact > 0 else { return "AI search, \(cost). " + found }
        let count = response.isCapped ? "\(response.total.formatted())+" : response.total.formatted()
        let noun = response.total == 1 && !response.isCapped ? "match" : "matches"
        return "AI found \(count) \(noun) \(place.phrase), \(cost)."
    }

    /// A search that did not run, said as one — and the way to run it again.
    private func didNotRun(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            emptyState(title: "The search didn't run", action: "Couldn't reach Dropwall: \(message)")
            Button {
                let source = ask.reading?.query ?? text
                Task { await searchServer(ShopQuery.parse(source).refined(cheaper: cheaper, formal: formal, inMySize: inMySize)) }
            } label: {
                NotificationsSection.SettingsAction(title: "Try again")
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
    }

    /// One server answer: the main list, the partial matches, a way to the next page — or
    /// which constraint emptied it.
    @ViewBuilder
    private func answered(_ response: ProductSearchResponse, place: Place, profile: SizeProfile) -> some View {
        let saved = savedKeys
        let exact = byTaste(response.exact)
        let partial = byTaste(response.partial)
        switch response.outcome {
        case .found, .closest:
            if exact.isEmpty, partial.isEmpty {
                NoteLine(text: "Nothing \(place.phrase).")
                    .padding(.horizontal, 20)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    cardGrid(exact, saved: saved)
                    if response.nextCursor != nil {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack(spacing: 8) {
                                if isLoadingMore { ProgressView().controlSize(.mini).tint(.muted) }
                                NotificationsSection.SettingsAction(title: "More")
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 12)
                    }
                    if !partial.isEmpty {
                        if !exact.isEmpty { partlyMatching }
                        cardGrid(partial, saved: saved)
                    }
                }
            }
        default:
            failure(response.outcome, query: served.query, profile: profile, place: place, searched: response.searched)
        }
    }

    private func cardGrid(_ hits: [ProductSearchHit], saved: Set<String>) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
            ForEach(hits) { hit in
                ShopCardTile(
                    card: hit.card,
                    matched: hit.matched,
                    byMeaning: hit.byMeaning == true,
                    isSaved: saved.contains(hit.card.productExternalID),
                    onSave: { save(hit.card) },
                    onOpen: { viewing = hit.card }
                )
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Asking Dropwall

    /// Runs one turn, then hands its results to the page as the answer for its own reading —
    /// when the chips on screen add nothing the model's request did not carry, which is the
    /// only case in which they are the same page.
    private func runAsk(_ turn: @escaping @MainActor () async -> Void) {
        let sent = reach
        Task {
            await turn()
            guard let reading = ask.reading, let results = ask.results, sent == reach else { return }
            let asked = ShopQuery.parse(reading.query)
            let query = asked.refined(cheaper: cheaper, formal: formal, inMySize: inMySize)
            guard query == asked.refined(cheaper: false, formal: false, inMySize: inMySize) else { return }
            served = Served(query: query, reach: sent, answer: .answered(results))
            primed = query
            primedReach = sent
        }
    }

    /// A thread's answer, ordered by what you own (`TasteOrder`) — the phone's half of "ranked
    /// by taste", because the wardrobe never leaves it. The free search keeps the server's own
    /// order: it is the same answer on both ends.
    private func byTaste(_ hits: [ProductSearchHit]) -> [ProductSearchHit] {
        guard ask.reading != nil, !tasteRank.isEmpty else { return hits }
        return hits.enumerated()
            .sorted { a, b in
                let one = tasteRank[a.element.id] ?? Int.max
                let other = tasteRank[b.element.id] ?? Int.max
                return one == other ? a.offset < b.offset : one < other
            }
            .map(\.element)
    }

    private var tasteKey: TasteKey {
        let response = ask.reading == nil ? nil : served.answer.response
        return TasteKey(
            query: served.query.text,
            hits: response.map { ($0.exact + $0.partial).map(\.id) } ?? [],
            saves: saves.count,
            newestSave: saves.first?.savedAt,
            statement: statement.statement.text
        )
    }

    /// Ranks what has arrived and is not ranked yet, after everything that is — so a MORE page
    /// takes its place below the cards already read and never reshuffles them.
    private func orderByTaste() {
        let key = tasteKey
        if key.query != tasteRankQuery {
            tasteRank = [:]
            tasteRankQuery = key.query
        }
        guard let response = served.answer.response, !key.hits.isEmpty else { return }
        let fresh = (response.exact + response.partial).filter { tasteRank[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        // The same pool the picks pair against: the wardrobe whatever its taste setting, or
        // every save that counts for somebody who never filed anything as owned.
        let wardrobe = TasteScope(boards: tasteBoards, saves: saves).pairingPool(saves).compactMap(\.update).map(\.garment)
        let ordered = TasteOrder.order(
            fresh,
            wardrobe: wardrobe,
            statement: statement.statement,
            garment: \.card.garment,
            isAvailable: { hit in
                let variants = hit.card.variants ?? []
                return variants.isEmpty ? (hit.card.isAvailable ?? true) : variants.contains(where: \.available)
            }
        )
        var next = tasteRank
        var position = (next.values.max() ?? -1) + 1
        for hit in ordered {
            next[hit.id] = position
            position += 1
        }
        tasteRank = next
    }

    /// Product keys already in the collection, for the bookmark on a card with no row.
    private var savedKeys: Set<String> {
        var keys: Set<String> = []
        for update in saves.compactMap(\.update) {
            keys.insert(update.externalID)
            if let product = update.productExternalID { keys.insert(product) }
        }
        return keys
    }

    /// Keeps a server result — `DiscoverSave`, which lands it on the row the phone may already
    /// hold, and mints one only for this.
    private func save(_ card: DiscoverCard) {
        guard let update = DiscoverSave.save(card, in: context) else { return }
        confirmation.confirm(update, destination: SavedItem.SaveType.inspiration.label)
    }

    // MARK: - Picks

    @ViewBuilder
    private func picksSection(day: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today’s picks")
                .font(.editorial(24))
                .foregroundStyle(Color.ink)
            NoteLine(text: hasWardrobe
                ? "From your shops, for what you own. New ones tomorrow."
                : "From your shops. New ones tomorrow.")
            if picksSettled, !hasWardrobe, !picks.isEmpty {
                // Said once, here, rather than on every card: with nothing to pair against
                // the picks still work, and this is how they start arguing from your clothes.
                NoteLine(text: "Fill your Wardrobe and they pair with it.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)

        if catalogue.phase != .ready || !picksSettled {
            reading(label: "Choosing today’s picks…")
        } else if catalogue.shops == 0 {
            picksNote("Follow a few shops and picks start here.")
        } else if catalogue.index.listings.isEmpty {
            picksNote("Nothing yet. It arrives with the next sync.")
        } else if picks.isEmpty {
            picksNote("Nothing left to pick today.")
        } else {
            LazyVStack(alignment: .leading, spacing: 44) {
                ForEach(picks) { pick in
                    // A row deleted under the picks — a prune — is skipped, never read.
                    if !pick.update.isDeleted, pick.update.modelContext != nil {
                        ShopPickCard(
                            pick: pick,
                            worded: worded[pick.id],
                            onOpenFit: { fitting = pick },
                            onRefuse: { refuse(pick, day: day) }
                        )
                        .transition(.opacity)
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: picks.map(\.id))
        }
    }

    private func picksNote(_ text: String) -> some View {
        NoteLine(text: text, size: 16)
            .padding(.horizontal, 20)
    }

    private func refuse(_ pick: ShopPick, day: String) {
        PickLedger.refuse(pick.id, on: day)
        refusals += 1
    }

    /// Today's set, chosen by `TodaysPicks` from this view's own queries — the same choice a
    /// background pass makes for the morning alert, which is why it lives there.
    private func choosePicks(day: String) async {
        guard let chosen = await TodaysPicks.choose(
            day: day,
            catalogue: catalogue,
            saves: saves,
            tasteBoards: tasteBoards,
            dismissals: dismissals,
            profile: sizes.profile,
            statement: statement.statement
        ) else { return }
        picks = chosen.picks
        hasWardrobe = chosen.hasWardrobe
        picksSettled = true
        // On screen, so the morning alert has nothing left to say today.
        if !chosen.picks.isEmpty { PicksNotice.seen(on: day, scope: ProfileScope.active) }
    }

    /// The model's sentence for the top few, where the server has a model — kept for the day,
    /// so this asks once (`PickReasons`). Anything unanswered keeps the phone's own reason.
    private func wordPicks(day: String) async {
        let known = PickReasons.cached(on: day)
        if known != worded { worded = known }
        guard ai.isAvailable, !picks.isEmpty else { return }
        let answered = await PickReasons.load(for: picks, day: day, via: ai)
        guard !Task.isCancelled else { return }
        if answered != worded { worded = answered }
    }

    // MARK: - Discover

    /// The deck, one row under the picks.
    private var discoverEntry: some View {
        Button { isBrowsing = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                Rule()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("More from brands like yours")
                            .font(.editorial(19))
                            .foregroundStyle(Color.ink)
                        NoteLine(text: "Shops you don't follow yet.")
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.muted)
                }
            }
            .padding(.horizontal, 20)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .padding(.top, 44)
    }

    /// The Discover deck, drawn in place over this tab rather than presented as a cover.
    ///
    /// **In place, on purpose.** Everything a save raises — the confirmation, the board
    /// picker, the watch editor, the question before removing one — is hosted at the root of
    /// the app, and a full-screen cover sits above the root: saving from a deck in a cover
    /// would have confirmed nothing and its Board button would have opened nothing. And the
    /// deck was laid out for a tab bar at its foot (its reading clears one by hand), which a
    /// cover takes away. Drawn here, it is exactly the screen the Discover tab was — the same
    /// `DiscoverFeedView`, supply and rules untouched — with a way back to Shop.
    private var deck: some View {
        DiscoverFeedView()
            .overlay(alignment: .topTrailing) {
                Button { isBrowsing = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.sweepInk)
                        // Fixed sweep, like the deck's own chips: it sits on the card's ground,
                        // which does not invert. Small, and in the filter row, so it neither
                        // crowds the save circle on the card below nor covers a chip.
                        .frame(width: 28, height: 28)
                        .background(Color.sweep, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 8)
                .accessibilityLabel("Close Discover")
            }
            .transition(.move(edge: .bottom))
            .zIndex(1)
    }
}
