// Renders the Dropwall app icon at 1024², in the app's own palette.
//
// Pure CoreGraphics — no AppKit, so it runs headless without an NSApplication.
//
// Run: swiftc -O RenderIcon.swift -o /tmp/render-icon && /tmp/render-icon <out-dir>
//
// **The mark is two swing tickets hanging from a wire, and it carries no letter.**
// It used to be one ticket with an `s` punched out of it, then a `d` when the app was
// renamed — which is the argument against a letter: a monogram has to be re-cut every time
// the name moves, and it says nothing in the meantime. Two tags on a line says the name
// outright. It also says the thing one tag never could: the app is about a *collection*,
// not a product.
//
// Three decisions hold the drawing together, and each was arrived at by rendering the
// alternative and looking at it at sixty points, which is the only size that matters.
//
// **The tags lean toward each other, and that is not a stylistic coin-toss.** Splayed —
// front leaning left, back leaning right — the front tag buries the back one and the pair
// reads as a single notched blob with a wedge behind it. Converging, both silhouettes stay
// whole. It is the only arrangement that still reads as *two* tags at forty points.
//
// **They rotate about their eyelets**, because that is the pivot a hanging tag actually
// turns on. It also has a useful consequence: a circle is invariant under rotation about
// its own centre, so the eyelet stays exactly where it was and the wire still threads
// through it without any extra arithmetic.
//
// **The wire sags.** A straight rule across the icon reads as a divider — furniture — and
// the sag is what makes it a line something is *hung from*. It is quadratic with its
// control point at mid-width, which means x is exactly linear in the curve parameter and
// the height under any x is closed-form. No curve walking to place the tags on it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

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

// MARK: - Palette

/// One appearance's ground and mark.
///
/// The ground is a gradient rather than a flat wash, top-left to bottom-right, as a light
/// falling across it. `top == bottom` makes it flat, which is what the tinted appearance
/// wants — see `tinted`.
struct Ground {
    var top: Int
    var bottom: Int
    var mark: CGColor
}

/// `Color.paper` falling to a shade below `Color.hairline`, with `Color.ink` on it.
let light = Ground(top: 0xFAFAF7, bottom: 0xE4E2DA, mark: rgb(0x14140F))

/// **A true inversion** — pale tickets on a dark ground — rather than an ink ticket on an
/// ink ground, which would have no contrast at all. `Color.wash` falling to `Color.paper`,
/// both in their dark values, carrying dark-mode `Color.ink`.
let dark = Ground(top: 0x1C1C19, bottom: 0x0E0E0C, mark: rgb(0xF5F5F0))

/// **Flat, deliberately, and the only appearance that is.**
///
/// iOS derives the tinted icon's hue from luminance, so every tone in the image becomes a
/// different strength of the user's chosen colour. A gradient ground therefore stops being
/// a light falling across the mark and becomes a *band of tint* competing with it — the
/// thing the tags are supposed to sit on turns into a second subject. Black ground and a
/// white mark gives the system the two-tone image it can actually tint, which is what the
/// icon has always handed it.
let tinted = Ground(top: 0x000000, bottom: 0x000000, mark: rgb(0xFFFFFF))

// MARK: - Geometry

/// The wire, sagging from edge to edge.
struct Wire {
    var y: CGFloat = 700
    var sag: CGFloat = 90
    var thickness: CGFloat = 28

    /// Closed-form because the control point sits at mid-width: with P0.x = 0,
    /// P1.x = side/2 and P2.x = side, the quadratic's x reduces to `side · t`.
    func height(atX x: CGFloat) -> CGFloat {
        let t = x / side
        return y - 4 * sag * t * (1 - t)
    }

    var path: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: y))
        p.addQuadCurve(to: CGPoint(x: side, y: y), control: CGPoint(x: side / 2, y: y - 2 * sag))
        return p
    }
}

/// A swing ticket, hung by its eyelet and free to swing about it.
///
/// **Cut corners over a flat top edge, not a gable.** A single apex across the full width
/// is a roof: an early cut of this shape read as a house at sixty points. A real swing
/// ticket has its two top corners taken off at 45° and keeps a flat edge between them, and
/// that flat edge is what the eye actually recognises. Every proportion below is a ratio of
/// the width so the two tags stay the same object at two sizes.
struct Tag {
    var eyeletCentre: CGPoint
    var w: CGFloat
    /// Degrees. Positive swings the body to the right.
    var angle: CGFloat

