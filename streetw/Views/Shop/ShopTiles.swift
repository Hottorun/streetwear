// ShopTiles.swift
// The pieces Shop is drawn from: a result in the grid, a pick, and the chips under the field.
//
// Both product units are the feed's vocabulary rather than a third one — `UpdateImage` or
// `ImageGallery`, `SaveAction` on the corner of the photograph, the `SizeRun` with your sizes
// ruled in vermilion, the menu every card shares — so a garment looks the same whichever tab
// it was found on, and saving one here is the same act as saving it anywhere else.

import StreetwCore
import SwiftData
import SwiftUI

/// A pick, with the rows it names. Resolved once per pass of the picks, never per body.
struct ShopPick: Identifiable {
    let update: BrandUpdate
    /// The owned piece the reason is about, when there is one.
    let partner: BrandUpdate?
    let pick: DailyPicks.Pick

    var id: String { pick.id }

    /// The one line the card exists to print.
    ///
    /// Every branch is a sentence the app can stand behind: a pairing `Pairing` actually
    /// found, a slot the wardrobe actually lacks, or something the store knows happened. A
    /// pick with none of those is never chosen (`DailyPicks.choose`), so there is no branch
    /// here that has to make one up.
    var headline: String {
        let brand = update.brand?.name ?? "a shop you follow"
        switch pick.reason {
        case .goesWith(let fills):
            let partnerName = partner.map { "your \($0.title)" } ?? "what you own"
            if let fills { return "You own no \(Self.noun(for: fills)) yet — this goes with \(partnerName)" }
            return "Goes with \(partnerName)"
        case .fills(let slot):
            return "You own no \(Self.noun(for: slot)) yet"
        case .fact(.backInYourSize):
            return "Back in your size"
        case .fact(.markedDown(let percent)):
            return "Marked down \(percent)% at \(brand)"
        case .fact(.new):
            return "New at \(brand) this week"
        case .fromYourShops:
            return "From \(brand), a shop you follow"
        }
    }

    /// The small line under it: the pairing's own reason, or which of your sizes came back.
    var detail: String? {
        if case .fact(.backInYourSize(let sizes)) = pick.reason {
            return "BACK IN " + sizes.joined(separator: ", ").uppercased()
        }
        return pick.detail?.uppercased()
    }

    /// Vermilion only for the restock, which is the one reason that is about now.
    var isTimely: Bool {
        if case .fact(.backInYourSize) = pick.reason { return true }
        return false
    }

    /// What a slot is called in a sentence about owning none of it.
    private static func noun(for slot: GarmentSlot) -> String {
        switch slot {
        case .outerwear: "outerwear"
        case .top: "tops"
        case .bottom: "bottoms"
        case .footwear: "shoes"
        case .headwear: "headwear"
        case .accessory: "accessories"
        case .unknown: "pieces like this"
        }
    }
}

