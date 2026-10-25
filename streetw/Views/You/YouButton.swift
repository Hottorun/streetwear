// YouButton.swift
// The way to everything about the person, from every tab.
//
// Four tabs became three — Feed, Shop, Saved — and the fourth was never really a tab. Style
// was a reading of somebody's taste with a settings gear on it, and the gear led to their
// sizes, their alerts and the sentence they wrote about how they dress; the brands they
// follow sat behind "ALL" at the head of the feed, the things they are waiting on behind a
// bell, the calendar behind another icon. All of that is one subject — *you* — and it lives on
// one page, behind one control that is in the same corner of every tab.
//
// The control is a person, not a gear. A gear says "configure the app"; this page is mostly a
// reading of somebody and a list of what they asked for, and the settings are its last few
// sections rather than its point.

import SwiftUI

/// Whether the You page is up, and the one way to ask for it.
///
/// **One object for the whole app, and the page is presented once, from the root** — not a
/// sheet per tab. Two reasons. A facet tapped on the page is a question about the collection,
/// so it has to close the page *and* change tab, and only the root knows there are tabs. And a
/// tab that owned its own copy of the sheet would present a second one over the first the
/// moment anything inside it asked again.
///
/// Built in `streetwApp.init` beside `CollectionRoute`, for that type's reason: a tab appears
/// before anything could have set it, and an environment object that is not there yet is a
/// crash rather than a no-op.
@MainActor
@Observable
final class YouRoute {
    var isOpen = false

    func open() {
        isOpen = true
    }
}

/// The avatar, top right on every tab.
///
/// A person symbol for now. There is nobody to put in it until sign-in exists, and a
/// placeholder photograph would be a claim that there is.
struct YouButton: View {
    @Environment(YouRoute.self) private var you: YouRoute

    /// `sweepInk` where the button sits on a fixed ground rather than in a bar — the Discover
    /// deck's ground does not invert, so adaptive ink would be near-white on cream at night.
    var ink: Color = .ink

    var body: some View {
        Button {
            you.open()
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(ink)
        }
        .accessibilityLabel("You")
        .accessibilityHint("Your taste, sizes, the brands you follow and settings")
    }
}

extension View {
    /// The You button in the top-right corner of a tab's navigation bar.
    ///
    /// Applied inside the tab's `NavigationStack`, like any other toolbar modifier — one line
    /// on each tab's root. **Apply it before the tab's own `.toolbar`**, nearer the content:
    /// SwiftUI lays a trailing group out with the outermost modifier's items first, so applied
    /// after, the avatar came out *ahead* of Select and the page's menu rather than in the
    /// corner.
    ///
    /// On iOS 26 it is set apart from the tab's own controls by a fixed spacer, which is what
    /// gives it a glass circle of its own instead of a seat in the page's capsule — it is not one
    /// of the page's actions, it is the way to a different page.
    func youButton() -> some View {
        toolbar {
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                YouButton()
            }
        }
    }
}
