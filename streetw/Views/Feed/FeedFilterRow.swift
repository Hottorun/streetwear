// FeedFilterRow.swift
// All · Drops · Restocks · Sales · Upcoming · Brand ▾ — the feed's one row of controls.
//
// It replaces four things: the alphabetical brand rail at the head of the feed, the
// calendar icon, the markdowns icon with its system badge, and the bell. The rail was a
// directory on the page whose subject is news; the icons were three unlabelled doors to
// three lists that each restated part of the feed. Each of those is now a filter over the
// one list, plus the brand menu — and the directory itself lives under You › Following.

import StreetwCore
import SwiftUI

struct FeedFilterRow: View {
    @Binding var filter: FeedFilter
    /// The one brand the feed is narrowed to, by the timeline's brand key. Nil is all.
    @Binding var brand: String?
    /// Followed brands, alphabetical — the order of something you aim at, which must not move.
    let brands: [Brand]
    let addBrand: () -> Void

    var body: some View {
        // **It never truncates.** The prototype pinned Brand ▾ at the right edge and let the
        // rest scroll under it, which on a 402pt phone cut UPCOMING to "UPCOMIN" — a control
        // that cannot be read is not one. Everything scrolls together now, each label at its
        // own width; at the default text size the whole row fits without scrolling, and at a
        // larger one, or with a long brand chosen, it scrolls rather than eliding a word.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    ForEach(FeedFilter.allCases) { option in
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { filter = option }
                        } label: {
                            FilterLabel(text: option.label, isOn: filter == option)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityAddTraits(filter == option ? .isSelected : [])
                    }
                    Rectangle()
                        .fill(Color.hairline)
                        .frame(width: 1, height: 13)
                    brandMenu
                        .id(Self.brandID)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            // A brand chosen from the menu is the selection, and a selection scrolled off
            // the edge is one you cannot see you made.
            .onChange(of: brand) { _, _ in
                withAnimation { proxy.scrollTo(Self.brandID, anchor: .trailing) }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(Color.paper)
    }

    private static let brandID = "brand-menu"

    private var chosen: Brand? {
        brand.flatMap { key in brands.first { $0.id.uuidString == key } }
    }

    /// A menu row, ticked when it is the one chosen.
    @ViewBuilder
    private func choice(_ name: String, isOn: Bool) -> some View {
        if isOn { Label(name, systemImage: "checkmark") } else { Text(name) }
    }

    private var brandMenu: some View {
        Menu {
            Button {
                brand = nil
            } label: {
                choice("All brands", isOn: brand == nil)
            }
            Divider()
            ForEach(brands) { item in
                Button {
                    brand = item.id.uuidString
                } label: {
                    // A quiet brand is still here — it is followed — and says why it is
                    // empty, so choosing it does not read as a broken filter.
                    choice(item.name, isOn: brand == item.id.uuidString)
                    if item.followMode != .everything {
                        Text(item.followMode.title)
                    }
                }
            }
            Divider()
            // **Adding a brand lives with the brands.** The rail's first tile did this, and
            // the feed's toolbar is kept for the one control every tab carries. You ›
            // Following is the other way in; the empty feed is the third.
            Button("Add a brand", systemImage: "plus", action: addBrand)
        } label: {
            FilterLabel(text: chosen?.name ?? "Brand", isOn: chosen != nil, opens: true)
        }
        .accessibilityLabel(chosen.map { "Brand: \($0.name)" } ?? "Brand")
    }
}

/// One choice in the row: tracked caps, with a rule under the one that is on — the strip
/// `SavedView` uses for its modes, so the two read as the same control.
private struct FilterLabel: View {
    let text: String
    let isOn: Bool
    /// Whether this opens a menu rather than choosing on the spot.
    var opens = false

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                Text(text.uppercased())
                    .font(.wordmark(10.5, isOn ? .semibold : .regular))
                    .tracking(0.8)
                    .lineLimit(1)
                if opens {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(isOn ? Color.ink : Color.muted)
            Rectangle()
                .fill(isOn ? Color.ink : Color.clear)
                .frame(height: 1)
        }
        .fixedSize()
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
