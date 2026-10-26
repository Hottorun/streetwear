// DropPiecesView.swift
// The page behind a card of several pieces: a drop, a wave of restocks, a sale rail.
//
// Drawn the way a release's page is (`CollectionReleaseView`), because to somebody reading
// the feed the two are the same thing — a brand put several things out at once — and the
// only difference is whether the brand gave it a name. What it holds is exactly what the
// card counted: `DropRoute` carries the rows, so "24 PIECES" opens onto twenty-four.

import StreetwCore
import SwiftData
import SwiftUI

struct DropPiecesView: View {
    @Environment(SizeProfileStore.self) private var sizes: SizeProfileStore

    let brand: Brand
    let kind: UpdateKind
    let pieces: [BrandUpdate]

    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]

    var body: some View {
        // Rows can go while this is open — unfollowing from the brand page one push deeper
        // cascades through them — and a tile reading a deleted row traps.
        let pieces = self.pieces.filter { !$0.isGone }

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                masthead(pieces)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(pieces) { piece in
                        MemberTile(update: piece)
                            .productLink(piece)
                            .contextMenu { UpdateMenu(update: piece) }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Color.paper)
        .navigationTitle(brand.isGone ? "" : brand.name)
        .toolbarTitleDisplayMode(.inline)
    }

    private func masthead(_ pieces: [BrandUpdate]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let newest = pieces.first {
                DataLabel(text: "\(FeedLabel.group(kind).text) · \(Stamp.short(newest.publishedAt).uppercased())")
            }
            // What happened, in the words the 1.0 spread used for it — "24 new products" —
            // because this page is that story at full size.
            Text(kind.headline(count: pieces.count))
                .font(.editorial(30))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !brand.isGone {
                NavigationLink(value: BrandRoute(brand: brand)) {
                    Wordmark(name: brand.name, size: 12)
                }
                .buttonStyle(.plain)
            }
            Rule().padding(.top, 6)
        }
        .padding(.horizontal, 20)
    }
}