/// One of today's picks: the garment, the reason with your own piece beside it, and the
/// ways to act on it.
struct ShopPickCard: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let pick: ShopPick
    let onOpenFit: () -> Void
    let onRefuse: () -> Void

    private var update: BrandUpdate { pick.update }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ImageGallery(
                    urls: update.imageURLs,
                    kind: update.kind,
                    drawnWidth: 400,
                    mark: update.brand?.name
                )
                SaveAction(update: update)
                    .padding(12)
            }
            .contentShape(.rect)
            .productLink(update)
            .accessibilityLabel(update.title)

            reason
                .padding(.horizontal, 20)
                .padding(.top, 14)

            VStack(alignment: .leading, spacing: 8) {
                Text(update.title)
                    .font(.editorial(17))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline) {
                    Wordmark(name: update.brand?.name ?? "", size: 11)
                    Spacer(minLength: 8)
                    ShopPrice(update: update, size: 12)
                }

                HStack(alignment: .firstTextBaseline) {
                    SizeRun(entries: SizeRun.entries(for: update, profile: sizes.profile), size: 11)
                    Spacer(minLength: 12)
                    // Quiet and last: turning something down is the rare act, and it must not
                    // be the thing a thumb lands on by accident on its way to the photograph.
                    Button(action: onRefuse) {
                        DataLabel(text: "NOT FOR ME", size: 9)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .layoutPriority(1)
                }
                .clipped()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .contentShape(.rect)
            .productLink(update)
        }
        .contextMenu {
            UpdateMenu(update: update)
            Divider()
            Button("Not for me", systemImage: "hand.thumbsdown", action: onRefuse)
        }
    }

    /// The argument, with the evidence beside it.
    ///
    /// A sentence claiming a match is a claim; the same sentence with a photograph of your own
    /// trousers next to it is checkable at a glance — `DiscoverCardView.anchorRow`'s reasoning,
    /// on paper rather than on the deck's dark foot. When there is a partner, the row is the
    /// way into the whole outfit: the card says this goes with something you own, and the next
    /// question is always what the fit would look like.
    @ViewBuilder
    private var reason: some View {
        let content = HStack(alignment: .center, spacing: 12) {
            if let partner = pick.partner {
                UpdateImage(
                    url: partner.primaryImageURL,
                    kind: partner.kind,
                    aspect: 1,
                    contentMode: .fit,
                    drawnWidth: 80,
                    // The wall's ground: this is a photograph of something kept.
                    backdrop: .sweep,
                    mark: partner.brand?.name
                )
                .frame(width: 48)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(pick.headline)
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = pick.detail {
                    DataLabel(text: detail, size: 9.5, color: pick.isTimely ? .signal : .muted)
                }
            }
            Spacer(minLength: 0)
            if pick.partner != nil {
                HStack(spacing: 4) {
                    DataLabel(text: "SEE THE FIT", size: 9)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.muted)
                }
                .fixedSize()
            }
        }

        if pick.partner != nil {
            Button(action: onOpenFit) { content.contentShape(.rect) }
                .buttonStyle(.borderless)
                .accessibilityHint("Builds the whole outfit around it")
        } else {
            content
        }
    }
}

/// One search result: the photograph, what it is, who made it, what it costs and whether it
/// comes in your size.
struct ShopResultTile: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let update: BrandUpdate
    /// The words a partial match carried, printed because they are the whole reason it is
    /// on the page. Nil for an exact match, where the reading above already says it.
    let matched: [String]?
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                UpdateImage(
                    url: update.primaryImageURL,
                    kind: update.kind,
                    aspect: 1,
                    drawnWidth: 200,
                    mark: update.brand?.name
                )
                SaveAction(update: update)
            }

            Text(update.title)
                .font(.editorial(13))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Wordmark(name: update.brand?.name ?? "", size: 9)
                Spacer(minLength: 4)
                ShopPrice(update: update, size: 11)
            }

            // Wrapping, and capped: a cap on the token count is not a cap on the width, so a
            // run of waist sizes would otherwise push the price into the next column — the
            // failure `MemberTile` documents.
            if isAvailable {
                SizeRun(
                    entries: SizeRun.entries(for: update, profile: sizes.profile),
                    size: 10,
                    limit: 5,
                    wraps: true
                )
            } else {
                DataLabel(text: "SOLD OUT", size: 9)
            }

            if let matched, !matched.isEmpty {
                DataLabel(text: "MATCHED " + matched.joined(separator: " · ").uppercased(), size: 8.5)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
        .productLink(update)
        .contextMenu { UpdateMenu(update: update) }
    }
}

/// The price as the feed prints it — the brand's own cut beside it when there is one.
struct ShopPrice: View {
    let update: BrandUpdate
    var size: CGFloat = 11

    var body: some View {
        if let price = update.priceLabel {
            Text([price, update.percentOffText].compactMap { $0 }.joined(separator: " "))
                .font(.data(size, .medium))
                .foregroundStyle(Color.ink)
                .fixedSize()
                .layoutPriority(1)
        }
    }
}

/// A refinement under the field, in the caps-and-capsule shape the app's chips take.
///
/// - Parameter isTyped: the same flag was set by a word in the field. The chip shows it on
///   and cannot switch it off — the word would only put it back — so it says so by being
///   disabled rather than by appearing to work.
struct ShopChip: View {
    let title: String
    let isOn: Bool
    var isTyped = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title.uppercased())
                    .font(.data(10, .medium))
                    .tracking(0.6)
            }
            .foregroundStyle(isOn ? Color.paper : Color.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isOn ? Color.ink : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(Color.ink.opacity(isOn ? 0 : 0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .disabled(isTyped)
        .opacity(isTyped ? 0.55 : 1)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
