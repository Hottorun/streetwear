// SaveToast.swift
// What happens after you keep something.
//
// Saving used to be one tap and then silence, with two consequences. Filing was only
// reachable through the left-swipe board picker, which most people never find; and a
// watch — "tell me if my size comes back" — could only be set from a product page, so the
// app's best idea was three taps from the moment you actually wanted it.
//
// The obvious fix is to ask on every save. That is the wrong fix: most saves are
// reflexive, the honest answer to "which board?" is usually "I don't know yet", and
// taxing the common case to serve the rare one is how a one-tap action becomes a
// decision. So the save still completes on its own, immediately and unconditionally, and
// what appears is a *confirmation you can amend* — the outcome, plus the two things you
// might have wanted instead, for as long as it takes to change your mind.
//
// Three deliberate details:
//
// - **No counting numerals.** A visible "3… 2… 1…" makes a quiet confirmation feel
//   timed, which is the opposite of the intent. The dwell is shown as a hairline that
//   drains — present if you look for it, silent if you don't.
// - **A watch is offered even when the thing is in stock.** This is the new capability.
//   Wanting to be told your size has gone and come back is not conditional on it being
//   gone *now*, and until this the question could only be asked about something already
//   sold out.
// - **It sits above the tab bar, not over the card.** `quickSave` owns the horizontal
//   drag on the bottom half of a feed card, and a control laid over that region would be
//   fighting the gesture for the same pixels.

import SwiftData
import SwiftUI

/// The one place a just-completed save is published, and where the sheets it can open are
/// held.
///
/// Observable and owned by the app rather than by a card, for the same reason `PushRoute`
/// is: the card that triggered this is inside a `LazyVStack` and may well be recycled or
/// scrolled away before the confirmation is finished with. State that outlives the view
/// that started it cannot live in that view.
@MainActor
@Observable
final class SaveConfirmation {
    struct Pending: Identifiable {
        let id = UUID()
        let update: BrandUpdate
        /// Where it went, in words — "Inspiration", "Wardrobe", or a board's name.
        let destination: String
    }

    /// How long the confirmation stays. Long enough to read the line, notice there are
    /// two actions and reach one; short enough not to loiter over the feed.
    ///
    /// Seconds rather than a `Duration`, because the drain animation and the dismissal
    /// timer both read it and they must not be able to drift apart — a hairline that
    /// empties before the toast goes says the buttons have stopped working.
    static let dwell: TimeInterval = 4.5

    private(set) var pending: Pending?

    /// Driven by the toast's buttons and presented from `ContentView`, so they survive the
    /// toast itself going away — a sheet owned by a view that dismisses itself on tap is a
    /// sheet that never opens.
    var choosingBoard: BrandUpdate?
    var settingWatch: BrandUpdate?

    /// How much room the screen underneath needs at the bottom.
    ///
    /// The toast is anchored above the tab bar, which is right for every screen except the
    /// one you are most likely to save from: a product page puts its buy button there, and
    /// covering the buy button for four seconds at the exact moment somebody decided they
    /// want the thing is the worst possible place to put a confirmation.
    var bottomClearance: CGFloat = 0

    func confirm(_ update: BrandUpdate, destination: String) {
        pending = Pending(update: update, destination: destination)
    }

    func clear() { pending = nil }

    /// Saving several things quickly should not queue several confirmations — the last
    /// one is the one being looked at. Replacing rather than queueing is also what keys
    /// the dwell timer, which restarts because the `id` changed.
    func chooseBoard() {
        guard let update = pending?.update else { return }
        clear()
        choosingBoard = update
    }

    func setWatch() {
        guard let update = pending?.update else { return }
        clear()
        settingWatch = update
    }
}

/// The confirmation itself. Renders nothing when there is nothing to confirm.
struct SaveToast: View {
    @Environment(SaveConfirmation.self) private var confirmation: SaveConfirmation

    /// Drains from 1 to 0 across the dwell. Restarted by `id`, so a second save resets it
    /// rather than inheriting however much of the first one was left.
    @State private var remaining: CGFloat = 1

    var body: some View {
        if let pending = confirmation.pending {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        DataLabel(text: "KEPT TO \(pending.destination.uppercased())", size: 9)
                        Text(pending.update.title)
                            .font(.editorial(13))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    action("Board", systemImage: "square.grid.2x2") { confirmation.chooseBoard() }
                    action("Notify", systemImage: "bell") { confirmation.setWatch() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // The dwell, shown rather than counted. Aligned leading so it empties in
                // the direction the line above it is read.
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.ink.opacity(0.28))
                        .frame(width: geometry.size.width * remaining)
                }
                .frame(height: 1)
            }
            .background(Color.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // Keyed on the save, so saving something else restarts both the countdown and
            // the drain instead of finishing the previous one's.
            .task(id: pending.id) {
                remaining = 1
                withAnimation(.linear(duration: SaveConfirmation.dwell)) { remaining = 0 }
                try? await Task.sleep(for: .seconds(SaveConfirmation.dwell))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { confirmation.clear() }
            }
            // Swiping it away is faster than waiting, and a confirmation you can't
            // dismiss is an interruption.
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        guard value.translation.height > 0 else { return }
                        withAnimation(.easeOut(duration: 0.2)) { confirmation.clear() }
                    }
            )
        }
    }

    private func action(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(title.uppercased())
                    .font(.wordmark(8, .semibold))
                    .tracking(0.8)
            }
            .foregroundStyle(Color.ink)
            .frame(width: 52)
            .contentShape(.rect)
        }
        // `.plain` would let the enclosing row take the tap as one target and neither
        // button would ever fire — the same trap as buttons in a `List` row.
        .buttonStyle(.borderless)
    }
}
