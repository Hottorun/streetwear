// ShopView.swift
// STUB, to be replaced by the real Shop tab — search on top, daily picks when the field is
// empty — which is being built separately. It exists so the three-tab shell compiles and
// opens on something true in the meantime: the Discover deck, which is the part of Shop that
// already exists.
//
// The deck has no navigation bar (see `DiscoverFeedView` for why paging needs it gone), so
// the You button is laid over the corner here instead of going through `.youButton()`.

import SwiftUI

struct ShopView: View {
    var body: some View {
        DiscoverFeedView()
            .overlay(alignment: .topTrailing) {
                YouButton(ink: .sweepInk)
                    .padding(9)
                    .background(Color.sweep, in: Circle())
                    .padding(.trailing, 14)
                    .padding(.top, 2)
            }
    }
}
