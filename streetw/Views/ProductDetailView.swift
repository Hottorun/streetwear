// ProductDetailView.swift
// The page a product gets when you tap it.
//
// Until now a tap went straight to Safari, which threw away everything the app had
// already fetched: eight photographs, the full size run, every colourway, the
// description, the tags. The catalogue hands all of it over for free and the feed card
// has room for none of it — so the choice was between a card that can't show it and a
// browser that doesn't know about your size profile.
//
// The buy still happens on the storefront, and the button that takes you there is the
// loudest thing on the page. What happens *here* is the deciding: is it my size, does it
// come in black, what does the back look like, and — the one thing the storefront cannot
// offer — tell me when it comes back.

import StreetwCore
import SwiftData
import SwiftUI

struct ProductDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore
    @Environment(SaveConfirmation.self) private var confirmation: SaveConfirmation

    let update: BrandUpdate

    /// Narrows the size run and the watch button. Nil means "all colours", which is also
    /// the only option for a product without a colour axis.
    @State private var selectedColorway: String?
    /// Which photograph the gallery is showing, held here rather than inside it because
    /// choosing a colourway is a statement about which photograph you want.
    @State private var imageIndex = 0

    private var colorways: [Colorway] { update.colorways }

    /// Variants in the chosen colourway, or all of them when none is chosen.
    private var visibleVariants: [VariantInfo] {
        guard let selectedColorway else { return update.variants }
        return update.variants.filter {
            $0.color?.caseInsensitiveCompare(selectedColorway) == .orderedSame
        }
    }

    private var runEntries: [SizeRun.Entry] {
        SizeRun.entries(for: visibleVariants, profile: sizes.profile)
    }

    /// Sold out in everything currently shown — the state the watcher exists for.
    private var isSoldOut: Bool {
        guard !visibleVariants.isEmpty else { return update.isAvailable == false }
        return !visibleVariants.contains { $0.available }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ImageGallery(
                    urls: update.imageURLs,
                    kind: update.kind,
                    // The detail page is the one place a horizontal swipe is unambiguous:
                    // nothing here files or dismisses, so paging owns the gesture outright.
                    isPagingEnabled: true,
                    // And the one place a tap has nothing better to do — the card's tap
                    // already brought you here. Deciding whether a fabric is the right
                    // one is most of what this page is for, and that needs the pixels the
                    // storefront is already publishing.
                    isZoomable: true,
                    mark: update.brand?.name,
                    selection: $imageIndex
                )
                .overlay(alignment: .topTrailing) {
                    SaveAction(update: update).padding(12)
                }

                VStack(alignment: .leading, spacing: 26) {
                    heading
                    if !runEntries.isEmpty { sizeSection }
                    if !colorways.isEmpty {
                        ColorwaySection(colorways: colorways, selected: $selectedColorway)
                            .onChange(of: selectedColorway) { _, colour in
                                showPhotograph(of: colour)
                            }
                    }
                    WatchSection(update: update, colorway: selectedColorway, isSoldOut: isSoldOut)
                    if let summary = update.summary, !summary.isEmpty { description(summary) }
                    metadata
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 28)

                // Above "more like this", deliberately. What you already own that goes
                // with this is a better answer than another version of it — and on
                // something not yet kept it is the argument for keeping it.
                GoesWith(subject: update)
                SimilarItems(to: update)
            }
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle(update.brand?.name ?? "")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Filing, from the page the thing is on.
                //
                // A save could only be put on a board from the confirmation toast — which
                // dismisses itself after a few seconds — or by going to the Saved tab and
                // finding it again. So the answer to "actually, this belongs with the
                // others" was to leave the product and go looking for it.
                Menu {
                    UpdateMenu(update: update)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { buyBar }
        .onAppear {
            // Opening the page is acknowledging the item, the same as tapping through to
            // the site used to be.
            update.isSeen = true
            try? context.save()
            // Lift the save confirmation clear of the buy bar while this page is up.
            confirmation.bottomClearance = StorefrontBar.height
        }
        .onDisappear { confirmation.bottomClearance = 0 }
    }

    // MARK: - Sections

    private var heading: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let state = FeedState(update: update, profile: sizes.profile) {
                DataLabel(text: state.text, size: 11, color: state.color)
            }
            Text(update.title)
                .font(.editorial(25))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let price = update.priceText {
                    Text(price)
                        .font(.data(15, .medium))
                        .foregroundStyle(Color.ink)
                }
                if let was = update.previousPriceText, update.kind == .priceDrop {
                    Text(was)
                        .font(.data(12))
                        .foregroundStyle(Color.muted)
                        .strikethrough(color: .muted)
                }
                Spacer(minLength: 0)
                DataLabel(text: Stamp.short(update.publishedAt).uppercased())
            }
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DataLabel(text: "SIZES")
                Spacer()
                if !sizes.profile.isEmpty {
                    DataLabel(text: "YOURS: \(sizes.profile.summary.uppercased())", size: 9)
                }
            }
            // No `limit` here, unlike the feed card. A sneaker's full run is 5–13 in half
            // sizes and gets truncated to an ellipsis in a card; on this page there is
            // room to print all of it, and printing all of it is the reason to be here —
            // but only across several lines. Unwrapped, a run that long is wider than the
            // phone and takes the whole page's width with it.
            SizeRun(entries: runEntries, size: 14, limit: .max, wraps: true)
        }
    }

    private func description(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: "DETAILS")
            Text(text)
                .font(.editorial(14))
                .foregroundStyle(Color.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var metadata: some View {
        let facts: [(String, String)] = [
            ("KIND", update.kind.label),
            update.productType.map { ("TYPE", $0) },
            update.gender == .unknown ? nil : ("CUT", update.gender.label)
        ].compactMap { $0 }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(facts, id: \.0) { label, value in
                HStack {
                    DataLabel(text: label, size: 9)
                    Spacer()
                    DataLabel(text: value.uppercased(), size: 9, color: .ink)
                }
            }
        }
    }

    /// Pinned to the bottom rather than buried in the scroll: buying is what the page is
    /// for, and it must be reachable without hunting for it.
    @ViewBuilder
    private var buyBar: some View {
        if let link = update.linkURL {
            StorefrontBar(url: link, isSoldOut: isSoldOut)
        }
    }

    private func showPhotograph(of colour: String?) {
        guard let index = update.imageIndex(forColorway: colour) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { imageIndex = index }
    }
}

