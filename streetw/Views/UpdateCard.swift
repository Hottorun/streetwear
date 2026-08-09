// UpdateCard.swift
// The visual unit of the whole app: one product / post, with a save action.

import StreetwCore
import SwiftData
import SwiftUI

struct UpdateCarousel: View {
    let updates: [BrandUpdate]
    var width: CGFloat = 150

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(updates) { update in
                    UpdateCard(update: update, width: width)
                }
            }
            .padding(.horizontal)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

struct UpdateCard: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore?

    let update: BrandUpdate
    var width: CGFloat = 150

    private var save: SavedItem? { update.save }

    /// "Back in M, L" beats a bare "Back" — the size is the whole point of a restock.
    /// Narrowed to the user's sizes when they've set them.
    private var restockLabel: String {
        let profile = sizes?.profile ?? SizeProfile()
        let mine = update.restockedSizes(matching: profile)
        let shown = (mine.isEmpty ? update.restockedSizes : mine)
            .filter { $0 != "Default Title" && !$0.isEmpty }
        guard !shown.isEmpty else { return "Back" }
        return "Back in \(shown.prefix(3).joined(separator: ", "))"
    }

    /// Only worth a badge once the user has actually told us their sizes.
    private var isInMySize: Bool {
        guard let profile = sizes?.profile, !profile.isEmpty, !update.variants.isEmpty else {
            return false
        }
        return !update.availableSizes(matching: profile).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                UpdateImage(url: update.primaryImageURL, kind: update.kind)
                    .frame(width: width, height: width * 1.25)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                SaveButton(isSaved: save != nil) { toggleSave() }
                    .padding(8)

                if isInMySize {
                    Text("Your size")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }

            Text(update.title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: width, alignment: .leading)

            HStack(spacing: 6) {
                if let price = update.priceText {
                    Text(price)
                        .font(.caption2.weight(.medium))
                }
                if update.isAvailable == false {
                    Text("Sold out")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if update.kind == .restock {
                    Label(restockLabel, systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture {
            if let link = update.linkURL { openURL(link) }
        }
        .contextMenu {
            Button("Save to Inspiration", systemImage: "bookmark") { setSave(.inspiration) }
            Button("Add to Wardrobe", systemImage: "tshirt") { setSave(.wardrobe) }
            if save != nil {
                Button("Remove", systemImage: "trash", role: .destructive) { removeSave() }
            }
            if let link = update.linkURL {
                Divider()
                Link("Open on site", destination: link)
            }
        }
    }

    private func toggleSave() {
        if save != nil { removeSave() } else { setSave(.inspiration) }
    }

    private func setSave(_ type: SavedItem.SaveType) {
        if let save {
            save.type = type
        } else {
            context.insert(SavedItem(update: update, type: type))
        }
        update.isSeen = true
        try? context.save()
    }

    private func removeSave() {
        guard let save else { return }
        context.delete(save)
        try? context.save()
    }
}

// MARK: - Pieces

struct UpdateImage: View {
    let url: URL?
    var kind: BrandUpdate.Kind = .product

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        placeholder.overlay(ProgressView())
                    }
                }
            } else {
                placeholder.overlay(
                    Image(systemName: kind.symbol)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                )
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        Rectangle().fill(.quaternary)
    }
}

struct SaveButton: View {
    let isSaved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSaved ? Color.accentColor : .white)
                .padding(7)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSaved)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}
