// ShareQuestionHost.swift
// Draws the questions shares raised, one at a time, until each has been seen through.
//
// Hosted at the root, under every tab, for the reason `SaveConfirmation`'s sheets are: the
// question arrives on a foreground, while somebody may be anywhere in the app. A question is
// taken off the queue only when its sheet **appeared and then went away** — answered,
// cancelled or swiped down. If it could not be presented at all (another sheet was already up,
// which SwiftUI answers by quietly presenting nothing), it is still there on the next
// foreground. That is the whole difference from the sheet this replaced. See `ShareQuestions`.

import SwiftData
import SwiftUI

struct ShareQuestionHost: ViewModifier {
    @Environment(ShareQuestions.self) private var questions: ShareQuestions
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    /// What is being presented, paired with its row.
    @State private var presenting: Presenting?
    /// Set by the sheet's content appearing — the proof that it was seen.
    @State private var seen: UUID?
    /// While a sheet is still going away, so the next is not presented over its exit.
    @State private var isSettling = false

    struct Presenting: Identifiable {
        let question: ShareQuestions.Question
        let update: BrandUpdate
        var id: UUID { question.id }
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenting, onDismiss: dismissed) { presenting in
                WatchEditor(
                    update: presenting.update,
                    colorway: presenting.question.color,
                    headline: presenting.question.headline
                )
                .presentationDetents([.medium, .large])
                .onAppear { seen = presenting.id }
            }
            .task(id: questions.revision) { present() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // A presentation that never appeared is offered again.
                if let current = presenting, seen != current.id { presenting = nil }
                present()
            }
    }

    private func present() {
        guard presenting == nil, !isSettling, scenePhase == .active else { return }
        let scope = remote.scope
        for question in questions.questions(for: scope) {
            // The row went — un-saved, or its profile's store was rebuilt — so there is
            // nothing left to ask about.
            guard let update = SharedSaveImporter.existingRow(for: question.externalID, in: context),
                  !update.isDeleted
            else {
                questions.resolve(question.id, for: scope)
                continue
            }
            presenting = Presenting(question: question, update: update)
            return
        }
    }

    private func dismissed() {
        guard let id = seen else { return }
        seen = nil
        isSettling = true
        questions.resolve(id, for: remote.scope)
        // The next one, once this sheet has finished going.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            isSettling = false
            present()
        }
    }
}

extension View {
    func shareQuestions() -> some View {
        modifier(ShareQuestionHost())
    }
}
