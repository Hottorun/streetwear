// ShareSheet.swift
// What the share sheet offers once the save is made: boards, a watch, or following the shop.
//
// Every choice is an *intent*, written into the share's inbox file and acted on by the app
// on its next foreground — the extension fetches nothing and opens no store. So the sheet says
// what will happen ("Dropwall will ask what you want to see when you next open it") rather
// than pretending it has already happened.

import Observation
import StreetwCore
import SwiftUI

/// One share, as the sheet is amending it.
@MainActor
@Observable
final class ShareDraft {
    enum Failure: Equatable {
        case noLink
        case noContainer
        case failed

        var headline: String {
            switch self {
            case .noLink: "Nothing to save"
            case .noContainer: "Dropwall can't reach its storage"
            case .failed: "Couldn't save that"
            }
        }

        var detail: String {
            switch self {
            case .noLink: "THIS DOESN'T CONTAIN A LINK"
            case .noContainer: "REINSTALL THE APP TO FIX IT"
            case .failed: "TRY AGAIN"
            }
        }
    }

    private(set) var failure: Failure?
    private var save: SharedSave?
    private var file: URL?

    let role: PageRole
    let product: ProductPage?
    let heading: String
    let shopName: String
    let isFollowed: Bool
    let boards: [SharedContext.Board]
    /// Sizes the page names, in its order and spelling.
    let sizes: [String]
    let colors: [String]
    let marksDownAreSaid: Bool

    var chosenBoards: Set<UUID> = [] { didSet { write() } }
    var newBoards: [String] = [] { didSet { write() } }
    var follows = false { didSet { write() } }
    var notifies = false { didSet { write() } }
    var chosenSizes: Set<String> = [] { didSet { write() } }
    var chosenColor: String? { didSet { write() } }

    init(failure: Failure) {
        self.failure = failure
        role = .product
        product = nil
        heading = ""
        shopName = ""
        isFollowed = false
        boards = []
        sizes = []
        colors = []
        marksDownAreSaid = false
    }

    init(save: SharedSave, context: SharedContext?) {
        self.save = save
        let base = save.page?.url ?? save.url
        let metadata = save.page?.metadata(base: base)
        let product = save.page?.product(base: base)
        self.product = product
        role = PageRole.of(base, product: product, metadata: metadata)

        let host = base.host()?.replacingOccurrences(of: "www.", with: "") ?? base.absoluteString
        shopName = metadata?.siteName.flatMap(BrandNaming.tidy) ?? host
        let domain = BrandDiscovery.registrableDomain(of: base.host() ?? "")
        isFollowed = context?.followedDomains.contains(domain) == true
        heading = product?.name ?? metadata?.title ?? save.title ?? host
        boards = context?.boards ?? []

        let variants = product?.variants ?? []
        // Only a variant that names a size is a size. A group whose variants say nothing but
        // the product's name again — Intimissimi's do — has no run to offer, and the app asks.
        sizes = variants.compactMap(\.size).uniqued()
        colors = variants.compactMap(\.color).uniqued()
        // Said only where it is true: a save's markdown is told from a followed shop's feed.
        marksDownAreSaid = isFollowed && (context?.savedPriceDropAlerts ?? true)

        // Your sizes pre-selected, read on this garment's own ladder exactly as the app reads it.
        if let profile = context?.sizes, !profile.isEmpty, !sizes.isEmpty {
            let name = product?.name ?? heading
            let sizeContext = SizeContext.matters(for: sizes)
                ? SizeContext.of(
                    gender: GenderClassifier.classify(title: name, productType: product?.category),
                    title: name,
                    productType: product?.category,
                    sizes: sizes
                )
                : .unknown
            chosenSizes = Set(sizes.filter { profile.claims($0, in: sizeContext) })
        }
    }

    /// Whether the page is saved at all — a shop page being followed is not.
    var savesPage: Bool { !(role == .shop && follows) }

    /// The first write, before anything is drawn.
    func start() {
        guard failure == nil else { return }
        write()
        if file == nil { failure = .failed }
    }

    func finish() {
        guard failure == nil else { return }
        save?.isComplete = true
        write()
    }

    func addBoard(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !newBoards.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        if let existing = boards.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            chosenBoards.insert(existing.id)
        } else {
            newBoards.append(name)
        }
    }

    private func write() {
        guard var save else { return }
        save.role = role
        save.boardIDs = chosenBoards.isEmpty ? nil : Array(chosenBoards)
        save.newBoards = newBoards.isEmpty ? nil : newBoards
        save.follow = role == .shop && follows ? true : nil
        if role == .product && notifies {
            save.notify = SharedNotify(
                sizes: sizes.filter(chosenSizes.contains),
                color: chosenColor,
                askSize: sizes.isEmpty
            )
        } else {
            save.notify = nil
        }
        self.save = save
        file = SharedInbox.write(save, to: file)
    }
}

/// Same voice as the app: paper, a serif line for what happened, mono for data. The design
/// system lives in the app target, so the few values it needs are restated below rather than
/// dragging the whole file into a second target.
struct ShareSheet: View {
    @Bindable var draft: ShareDraft
    let onDone: () -> Void

