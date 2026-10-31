// Tips.swift
// One-time tips at the point of use, with TipKit.
//
// A how-to printed on the page is read once and then sits there for ever; a tip says it once,
// where the thing is, and goes. Each is one line, dismissible, and never shown again — until
// You › Help asks for them back.
//
// **Replaying is a new id, not a datastore reset.** `Tips.resetDatastore()` may only run before
// `Tips.configure`, so it cannot answer a button pressed mid-session. Each tip's id carries
// `TipEpoch`, and "Show tips again" moves the epoch on: every tip becomes one TipKit has never
// seen. The epoch describes the phone, not a person, so it is not a profile-scoped key.

import SwiftUI
import TipKit

enum TipEpoch {
    private static let key = "tipEpoch"

    static var current: Int { UserDefaults.standard.integer(forKey: key) }

    static func replay() {
        UserDefaults.standard.set(current + 1, forKey: key)
    }

    /// Once, from `streetwApp.init`. Immediate, because each tip already has its own moment.
    static func configure() {
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}

/// Shop, before the first search: what the field takes.
struct ShopSearchTip: Tip {
    var epoch = TipEpoch.current
    /// Whether the camera is drawn — the scan exists only where the server has a model.
    var scans = false

    var id: String { "shop-search.\(epoch)" }
    var title: Text {
        Text(scans ? "Describe it in your words, or scan a garment" : "Describe it in your words — a colour, a garment, a price")
    }
}

/// Saved, the first time there is something on the wall.
struct WardrobeTip: Tip {
    var epoch = TipEpoch.current

    var id: String { "saved-wardrobe.\(epoch)" }
    var title: Text { Text("Long-press a save to add it to your Wardrobe") }
}

/// The fit canvas: how to size a piece, which the empty canvas does not say.
struct FitCanvasTip: Tip {
    var epoch = TipEpoch.current

    var id: String { "fit-canvas.\(epoch)" }
    var title: Text { Text("Pinch a piece, or drag its corner, to size it") }
}

/// A tip as the app draws everything else: one serif line on the wash, a rule of ink at its
/// edge, and a close mark. The system style is a rounded material card — a fragment of another
/// app on paper.
struct PaperTipStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.title?
                .font(.editorial(15))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(Color.wash)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.ink).frame(width: 2)
        }
    }
}

/// A tip inline, in the paper style — and nothing at all once it is spent.
struct PaperTip<Content: Tip>: View {
    let tip: Content

    var body: some View {
        TipView(tip, arrowEdge: nil)
            .tipViewStyle(PaperTipStyle())
            .tipBackground(Color.clear)
            .tipCornerRadius(0)
    }
}
