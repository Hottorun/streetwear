// Normalises the demo catalogue's packshots: every garment centred on a square of its own
// background colour, filling the same share of the frame, so a grid of them reads as one shoot.
//
//   swift AppStore/demo/square.swift AppStore/demo/images AppStore/demo/catalog
//
// Pure CoreGraphics/ImageIO for the same reason as Tools/AppIcon: it runs headless.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let side = 1400
let fill = 0.80

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func rgba(_ image: CGImage) -> (data: [UInt8], w: Int, h: Int) {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (data, w, h)
}

let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
    .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }

for file in files {
    guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
    let (px, w, h) = rgba(image)

    // Background: mean of the four corner patches.
    var bg = [0.0, 0.0, 0.0]
    var n = 0.0
    for (cx, cy) in [(0, 0), (w - 12, 0), (0, h - 12), (w - 12, h - 12)] {
        for y in cy..<cy + 12 { for x in cx..<cx + 12 {
            let i = (y * w + x) * 4
            for c in 0..<3 { bg[c] += Double(px[i + c]) }
            n += 1
        } }
    }
    bg = bg.map { $0 / n }

    // Content box: anything clearly off the background. Soft shadows sit under the
    // threshold, which is what we want — they are not the garment.
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in stride(from: 0, to: h, by: 2) {
        for x in stride(from: 0, to: w, by: 2) {
            let i = (y * w + x) * 4
            let d = abs(Double(px[i]) - bg[0]) + abs(Double(px[i + 1]) - bg[1]) + abs(Double(px[i + 2]) - bg[2])
            if d > 60 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    let boxW = Double(maxX - minX), boxH = Double(maxY - minY)
    let scale = Double(side) * fill / max(boxW, boxH)
    let midX = Double(minX + maxX) / 2, midY = Double(minY + maxY) / 2

    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: bg[0] / 255, green: bg[1] / 255, blue: bg[2] / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.interpolationQuality = .high
    // Image space is top-down; CGContext is bottom-up — flip the content centre's y.
    let drawW = Double(w) * scale, drawH = Double(h) * scale
    let originX = Double(side) / 2 - midX * scale
    let originY = Double(side) / 2 - (Double(h) - midY) * scale
    ctx.draw(image, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))

    let out = output.appending(path: file.deletingPathExtension().lastPathComponent + ".jpg")
    let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    CGImageDestinationFinalize(dest)
    print(out.lastPathComponent, "box", Int(boxW), "x", Int(boxH))
}
