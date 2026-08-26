// Renders the streetw app icon at 1024², in the app's own palette.
//
// Pure CoreGraphics/CoreText — no AppKit, so it runs headless without an NSApplication.
//
// Run: swiftc -O RenderIcon.swift -o /tmp/render-icon && /tmp/render-icon <out-dir>

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

struct Palette {
    /// Behind the ticket — and, showing through it, the letter and the eyelet. One colour
    /// doing both jobs is the whole effect: see `render`.
    var ground: CGColor
    /// The ticket itself.
    var mark: CGColor
}

func rgb(_ hex: Int) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            1
        ]
    )!
}

// `Color.wash` and `Color.ink` out of DesignSystem.swift, each appearance taking its own
// pair. **The dark appearance is a true inversion** — a paper ticket on a dark ground —
// rather than an ink ticket on an ink ground, which would have no contrast at all. So the
// ticket is always the `ink` of its own appearance and the ground is always that
// appearance's `wash`.
let light = Palette(ground: rgb(0xEFEEE9), mark: rgb(0x14140F))
let dark = Palette(ground: rgb(0x1C1C19), mark: rgb(0xF5F5F0))
// Tinted: iOS derives the hue from luminance, so this carries no colour of its own.
let tinted = Palette(ground: rgb(0x000000), mark: rgb(0xFFFFFF))

/// New York — the serif the app sets every title in. Loaded from the file because it is a
/// hidden system family that cannot be looked up by name.
func serif(_ size: CGFloat) -> CTFont {
    let url = URL(fileURLWithPath: "/System/Library/Fonts/NewYork.ttf") as CFURL
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
          let first = descriptors.first else {
        fatalError("New York not found")
    }
    return CTFontCreateWithFontDescriptor(first, size, nil)
}

// MARK: - Dimensions

/// A swing ticket, in canvas coordinates.
struct Ticket {
    var width: CGFloat = 530
    var height: CGFloat = 660
    /// **Cut corners over a flat top edge, not a gable.** A single apex across the full
    /// width is a roof: an earlier cut of this shape read as a house at sixty points. A real
    /// swing ticket has its two top corners taken off at 45° and keeps a flat edge between
    /// them, and that flat edge is what the eye actually recognises.
    var chamfer: CGFloat = 132
    var eyelet: CGFloat = 68
    /// From the top edge down to the eyelet's centre.
    var eyeletDrop: CGFloat = 104

    var originX: CGFloat { (side - width) / 2 }
    var originY: CGFloat { (side - height) / 2 - 4 }
    var top: CGFloat { originY + height }

    var eyeletRect: CGRect {
        CGRect(
            x: side / 2 - eyelet / 2,
            y: top - eyeletDrop - eyelet / 2,
            width: eyelet,
            height: eyelet
        )
    }

    /// The field between the eyelet and the foot. The letter is centred here rather than on
    /// the outline: the eyelet takes a bite out of the top and the eye reads the field that
    /// is left, so centring on the whole shape puts the letter visibly low.
    var fieldCentre: CGFloat { (eyeletRect.minY + originY) / 2 }

    var outline: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: originX, y: originY))
        path.addLine(to: CGPoint(x: originX + width, y: originY))
        path.addLine(to: CGPoint(x: originX + width, y: top - chamfer))
        path.addLine(to: CGPoint(x: originX + width - chamfer, y: top))
        path.addLine(to: CGPoint(x: originX + chamfer, y: top))
        path.addLine(to: CGPoint(x: originX, y: top - chamfer))
        path.closeSubpath()
        return path
    }
}

let ticket = Ticket()

/// **The letter sits inside the field now, and the ticket is a ticket again.**
///
/// It used to be 700 tall — far bigger than the ticket, cropped on every side, with the crop
/// as the drawing. That is a strong mark and it costs the thing the mark is *of*: at 700 the
/// `s` eats both chamfers and swallows the eyelet, so the silhouette stops reading as a swing
/// tag and the eyelet reads as part of the letter. Contained, the shape survives and the
/// letter is legible at sixty points, which is the only size that matters.
let letterHeight: CGFloat = 300

