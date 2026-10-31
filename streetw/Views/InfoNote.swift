// InfoNote.swift
// What has to be said, a tap away instead of printed on the page.
//
// **The copy rule** (`CLAUDE.md`, *Copy*): labels and statuses stay, in a few words; how-tos go to
// onboarding or a one-time tip; and anything that must stay true and reachable — why something
// was refused, what reaches the server or the AI, how credits work — lives behind an ⓘ that opens
// a short sheet. The page carries the label; the sheet carries the reason.

import SwiftUI

/// A short statement behind an ⓘ: a title and a few one-sentence lines, and optionally a link.
struct InfoNote: Identifiable, Equatable {
    let title: String
    let lines: [String]
    var link: Link?

    struct Link: Equatable {
        let title: String
        let url: URL
    }

    var id: String { title }
}

/// The ⓘ beside a label. Its own button, so it can sit next to — never inside — another control.
struct InfoButton: View {
    let note: InfoNote
    /// "WHY?" beside a refusal reads better than a bare glyph; everywhere else, the glyph alone.
    var label: String?

    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: {
            HStack(spacing: 4) {
                if let label {
                    DataLabel(text: label, size: 10, color: .ink)
                }
                Image(systemName: "info.circle")
                    .font(.system(size: label == nil ? 14 : 10, weight: .regular))
                    .foregroundStyle(label == nil ? Color.muted : Color.ink)
            }
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label.map { "\($0.capitalized) — \(note.title)" } ?? "About \(note.title)")
        .sheet(isPresented: $isShowing) { InfoSheet(note: note) }
    }
}

/// The sheet: the title in the serif, each line in ink at a readable size — never a grey paragraph.
struct InfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let note: InfoNote

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(note.title)
                        .font(.editorial(26))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(note.lines, id: \.self) { line in
                        VStack(alignment: .leading, spacing: 12) {
                            Rule()
                            Text(line)
                                .font(.editorial(16))
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let link = note.link {
                        Button { openURL(link.url) } label: {
                            NotificationsSection.SettingsAction(title: link.title)
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 32)
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
}
