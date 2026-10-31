// ScanView.swift
// One photograph of one garment, read — and then the three things worth doing with it.
//
// The order of the screen is the order of the promises in `docs/ai.md`, *The scan*:
//
// - **The price is said before anything is sent.** Reading costs credits, and the button that
//   sends the photograph says how many. Nothing leaves the phone until it is pressed.
// - **Only this photograph is sent**, cut out first where `Cutout` can, and never stored on the
//   server. The line under the picker says so, because it is the question somebody pointing a
//   camera at their wardrobe is entitled to ask.
// - **Then you choose**, and nothing is kept until you do:
//   *Add to my wardrobe* — a save with your photograph and no product behind it;
//   *Does it go with my wardrobe* — a verdict and a few fits, worked out on the phone from the
//   reading (`Pairing`, `Outfit`, `FitProposal`), so the wardrobe never leaves it;
//   *Find this or something like it* — the products the server says look like it, or a search
//   for the reading's own words.
// - **A failure says which one it was** (`AIRefusal`, `AIRefusalNotice`), and is never drawn as an empty answer.

import PhotosUI
import StreetwCore
import SwiftData
import SwiftUI

struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AIStore.self) private var ai: AIStore
    @Environment(StyleStatementStore.self) private var statement: StyleStatementStore
    @Query(sort: \SavedItem.savedAt, order: .reverse) private var saves: [SavedItem]
    @Query(filter: Board.shapingTaste) private var tasteBoards: [Board]

    /// Where "find this" goes when the host has a search of its own — see `ScanButton`.
    var onFind: ((String) -> Void)?

    private enum Stage {
        case choosing
        case preparing(UIImage)
        case ready(ScanPhoto.Prepared)
        case reading(ScanPhoto.Prepared)
        case read(ScannedGarment, AIScanResponse)
        case failed(ScanPhoto.Prepared, AIRefusal)
    }

    private enum Choice: Equatable {
        case wardrobe, goesWith, find
    }

    /// One fit the canvas is opened on, around the scanned garment.
    private struct Opening: Identifiable {
        let id = UUID()
        var subject: FitSubject
        var anchor: String?
    }

    @State private var stage: Stage = .choosing
    @State private var picked: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var choice: Choice?
    /// The save *Add to my wardrobe* made, so the button says it is done and the fits are built
    /// around the save rather than around a second, unkept copy of the same garment.
    @State private var added: SavedItem?
    @State private var addFailed = false
    @State private var opening: Opening?

    /// "2 CREDITS", from the server's table. Nil when it named no price — never printed as free.
    private var price: String? { ai.costLabel(for: .scan) }

    /// The send button's words, with the price on it whenever there is one to state.
    private func sendLabel(_ verb: String) -> String {
        price.map { "\(verb) — \($0)" } ?? verb
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch stage {
                    case .choosing:
                        choosing
                    case .preparing(let image):
                        photograph(image)
                        working("Cutting it out…")
                    case .ready(let prepared):
                        photograph(prepared.cutout ?? prepared.photo)
                        ready(prepared)
                    case .reading(let prepared):
                        photograph(prepared.cutout ?? prepared.photo)
                        working("Reading the photograph…")
                    case .read(let scanned, let response):
                        photograph(scanned.cutout ?? scanned.photo)
                        read(scanned, response)
                    case .failed(let prepared, let failure):
                        photograph(prepared.cutout ?? prepared.photo)
                        failed(prepared, failure)
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper)
            .navigationTitle("Scan")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.data(13, .semibold))
                }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker { image in prepare(image) }
                    .ignoresSafeArea()
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        prepare(image)
                    }
                    picked = nil
                }
            }
            .sheet(item: $opening) { opening in
                FitCanvas(fit: nil, starting: .around(opening.subject, anchor: opening.anchor))
            }
            // Asked again on the way in: whether the caller can spend is part of the answer,
            // and somebody may have signed in since the app last asked.
            .task { await ai.refresh() }
        }
        .tint(.ink)
    }

    // MARK: - Choosing a photograph

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Photograph one garment")
                    .font(.editorial(26))
                    .foregroundStyle(Color.ink)
                // How to take it, in one line; what the scan reads is the reading itself.
                NoteLine(text: "Laid flat or on a hanger, against something plain.", size: 16)
            }

            VStack(spacing: 10) {
                if CameraPicker.isAvailable {
                    Button { isShowingCamera = true } label: {
                        actionLabel("Take a photo", systemImage: "camera", isPrimary: true)
                    }
                    .buttonStyle(.borderless)
                }
                PhotosPicker(selection: $picked, matching: .images) {
                    actionLabel("Choose from Photos", systemImage: "photo", isPrimary: !CameraPicker.isAvailable)
                }
                .buttonStyle(.borderless)
            }

            privacy
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// Said before the photograph is chosen, not after it has gone.
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rule()
                .padding(.bottom, 6)
            // The price before anything is spent, and what leaves the phone — both kept, as
            // sentences; the rest of what goes to the AI is behind You › About.
            NoteLine(text: price.map { "Reading it costs \($0)." } ?? "Reading it uses credits.", color: .ink)
            NoteLine(text: "Only this photograph is sent, read once, and never stored.")
        }
    }

    private func prepare(_ image: UIImage) {
        choice = nil
        added = nil
        addFailed = false
        stage = .preparing(image)
        Task {
            guard let prepared = await ScanPhoto.prepare(image) else {
                stage = .choosing
                return
            }
            stage = .ready(prepared)
        }
    }

    // MARK: - Sending it

    private func ready(_ prepared: ScanPhoto.Prepared) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if prepared.cutout == nil {
                // Said, because what is sent is then the whole frame, and somebody should know
                // that before pressing the button rather than find out from the reading.
                NoteLine(text: "Nothing to cut out, so the whole photograph is sent.")
            }
            if ai.isSignedIn {
                Button { send(prepared) } label: {
                    actionLabel(sendLabel("Read it"), systemImage: "text.viewfinder", isPrimary: true)
                }
                .buttonStyle(.borderless)
            } else {
                // Not a disabled button: a control that cannot be pressed for a reason it does
                // not state is indistinguishable from a broken one.
                AIRefusalNotice(refusal: .signedOut)
            }
            Button { stage = .choosing } label: {
                actionLabel("Choose another", systemImage: "arrow.uturn.backward", isPrimary: false)
            }
            .buttonStyle(.borderless)
            privacy
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func send(_ prepared: ScanPhoto.Prepared) {
        stage = .reading(prepared)
        Task {
            switch await ai.scan(AIScanRequest(image: prepared.upload)) {
            case .success(let response):
                let scanned = ScannedGarment(photo: prepared.photo, cutout: prepared.cutout, reading: response.reading)
                stage = .read(scanned, response)
            case .failure(let failure):
                stage = .failed(prepared, failure)
            }
        }
    }

    /// Which refusal it was, and its one remedy — sign in, credits — or "try again" for a
    /// failure the same press might get past. Never the empty answer.
    private func failed(_ prepared: ScanPhoto.Prepared, _ refusal: AIRefusal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AIRefusalNotice(refusal: refusal, retry: { send(prepared) })
            Button { stage = .choosing } label: {
                actionLabel("Choose another", systemImage: "arrow.uturn.backward", isPrimary: false)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    // MARK: - The reading

    private func read(_ scanned: ScannedGarment, _ response: AIScanResponse) -> some View {
        let reading = scanned.reading
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                NoteLine(text: "The scan read:")
                Text(reading.description)
                    .font(.editorial(24))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                let facts = ([reading.type] + reading.colours + [reading.material, reading.pattern].compactMap { $0 })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if reading.isGarment, !facts.isEmpty {
                    Text(facts.joined(separator: ", "))
                        .font(.editorial(16))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if reading.isGarment, !reading.style.isEmpty {
                    NoteLine(text: "Style: " + reading.style.joined(separator: ", ") + ".")
                }
                ChargeLine(charge: response.charge)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)

            if reading.isGarment {
                choices(scanned, response)
            } else {
                // The model saw no garment, so there is nothing to keep, pair or look for —
                // and offering the three buttons anyway would act on a reading of a doorway.
                VStack(alignment: .leading, spacing: 14) {
                    Rule()
                    Text("That doesn't look like one garment. Try a single piece on its own.")
                        .font(.editorial(16))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { stage = .choosing } label: {
                        actionLabel("Try another photograph", systemImage: "camera", isPrimary: true)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func choices(_ scanned: ScannedGarment, _ response: AIScanResponse) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            choiceRow(
                title: added == nil ? "Add to my wardrobe" : "In your wardrobe",
                detail: added == nil
                    ? "Kept with your photograph, and used in fits."
                    : "In Saved › Wardrobe, with your photograph.",
                systemImage: added == nil ? "tshirt" : "checkmark",
                isOn: choice == .wardrobe
            ) {
                choice = .wardrobe
                addToWardrobe(scanned)
            }
            .disabled(added != nil)
            if addFailed {
                NoteLine(text: "The photograph couldn't be saved, so nothing was kept.", color: .signal)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            choiceRow(
                title: "Does it go with my wardrobe?",
                detail: "Worked out on this phone; your wardrobe isn't sent.",
                systemImage: "hanger",
                isOn: choice == .goesWith
            ) { choice = choice == .goesWith ? nil : .goesWith }
            if choice == .goesWith { goesWith(scanned) }

            choiceRow(
                title: "Find this or something like it",
                detail: response.similar?.isEmpty == false
                    ? (response.similarBasis == "photograph"
                        ? "Products that look like your photograph."
                        : "Products like “\(scanned.reading.searchText)”.")
                    : "Searches the shops we watch for “\(scanned.reading.searchText)”.",
                systemImage: "magnifyingglass",
                isOn: choice == .find
            ) {
                // What the photograph matched is shown here, wherever the scan was opened: in
                // Shop's field it would be reduced to the reading's words.
                if let onFind, response.similar?.isEmpty != false {
                    onFind(scanned.reading.searchText)
                    dismiss()
                } else {
                    choice = choice == .find ? nil : .find
                }
            }
            if choice == .find {
                ScanFindResults(searchText: scanned.reading.searchText, similar: response.similar, similarBasis: response.similarBasis)
                    .padding(.top, 4)
            }
            Rule()
        }
    }

    private func addToWardrobe(_ scanned: ScannedGarment) {
        guard added == nil else { return }
        if let save = scanned.save(as: .wardrobe, in: context) {
            added = save
            addFailed = false
        } else {
            addFailed = true
        }
    }

    // MARK: - Does it go with my wardrobe

    /// The verdict and a few fits, from the reading and the wardrobe, on the phone.
    ///
    /// Built around the save once *Add to my wardrobe* has made one, so a fit kept from here is
    /// made of the garment that is now in the collection rather than of a second, unkept copy.
    private func goesWith(_ scanned: ScannedGarment) -> some View {
        let subject: FitSubject = added.map(FitSubject.kept) ?? .scan(scanned)
        let judged = ScanVerdict(subject: subject, saves: saves, boards: tasteBoards, statement: statement.statement)
        return VStack(alignment: .leading, spacing: 14) {
            Text(judged.headline)
                .font(.editorial(19))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let line = judged.line {
                NoteLine(text: line, color: .ink)
            }
            if !judged.outfits.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(judged.outfits, id: \.anchor) { outfit in
                            Button {
                                opening = Opening(subject: subject, anchor: outfit.anchor)
                            } label: {
                                ScanOutfitCard(subject: subject, pieces: outfit.pieces.map(\.save), reason: outfit.reason)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -20)
                .contentMargins(.horizontal, 20, for: .scrollContent)
                NoteLine(text: "Tap one to arrange it. Nothing is kept until you save the fit.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Pieces

    private func photograph(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .padding(.vertical, 16)
            .background(Color.sweep)
    }

    private func working(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            NoteLine(text: label)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func choiceRow(
        title: String,
        detail: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.editorial(18))
                            .foregroundStyle(Color.ink)
                        NoteLine(text: detail, size: 13)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isOn ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.muted)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
    }

    private func actionLabel(_ title: String, systemImage: String, isPrimary: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.data(13, .semibold))
        }
        .foregroundStyle(isPrimary ? Color.paper : Color.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(isPrimary ? Color.ink : Color.clear)
        .overlay {
            if !isPrimary { Rectangle().stroke(Color.ink.opacity(0.35), lineWidth: 1) }
        }
        .contentShape(.rect)
    }
}

/// "Does it go with my wardrobe", answered.
///
/// **The headline is a count and the line is the best fit's reason**, because those are the two
/// things that can be said truthfully from rules: how much of the wardrobe the colour wheel,
/// the slot gate and the weight rule let it sit beside, and what `Outfit` saw in the best whole
/// outfit. Each fit is a `FitProposal` opening pinned to a different piece, so the canvas opened
/// on one lays out exactly the fit the card shows.
@MainActor
struct ScanVerdict {
    let headline: String
    let line: String?
    let outfits: [(anchor: String, pieces: [FitProposal.Option], reason: String?)]

    init(subject: FitSubject, saves: [SavedItem], boards: [Board], statement: StyleStatement) {
        let garment = subject.garment
        let pool = TasteScope(boards: boards, saves: saves).pairingPool(saves.filter(\.hasPhotograph))
        let wardrobe = pool.compactMap(\.garment).filter { $0.id != garment.id }
        let proposal = FitProposal(around: subject, anchor: nil, saves: saves, boards: boards, statement: statement)
        let matches = Pairing.best(for: garment, from: wardrobe, limit: .max, statement: statement)
        outfits = proposal.outfits(limit: 3, statement: statement)

        if garment.slot == .unknown {
            headline = "The scan couldn't place it on the body, so there's nothing to put it with."
            line = nil
        } else if wardrobe.isEmpty {
            headline = "Nothing in your wardrobe to judge it against yet."
            line = "Add what you own first — scan it, or keep things as Wardrobe"
        } else if matches.isEmpty {
            headline = "Nothing you own goes with it."
            line = nil
        } else {
            headline = matches.count == 1
                ? "Goes with one thing you own."
                : "Goes with \(matches.count) things you own."
            line = outfits.first?.reason ?? matches.first?.verdict.reason
        }
    }
}

/// One fit around the scanned garment: the garment, and the pieces the wardrobe gave it.
private struct ScanOutfitCard: View {
    let subject: FitSubject
    let pieces: [SavedItem]
    let reason: String?

    private let width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                subjectImage
                    .frame(width: width * 0.55, height: width * 0.55)
                    .offset(x: -width * 0.14, y: -width * 0.2)
                ForEach(Array(pieces.prefix(3).enumerated()), id: \.offset) { index, piece in
                    FitPieceImage(item: piece)
                        .frame(width: width * 0.55, height: width * 0.55)
                        .offset(
                            x: CGFloat(index % 2 == 0 ? 1 : -1) * width * 0.14,
                            y: CGFloat(index + 1) * width * 0.13 - width * 0.2
                        )
                }
            }
            .frame(width: width, height: width)
            .clipped()
            .background(Color.sweep)

            if let reason {
                NoteLine(text: reason, size: 12, color: .ink)
                    .lineLimit(2)
                    .frame(width: width, alignment: .leading)
            }
            NoteLine(text: "\(pieces.count + 1) pieces", size: 12)
        }
    }

    @ViewBuilder
    private var subjectImage: some View {
        switch subject {
        case .scan(let scanned):
            Image(uiImage: scanned.cutout ?? scanned.photo).resizable().scaledToFit()
        case .kept(let save):
            FitPieceImage(item: save)
        case .product(let update):
            FitPieceImage(update: update)
        case .discovery:
            Color.clear
        }
    }
}
