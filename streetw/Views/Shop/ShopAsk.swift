// ShopAsk.swift
// Asking Dropwall: the paid path beside Shop's free field.
//
// The field still searches by the grammar, for nothing, exactly as before. Asking is a second,
// explicit act — a row that says it is AI and what it costs — and what comes back is drawn in
// the free path's own words:
//
// - **The model reads; the server's own search finds.** The answer is a rewrite of the thread
//   into the `ShopQuery` grammar (`AISearchReading.query`), and Shop prints the phone's own
//   reading of *that* — the same line, struck words and all, that a typed search prints. What
//   was searched is visible and correctable, and the model never names a product.
// - **The thread is the phone's** (`ShopAsk`). Each reply sends the turns so far with the
//   server's signed token, and a reply inside a paid thread costs nothing. Once the token is
//   spent — six turns, or thirty minutes — a reply says it starts a new search, at its price,
//   before it is sent.
// - **Every action says what it cost**, from the answer's own `AICharge`: "1 CREDIT · 48 LEFT",
//   "NO CHARGE — PART OF THIS SEARCH".
// - **A refusal is said, never drawn as an empty list** (`AIRefusalNotice`).
//
// "Show me more" is the open web, worded as such, at its own price. A result from a shop the
// server watches opens or follows that shop; any other offers the ordinary site check.
// See `docs/ai.md` and `docs/discover.md` (*Shop*).

import StreetwCore
import SwiftData
import SwiftUI

/// One search thread, as the phone holds it.
@MainActor
@Observable
final class ShopAsk {
    /// "Show me more", which is asked separately and only when somebody asks.
    enum Web: Equatable {
        case idle
        case looking
        case answered([AIWebItem], AICharge)
        case refused(AIRefusal)
    }

    /// The description that opened the thread — the field's text when Ask was pressed. The
    /// thread ends when the field stops saying it.
    private(set) var opening: String?
    /// Every turn the server has answered, oldest first.
    private(set) var turns: [AISearchTurn] = []
    /// The latest reading, which is what the page searches and prints.
    private(set) var reading: AISearchReading?
    /// The latest turn's results, so the first draw needs no second request.
    private(set) var results: ProductSearchResponse?
    private(set) var turnsLeft = 0
    private(set) var isAsking = false
    private(set) var refusal: AIRefusal?
    /// What the last answered action took.
    private(set) var charge: AICharge?
    private(set) var web: Web = .idle
    /// The grammar text `web` answers — the thread's reading, or the field's own text when the
    /// open web was offered under a free search that found little.
    private(set) var webQuery: String?

    private var token: String?
    private var tokenIssuedAt: Date?
    /// The text of a turn that was refused, so "try again" sends exactly it.
    private var refusedText: String?

    /// How long a thread's token is good for — `AIThreadToken`'s thirty minutes, less a
    /// minute's margin, so a reply sent at 29:59 is not promised free and then charged.
    static let tokenLifetime: TimeInterval = 29 * 60

    var isOpen: Bool { opening != nil }

    /// The next reply continues this thread, free — rather than starting, and paying for, a
    /// new one.
    var continues: Bool {
        guard token != nil, turnsLeft > 0, let issued = tokenIssuedAt else { return false }
        return Date().timeIntervalSince(issued) < Self.tokenLifetime
    }

    /// Where a turn searches: the field's one list, or only your own shops — whatever the chips
    /// say when the turn is sent, so a thread answers with the list the free search would.
    struct Reach: Equatable {
        var scope: ProductSearchScope = .all
        var boost: FollowedBoost? = .standard
    }

    /// Opens a thread on the field's text.
    func ask(_ text: String, inMySize: Bool, reach: Reach, via ai: AIStore) async {
        opening = text
        turns = []
        reading = nil
        results = nil
        token = nil
        tokenIssuedAt = nil
        turnsLeft = 0
        charge = nil
        web = .idle
        webQuery = nil
        await send(text, inMySize: inMySize, reach: reach, via: ai)
    }

    /// A short reply, or a suggestion tapped.
    func reply(_ text: String, inMySize: Bool, reach: Reach, via ai: AIStore) async {
        guard isOpen, !isAsking else { return }
        await send(text, inMySize: inMySize, reach: reach, via: ai)
    }

    /// Sends the refused turn again — after signing in, buying credits, or a network blink.
    func retry(inMySize: Bool, reach: Reach, via ai: AIStore) async {
        guard let text = refusedText ?? opening else { return }
        await send(text, inMySize: inMySize, reach: reach, via: ai)
    }

