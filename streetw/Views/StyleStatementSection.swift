// StyleStatementSection.swift
// The one place the app asks instead of inferring.
//
// Everything else on this screen is a fact with an obvious shape — a size is a size, a
// gender filter is one of four values. This is a sentence, and it is here because the app's
// entire reading of somebody is otherwise reconstructed from their behaviour. That works,
// eventually, and it is silent and slow: a person who wears checkered shirts with black
// shorts has no way to say so except by saving enough of them that the arithmetic notices.
//
// Two things make a free-text field honest rather than magical, and both are here:
//
// - **It says what it understood.** The reading is printed under the box, in the app's own
//   data voice. Somebody who writes a paragraph and gets back three words can see instantly
//   that it took less than they meant, which is the difference between a field you can
//   correct and a black box you have to trust.
// - **It says what it does.** It reorders suggestions and nudges the brand ranking. It never
//   hides anything — the same rule the size profile follows, for the same reason: a filter
//   you did not know you had set is indistinguishable from a broken feed.
//
// Committed on the way out of the field rather than per keystroke: the parse is cheap but
// the reading flickering word by word while somebody types a sentence is not something to
// watch happen.

import StreetwCore
import SwiftUI

struct StyleStatementSection: View {
    @Environment(StyleStatementStore.self) private var store: StyleStatementStore

    @State private var draft = ""
    @FocusState private var isWriting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsHeader(
                title: "In your words",
                note: "Say how you actually dress and streetw will lean that way when it suggests fits, pairings and brands. It never hides anything you'd otherwise see."
            )

            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    "I wear checkered shirts with black shorts. No big logos.",
                    text: $draft,
                    axis: .vertical
                )
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
                .lineLimit(3...8)
                .focused($isWriting)
                .submitLabel(.done)
                Rule()
            }

            reading
        }
        .onAppear { draft = store.statement.text }
        // On blur, and on the way out of the sheet. A settings field that only saves when
        // you happen to dismiss the keyboard is a field that loses what you wrote.
        .onChange(of: isWriting) { _, writing in if !writing { commit() } }
        .onDisappear { commit() }
    }

    /// What the parse took from it, printed back.
    @ViewBuilder
    private var reading: some View {
        let understood = store.statement.reading
        if !understood.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                DataLabel(text: "READING")
                FlowRow(spacing: 8) {
                    ForEach(understood, id: \.self) { term in
                        Text(term.uppercased())
                            .font(.data(10, .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.wash)
                    }
                }
            }
        } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Written something, understood nothing. Saying so is better than an empty
            // space that reads as the field having been ignored — which it has.
            DataLabel(text: "NOTHING RECOGNISED YET — TRY NAMING COLOURS AND GARMENTS")
        }
    }

    private func commit() {
        guard draft != store.statement.text else { return }
        store.write(draft)
    }
}
