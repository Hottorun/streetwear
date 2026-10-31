// FollowFilterView.swift
// Choosing which part of a brand to follow: All, its biggest categories, or your own words.
//
// Asked once after a new follow (`FollowFilterPrompt`) and editable afterwards from the brand
// page's "What reaches you", beside the mode. Three things on one page and nothing else:
//
// - **All**, chosen unless something else is. Skipping leaves it, which is what a follow was
//   before this existed — a filter you did not set is indistinguishable from a broken follow.
// - **The brand's three biggest categories**, counted by the server over its whole catalogue
//   (`GET /v1/brands/:id/categories`), or by the phone over its own rows standalone. Each
//   chip admits what it counted (`FollowCategory`).
// - **Your own words**, read by Shop's grammar and **printed back** the way Shop's field is:
//   "JEANS · NOT KIDS". A field that changes what reaches you without saying how is a black
//   box; the reading is what makes it correctable. What a follow cannot act on — "in my size",
//   "cheaper" — is printed as unused rather than silently dropped.
//
// And one line that keeps it honest: how many of the products on this phone the choice lets
// through, and that sales and anything Dropwall cannot place always come through.

import StreetwCore
import SwiftData
import SwiftUI

struct FollowFilterView: View {
    @Environment(RemoteSync.self) private var remote: RemoteSync

    let brand: Brand
    /// Just followed, rather than edited from the brand page: the wording, and Skip.
    var isNewFollow = true
    let onDone: () -> Void

    @State private var offered: [FollowCategoryCount] = []
    @State private var isLoadingCategories = true
    @State private var chosen: [String] = []
    @State private var words = ""
    @State private var garments: [FollowFilter.Item] = []
    @State private var admitted: Int?
    @State private var isSaving = false
    @State private var failure: String?
    @State private var didLoad = false

    private var filter: FollowFilter {
        FollowFilter(categories: chosen, words: words)
    }