    func end() {
        opening = nil
        turns = []
        reading = nil
        results = nil
        token = nil
        tokenIssuedAt = nil
        turnsLeft = 0
        isAsking = false
        refusal = nil
        refusedText = nil
        charge = nil
        web = .idle
        webQuery = nil
    }

    private func send(_ text: String, inMySize: Bool, reach: Reach, via ai: AIStore) async {
        isAsking = true
        refusal = nil
        defer { isAsking = false }

        var request: AISearchRequest
        if continues {
            request = AISearchRequest(text: text, thread: turns, threadToken: token, inMySize: inMySize)
        } else if let reading {
            // The token is spent: a new thread, which the server charges for. It opens on what
            // was understood so far plus the reply, so "no wool" still means no wool *suits* —
            // a reply on its own would be a search for nothing in particular.
            request = AISearchRequest(text: "\(reading.query) \(text)", inMySize: inMySize)
        } else {
            request = AISearchRequest(text: text, inMySize: inMySize)
        }
        // The same one list the field searches (Phase 5).
        request.scope = reach.scope
        request.boost = reach.boost
        request.meaning = true

        switch await ai.search(request) {
        case .success(let answer):
            // A new thread starts its own history.
            if request.threadToken == nil { turns = [] }
            turns.append(AISearchTurn(text: request.text, query: answer.reading.query))
            reading = answer.reading
            results = answer.results
            token = answer.threadToken
            tokenIssuedAt = Date()
            turnsLeft = answer.turnsLeft
            charge = answer.charge
            refusedText = nil
            // A new reading is a new question for the web too.
            web = .idle
            webQuery = nil
        case .failure(let why):
            refusal = why
            refusedText = text
        }
    }

    /// "Show me more": the latest reading — or, with no thread, the field's own text — asked of
    /// the open web in the reader's country.
    func showMore(_ fallback: String?, country: String?, via ai: AIStore) async {
        guard let query = reading?.query ?? fallback, !query.isEmpty, web != .looking else { return }
        webQuery = query
        web = .looking
        switch await ai.webSearch(AIWebSearchRequest(query: query, country: country)) {
        case .success(let answer):
            web = .answered(answer.items, answer.charge)
            charge = answer.charge
        case .failure(let why):
            web = .refused(why)
        }
    }
}

// MARK: - Pieces

/// The row that offers to ask — or, signed out, says what asking needs.
///
/// **It says AI and it says the price**, before anything is spent: a sparkle, because this is
/// the one place in Shop where a model is behind the answer, and "1 CREDIT" in the same line.
/// Signed out it is still drawn, as "Sign in to use", and takes you to sign-in — a feature that
/// silently does not exist for somebody is indistinguishable from one that is broken.
struct AskOffer: View {
    @Environment(AIStore.self) private var ai: AIStore
    @Environment(YouRoute.self) private var you: YouRoute

    let ask: () -> Void

