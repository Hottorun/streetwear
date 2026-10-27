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
// - **A failure says which one it was** (`AIFailure`), and is never drawn as an empty answer.

import PhotosUI
import StreetwCore
import SwiftData
import SwiftUI

struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ServerSettings.self) private var settings: ServerSettings
    @Environment(ProfileStore.self) private var profiles: ProfileStore
    @Environment(AIAvailability.self) private var ai: AIAvailability
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
        case failed(ScanPhoto.Prepared, AIFailure)
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

    private var price: Int { ai.credits(for: .scan) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch stage {
                    case .choosing:
                        choosing
                    case .preparing(let image):
                        photograph(image)
                        working("CUTTING IT OUT")
                    case .ready(let prepared):
                        photograph(prepared.cutout ?? prepared.photo)
                        ready(prepared)
                    case .reading(let prepared):
                        photograph(prepared.cutout ?? prepared.photo)
                        working("READING THE PHOTOGRAPH")
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
                Text("Laid flat or on a hanger, against something plain. One piece to a photograph — the scan reads what it is, its colours, what it's made of and how it's worn.")
                    .font(.editorial(15))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if CameraPicker.isAvailable {
                    Button { isShowingCamera = true } label: {
                        actionLabel("TAKE A PHOTO", systemImage: "camera", isPrimary: true)
                    }
                    .buttonStyle(.borderless)
                }
                PhotosPicker(selection: $picked, matching: .images) {
                    actionLabel("CHOOSE FROM PHOTOS", systemImage: "photo", isPrimary: !CameraPicker.isAvailable)
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
            DataLabel(text: "READING IT COSTS \(CreditAction.price(price))", size: 10, color: .ink)
            DataLabel(text: "ONLY THIS PHOTOGRAPH IS SENT, TO BE READ ONCE. DROPWALL NEVER STORES IT.", size: 10)
                .fixedSize(horizontal: false, vertical: true)
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
                DataLabel(text: "NOTHING TO CUT OUT — THE WHOLE PHOTOGRAPH IS SENT", size: 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ai.isSignedIn {
                Button { send(prepared) } label: {
                    actionLabel("READ IT · \(CreditAction.price(price))", systemImage: "text.viewfinder", isPrimary: true)
                }
                .buttonStyle(.borderless)
            } else {
                // Not a disabled button: a control that cannot be pressed for a reason it does
                // not state is indistinguishable from a broken one.
                Text(AIFailure.signIn.message)
                    .font(.editorial(16))
                    .foregroundStyle(Color.ink)
            }
            Button { stage = .choosing } label: {
                actionLabel("CHOOSE ANOTHER", systemImage: "arrow.uturn.backward", isPrimary: false)
            }
            .buttonStyle(.borderless)
            privacy
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func send(_ prepared: ScanPhoto.Prepared) {
        guard let client = AIClient(settings: settings, profile: profiles.session.scope.id) else {
            stage = .failed(prepared, .offline)
            return
        }
        stage = .reading(prepared)
        Task {
            switch await client.scan(prepared.upload) {
            case .success(let response):
                let scanned = ScannedGarment(photo: prepared.photo, cutout: prepared.cutout, reading: response.reading)
                stage = .read(scanned, response)
            case .failure(let failure):
                stage = .failed(prepared, failure)
            }
        }
    }

    private func failed(_ prepared: ScanPhoto.Prepared, _ failure: AIFailure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(failure.message)
                .font(.editorial(17))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if failure.isRetryable {
                Button { send(prepared) } label: {
                    actionLabel("TRY AGAIN · \(CreditAction.price(price))", systemImage: "arrow.clockwise", isPrimary: true)
                }
                .buttonStyle(.borderless)
            }
            Button { stage = .choosing } label: {
                actionLabel("CHOOSE ANOTHER", systemImage: "arrow.uturn.backward", isPrimary: false)
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
                DataLabel(text: "WHAT THE SCAN READ")
                Text(reading.description)
                    .font(.editorial(24))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                let facts = ([reading.type] + reading.colours + [reading.material, reading.pattern].compactMap { $0 })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if reading.isGarment, !facts.isEmpty {
                    Text(facts.joined(separator: " · ").uppercased())
                        .font(.data(12))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if reading.isGarment, !reading.style.isEmpty {
                    DataLabel(text: reading.style.joined(separator: " · ").uppercased(), size: 10)
                }
                if let line = response.charge.line {
                    DataLabel(text: line, size: 9)
                }
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
                    Text("That doesn't look like one garment. Try a photograph of a single piece, on its own.")
                        .font(.editorial(16))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { stage = .choosing } label: {
                        actionLabel("TRY ANOTHER PHOTOGRAPH", systemImage: "camera", isPrimary: true)
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
                    ? "KEPT WITH YOUR PHOTOGRAPH. IT GOES INTO FITS LIKE ANYTHING YOU OWN."
                    : "SAVED › WARDROBE, WITH YOUR PHOTOGRAPH.",
                systemImage: added == nil ? "tshirt" : "checkmark",
                isOn: choice == .wardrobe
            ) {
                choice = .wardrobe
                addToWardrobe(scanned)
            }
            .disabled(added != nil)
            if addFailed {
                DataLabel(text: "THE PHOTOGRAPH COULDN'T BE SAVED ON THIS PHONE. NOTHING WAS KEPT.", size: 10, color: .signal)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            choiceRow(
                title: "Does it go with my wardrobe?",
                detail: "WORKED OUT ON THIS PHONE. YOUR WARDROBE ISN'T SENT ANYWHERE.",
                systemImage: "hanger",
                isOn: choice == .goesWith
            ) { choice = choice == .goesWith ? nil : .goesWith }
            if choice == .goesWith { goesWith(scanned) }

            choiceRow(
                title: "Find this or something like it",
                detail: response.similar?.isEmpty == false
                    ? "PRODUCTS THAT LOOK LIKE YOUR PHOTOGRAPH."
                    : "SEARCHES THE SHOPS DROPWALL WATCHES FOR “\(scanned.reading.searchText.uppercased())”.",
                systemImage: "magnifyingglass",
                isOn: choice == .find
            ) {
                if let onFind {
                    onFind(scanned.reading.searchText)
                    dismiss()
                } else {
                    choice = choice == .find ? nil : .find
                }
            }
            if choice == .find {
                ScanFindResults(searchText: scanned.reading.searchText, similar: response.similar)
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
                DataLabel(text: line.uppercased(), size: 10, color: .ink)
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
                DataLabel(text: "TAP ONE TO ARRANGE IT · NOTHING IS KEPT UNTIL YOU SAVE THE FIT", size: 9)
                    .fixedSize(horizontal: false, vertical: true)
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
            DataLabel(text: label)
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
                        DataLabel(text: detail, size: 9)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
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
                .font(.data(12, .semibold))
                .tracking(1.1)
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
                DataLabel(text: reason.uppercased(), size: 9, color: .ink)
                    .lineLimit(2)
                    .frame(width: width, alignment: .leading)
            }
            DataLabel(text: "\(pieces.count + 1) PIECES", size: 9)
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
