// ScanFindResults.swift
// "Find this or something like it": what the server says looks like the photograph, or a
// search for the scan's own words.
//
// **`similar` first, when it came back** — the embedding service read the photograph itself,
// which beats any description of it. Otherwise the reading's `searchText` is searched exactly as
// Shop's field would search it (`GET /v1/products/search`), your shops first and every shop the
// server watches when yours have nothing, and the line above the grid says which it was. The
// search is free: the reading was what was paid for. A search that failed says it failed.

import StreetwCore
import SwiftData
import SwiftUI

struct ScanFindResults: View {
    @Environment(\.modelContext) private var context
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(ProfileStore.self) private var profiles: ProfileStore
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]

    let searchText: String
    let similar: [DiscoverCard]?

    private enum Answer {
        case loading
        case found(cards: [(card: DiscoverCard, matched: [String]?)], label: String)
        case none(String)
        case failed
    }

    @State private var answer: Answer = .loading
    @State private var viewing: DiscoverCard?
    /// Bumped by "try again", so the search is asked afresh.
    @State private var attempt = 0

    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]

    /// What is already kept, by product, so a tile's bookmark is filled for it — the rule
    /// `ShopView.savedKeys` follows.
    private var savedKeys: Set<String> {
        var keys: Set<String> = []
        for update in saves.compactMap(\.update) {
            keys.insert(update.externalID)
            if let product = update.productExternalID { keys.insert(product) }
        }
        return keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch answer {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    DataLabel(text: "LOOKING")
                }
                .padding(.horizontal, 20)
            case .found(let cards, let label):
                DataLabel(text: label, size: 10, color: .ink)
                    .padding(.horizontal, 20)
                let saved = savedKeys
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(cards, id: \.card.productExternalID) { entry in
                        ShopCardTile(
                            card: entry.card,
                            matched: entry.matched,
                            isSaved: saved.contains(entry.card.productExternalID),
                            onSave: { DiscoverSave.save(entry.card, in: context) },
                            onOpen: { viewing = entry.card }
                        )
                    }
                }
                .padding(.horizontal, 16)
            case .none(let line):
                Text(line)
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            case .failed:
                VStack(alignment: .leading, spacing: 10) {
                    Text("The search didn't go through — that's not the same as nothing being there.")
                        .font(.editorial(16))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { attempt += 1 }
                        .font(.data(12, .semibold))
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 20)
        .task(id: attempt) { await find() }
        .sheet(item: $viewing) { card in
            DiscoverProductSheet(
                card: card,
                isSaved: savedKeys.contains(card.productExternalID),
                onSave: { DiscoverSave.save(card, in: context) }
            )
        }
    }

    private func find() async {
        if let similar, !similar.isEmpty {
            answer = .found(
                cards: similar.map { (card: $0, matched: nil) },
                label: similar.count == 1 ? "ONE PRODUCT LOOKS LIKE IT" : "\(similar.count) PRODUCTS LOOK LIKE IT"
            )
            return
        }
        guard let baseURL = settings.baseURL else {
            answer = .failed
            return
        }
        answer = .loading
        let api = StreetwAPI(baseURL: baseURL, token: settings.token, profileID: profiles.session.scope.id)
        do {
            for scope in [ProductSearchScope.followed, .all] {
                let response = try await api.searchProducts(searchText, scope: scope, cheaper: false, formal: false, inMySize: false)
                let hits = response.exact + response.partial
                guard !hits.isEmpty else { continue }
                let place = scope == .followed ? "IN YOUR SHOPS" : "IN EVERY SHOP DROPWALL WATCHES"
                answer = .found(
                    cards: hits.map { (card: $0.card, matched: $0.matched) },
                    label: "\(place) · “\(searchText.uppercased())”"
                )
                return
            }
            answer = .none("Nothing in the shops Dropwall watches matches “\(searchText)”.")
        } catch {
            answer = .failed
        }
    }
}

/// The results on their own page — from a garment of your own, where "find it" is asked long
/// after the scan.
struct ScanFindSheet: View {
    @Environment(\.dismiss) private var dismiss

    let searchText: String
    let similar: [DiscoverCard]?

    var body: some View {
        NavigationStack {
            ScrollView {
                ScanFindResults(searchText: searchText, similar: similar)
                    .padding(.top, 12)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle("Like it")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.data(13, .semibold))
                }
            }
        }
        .tint(.ink)
    }
}
