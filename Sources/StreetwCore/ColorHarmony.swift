// ColorHarmony.swift
// Whether two garments look like they were chosen together.
//
// The gap this closes is the one the roadmap already named: fits were proposed from slots
// and savedAt alone, so nothing about a suggestion had ever *looked* at the clothes. A
// proposal could pair an orange hoodie with burgundy trousers and be, structurally, a
// perfectly good outfit — one top, one bottom, both things you kept — and obviously wrong
// to anyone with eyes.
//
// Deliberately not a model. There is nothing to train on: no labelled outfits, no
// engagement signal, and a user count where even co-follow recommendations are documented
// as meaningless. What there *is* is a dominant colour per saved item, already computed by
// `ImageTagger` on the way into the collection and currently read by nothing but the taste
// summary. Three rules over that get most of the way, and — unlike a model — they can say
// why, which is what turns a suggestion into a proposal rather than a shuffle.
//
// The rules, in the order they fire:
//
// - **A neutral goes with anything.** Most streetwear is black, grey, cream or denim, so
//   this is the common case rather than the escape hatch, and it is the reason the whole
//   thing can be this simple.
// - **One colour, worn twice, is a decision.** Two greens read as intent; the eye grants
//   monochrome a licence it grants nothing else.
// - **Two saturated colours are a risk**, and how much of one depends on how far apart
//   they sit on the wheel. Adjacent is a gradient and reads as considered; opposite is a
//   deliberate clash and is fine on purpose; the awkward middle — orange against purple —
//   is the one thing this exists to keep out of a suggestion.
//
// A colour it doesn't know scores neutral rather than badly: an unrecognised name means
// the classifier had no opinion, and inventing one would suppress a fit for no reason.

import Foundation

public enum ColorHarmony {
    /// How well two garment colours sit together, 0…1, with a line saying why.
    ///
    /// The reason is not decoration. A suggestion nobody understands is indistinguishable
    /// from a random pair, and the whole complaint about the old row was that it felt like
    /// one — so anything that scores a fit has to be able to account for itself in the
    /// four words that fit under a card.
    public static func score(_ first: String?, _ second: String?) -> (score: Double, reason: String?) {
        guard let first, let second,
              let a = Swatch(name: first), let b = Swatch(name: second)
        else { return (0.5, nil) }

        if a.name == b.name {
            return a.isNeutral
                ? (0.9, "All \(a.name.lowercased())")
                : (0.85, "\(a.name) on \(b.name.lowercased())")
        }

        if a.isNeutral && b.isNeutral {
            return (0.85, "\(a.name) and \(b.name.lowercased())")
        }

        if a.isNeutral || b.isNeutral {
            let colour = a.isNeutral ? b : a
            let neutral = a.isNeutral ? a : b
            return (0.8, "\(colour.name) with \(neutral.name.lowercased())")
        }

        // Both are chromatic. Distance around the wheel decides, in degrees.
        // The bands are wide and the gap between them is narrow, which is the correct
        // shape for this: the failure being guarded against is a specific, small family of
        // pairings, and everything else should get through. 65° keeps blue with teal and
        // purple — a boundary that sat at 40 and cut blue off from teal by a single
        // degree — while 140° keeps blue with orange and yellow, which are complementary
        // and among the most-worn combinations there are.
        let distance = a.separation(from: b)
        switch distance {
        case ..<65: return (0.7, "\(a.name) into \(b.name.lowercased())")
        case 140...: return (0.65, "\(a.name) against \(b.name.lowercased())")
        default: return (0.25, nil)
        }
    }

    /// Whether a pair is bad enough that proposing it would read as a bug.
    ///
    /// The bar is low on purpose. This suppresses the small number of genuinely jarring
    /// combinations rather than curating taste — an app that only ever proposed safe
    /// outfits would propose black on black forever, which is not a service.
    public static func isClash(_ first: String?, _ second: String?) -> Bool {
        score(first, second).score < 0.4
    }

    /// Whether a word is a colour this understands, and what to call it.
    ///
    /// Exposed so anything reading free text — `StyleStatement`, above all — can tell a
    /// colour from a garment without keeping a second list of colour words. Two lists would
    /// disagree, and the symptom would be somebody writing "olive" and the app agreeing it
    /// is a colour on one screen and treating it as a fabric on another.
    public static func canonicalName(of raw: String) -> String? {
        Swatch(name: raw)?.name
    }

    /// One of the names `ColorNamer` produces, placed on the wheel.
    ///
    /// Hue is in degrees and only means anything for the chromatic ones; a neutral carries
    /// nil, which is the whole distinction the rules above turn on. The values are the
    /// centre of each band rather than anything measured — this is deciding whether two
    /// garments fight, not matching paint.
    struct Swatch {
        var name: String
        var hue: Double?

        var isNeutral: Bool { hue == nil }

        init?(name raw: String) {
            let key = raw.trimmingCharacters(in: .whitespaces).capitalized
            guard let hue = Self.wheel[key] else { return nil }
            self.name = key
            self.hue = hue
        }

        /// Degrees between two hues, never more than 180 — the wheel wraps, so red at 0
        /// and pink at 340 are 20 apart and not 340.
        func separation(from other: Swatch) -> Double {
            guard let mine = hue, let theirs = other.hue else { return 0 }
            let raw = abs(mine - theirs).truncatingRemainder(dividingBy: 360)
            return min(raw, 360 - raw)
        }

        /// Nil hue means neutral: it sits with everything and fights with nothing.
        ///
        /// Navy and brown are in here deliberately. They are chromatic to a colour picker
        /// and neutral to a wardrobe — navy has been a suit for a century and brown is
        /// most of what leather and denim wash out to — and treating them as saturated
        /// colours would have the row refusing to put a navy jacket over olive trousers,
        /// which is an outfit people actually wear.
        static let wheel: [String: Double?] = [
            "Black": nil, "White": nil, "Grey": nil, "Charcoal": nil,
            "Cream": nil, "Beige": nil, "Tan": nil, "Navy": nil, "Brown": nil,

            "Red": 0, "Orange": 30, "Yellow": 55, "Olive": 75,
            "Green": 120, "Forest": 135, "Teal": 180, "Blue": 220,
            "Purple": 280, "Pink": 330, "Burgundy": 350
        ]
    }
}