extension BrandUpdate {
    /// Which photograph shows a colourway, if the catalogue said.
    ///
    /// Nil is a real and common answer, and callers must treat it as "leave the gallery
    /// alone" rather than as an error. Plenty of storefronts publish no association at
    /// all; plenty more — Palace and BBC among them — put each colourway on its own
    /// product handle, so the colour axis has exactly one value and there is nothing to
    /// move to. Deselecting also lands here, deliberately: "Show all" is not a request to
    /// yank the gallery back to the first frame.
    func imageIndex(forColorway colour: String?) -> Int? {
        guard let colour else { return nil }
        let match = variants.first {
            $0.color?.caseInsensitiveCompare(colour) == .orderedSame && $0.imageIndex != nil
        }
        guard let index = match?.imageIndex, imageURLs.indices.contains(index) else { return nil }
        return index
    }
}

// MARK: - Shared product blocks

/// The way out to the storefront, pinned to the bottom of whichever page is showing.
///
/// Shared with the archive rather than restyled there, for the same reason
/// `ColorwaySection` and `WatchSection` are: a saved thing is still a product, and going
/// to look at it on the site is the same act whether you found it in the feed this morning
/// or kept it a year ago. Naming the host — "OPEN ON KITH.COM" — is what makes it a
/// destination rather than a generic link.
struct StorefrontBar: View {
    @Environment(\.openURL) private var openURL

    let url: URL
    var isSoldOut: Bool