    var body: some View {
        Button {
            if ai.isSignedIn { ask() } else { you.open() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask Dropwall")
                        .font(.editorial(17))
                        .foregroundStyle(Color.ink)
                    DataLabel(text: note, size: 9.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                DataLabel(
                    text: ai.isSignedIn ? (ai.costLabel(for: .search) ?? "CREDITS") : "SIGN IN TO USE",
                    size: 10,
                    color: .ink
                )
                .fixedSize()
            }
            // A `Button` centres a wrapped label; this page reads from the left edge.
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(Rectangle().stroke(Color.hairline, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityHint(ai.isSignedIn ? "Uses AI to read your description, then searches your shops" : "Opens sign-in")
    }

    private var note: String {
        ai.isSignedIn
            ? "AI READS YOUR DESCRIPTION, THEN SEARCHES EVERY SHOP WE WATCH · REPLIES IN THE SAME SEARCH ARE FREE"
            : "AI READS YOUR DESCRIPTION — CREDITS NEED AN ACCOUNT"
    }
}

/// What an action took, said once it has taken it.
struct ChargeLine: View {
    let charge: AICharge

    var body: some View {
        DataLabel(text: Self.text(charge), size: 9.5)
    }

    static func text(_ charge: AICharge) -> String {
        let left = charge.balance.map { " · \($0) LEFT" } ?? " · UNLIMITED ACCOUNT"
        if charge.credits == 0 {
            return charge.balance == nil ? "NO CHARGE · UNLIMITED ACCOUNT" : "NO CHARGE — PART OF THIS SEARCH\(left)"
        }
        return AIStore.creditsLabel(charge.credits) + left
    }
}

/// An AI action that did not run, said in words, with the one thing that fixes it.
///
/// For any AI surface — the scan uses it too. Sign-in and buying both open You, where sign-in
/// leads the page and the packs are under Credits.
struct AIRefusalNotice: View {
    @Environment(YouRoute.self) private var you: YouRoute

    let refusal: AIRefusal
    /// Offered for a failure the same press might get past.
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(refusal.title)
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
            DataLabel(text: refusal.detail, size: 9.5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 22) {
                if let remedy = refusal.remedy {
                    Button { you.open() } label: {
                        NotificationsSection.SettingsAction(title: remedy)
                    }
                    .buttonStyle(.borderless)
                }
                // Not for the cost cap: it is a month's limit, and the same press cannot pass it.
                if let retry, refusal != .costCap {
                    Button(action: retry) {
                        NotificationsSection.SettingsAction(title: "Try again")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The model's side of the conversation: what it said, what it offers next, and the field
/// that continues the thread.
struct AskThreadHeader: View {
    @Environment(AIStore.self) private var ai: AIStore

    let ask: ShopAsk
    let reply: (String) -> Void
    /// Sends the refused turn again.
    let retry: () -> Void
    let end: () -> Void

    @State private var draft = ""
    @FocusState private var isReplying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.ink)
                DataLabel(text: "ASKED DROPWALL · AI", size: 10, color: .ink)
                Spacer(minLength: 8)
                Button(action: end) {
                    DataLabel(text: "BACK TO SEARCH", size: 9.5)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
            }

            if let reply = ask.reading?.reply, !reply.isEmpty {
                Text(reply)
                    .font(.editorial(18))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let charge = ask.charge, !ask.isAsking {
                ChargeLine(charge: charge)
            }

            if ask.isAsking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(.muted)
                    DataLabel(text: "DROPWALL IS READING IT", size: 10)
                }
            } else if let refusal = ask.refusal {
                AIRefusalNotice(refusal: refusal, retry: retry)
            }

            if let suggestions = ask.reading?.suggestions, !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            SuggestionChip(title: suggestion) { send(suggestion) }
                                .disabled(ask.isAsking)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if ask.reading != nil { replyField }
        }
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField(
                    "",
                    text: $draft,
                    prompt: Text("Reply — “no wool”, “in navy”").foregroundStyle(Color.muted)
                )
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
                .focused($isReplying)
                .submitLabel(.send)
                .autocorrectionDisabled()
                .onSubmit { send(draft) }
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(trimmed.isEmpty ? Color.muted : Color.ink)
                }
                .buttonStyle(.borderless)
                .disabled(trimmed.isEmpty || ask.isAsking)
                .accessibilityLabel("Send reply")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(Rectangle().stroke(isReplying ? Color.ink : Color.hairline, lineWidth: 1))
            DataLabel(text: replyNote, size: 9.5)
        }
    }

    /// Said before the reply is sent, because it is the moment the price changes.
    private var replyNote: String {
        if ask.continues {
            let left = ask.turnsLeft
            return left == 1 ? "1 MORE REPLY IN THIS SEARCH · FREE" : "\(left) MORE REPLIES IN THIS SEARCH · FREE"
        }
        let price = ai.costLabel(for: .search) ?? "CREDITS"
        return "THIS SEARCH IS USED UP — A REPLY STARTS A NEW ONE · \(price)"
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        isReplying = false
        reply(text)
    }
}

/// A short reply the model offered, sent as the next turn when tapped. Outlined like the
/// grammar's chips, with an arrow rather than a check: it is a thing to say, not a switch.
private struct SuggestionChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.data(10, .medium))
                    .tracking(0.6)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(Capsule().stroke(Color.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Show me more

/// The open web, offered under everything the catalogue had, and drawn as a list of shops'
/// own pages — none of it is ours, so nothing is claimed that the page did not say.
struct ShowMoreSection: View {
    @Environment(AIStore.self) private var ai: AIStore
    @Environment(LocationSetting.self) private var location: LocationSetting

    let ask: ShopAsk
    /// The free search's grammar text, asked when no thread has a reading.
    var query: String?
    let followShop: (AIWebItem) -> Void

    /// The answer only while it is about what is on screen: a new search is a new question.
    private var web: ShopAsk.Web {
        ask.webQuery == (ask.reading?.query ?? query) ? ask.web : .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
                .padding(.bottom, 14)
            switch web {
            case .idle:
                offer
            case .looking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(.muted)
                    DataLabel(text: "LOOKING ON THE WEB", size: 10)
                }
            case .refused(let why):
                AIRefusalNotice(refusal: why) {
                    Task { await ask.showMore(query, country: location.country, via: ai) }
                }
            case .answered(let items, let charge):
                answered(items, charge: charge)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 36)
    }

    private var offer: some View {
        Button {
            Task { await ask.showMore(query, country: location.country, via: ai) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                        Text("Show me more")
                            .font(.editorial(17))
                    }
                    .foregroundStyle(Color.ink)
                    DataLabel(text: scopeNote, size: 10)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                DataLabel(text: ai.costLabel(for: .webSearch) ?? "CREDITS", size: 10, color: .ink)
                    .fixedSize()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }

    /// Which web, said before it is asked.
    private var scopeNote: String {
        let country = location.country.map { " THAT SELL IN \(LocationSetting.inSentence($0).uppercased())" } ?? ""
        return "AI SEARCHES THE OPEN WEB FOR SHOPS\(country) — BEYOND THE SHOPS WE WATCH"
    }

    @ViewBuilder
    private func answered(_ items: [AIWebItem], charge: AICharge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.ink)
                DataLabel(text: "ON THE WEB · FOUND BY AI", size: 10, color: .ink)
            }
            ChargeLine(charge: charge)
        }
        .padding(.bottom, 14)

        if items.isEmpty {
            Text("Nothing on the web that the search could stand behind")
                .font(.editorial(16))
                .foregroundStyle(Color.muted)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    WebResultRow(item: item, followShop: { followShop(item) })
                }
            }
        }
    }
}

