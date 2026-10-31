// OnboardingTour.swift
// Four cards that say what the app does, each a picture of the app and one sentence.
//
// They replace "How it works" — four features in two sizes of grey text, one of them a swipe
// the app no longer has. A card is what somebody skims on the screen where they are least
// invested in reading: so each is one surface of the app drawn in its own type, a headline and
// a sentence. The pictures are composed from the design system rather than captured, so they
// stay true when the palette or the type moves, and never show a real brand's photograph.
//
// Shown at the start of the first run (`OnboardingView`) and again from You › Help
// (`TourSheet`).

import SwiftUI

/// The cards, paged. The caller owns the page so it can say "Next" and "Continue".
struct TourCards: View {
    @Binding var page: Int

    static let count = TourCard.allCases.count

    var body: some View {
        TabView(selection: $page) {
            ForEach(TourCard.allCases) { card in
                TourCardView(card: card)
                    .tag(card.rawValue)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

/// The dots under the cards, in ink — the system's page dots are white on paper.
struct TourDots: View {
    let page: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<TourCards.count, id: \.self) { index in
                Rectangle()
                    .fill(index == page ? Color.ink : Color.hairline)
                    .frame(width: index == page ? 22 : 8, height: index == page ? 3 : 1)
            }
        }
        .animation(.easeOut(duration: 0.15), value: page)
        .accessibilityHidden(true)
    }
}

enum TourCard: Int, CaseIterable, Identifiable {
    case watch, follow, share, search

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .watch: "Watch your shops"
        case .follow: "Follow only what you want"
        case .share: "Save from anywhere"
        case .search: "Search everything, or scan it"
        }
    }

    var line: String {
        switch self {
        case .watch: "New drops, restocks in your size and sales, from every shop you follow, in one feed."
        case .follow: "Hear about everything from a brand, only its sales, or just the pieces you choose."
        case .share: "In Safari or any app, tap Share, then Dropwall, and it's saved."
        case .search: "Describe a garment to search every shop we watch — or photograph one to find it."
        }
    }
}

private struct TourCardView: View {
    let card: TourCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            illustration
                .frame(maxWidth: .infinity)
                .frame(height: 420)
                .background(Color.wash)
                .clipped()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text(card.title)
                    .font(.editorial(30))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.line)
                    .font(.editorial(18))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch card {
        case .watch: TourFeedPicture()
        case .follow: TourFollowPicture()
        case .share: TourSharePicture()
        case .search: TourSearchPicture()
        }
    }
}

// MARK: - The pictures

/// A garment on the sweep, standing in for a shop's photograph.
private struct TourPhoto: View {
    let symbol: String
    var height: CGFloat = 120

    var body: some View {
        Color.sweep
            .frame(height: height)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: height * 0.36, weight: .light))
                    .foregroundStyle(Color.sweepInk.opacity(0.78))
            }
    }
}

/// One feed card as the feed draws it: photograph, brand, one label, the price.
private struct MiniFeedCard: View {
    let symbol: String
    let brand: String
    let label: String
    var urgent = false
    let price: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TourPhoto(symbol: symbol, height: 96)
            Wordmark(name: brand, size: 10)
            HStack(spacing: 5) {
                if urgent {
                    Circle().fill(Color.signal).frame(width: 5, height: 5)
                }
                Text(label)
                    .font(.data(9, .medium))
                    .tracking(0.6)
                    .foregroundStyle(urgent ? Color.signal : Color.ink)
            }
            Text(price)
                .font(.data(10))
                .foregroundStyle(Color.ink)
        }
    }
}

/// The feed: two columns of events across brands.
private struct TourFeedPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(["All", "Drops", "Restocks", "Sales"], id: \.self) { chip in
                    Text(chip.uppercased())
                        .font(.data(9, chip == "All" ? .semibold : .regular))
                        .foregroundStyle(chip == "All" ? Color.paper : Color.ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(chip == "All" ? Color.ink : Color.paper)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                MiniFeedCard(symbol: "tshirt.fill", brand: "Kith", label: "NEW", price: "$95")
                MiniFeedCard(symbol: "shoe.fill", brand: "Aimé Leon Dore", label: "BACK IN YOUR SIZE", urgent: true, price: "$240")
            }
            HStack(alignment: .top, spacing: 12) {
                MiniFeedCard(symbol: "handbag.fill", brand: "Staud", label: "−30%", price: "$171")
                MiniFeedCard(symbol: "hanger", brand: "Palace", label: "LOCKED · DROP IMMINENT", urgent: true, price: "—")
            }
        }
        .padding(.horizontal, 28)
            }
}

