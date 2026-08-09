// SavedItem.swift
// Model for content the user has saved (wardrobe/inspiration)
import Foundation
import SwiftData

@Model
final class SavedItem {
    enum SaveType: String, Codable, Sendable, CaseIterable, Identifiable {
        case inspiration
        case wardrobe

        var id: String { rawValue }

        var label: String {
            switch self {
            case .inspiration: "Inspiration"
            case .wardrobe: "Wardrobe"
            }
        }

        var symbol: String {
            switch self {
            case .inspiration: "bookmark"
            case .wardrobe: "tshirt"
            }
        }
    }

    var id: UUID = UUID()
    var update: BrandUpdate?
    var savedAt: Date = Date()
    var type: SaveType = SaveType.inspiration
    var note: String?

    init(update: BrandUpdate?, savedAt: Date = Date(), type: SaveType = .inspiration, note: String? = nil) {
        self.id = UUID()
        self.update = update
        self.savedAt = savedAt
        self.type = type
        self.note = note
    }
}
