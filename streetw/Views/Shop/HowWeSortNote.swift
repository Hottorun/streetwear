// HowWeSortNote.swift
// What orders Shop’s one list, said in words, from the results (Phase 5).
//
// **Every sentence here is about what the answer on screen was given**, not about what the app
// would like to do: a server that predates the lift answers with no `boost`, and the note then
// says your shops were not lifted, rather than claiming they were. And it says the one thing
// that never orders the list — commission — because a ranked list of shops is exactly where a
// reader is entitled to wonder.

import StreetwCore
import SwiftUI

struct HowWeSortNote: View {
    @Environment(\.dismiss) private var dismiss

    /// The answer the note is about; nil before one has arrived.
    let answer: ProductSearchResponse?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("How we sort")
                        .font(.editorial(28))
                        .foregroundStyle(Color.ink)

                    reason(
                        "How well it matches",
                        "What you wrote, word by word: a product’s name counts most, then its type, its colours, its tags and the shop’s name. In stock comes before sold out, which still shows, because a size that’s gone can come back."
                            + (answer?.meaningSearched == true
                                ? " Where a product doesn’t say your words but means what you wrote, it can still be a result, and it says MATCHED BY MEANING."
                                : "")
                    )
                    reason("The shops you follow", followed)
                    reason(
                        "Your taste",
                        "When you ask Dropwall, what you own puts what goes with it first. That’s worked out on this phone — your wardrobe isn’t sent anywhere."
                    )
                    reason(
                        "Your size",
                        "In my size keeps only what’s buyable in one of your sizes today. Everywhere else, your sizes are marked on each product’s size run."
                    )
                    reason(
                        "Never by commission",
                        "No shop pays to be placed or lifted, and nothing is ordered by what Dropwall might earn from it."
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.data(13, .semibold))
                }
            }
        }
        .tint(.ink)
        .presentationDetents([.medium, .large])
    }

    /// Said from the answer’s own scope and lift.
    private var followed: String {
        guard let answer else {
            return "They’re lifted a little in every search. More from my brands lifts them further; Only my brands searches nothing else."
        }
        if answer.scope == .followed {
            return "This search is only your shops — Only my brands is on. Turn it off to search every shop we watch."
        }
        switch answer.boost {
        case .more?:
            return "More from my brands is on, so your shops are lifted further than usual. Only my brands searches nothing else."
        case .standard?:
            return "They’re lifted a little among equally good matches. More from my brands lifts them further; Only my brands searches nothing else."
        case nil:
            return "This answer treats every shop the same — the server it came from doesn’t lift your shops yet."
        }
    }

    private func reason(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rule()
            DataLabel(text: title.uppercased(), size: 10, color: .ink)
            Text(detail)
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
