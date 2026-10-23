// WatchesView.swift
// Everything you're waiting on.
//
// A watch is neither a feed item nor a saved one. It isn't in the feed because nothing has
// happened yet — that is the whole point of it — and it isn't in the collection because
// the collection is a record of things you kept, not a queue of things you want. Left in
// only the two existing rooms, a watch would be invisible between the moment you set it
// and the moment it fires, which is exactly when you'd want to check what you're waiting
// on and stop waiting for the ones you've gone off.
//
// Reached from the feed's toolbar, and shows fired watches alongside pending ones: seeing
// that the thing you waited for came back is the payoff, and a row that vanishes at the
// moment it succeeds is a worse experience than one that says so.

import StreetwCore
import SwiftData
import SwiftUI

struct WatchesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(RemoteSync.self) private var remote: RemoteSync
    @Environment(ServerSettings.self) private var settings: ServerSettings

    @Query(sort: \StockWatch.createdAt, order: .reverse) private var watches: [StockWatch]

    private var pending: [StockWatch] { watches.filter { $0.isActive && $0.update != nil } }
    private var fired: [StockWatch] { watches.filter { !$0.isActive && $0.update != nil } }

    var body: some View {
        NavigationStack {
            Group {
                if watches.isEmpty {
                    EditorialEmptyState(
                        title: "Nothing on watch",
                        // Not "open something sold out" any more: `SaveConfirmation`
                        // made a watch settable on something in stock, which was the whole
                        // point of it — wanting to know your size went and came back is not
                        // conditional on it being gone right now.
                        action: "OPEN ANYTHING AND ASK TO BE TOLD WHEN YOUR SIZE IS IN STOCK"
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            section("WAITING", watches: pending)
                            section("CAME BACK", watches: fired)
                        }
                        .padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Color.paper)
            .appDestinations()
            .navigationTitle("Watching")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.ink)
    }

    @ViewBuilder
    private func section(_ title: String, watches: [StockWatch]) -> some View {
        if !watches.isEmpty {
            DataLabel(text: title)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(watches) { watch in
                if let update = watch.update {
                    // **`.swipeActions` only works inside a `List`**, and this is a
                    // `LazyVStack` in a `ScrollView` — so the modifier that used to be here
                    // was inert. The swipe is the gesture most people try first, and it did
                    // nothing at all: no movement, no action, no feedback. The feature was
                    // only ever reachable through the context menu, which is a long press
                    // nobody is told about.
                    //
                    // So the affordance is visible instead, in the trailing column, the way
                    // `DropCalendarView` already puts its action beside a row. The context
                    // menu stays for whoever has learned it.
                    HStack(spacing: 12) {
                        NavigationLink(value: ProductRoute(update: update)) {
                            WatchListRow(watch: watch, update: update)
                        }
                        .buttonStyle(.plain)

                        Button { remove(watch) } label: {
                            DataLabel(text: "STOP", color: .signal)
                                // 44pt of target under a small label, which is Apple's
                                // minimum and roughly twice what the text occupies.
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Stop watching \(update.title)")
                    }
                    .padding(.trailing, 20)
                    .overlay(alignment: .bottom) { Rule().padding(.horizontal, 20) }
                    .contextMenu {
                        Button("Stop watching", systemImage: "bell.slash", role: .destructive) {
                            remove(watch)
                        }
                    }
                }
            }
        }
    }

    private func remove(_ watch: StockWatch) {
        // Server first, for the same reason unfollowing is: a watch deleted only locally
        // keeps firing pushes from a server that still holds it.
        if settings.isConfigured {
            let remote = self.remote
            Task { await remote.deleteWatch(watch) }
        }
        context.delete(watch)
        try? context.save()
    }
}

struct WatchListRow: View {
    let watch: StockWatch
    let update: BrandUpdate

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            UpdateImage(
                url: update.primaryImageURL,
                kind: update.kind,
                aspect: 1,
                drawnWidth: 90,
                mark: update.brand?.name
            )
                .frame(width: 62)

            VStack(alignment: .leading, spacing: 5) {
                if let brand = update.brand {
                    Wordmark(name: brand.name, size: 9, color: .muted)
                }
                Text(update.title)
                    .font(.editorial(14))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    DataLabel(
                        text: watch.summary.uppercased(),
                        size: 10,
                        color: watch.isActive ? .ink : .muted
                    )
                    if !watch.isActive {
                        DataLabel(
                            text: watch.firedSizes.isEmpty
                                ? "BACK"
                                : "BACK IN \(watch.firedSizes.joined(separator: ", ").uppercased())",
                            size: 10,
                            color: .signal
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}
