// ShareQuestionHost.swift
// Draws the questions shares raised, one at a time, until each has been seen through.
//
// Hosted at the root, under every tab, for the reason `SaveConfirmation`'s sheets are: the
// question arrives on a foreground, while somebody may be anywhere in the app. A question is
// taken off the queue only when it is **answered** — Start watching or Cancel. Having appeared
// is not enough: on a fresh install the question went up, the onboarding cover arrived a moment
// later, SwiftUI took the sheet down to show it, and an earlier version of this host counted
// that as seen and dropped the question unanswered. So the sheet cannot be swiped away, and any
// other way it goes — taken down, never presented because another sheet was up — leaves the
// question queued for the next foreground. See `ShareQuestions`.

import SwiftData
import SwiftUI

struct ShareQuestionHost: ViewModifier {
    @Environment(ShareQuestions.self) private var questions: ShareQuestions
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    /// What is being presented, paired with its row.
    @State private var presenting: Presenting?
    /// Set by the sheet's content appearing — so a presentation that never appeared is offered again.
    @State private var seen: UUID?
    /// Set by an answer, the only thing that takes a question off the queue.
    @State private var answered: UUID?
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
                    headline: presenting.question.headline,
                    onAnswer: { answered = presenting.id }
                )
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
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
        seen = nil
        guard let id = answered else {
            // Taken down unanswered — most likely for a cover. Offered once more shortly, and
            // again on every foreground until it is answered.
            Task {
                try? await Task.sleep(for: .seconds(2))
                present()
            }
            return
        }
        answered = nil
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