/// A brand page's "What reaches you": the mode, and the pieces.
private struct TourFollowPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Wordmark(name: "Aimé Leon Dore", size: 16)
            VStack(alignment: .leading, spacing: 10) {
                NoteLine(text: "What reaches you", size: 13)
                HStack(spacing: 18) {
                    ForEach(["Everything", "Sales only", "Quiet"], id: \.self) { mode in
                        let isOn = mode == "Everything"
                        VStack(spacing: 5) {
                            Text(mode.uppercased())
                                .font(.wordmark(10, isOn ? .semibold : .regular))
                                .tracking(1.2)
                                .foregroundStyle(isOn ? Color.ink : Color.muted)
                            Rectangle().fill(isOn ? Color.ink : Color.clear).frame(height: 1)
                        }
                        .fixedSize()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                NoteLine(text: "Which pieces", size: 13)
                FlowRow(spacing: 7) {
                    ForEach([("Knitwear", true), ("Trousers", true), ("Shoes", false), ("Outerwear", true), ("Accessories", false)], id: \.0) { chip, isOn in
                        HStack(spacing: 5) {
                            if isOn {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                            }
                            Text(chip).font(.data(10, isOn ? .semibold : .regular))
                        }
                        .foregroundStyle(isOn ? Color.paper : Color.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(isOn ? Color.ink : Color.paper)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
    }
}

/// A product page in Safari with the share sheet up and Dropwall in its row.
private struct TourSharePicture: View {
    var body: some View {
        VStack(spacing: 0) {
            // The address bar.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 8))
                Text("kith.com/products/wool-overshirt")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Color.ink.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.paper, in: Capsule())
            .padding(.top, 20)

            TourPhoto(symbol: "tshirt.fill", height: 110)
                .padding(.horizontal, 70)
                .padding(.top, 14)

            Spacer(minLength: 12)

            // The share sheet.
            VStack(alignment: .leading, spacing: 12) {
                Capsule().fill(Color.hairline).frame(width: 36, height: 4).frame(maxWidth: .infinity)
                HStack(alignment: .top, spacing: 18) {
                    shareApp(name: "Dropwall", isOurs: true)
                    shareApp(name: "Messages")
                    shareApp(name: "Mail")
                    shareApp(name: "Notes")
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 14)
            .background(Color.paper)
        }
        .padding(.horizontal, 22)
    }

    private func shareApp(name: String, isOurs: Bool = false) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOurs ? Color.ink : Color.hairline)
                .frame(width: 52, height: 52)
                .overlay {
                    if isOurs { Tags().frame(width: 30, height: 22) }
                }
                .overlay {
                    if isOurs {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(Color.signal, lineWidth: 2)
                            .padding(-4)
                    }
                }
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(Color.ink)
        }
    }

    /// The icon's mark, roughly: two swing tickets on a wire.
    private struct Tags: View {
        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.15))
                    path.addQuadCurve(to: CGPoint(x: w, y: h * 0.15), control: CGPoint(x: w / 2, y: h * 0.45))
                }
                .stroke(Color.paper, lineWidth: 1)
                Rectangle().fill(Color.paper)
                    .frame(width: w * 0.28, height: h * 0.6)
                    .offset(x: w * 0.16, y: h * 0.34)
                Rectangle().fill(Color.paper)
                    .frame(width: w * 0.28, height: h * 0.6)
                    .offset(x: w * 0.56, y: h * 0.38)
            }
        }
    }
}

/// Shop's field with a description in it, the scope under it, and the first results.
private struct TourSearchPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Text("Black trousers under 200")
                    .font(.editorial(15))
                Spacer(minLength: 8)
                Image(systemName: "camera")
                    .font(.system(size: 13))
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.paper)
            .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))

            NoteLine(text: "18 matches in every shop we watch.", size: 13, color: .ink)
                .padding(.bottom, 4)

            HStack(alignment: .top, spacing: 12) {
                result(symbol: "hanger", brand: "Carhartt WIP", price: "$120")
                result(symbol: "hanger", brand: "Drake's", price: "$185")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
    }

    private func result(symbol: String, brand: String, price: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TourPhoto(symbol: symbol, height: 130)
            Wordmark(name: brand, size: 10)
            Text(price).font(.data(10)).foregroundStyle(Color.ink)
        }
    }
}

// MARK: - Replaying

/// The cards again, from You › Help.
struct TourSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .font(.data(13, .semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
            }
            TourCards(page: $page)
            VStack(spacing: 18) {
                TourDots(page: page)
                Button {
                    if page < TourCards.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(page < TourCards.count - 1 ? "Next" : "Done")
                        .font(.wordmark(13))
                        .tracking(1.2)
                        .foregroundStyle(Color.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.ink)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 12)
        }
        .background(Color.paper)
    }
}