    /// What the bar overlaps and therefore has to be lifted clear of, in points. The save
    /// confirmation reads this so it never covers the one control the page is for.
    static let height: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            Rule()
            Button {
                openURL(url)
            } label: {
                HStack(spacing: 8) {
                    Text(isSoldOut ? "VIEW ON SITE" : "OPEN ON \(host)")
                        .font(.data(12, .semibold))
                        .tracking(1.1)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.paper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(Color.ink)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
        .background(.bar)
    }

    /// "KITH.COM" — naming the destination, so the button says where it goes.
    private var host: String {
        (url.host() ?? "site").replacingOccurrences(of: "www.", with: "").uppercased()
    }
}

/// The colourways a product comes in, selectable to narrow the size run and any watch
/// started from the same screen.
///
/// Pulled out of `ProductDetailView` because the archive needs it too. A saved thing is
/// still a product — it has a price, a size run and colourways — and the page that dropped
/// all of that turned "the item I kept" into a title and a photograph, which is exactly
/// the information a bookmark already gives you.
struct ColorwaySection: View {
    let colorways: [Colorway]
    @Binding var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DataLabel(text: "COLOURWAYS")
                Spacer()
                if selected != nil {
                    Button("Show all") { selected = nil }
                        .font(.data(10, .medium))
                        .foregroundStyle(Color.muted)
                        .buttonStyle(.borderless)
                }
            }

            FlowRow(spacing: 10) {
                ForEach(colorways) { colorway in
                    ColorwayChip(
                        colorway: colorway,
                        isSelected: selected?.caseInsensitiveCompare(colorway.name) == .orderedSame
                    ) {
                        selected = selected?.caseInsensitiveCompare(colorway.name) == .orderedSame
                            ? nil
                            : colorway.name
                    }
                }
            }
        }
    }
}

/// Standing watches on a product, and the way to start another.
///
/// On the archive this is the point of the page rather than a footnote: the most common
/// reason to keep something you can't have is that it was sold out, and the app's whole
/// justification is being able to say when it comes back.
struct WatchSection: View {
    @Environment(\.modelContext) private var context

    let update: BrandUpdate
    /// Pre-selects the colourway the surrounding page is showing.
    var colorway: String?
    var isSoldOut: Bool

    @State private var isEditorPresented = false

