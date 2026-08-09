// BrandsView.swift
// The brand list and the add-brand flow.

import StreetwCore
import SwiftData
import SwiftUI

struct BrandsView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var engine: SyncEngine

    @Query(sort: \Brand.name) private var brands: [Brand]
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if brands.isEmpty {
                    EmptyStateView(
                        symbol: "tag",
                        title: "No brands yet",
                        message: "Paste a brand's website and streetw figures out what it can watch."
                    )
                } else {
                    List {
                        ForEach(brands) { brand in
                            NavigationLink {
                                BrandDetailView(brand: brand)
                            } label: {
                                BrandRow(brand: brand)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Brands")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add brand", systemImage: "plus") { isAdding = true }
                }
            }
            .sheet(isPresented: $isAdding) {
                AddBrandView()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(brands[index]) }
        try? context.save()
    }
}

struct BrandRow: View {
    let brand: Brand

    var body: some View {
        HStack(spacing: 12) {
            BrandMonogram(name: brand.name)

            VStack(alignment: .leading, spacing: 2) {
                Text(brand.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    ForEach(brand.sources) { source in
                        Image(systemName: source.kind.symbol)
                            .font(.caption2)
                    }
                    if let style = brand.styleDescription, !style.isEmpty {
                        Text(style).font(.caption).lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            if brand.isLockedForDrop {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if brand.unseenCount > 0 {
                Text("\(brand.unseenCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}

struct BrandMonogram: View {
    let name: String

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .frame(width: 42, height: 42)
            .overlay(
                Text(initials)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            )
    }
}

#Preview {
    BrandsView()
        .modelContainer(PreviewData.container)
        .environment(PreviewData.engine)
}
