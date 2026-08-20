// StyleStatementStore.swift
// Persistence for what somebody says about their own style.
//
// `UserDefaults` rather than SwiftData, for the same reason `SizeProfileStore` is: it is one
// small value belonging to this device and this person, and putting it in the schema would
// mean a migration for a settings field. It is also, deliberately, **local only** — the
// server never sees it. It is a sentence somebody wrote about themselves, it is used to
// reorder suggestions computed on the phone, and there is nothing the backend could do with
// it that would be worth sending it for. Same bargain as the taste vector.

import Foundation
import StreetwCore
import SwiftUI

@MainActor
@Observable
final class StyleStatementStore {
    private static let key = "styleStatement"

    /// The parse, kept whole. Written on every change because the parse is cheap and the
    /// alternative — storing the text and re-parsing per read — would run it inside view
    /// bodies, which is where this app has been bitten before.
    private(set) var statement: StyleStatement

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(StyleStatement.self, from: data) {
            statement = decoded
        } else {
            statement = StyleStatement()
        }
    }

    /// Re-reads the sentence and stores both it and what was understood.
    func write(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        statement = trimmed.isEmpty ? StyleStatement() : StyleStatement.parse(trimmed)
        guard let data = try? JSONEncoder().encode(statement) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