    var h: CGFloat { w * 1.245 }
    var chamfer: CGFloat { w * 0.249 }
    var eyelet: CGFloat { w * 0.128 }
    var eyeletDrop: CGFloat { h * 0.158 }

    private var topY: CGFloat { eyeletCentre.y + eyeletDrop }
    private var originX: CGFloat { eyeletCentre.x - w / 2 }

    private var upright: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: originX, y: topY - h))
        p.addLine(to: CGPoint(x: originX + w, y: topY - h))
        p.addLine(to: CGPoint(x: originX + w, y: topY - chamfer))
        p.addLine(to: CGPoint(x: originX + w - chamfer, y: topY))
        p.addLine(to: CGPoint(x: originX + chamfer, y: topY))
        p.addLine(to: CGPoint(x: originX, y: topY - chamfer))
        p.closeSubpath()
        return p
    }

    var outline: CGPath {
        var t = CGAffineTransform(translationX: eyeletCentre.x, y: eyeletCentre.y)
            .rotated(by: -angle * .pi / 180)
            .translatedBy(x: -eyeletCentre.x, y: -eyeletCentre.y)
        return upright.copy(using: &t)!
    }

    /// Unmoved by the rotation, being a circle turned about its own centre.
    var eyeletRect: CGRect {
        CGRect(
            x: eyeletCentre.x - eyelet / 2,
            y: eyeletCentre.y - eyelet / 2,
            width: eyelet,
            height: eyelet
        )
    }
}

let wire = Wire()

/// The pair. The back one is smaller as well as further right: offset alone reads as two
/// tags side by side, and it is the size difference that makes the second one read as
/// *behind* rather than *beside*.
let frontWidth: CGFloat = 350
let backWidth: CGFloat = 350 * 0.84
let frontX: CGFloat = 390
let backX: CGFloat = 665
let leanDegrees: CGFloat = 22

/// How wide a bite of ground is taken out around the front tag.
///
/// Without it the two silhouettes merge into one shape wherever they overlap, and the whole
/// point of the pair is lost at exactly the sizes it matters. It is a stroke of the ground
/// *painted with the ground*, not with a flat colour sampled from it — see `paintGround`.
let halo: CGFloat = 38

// MARK: - Drawing

/// Paint the ground through whatever is currently clipped.
///
/// **The halo and the eyelets have to be painted this way rather than filled with a
/// colour.** They are holes back to the ground, and the ground is a gradient — so filling
/// them with `top` leaves a pale outline anywhere the gradient has moved on, which on this
/// composition is the whole bottom-right. Clipping and re-drawing the same gradient makes a
/// hole an actual hole.
func paintGround(_ g: Ground, in context: CGContext) {
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [rgb(g.top), rgb(g.bottom)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: side),
        end: CGPoint(x: side, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

func draw(_ tag: Tag, on g: Ground, halo haloWidth: CGFloat, in context: CGContext) {
    if haloWidth > 0 {
        context.saveGState()
        context.addPath(tag.outline)
        context.setLineWidth(haloWidth)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        paintGround(g, in: context)
        context.restoreGState()
    }

    context.addPath(tag.outline)
    context.setFillColor(g.mark)
    context.fillPath()

    // The hole — and the wire seen through it, which is the detail that says the tags are
    // *threaded* on the line rather than stacked in front of it.
    context.saveGState()
    context.addEllipse(in: tag.eyeletRect)
    context.clip()
    paintGround(g, in: context)
    context.addPath(wire.path)
    context.setStrokeColor(g.mark)
    context.setLineWidth(wire.thickness)
    context.strokePath()
    context.restoreGState()
}

func render(_ g: Ground, to url: URL) {
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

    paintGround(g, in: context)

    context.addPath(wire.path)
    context.setStrokeColor(g.mark)
    context.setLineWidth(wire.thickness)
    context.setLineCap(.butt)
    context.strokePath()

    let back = Tag(
        eyeletCentre: CGPoint(x: backX, y: wire.height(atX: backX)),
        w: backWidth,
        angle: -leanDegrees
    )
    let front = Tag(
        eyeletCentre: CGPoint(x: frontX, y: wire.height(atX: frontX)),
        w: frontWidth,
        angle: leanDegrees
    )

    // Back first, and only the front one takes a halo: the bite is needed where one
    // silhouette crosses another, which is one edge, not two.
    draw(back, on: g, halo: 0, in: context)
    draw(front, on: g, halo: halo, in: context)

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