    /// The chips: the biggest categories, then anything already chosen that is not among
    /// them, so editing a filter never hides a chip it holds.
    private var chips: [(id: String, label: String)] {
        var out = offered.map { (id: $0.category, label: $0.label) }
        for id in chosen where !out.contains(where: { $0.id == id }) {
            out.append((id, FollowCategory.named(id)?.label ?? id.capitalized))
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                categoriesSection
                wordsSection
                previewLine
                if let failure {
                    NoteLine(text: failure, color: .signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Color.paper)
        .safeAreaInset(edge: .bottom) { actions }
        .task { await load() }
        // Debounced: the count re-reads every garment through the grammar, and a word half
        // typed is not a question worth answering.
        .task(id: filter) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await count()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoteLine(text: isNewFollow ? "Now following." : "What reaches you")
            Wordmark(name: brand.name, size: 18)
            Text("What do you want to hear about?")
                .font(.editorial(24))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Sales, and anything Dropwall can't place, always come through.")
                .font(.editorial(14))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoteLine(text: offered.isEmpty ? "Categories" : "Its biggest categories", color: .ink)
            FlowRow(spacing: 8) {
                ShopChip(title: "All", isOn: chosen.isEmpty) { chosen = [] }
                ForEach(chips, id: \.id) { chip in
                    ShopChip(title: chip.label, isOn: chosen.contains(chip.id)) { toggle(chip.id) }
                }
            }
            if isLoadingCategories && offered.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    NoteLine(text: "Counting what they sell…", size: 13)
                }
            } else if offered.isEmpty {
                NoteLine(text: "Nothing to count yet. Your own words still work.", size: 13)
            }
        }
    }

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoteLine(text: "Or in your own words", color: .ink)
            TextField("jeans · bags · no kids", text: $words)
                .font(.editorial(17))
                .foregroundStyle(Color.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            Rule()
            let reading = FollowFilter(words: words).reading
            if !reading.isEmpty {
                NoteLine(text: "Reads as: " + reading.joined(separator: ", ") + ".", size: 13, color: .ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let unused = FollowFilter(words: words).unused
            if !unused.isEmpty {
                NoteLine(text: "Not used for a follow: " + unused.joined(separator: ", ") + ".", size: 13)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Shop's words work here: a garment, a colour, “no …”, “under 100”.")
                .font(.data(10))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var previewLine: some View {
        if let admitted, !garments.isEmpty, !filter.isEmpty {
            NoteLine(
                text: "Lets through \(admitted) of \(garments.count) products on this phone.",
                size: 13,
                color: admitted == 0 ? .signal : .muted
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                onDone()
            } label: {
                Text(isNewFollow ? "Skip" : "Cancel")
                    .font(.data(12, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
            }
            .buttonStyle(.borderless)

            Button {
                Task { await save() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(.paper)
                    } else {
                        Text(filter.isEmpty ? "Follow all of it" : "Follow these")
                            .font(.data(12, .semibold))
                            .tracking(1.1)
                    }
                }
                .foregroundStyle(Color.paper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.ink)
            }
            .buttonStyle(.borderless)
            .disabled(isSaving)
        }
        .padding(20)
        .background(Color.paper)
    }

    // MARK: - Acting

    private func toggle(_ id: String) {
        if let index = chosen.firstIndex(of: id) {
            chosen.remove(at: index)
        } else {
            chosen.append(id)
        }
    }

    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        if let current = brand.followFilter {
            chosen = current.categories
            words = current.words ?? ""
        }
        // One per garment, read once: the count below runs on every change.
        var seen = Set<String>()
        var items: [FollowFilter.Item] = []
        for update in brand.updates where [.product, .restock, .priceDrop].contains(update.kind) && !update.isMerchandise {
            guard seen.insert(update.productExternalID ?? update.externalID).inserted else { continue }
            items.append(update.followItem)
        }
        garments = items
        let answer = await remote.categories(for: brand)
        offered = answer.categories
        isLoadingCategories = false
    }

    /// How many of the phone's garments the choice lets through, off the main actor.
    private func count() async {
        let filter = filter
        let items = garments
        admitted = await Task.detached(priority: .userInitiated) {
            let matcher = FollowFilter.Matcher(filter)
            return items.count { matcher.admits(.product, $0) }
        }.value
    }

    private func save() async {
        isSaving = true
        failure = nil
        defer { isSaving = false }
        let chosenFilter = filter.normalized
        // Nothing to send when nothing changed — Skip by another name.
        guard chosenFilter != brand.followFilter else {
            onDone()
            return
        }
        do {
            try await remote.setFollowFilter(chosenFilter, for: brand)
            onDone()
        } catch {
            failure = "Not saved: \(error.localizedDescription)"
        }
    }
}

/// `FollowFilterView` in a sheet of its own, for the question a new follow raises.
struct FollowFilterSheet: View {
    let brand: Brand
    let onDone: () -> Void

    var body: some View {
        FollowFilterView(brand: brand, isNewFollow: true, onDone: onDone)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
    }
}

// MARK: - Hosting the question

/// Draws `FollowFilterPrompt`'s next question from this view, while it is the top host.
///
/// On the root and on every sheet a follow can be made from without closing it — You, the
/// add-brand sheet — because a sheet cannot be presented from under another one: the root
/// asking while You is open would be refused, silently. The topmost host on screen asks.
///
/// **It waits a moment before drawing**, and re-checks that it is still on top. Most follows
/// are made from a sheet that closes as the follow lands (a brand preview, the add-brand
/// search), and presenting from underneath one still animating away is presenting from a view
/// that is busy; the wait lets that close and its host leave the stack first.
private struct FollowFilterHost: ViewModifier {
    @Environment(FollowFilterPrompt.self) private var prompt: FollowFilterPrompt
    @Environment(\.modelContext) private var context

    @State private var token = UUID()
    @State private var asking: Asking?
    /// What was last drawn, for the dismissal to finish — `asking` is already nil by then.
    @State private var asked: UUID?

    struct Asking: Identifiable {
        let id: UUID
        let brand: Brand
    }

    private struct Trigger: Equatable {
        var head: UUID?
        var isTop: Bool
    }

    func body(content: Content) -> some View {
        content
            .onAppear { prompt.enter(token) }
            .onDisappear { prompt.leave(token) }
            .task(id: Trigger(head: prompt.head, isTop: prompt.topHost == token)) {
                guard asking == nil, let head = prompt.head, prompt.topHost == token else { return }
                try? await Task.sleep(for: .milliseconds(700))
                // A follow made by server id may reach the store a sync later (a Shop result,
                // the share sheet), so a brand not here yet is waited for — briefly. One that
                // never arrives was unfollowed or never landed, and is not asked about.
                for _ in 0..<12 {
                    guard !Task.isCancelled, asking == nil, prompt.head == head, prompt.topHost == token else { return }
                    if let brand = FollowFilterPrompt.brand(head, in: context) {
                        asked = head
                        asking = Asking(id: head, brand: brand)
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                if prompt.head == head { prompt.finish(head) }
            }
            .sheet(item: $asking, onDismiss: {
                // However it closed — answered, skipped, swiped away — it has been asked.
                if let asked { prompt.finish(asked) }
                asked = nil
            }) { question in
                FollowFilterSheet(brand: question.brand) { asking = nil }
            }
    }
}

extension View {
    /// Lets `FollowFilterPrompt` ask its question from here — see `FollowFilterHost`.
    func followFilterHost() -> some View {
        modifier(FollowFilterHost())
    }
}