    @State private var isNaming = false
    @State private var boardName = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let failure = draft.failure {
                        header(label: failure.detail, title: failure.headline)
                    } else {
                        content
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            Button(action: onDone) {
                Text("DONE")
                    .font(ShareStyle.data(12, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(ShareStyle.paper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(ShareStyle.ink)
            }
            .buttonStyle(.borderless)
            .padding(20)
        }
        .background(ShareStyle.paper)
    }

    @ViewBuilder
    private var content: some View {
        if draft.role == .shop {
            header(
                label: draft.follows ? "NOTHING SAVED · FOLLOWING INSTEAD" : "SAVED AS A LINK",
                title: draft.shopName
            )
            followSection
        } else {
            header(label: "SAVED TO DROPWALL", title: draft.heading)
        }

        if draft.savesPage {
            boardSection
        }
        if draft.role == .product {
            notifySection
        }
    }

    private func header(label: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShareLabel(text: label)
            Text(title)
                .font(ShareStyle.editorial(22))
                .foregroundStyle(ShareStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Follow

    @ViewBuilder
    private var followSection: some View {
        if draft.isFollowed {
            Text("You already follow \(draft.shopName).")
                .font(ShareStyle.editorial(15))
                .foregroundStyle(ShareStyle.muted)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ShareChip(
                    label: draft.follows ? "Following \(draft.shopName)" : "Follow \(draft.shopName)",
                    isOn: draft.follows,
                    systemImage: draft.follows ? "checkmark" : "plus"
                ) { draft.follows.toggle() }
                Text(draft.follows
                     ? "Dropwall will ask what you want to see when you next open it."
                     : "This looks like a shop rather than one product.")
                    .font(ShareStyle.data(11))
                    .foregroundStyle(ShareStyle.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Boards

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShareLabel(text: "BOARD")
            ShareFlow(spacing: 8) {
                ForEach(draft.boards) { board in
                    ShareChip(label: board.name, isOn: draft.chosenBoards.contains(board.id)) {
                        if draft.chosenBoards.contains(board.id) {
                            draft.chosenBoards.remove(board.id)
                        } else {
                            draft.chosenBoards.insert(board.id)
                        }
                    }
                }
                ForEach(draft.newBoards, id: \.self) { name in
                    ShareChip(label: name, isOn: true, systemImage: "xmark") {
                        draft.newBoards.removeAll { $0 == name }
                    }
                }
                if !isNaming {
                    ShareChip(label: "New board…", isOn: false, systemImage: "plus") { isNaming = true }
                }
            }
            if isNaming {
                HStack(spacing: 10) {
                    TextField("Board name", text: $boardName)
                        .font(ShareStyle.editorial(15))
                        .submitLabel(.done)
                        .onSubmit(addBoard)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(ShareStyle.wash)
                    Button("ADD", action: addBoard)
                        .font(ShareStyle.data(11, .semibold))
                        .foregroundStyle(ShareStyle.ink)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func addBoard() {
        draft.addBoard(named: boardName)
        boardName = ""
        isNaming = false
    }

    // MARK: - Notify

    private var notifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShareChip(
                label: "Notify me",
                isOn: draft.notifies,
                systemImage: draft.notifies ? "bell.fill" : "bell"
            ) { draft.notifies.toggle() }

            if draft.notifies {
                if draft.sizes.isEmpty {
                    note("This page lists no sizes. Dropwall will ask which one when you next open it.")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ShareLabel(text: "SIZE")
                        ShareFlow(spacing: 8) {
                            ShareChip(label: "Any size", isOn: draft.chosenSizes.isEmpty) {
                                draft.chosenSizes = []
                            }
                            ForEach(draft.sizes, id: \.self) { size in
                                ShareChip(label: size, isOn: draft.chosenSizes.contains(size)) {
                                    if draft.chosenSizes.contains(size) {
                                        draft.chosenSizes.remove(size)
                                    } else {
                                        draft.chosenSizes.insert(size)
                                    }
                                }
                            }
                        }
                    }
                }
                if !draft.colors.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShareLabel(text: "COLOUR")
                        ShareFlow(spacing: 8) {
                            ShareChip(label: "Any colour", isOn: draft.chosenColor == nil) {
                                draft.chosenColor = nil
                            }
                            ForEach(draft.colors, id: \.self) { color in
                                ShareChip(label: color, isOn: draft.chosenColor == color) {
                                    draft.chosenColor = draft.chosenColor == color ? nil : color
                                }
                            }
                        }
                    }
                }
                note("Dropwall tells you when one of these is back in stock.")
            }
            if draft.marksDownAreSaid {
                note("If it's marked down, Dropwall tells you that too.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(ShareStyle.data(11))
            .foregroundStyle(ShareStyle.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The few pieces of the app's design system the sheet draws with

enum ShareStyle {
    static let ink = adaptive(light: 0x14140F, dark: 0xF5F5F0)
    static let paper = adaptive(light: 0xFAFAF7, dark: 0x0E0E0C)
    static let wash = adaptive(light: 0xEFEEE9, dark: 0x1C1C19)
    static let muted = adaptive(light: 0x8A8A80, dark: 0x87877D)

    static func editorial(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .body).scaledValue(for: size), weight: weight, design: .serif)
    }

    static func data(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .caption2).scaledValue(for: size), weight: weight, design: .monospaced)
    }

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private struct ShareLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ShareStyle.data(11))
            .tracking(0.4)
            .foregroundStyle(ShareStyle.muted)
    }
}

/// The app's chip: ink when on, wash when off, mono caps.
private struct ShareChip: View {
    let label: String
    let isOn: Bool
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(label.uppercased())
                    .font(ShareStyle.data(11, isOn ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? ShareStyle.paper : ShareStyle.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isOn ? ShareStyle.ink : ShareStyle.wash)
        }
        .buttonStyle(.borderless)
    }
}

/// Chips that wrap, answering with the width they were proposed — the property the app's
/// `FlowRow` exists for, so one long board name cannot widen the whole sheet.
private struct ShareFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + min(size.width, width)
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0.lowercased()).inserted }
    }
}
