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
        // How far apart the channels actually are, in absolute terms.
        //
        // **Saturation cannot be trusted in the dark, and this is the whole reason it is
        // measured twice.** HSB saturation is `(max - min) / max`, so it *divides by the
        // brightness* — and near black that denominator is tiny. A black hoodie shot under
        // cool studio light comes back around (0.09, 0.10, 0.12): the channels are three
        // hundredths apart, which no eye would call a colour, and the arithmetic reports a
        // saturation of 0.25 with a blue hue. So the achromatic branch declined it and the
        // dark branch named it **Navy**.
        //
        // Measured on a real collection: of twenty-eight saved garments, sixteen came back
        // Navy — including one titled "washed black", one called "Onyx" and a pair of black
        // shorts. The style profile then reported the wardrobe as navy, every fit it
        // proposed read "All navy", and the one thing the colour rules exist to do — notice
        // that a garment has a colour — was being done wrong on most of the collection.
        let chroma = max(red, green, blue) - min(red, green, blue)

        // Achromatic first. Almost all product photography is shot on white, and most
        // streetwear is black, grey or off-white — so these are the common cases, not
        // the edge cases, and hue is meaningless once saturation is this low.
        if saturation < 0.12 || chroma < Self.faintestChroma {
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

        // Very dark colours read as their dark name regardless of how saturated they are —
        // but only once the channels are far enough apart to be a colour at all. A real navy
        // (#1B1F3B) separates by 0.13; a black garment with a cool cast separates by 0.03,
        // and calling that navy is how a wardrobe of black clothes described itself as blue.
        if brightness < 0.22 {
            guard chroma >= Self.darkColourChroma else {
                return NamedColor(name: brightness < 0.09 ? "Black" : "Charcoal", confidence: 0.8)
            }
            // **The circle is covered, and it was not.** Three arcs were named and the rest
            // fell through to "Black" — so a chocolate brown (0.20, 0.12, 0.06), a dark teal,
            // a dark purple and a dark orange were all filed as black, with a cliff at
            // `brightness == 0.22`: one notch brighter and the same chocolate came back
            // "Brown". A dark colour is still that colour, and a wardrobe that describes
            // itself as entirely black is the failure this whole band exists to avoid — the
            // chroma guard above is what keeps a black garment with a cool cast out of here.
            //
            // Every name is one `ColorHarmony.Swatch.wheel` knows. A name it does not hold
            // scores 0.5 against everything, which is a silent way of saying nothing.
            switch hue {
            case ..<0.05: return NamedColor(name: "Burgundy", confidence: 0.8)
            case ..<0.11: return NamedColor(name: "Brown", confidence: 0.75)
            case ..<0.2: return NamedColor(name: "Olive", confidence: 0.7)
            case ..<0.45: return NamedColor(name: "Forest", confidence: 0.75)
            case ..<0.55: return NamedColor(name: "Teal", confidence: 0.7)
            case ..<0.76: return NamedColor(name: "Navy", confidence: 0.85)
            case ..<0.92: return NamedColor(name: "Purple", confidence: 0.7)
            default: return NamedColor(name: "Burgundy", confidence: 0.8)
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

    /// Below this the channels are close enough together that there is no colour to name,
    /// whatever the ratio between them says. Deliberately small — this only has to catch the
    /// cast a camera puts on a grey card, not to arbitrate between muted colours.
    private static let faintestChroma = 0.055

    /// And a *dark* colour has to separate further still before it is named.
    ///
    /// Higher than `faintestChroma` because the dark band assigns a hue with no saturation
    /// floor at all — it is the one place a two-hundredths difference between channels could
    /// become the word "Forest". A real navy clears this comfortably.
    private static let darkColourChroma = 0.09

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
