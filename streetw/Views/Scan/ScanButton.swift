// ScanButton.swift
// The one way into the clothes scan, wherever it is placed: Saved's "+", and Shop's field.
//
// **Drawn only where it can work** — on a deployment whose server holds a provider key, and
// never standalone (`AIAvailability.isOffered`). A camera that can only fail is a placeholder.

import SwiftUI

/// A camera glyph that opens the scan.
///
/// - Parameter onFind: where "find this or something like it" goes. Nil — Saved's case — and
///   the scan answers it itself, from the catalogue the server holds; Shop passes its own field,
///   so the reading's search text lands where somebody was already searching.
struct ScanButton: View {
    @Environment(AIAvailability.self) private var ai: AIAvailability

    var onFind: ((String) -> Void)?

    @State private var isScanning = false

    var body: some View {
        if ai.isOffered {
            Button { isScanning = true } label: {
                Image(systemName: "camera")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Scan a garment")
            .scanSheet(isPresented: $isScanning, onFind: onFind)
        }
    }
}

extension View {
    /// Presents the scan. For a host that has its own control — a menu item, as on Saved.
    func scanSheet(isPresented: Binding<Bool>, onFind: ((String) -> Void)? = nil) -> some View {
        sheet(isPresented: isPresented) {
            ScanView(onFind: onFind)
        }
    }
}
