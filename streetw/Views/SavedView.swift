// SavedView.swift
// Inspiration (things you liked) and Wardrobe (things you own).

import SwiftData
import SwiftUI

struct SavedView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @State private var filter: SavedItem.SaveType = .inspiration

    private var visible: [SavedItem] {
        saves.filter { $0.type == filter && $0.update != nil }
    }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if visible.isEmpty {
                    EmptyStateView(
                        symbol: filter.symbol,
                        title: filter == .inspiration ? "Nothing saved yet" : "Wardrobe is empty",
                        message: filter == .inspiration
                            ? "Tap the bookmark on anything in your feed to save it here."
                            : "Long-press an item and choose \"Add to Wardrobe\" for things you own."
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(visible) { save in
                                if let update = save.update {
                                    UpdateCard(update: update, width: 110)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Saved")
            .safeAreaInset(edge: .top) {
                Picker("Kind", selection: $filter) {
                    ForEach(SavedItem.SaveType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
    }
}

#Preview {
    SavedView()
        .modelContainer(PreviewData.container)
}
