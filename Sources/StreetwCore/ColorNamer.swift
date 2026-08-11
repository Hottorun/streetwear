// ColorNamer.swift
// Turning a pixel into a word someone would actually use.
//
// A style profile that says "#3B3C42" is useless; one that says "Charcoal" is a fact
// about your wardrobe. The mapping is done in HSB rather than by distance to a table of
// reference RGB values, because the categories people use are themselves HSB-shaped:
// "navy" is a dark blue, "cream" is an unsaturated bright warm, "burgundy" is a dark
// red. Hue decides *which* colour, saturation and brightness decide *which one of it*.
//
// Kept in the portable layer with tests because it is pure arithmetic — the Vision and
// CoreImage work that produces the pixel has to live in the app, but none of the
// judgement does.

import Foundation

public struct NamedColor: Sendable, Hashable {
    public var name: String
    /// Roughly how confident the naming is, from how far the colour sits from the
    /// boundaries of its band. Lets a caller drop borderline calls rather than assert
    /// that a muddy grey-green is "Olive".
    public var confidence: Double

    public init(name: String, confidence: Double) {
        self.name = name
        self.confidence = confidence
    }
}

public enum ColorNamer {
    /// Names an RGB colour, each component 0–1.
    public static func name(red: Double, green: Double, blue: Double) -> NamedColor {
        let (hue, saturation, brightness) = hsb(red: red, green: green, blue: blue)

        // Achromatic first. Almost all product photography is shot on white, and most
        // streetwear is black, grey or off-white — so these are the common cases, not
        // the edge cases, and hue is meaningless once saturation is this low.
        if saturation < 0.12 {
            switch brightness {
            // True black is darker than people think: #1C1C1E, the colour of most
            // "black" garments in a photograph, is charcoal to the eye.
            case ..<0.09: return NamedColor(name: "Black", confidence: 0.95)
            case ..<0.3: return NamedColor(name: "Charcoal", confidence: 0.85)
            case ..<0.65: return NamedColor(name: "Grey", confidence: 0.85)
            case ..<0.9:
                // Warm off-whites are "cream"/"ecru" in this world and are worth
                // distinguishing from a true white — half a rail of streetwear is one
                // or the other.
                return NamedColor(name: saturation > 0.05 && hue < 0.15 ? "Cream" : "Grey", confidence: 0.7)
            default:
                return NamedColor(name: saturation > 0.04 && hue < 0.15 ? "Cream" : "White", confidence: 0.9)
            }
        }

        // Very dark colours read as their dark name regardless of how saturated they are.
        if brightness < 0.22 {
            switch hue {
            case 0.55..<0.75: return NamedColor(name: "Navy", confidence: 0.85)
            case 0.0..<0.05, 0.92...1.0: return NamedColor(name: "Burgundy", confidence: 0.8)
            case 0.2..<0.45: return NamedColor(name: "Forest", confidence: 0.75)
            default: return NamedColor(name: "Black", confidence: 0.7)
            }
        }

        let confidence = min(1, 0.55 + saturation * 0.45)

        switch hue {
        case ..<0.042, 0.94...:
            if brightness < 0.45 { return NamedColor(name: "Burgundy", confidence: confidence) }
            if saturation < 0.45 { return NamedColor(name: "Pink", confidence: confidence * 0.9) }
            return NamedColor(name: "Red", confidence: confidence)
        case ..<0.075:
            // The brown/tan/orange band is the messiest in the whole space, and it is
            // also where most outerwear and footwear lands, so it gets three answers
            // rather than one.
            if brightness < 0.5 { return NamedColor(name: "Brown", confidence: confidence) }
            if saturation < 0.5 { return NamedColor(name: "Tan", confidence: confidence) }
            return NamedColor(name: "Orange", confidence: confidence)
        case ..<0.11:
            if brightness < 0.45 { return NamedColor(name: "Brown", confidence: confidence) }
            // Beige is paler *and* flatter than tan; saturation is what separates them,
            // not brightness. #D2B48C is literally the colour named "tan".
            if saturation < 0.22 { return NamedColor(name: "Beige", confidence: confidence) }
            return saturation < 0.5
                ? NamedColor(name: "Tan", confidence: confidence)
                : NamedColor(name: "Orange", confidence: confidence)
        case ..<0.15:
            return brightness < 0.5
                ? NamedColor(name: "Olive", confidence: confidence)
                : NamedColor(name: "Yellow", confidence: confidence)
        case ..<0.25:
            // Olive runs further into the greens than a naive hue split suggests —
            // #556B2F sits at 0.23 and is olive to anyone who wears it.
            return brightness < 0.5
                ? NamedColor(name: "Olive", confidence: confidence)
                : NamedColor(name: "Green", confidence: confidence)
        case ..<0.45:
            return brightness < 0.45
                ? NamedColor(name: "Forest", confidence: confidence)
                : NamedColor(name: "Green", confidence: confidence)
        case ..<0.52:
            return NamedColor(name: "Teal", confidence: confidence)
        case ..<0.6:
            return brightness < 0.5
                ? NamedColor(name: "Navy", confidence: confidence)
                : NamedColor(name: "Blue", confidence: confidence)
        case ..<0.72:
            return brightness < 0.4
                ? NamedColor(name: "Navy", confidence: confidence)
                : NamedColor(name: "Blue", confidence: confidence)
        case ..<0.83:
            return NamedColor(name: "Purple", confidence: confidence)
        default:
            return NamedColor(name: "Pink", confidence: confidence)
        }
    }

    /// Hue 0–1, saturation 0–1, brightness 0–1.
    public static func hsb(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        var hue = 0.0
        if delta > 0 {
            if maximum == red {
                hue = (green - blue) / delta
            } else if maximum == green {
                hue = 2 + (blue - red) / delta
            } else {
                hue = 4 + (red - green) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maximum == 0 ? 0 : delta / maximum, maximum)
    }

    /// Whether a pixel is likely to be the seamless backdrop rather than the garment.
    ///
    /// Storefront product shots are overwhelmingly shot on pure white or pure black
    /// sweeps. Counting those pixels would make every profile say "White", so they are
    /// excluded from the dominant-colour vote — at the cost of genuinely white garments
    /// being decided by their shadows and trim, which is the better trade.
    public static func isLikelyBackdrop(red: Double, green: Double, blue: Double) -> Bool {
        let (_, saturation, brightness) = hsb(red: red, green: green, blue: blue)
        // 0.93, tried at 0.88 and reverted: the lower threshold does exclude the grey
        // studio sweep, but it also eats the near-white pixels of a *white garment*,
        // leaving only its shadows and folds — which vote "Grey". Measured on real Kith
        // and BBC shots, three white tees went from correct to wrong. Letting a little
        // backdrop through is the cheaper error.
        return (brightness > 0.93 && saturation < 0.06) || brightness < 0.06
    }
}
