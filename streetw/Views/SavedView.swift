// SavedView.swift
// The calm room: Inspiration (things you liked) and Wardrobe (things you own).
//
// Everything the feed does to create urgency is absent here by design — no counts, no
// "new", no stock, no accent colour. Two columns of varying heights so the page reads as
// a wall rather than a table; the images do all the work.

import SwiftData
import SwiftUI

struct SavedView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @State private var filter: SavedItem.SaveType = .inspiration

    private var visible: [SavedItem] {
        saves.filter { $0.type == filter && $0.update != nil }
    }

    /// Split by hand rather than with `LazyVGrid`, which forces every row to the height
    /// of its tallest cell and would flatten the wall back into a table.
    private var columns: ([SavedItem], [SavedItem]) {
        var left: [SavedItem] = []
        var right: [SavedItem] = []
        for (index, item) in visible.enumerated() {
            if index.isMultiple(of: 2) { left.append(item) } else { right.append(item) }
        }
        return (left, right)
    }

    var body: some View {
        NavigationStack {
            Group {
                if visible.isEmpty {
                    EditorialEmptyState(
                        title: filter == .inspiration ? "Nothing kept yet" : "Wardrobe is empty",
                        action: filter == .inspiration
                            ? "TAP THE BOOKMARK ON ANYTHING IN YOUR FEED"
                            : "LONG-PRESS AN ITEM AND CHOOSE ADD TO WARDROBE"
                    )
                } else {
                    wall
                }
            }
            .background(Color.paper)
            .navigationTitle("Saved")
            .toolbarTitleDisplayMode(.inlineLarge)
            .safeAreaInset(edge: .top) { modePicker }
        }
        .tint(.ink)
    }

    private var wall: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                column(columns.0, offset: 0)
                column(columns.1, offset: 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private func column(_ items: [SavedItem], offset: Int) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(items) { save in
                if let update = save.update {
                    CollectionTile(update: update, aspect: aspect(for: save, offset: offset))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Deterministic rather than random, so a tile doesn't change shape on every redraw —
    /// a collection that reflows while you look at it is the opposite of calm.
    private func aspect(for save: SavedItem, offset: Int) -> CGFloat {
        let ratios: [CGFloat] = [1, 0.8, 1, 0.75]
        let index = abs(save.id.hashValue &+ offset) % ratios.count
        return ratios[index]
    }

    /// A two-word switch, set as type. A segmented control here would be the loudest
    /// object on a page whose whole job is to be quiet.
    private var modePicker: some View {
        HStack(spacing: 20) {
            ForEach(SavedItem.SaveType.allCases) { type in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { filter = type }
                } label: {
                    VStack(spacing: 5) {
                        Text(type.label.uppercased())
                            .font(.wordmark(11, filter == type ? .semibold : .regular))
                            .tracking(1.4)
                            .foregroundStyle(filter == type ? Color.ink : Color.muted)
                        Rectangle()
                            .fill(filter == type ? Color.ink : Color.clear)
                            .frame(height: 1)
                    }
                    .fixedSize()
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(Color.paper)
    }
}

#Preview {
    SavedView()
        .modelContainer(PreviewData.container)
}
