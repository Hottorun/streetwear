// FitAsk.swift
// The fit canvas's two questions for the model: is this fit any good, judging from the
// photographs — and which of the pieces the phone would add actually go with it.
//
// Every rule on the canvas reads words and one measured colour, so a pair can pass all of them
// and be obviously wrong to anybody looking (`ROADMAP.md`, *Fit judging and suggestions that
// look at the photographs*). Both questions are something the reader asks, by name and at a
// stated price, about garments they put on the canvas themselves (`docs/ai.md`, *Fits*):
//
// - **Judge** sends the placed pieces — a catalogue photograph by URL, the reader's own as the
//   JPEG already on the phone — and draws the verdict `Outfit` already speaks in, a line, a few
//   notes, and a mark on the one piece to change.
// - **Suggest** sends the fit and at most twelve candidates **the phone chose** — the proposal's
//   shelves, or the wardrobe's best by `Pairing` — and the model only orders them and drops the
//   ones that clash. The free, rule-based shelf is still drawn first; this is a second shelf.

import StreetwCore
import SwiftUI

enum FitAsk {
    enum Kind: Equatable {
        case judge, suggest
    }

    /// What came back from judging, tied to the pieces it was about.
    struct Judgement {
        var verdict: AIFitVerdict
        /// The placements the model was shown, in the order it was shown them.
        var shown: [UUID]
        var charge: AICharge

        /// The placement the model said to change, when it named one.
        var swap: UUID? {
            verdict.swap.flatMap { shown.indices.contains($0) ? shown[$0] : nil }
        }

        /// Whether the canvas still holds exactly what was judged. A verdict about a fit
        /// somebody has since changed is kept on screen, but says so.
        func isCurrent(for placements: [FitPlacement]) -> Bool {
            Set(placements.map(\.itemID)) == Set(shown)
        }
    }

    /// A candidate the phone chose, before or after the model has looked at it.
    struct Candidate {
        var save: SavedItem
        /// The proposal option it came from, so taking it swaps rather than adds.
        var option: FitProposal.Option?
    }

    struct Suggestion: Identifiable {
        var save: SavedItem
        var option: FitProposal.Option?
        var reason: String

        init(candidate: Candidate, reason: String) {
            self.save = candidate.save
            self.option = candidate.option
            self.reason = reason
        }

        var id: UUID { save.id }
    }

    /// The candidates the phone offers the model, best first by its own rules.
    ///
    /// The proposal's shortlist when the canvas was opened around a garment — the shelf the
    /// reader is already looking at — and otherwise the wardrobe scored the way
    /// `FitSuggestions.accompaniment` scores a piece against an outfit: the **worst** verdict
    /// against anything already placed, refused on a clash the reader has not stated.
    @MainActor
    static func candidates(
        proposal: FitProposal?,
        saves: [SavedItem],
        placed: Set<UUID>,
        against garments: [Garment],
        statement: StyleStatement
    ) -> [Candidate] {
        if let proposal, !proposal.isEmpty {
            return proposal.shelves
                .flatMap(\.options)
                .filter { !placed.contains($0.id) }
                .sorted { $0.score == $1.score ? $0.id.uuidString < $1.id.uuidString : $0.score > $1.score }
                .prefix(AIFits.maxCandidates)
                .map { Candidate(save: $0.save, option: $0) }
        }

        var scored: [(save: SavedItem, score: Double)] = []
        for save in saves where save.hasPhotograph && !placed.contains(save.id) {
            guard let candidate = save.garment, candidate.slot != .unknown else { continue }
            var worst = Double.greatestFiniteMagnitude
            var refused = false
            for piece in garments {
                if !statement.statedPairing(between: piece, and: candidate),
                   ColorHarmony.isClash(piece.color, candidate.color) {
                    refused = true
                    break
                }
                if Outfit.isLayeredPair(piece, candidate) {
                    worst = min(worst, ColorHarmony.score(piece.color, candidate.color).score)
                    continue
                }
                let verdict = Pairing.score(piece, with: candidate, statement: statement)
                if verdict.isRefused {
                    refused = true
                    break
                }
                worst = min(worst, verdict.score)
            }
            guard !refused, worst < .greatestFiniteMagnitude else { continue }
            scored.append((save, worst))
        }
        return scored
            .sorted { $0.score == $1.score ? $0.save.id.uuidString < $1.save.id.uuidString : $0.score > $1.score }
            .prefix(AIFits.maxCandidates)
            .map { Candidate(save: $0.save, option: nil) }
    }

    // MARK: - What the model is shown