/// The rule under the letter — **the app's own signature element, not decoration.**
///
/// `SizeRun` prints a garment's sizes and draws exactly this under the one you wear. So a
/// swing tag with a letter and a rule beneath it is not a monogram in a shape; it is the
/// thing the app does, drawn once: *your size, marked*. It spans the letter's inked width
/// and nothing more, the same way the rule in `SizeRun` spans its token — a rule that
/// overhung would read as an underscore rather than as a mark under a size.
let ruleThickness: CGFloat = 30
/// From the bottom of the letter's inked box to the top of the rule.
let ruleGap: CGFloat = 46

// MARK: - Drawing

/// - Returns: the box the glyph actually inked, in canvas coordinates — which is what the
///   rule underneath measures itself against. Asking CoreText afterwards would mean
///   repeating the layout, and guessing from the font metrics would be wrong: the advance
///   width of an `s` is wider than its ink.
@discardableResult
func draw(_ text: String, color: CGColor, height: CGFloat, center: CGPoint, in context: CGContext) -> CGRect {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: text,
            attributes: [
                // CoreText's own attribute names — AppKit's `.font`/`.foregroundColor`
                // spellings need an import that needs an NSApplication.
                NSAttributedString.Key(kCTFontAttributeName as String): serif(800),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): color,
                // Negative stroke widens the glyph. New York is a variable font and its
                // default instance reads thin once a letter is this big.
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -3.0
            ]
        )
    )
    // Optical centring, on the *inked* box: the ascender and descender of a lone lowercase
    // glyph are mostly empty and would push the letter off the middle of the ticket.
    let box = CTLineGetImageBounds(line, context)
    let scale = height / box.height
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.midX, y: -box.midY)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()

    let width = box.width * scale
    return CGRect(
        x: center.x - width / 2,
        y: center.y - height / 2,
        width: width,
        height: height
    )
}

func render(_ palette: Palette, to url: URL) {
    guard let context = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        // Opaque: an app icon has no transparency to give, in any appearance.
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("no context") }

    context.setFillColor(palette.ground)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))

    context.addPath(ticket.outline)
    context.setFillColor(palette.mark)
    context.fillPath()

    // **The letter and its rule are the ground coming through the ticket, not ink on it.**
    //
    // Painted in `ground` rather than in a third colour, which is what makes this a punched
    // tag rather than a printed one — and it is why the whole mark survives the tinted
    // appearance, where iOS derives a hue from luminance and a third colour would have
    // nothing to say. The clip stays even though nothing reaches the edge any more: it costs
    // one call and it is the guarantee that changing `letterHeight` can never quietly break
    // the silhouette.
    //
    // Set as one block — letter above, rule below, the pair centred in the field — so the
    // two move together. Centring the letter alone and hanging a rule off it would drift the
    // mark low the moment either measurement changed.
    let block = letterHeight + ruleGap + ruleThickness
    let blockBottom = ticket.fieldCentre - block / 2

    context.saveGState()
    context.addPath(ticket.outline)
    context.clip()
    let letter = draw(
        "s",
        color: palette.ground,
        height: letterHeight,
        center: CGPoint(
            x: side / 2,
            y: blockBottom + ruleThickness + ruleGap + letterHeight / 2
        ),
        in: context
    )
    context.setFillColor(palette.ground)
    context.fill(
        CGRect(x: letter.minX, y: blockBottom, width: letter.width, height: ruleThickness)
    )
    context.restoreGState()

    // The hole goes through everything a real ticket is made of, the letter included — and
    // at this letter size it is most of what is left saying "ticket" rather than "shape".
    context.setFillColor(palette.ground)
    context.fillEllipse(in: ticket.eyeletRect)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
          ) else { fatalError("no image") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
render(light, to: out.appendingPathComponent("icon-light.png"))
render(dark, to: out.appendingPathComponent("icon-dark.png"))
render(tinted, to: out.appendingPathComponent("icon-tinted.png"))
print("wrote 3 icons to \(out.path)")