    var body: some View {
        let active = update.activeWatches
        let fired = update.watches.filter { !$0.isActive }

        VStack(alignment: .leading, spacing: 12) {
            if !active.isEmpty || !fired.isEmpty {
                DataLabel(text: "WATCHING")
                ForEach(active + fired) { watch in
                    WatchRow(watch: watch) { context.delete(watch); try? context.save() }
                }
            }

            Button {
                isEditorPresented = true
            } label: {
                Label(
                    active.isEmpty ? "Notify me when it's back" : "Watch another size",
                    systemImage: "bell"
                )
                .font(.data(12, .medium))
                // The accent, spent here on purpose: on a sold-out product this is the
                // only action available and the whole reason the app exists.
                .foregroundStyle(isSoldOut && active.isEmpty ? Color.signal : Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .overlay(alignment: .top) { Rule() }
            .overlay(alignment: .bottom) { Rule() }
        }
        .sheet(isPresented: $isEditorPresented) {
            WatchEditor(update: update, colorway: colorway)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Colourway chip

/// A swatch plus its name. The swatch is a hint, the name is the authority — brands call
/// things "Nocturne", and `ColorSwatch` returns nil rather than inventing a colour for it.
struct ColorwayChip: View {
    let colorway: Colorway
    let isSelected: Bool
    let action: () -> Void

    private var swatch: Color? {
        ColorSwatch.rgb(for: colorway.name).map {
            Color(red: $0.red, green: $0.green, blue: $0.blue)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 13, height: 13)
                        // A white swatch on near-white paper is invisible without this.
                        .overlay(Circle().stroke(Color.hairline, lineWidth: 0.5))
                        // Sold out reads as a drained swatch, matching the struck-through
                        // sizes in the run above it.
                        .opacity(colorway.isAvailable ? 1 : 0.35)
                }
                Text(colorway.name.uppercased())
                    .font(.data(10, isSelected ? .semibold : .regular))
                    .strikethrough(!colorway.isAvailable, color: .muted)
                    .foregroundStyle(colorway.isAvailable ? Color.ink : Color.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(isSelected ? Color.wash : Color.clear)
            .overlay {
                Rectangle().stroke(isSelected ? Color.ink : Color.hairline, lineWidth: isSelected ? 1 : 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Watches

struct WatchRow: View {
    let watch: StockWatch
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: watch.isActive ? "bell.fill" : "checkmark")
                .font(.system(size: 10))
                .foregroundStyle(watch.isActive ? Color.signal : Color.muted)

            VStack(alignment: .leading, spacing: 2) {
                Text(watch.summary.uppercased())
                    .font(.data(11, .medium))
                    .foregroundStyle(Color.ink)
                if !watch.isActive {
                    DataLabel(
                        text: watch.firedSizes.isEmpty
                            ? "CAME BACK"
                            : "CAME BACK IN \(watch.firedSizes.joined(separator: ", ").uppercased())",
                        size: 9
                    )
                }
            }

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop watching")
        }
    }
}

/// Choosing what to watch. A size and a colour, both optional.
struct WatchEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings

    let update: BrandUpdate
    /// Pre-selected from whatever colourway the page was showing.
    var colorway: String?
    /// Set when the sheet appears unasked-for — after sharing in something sold out —
    /// where it has to say why it is here before it asks anything.
    var headline: String?

    @State private var size: String?
    @State private var color: String?

    /// Every size this product is cut in, sold out or not — you watch what you *can't*
    /// buy, so restricting this to available sizes would empty the list exactly when it
    /// matters.
    private var allSizes: [String] {
        var seen = Set<String>()
        return update.variants
            .filter(\.isMeaningfulSize)
            .filter { color == nil || $0.color?.caseInsensitiveCompare(color!) == .orderedSame }
            .map(\.displaySize)
            .filter { seen.insert($0).inserted }
    }

    private var allColors: [String] { update.colorways.map(\.name) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let headline {
                            Text(headline)
                                .font(.editorial(20))
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(update.title)
                            .font(.editorial(headline == nil ? 18 : 14))
                            .foregroundStyle(headline == nil ? Color.ink : Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !allSizes.isEmpty {
                        picker(title: "SIZE", options: allSizes, selection: $size, anyLabel: "ANY SIZE")
                    }
                    if !allColors.isEmpty {
                        picker(title: "COLOUR", options: allColors, selection: $color, anyLabel: "ANY COLOUR")
                    }

                    Text(settings.isConfigured
                         ? "streetw watches this on the server, so the alert arrives even when the app is closed."
                         : "Without a server this is checked when the app refreshes, so an alert can be late.")
                        .font(.data(11))
                        .foregroundStyle(Color.muted)
                        .lineSpacing(2)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle("Notify me")
            .toolbarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(action: create) {
                    Text("START WATCHING")
                        .font(.data(12, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(Color.ink)
                }
                .buttonStyle(.borderless)
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(.ink)
        .onAppear { color = colorway }
    }

    private func picker(
        title: String,
        options: [String],
        selection: Binding<String?>,
        anyLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DataLabel(text: title)
            FlowRow(spacing: 8) {
                chip(label: anyLabel, isOn: selection.wrappedValue == nil) {
                    selection.wrappedValue = nil
                }
                ForEach(options, id: \.self) { option in
                    chip(label: option, isOn: selection.wrappedValue == option) {
                        selection.wrappedValue = selection.wrappedValue == option ? nil : option
                    }
                }
            }
        }
    }

    private func chip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(.data(11, isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.paper : Color.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(isOn ? Color.ink : Color.wash)
        }
        .buttonStyle(.borderless)
    }

    private func create() {
        let watch = StockWatch(update: update, size: size, color: color)
        context.insert(watch)
        try? context.save()

        // Mirrored server-side so the poller can push it without the app running. A
        // failure here is not fatal — the local watch still fires on the next sync — so
        // it is deliberately not awaited before dismissing.
        if settings.isConfigured {
            Task { await remote.createWatch(watch) }
        }
        dismiss()
    }
}