    /// A catalogue photograph is sent by URL, at a rendition the server need not shrink; the
    /// reader's own photograph is sent as the JPEG already on the phone. Nil when there is no
    /// photograph to show, which leaves the piece out rather than sending a title alone.
    @MainActor
    static func piece(for save: SavedItem) -> AIFitPiece? {
        guard let garment = save.garment else { return nil }
        if save.isOwnGarment {
            guard let jpeg = OwnPhotos.upload(for: save) else { return nil }
            return AIFitPiece(slot: garment.slot.rawValue, title: save.displayTitle, colour: garment.color, image: jpeg)
        }
        guard let url = FitPieceImage.source(for: save) else { return nil }
        return AIFitPiece(
            slot: garment.slot.rawValue,
            title: save.displayTitle,
            colour: garment.color,
            imageURL: ImageRendition.sized(url, width: Self.sentWidth)
        )
    }

    @MainActor
    static func piece(for piece: FitCanvas.Piece) -> AIFitPiece? {
        switch piece {
        case .kept(let save):
            return self.piece(for: save)
        case .pending(let subject):
            let garment = subject.garment
            switch subject {
            case .product(let update):
                guard let url = update.packshotURL ?? update.primaryImageURL else { return nil }
                return AIFitPiece(slot: garment.slot.rawValue, title: update.title, colour: garment.color,
                                  imageURL: ImageRendition.sized(url, width: Self.sentWidth))
            case .discovery(let card, _, _, let packshot):
                guard let url = packshot ?? card.imageURLs.first.flatMap(URL.init(string:)) else { return nil }
                return AIFitPiece(slot: garment.slot.rawValue, title: card.title, colour: garment.color,
                                  imageURL: ImageRendition.sized(url, width: Self.sentWidth))
            case .kept(let save):
                return self.piece(for: save)
            case .scan(let scanned):
                guard let jpeg = scanned.photo.jpegData(compressionQuality: 0.8), jpeg.count <= AIScan.maxBytes else {
                    return nil
                }
                return AIFitPiece(slot: garment.slot.rawValue, title: scanned.reading.description,
                                  colour: garment.color, image: jpeg)
            }
        }
    }

    /// Wide enough for a model to see a fabric's texture, a fraction of a storefront original.
    private static let sentWidth = 800
}

// MARK: - Drawing the answers

/// The verdict, over the foot of the canvas.
struct FitJudgementPanel: View {
    let judgement: FitAsk.Judgement
    let isCurrent: Bool
    let onClose: () -> Void

    @State private var isExpanded = false

    private var verdictLabel: String {
        switch judgement.verdict.verdict.lowercased() {
        case "works": "It works."
        case "risky": "It's risky."
        case "clashes": "It clashes."
        default: judgement.verdict.verdict.prefix(1).uppercased() + judgement.verdict.verdict.dropFirst()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verdictLabel)
                    .font(.editorial(18, .semibold))
                    .foregroundStyle(judgement.verdict.verdict.lowercased() == "clashes" ? Color.signal : Color.ink)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.muted)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close the verdict")
            }
            Text(judgement.verdict.summary)
                .font(.editorial(16))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            // **Folded by default**, because the panel lies over the canvas and the piece it
            // marks is as often as not the shoes, at the foot of it — four notes open hid the
            // one thing the verdict was pointing at.
            if isExpanded {
                ForEach(Array(judgement.verdict.notes.prefix(4).enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("—").font(.data(11)).foregroundStyle(Color.muted)
                        Text(note)
                            .font(.editorial(13))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ChargeLine(charge: judgement.charge)
            }
            if judgement.swap != nil, isCurrent {
                NoteLine(text: "Change the marked piece.", size: 13, color: .signal)
            }
            if !isCurrent {
                NoteLine(text: "The fit has changed since.", size: 13)
            }
            if !isExpanded, !judgement.verdict.notes.isEmpty {
                NoteLine(text: judgement.verdict.notes.count == 1 ? "Tap for the note." : "Tap for \(min(judgement.verdict.notes.count, 4)) notes.", size: 13)
            }
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() } }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paper, in: Rectangle())
        .overlay(Rectangle().stroke(Color.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
    }
}

/// A question that could not be asked, said as such — `AIRefusalNotice`, with its remedy, on a
/// card that can be put away.
struct FitAskFailureLine: View {
    let refusal: AIRefusal
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AIRefusalNotice(refusal: refusal)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.muted)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color.paper, in: Rectangle())
        .overlay(Rectangle().stroke(Color.hairline, lineWidth: 0.5))
    }
}

/// One candidate on the asked shelf: the photograph, and the reason the model gave.
struct FitAskedTile: View {
    let suggestion: FitAsk.Suggestion
    let isPlaced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FitPieceImage(item: suggestion.save)
                .frame(width: 64, height: 64)
                .background(Color.paper)
                .overlay {
                    if isPlaced { Rectangle().stroke(Color.ink, lineWidth: 1.5) }
                }
                .padding(.bottom, 2)
            Text(suggestion.reason)
                .font(.editorial(10))
                .foregroundStyle(isPlaced ? Color.ink : Color.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 96, alignment: .leading)
        .contentShape(.rect)
    }
}
