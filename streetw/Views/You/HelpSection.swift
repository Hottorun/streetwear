// HelpSection.swift
// The way back to the tour and the tips, once they have been dismissed.
//
// The first run shows the tour once and each tip once — so somebody who skipped them, or wants
// to hand the phone to somebody else, needs a route back that is not reinstalling.

import SwiftUI

struct HelpSection: View {
    @State private var isTouring = false
    @State private var didReplayTips = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeader(title: "Help")

            VStack(spacing: 0) {
                Button { isTouring = true } label: {
                    YouRow(title: "How Dropwall works", chevron: true)
                }
                .buttonStyle(.borderless)

                Button {
                    TipEpoch.replay()
                    didReplayTips = true
                } label: {
                    YouRow(
                        title: "Show tips again",
                        detail: didReplayTips ? "They'll show as you go" : nil,
                        detailColor: .ink
                    )
                }
                .buttonStyle(.borderless)
                .disabled(didReplayTips)
            }
        }
        .fullScreenCover(isPresented: $isTouring) {
            TourSheet()
        }
    }
}