/// One shop's page from the open web: it opens in Safari, and the shop is one tap from being
/// watched — opened, if Dropwall already watches it.
private struct WebResultRow: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let item: AIWebItem
    let followShop: () -> Void

    @State private var isFollowing = false
    @State private var failure: String?

    var body: some View {
        let followed = followedBrand
        VStack(alignment: .leading, spacing: 10) {
            Button { openURL(item.url) } label: {
                HStack(alignment: .top, spacing: 12) {
                    UpdateImage(url: item.imageURL, aspect: 1, drawnWidth: 120, mark: item.shop)
                        .frame(width: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title)
                            .font(.editorial(15))
                            .foregroundStyle(Color.ink)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Wordmark(name: item.shop, size: 10)
                        HStack(spacing: 6) {
                            if let price = PriceFormat.text(amount: item.price, currency: item.currency) {
                                Text(price)
                                    .font(.data(11, .medium))
                                    .foregroundStyle(Color.ink)
                            }
                            DataLabel(text: (item.url.host() ?? "").uppercased(), size: 9)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.muted)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens the shop's page in Safari")

            HStack(spacing: 8) {
                if let followed {
                    NavigationLink(value: BrandRoute(brand: followed)) {
                        DataLabel(text: "YOU FOLLOW \(followed.name.uppercased()) · OPEN", size: 9.5, color: .ink)
                            .frame(minHeight: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else if item.brandID != nil {
                    Button { follow() } label: {
                        HStack(spacing: 6) {
                            if isFollowing { ProgressView().controlSize(.mini).tint(.muted) }
                            DataLabel(text: "DROPWALL WATCHES THIS SHOP · FOLLOW IT", size: 9.5, color: .ink)
                        }
                        .frame(minHeight: 32)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isFollowing)
                } else {
                    Button(action: followShop) {
                        DataLabel(text: "FOLLOW THIS SHOP", size: 9.5, color: .ink)
                            .frame(minHeight: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let failure {
                DataLabel(text: failure.uppercased(), size: 9, color: .signal)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rule() }
    }

    /// The followed brand the server says this is, by its remote id. One indexed fetch; a list
    /// of a dozen rows asks it a dozen times, once per body.
    private var followedBrand: Brand? {
        guard let id = item.brandID else { return nil }
        var descriptor = FetchDescriptor<Brand>(predicate: #Predicate { $0.remoteID == id && $0.followed })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Follows a shop the server already watches, then syncs so its row and its news arrive.
    private func follow() {
        guard let id = item.brandID else { return }
        Task {
            isFollowing = true
            failure = nil
            do {
                try await remote.follow(brandID: id)
                _ = await remote.sync(sizes: sizes.profile)
            } catch {
                failure = error.localizedDescription
            }
            isFollowing = false
        }
    }
}
