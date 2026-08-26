# The app icon

`streetw/Assets.xcassets/AppIcon.appiconset` holds three 1024² PNGs — light, dark and
tinted — and they are **generated**, not drawn. `RenderIcon.swift` is the source of truth:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftc -O Tools/AppIcon/RenderIcon.swift -o /tmp/render-icon
/tmp/render-icon streetw/Assets.xcassets/AppIcon.appiconset
```

Kept as code for the same reason the palette is: the icon uses the app's own colours
(`Color.wash` and `Color.ink`, each appearance taking its own pair) and its own typeface,
and a hand-exported PNG
drifts from those the first time one of them changes — silently, on the one surface nobody
looks at twice. Editing the constants and re-running keeps the two in step.

Pure CoreGraphics and CoreText, deliberately — importing AppKit needs an `NSApplication`
and traps when run headless, which is how this is run.

## What it is

A **swing ticket** carrying a serif `s` with a rule under it, on the app's own `wash` grey.

The ticket says clothes without a word, which no arrangement of letters managed. The letter
and the rule beneath it say what the app *does*: `SizeRun` prints a garment's sizes and
draws exactly that rule under the one you wear, so this is not a monogram inside a shape —
it is a tag with your size marked on it.

**It carries no vermilion.** The rule is the app's device and in the app it is vermilion,
but here it is drawn in the ground like the letter, so the mark stays two tones of ink and
paper and survives the tinted appearance intact — iOS derives that hue from luminance, and a
third colour would have nothing to say there. Spending the accent is one constant away
(`palette.mark` → a vermilion in `draw`'s fill) and was drawn several ways before; see
*What it replaced*.

Six things about the drawing are load-bearing.

**The letter sits inside the field, and that is a reversal.** It used to be 700 tall — far
larger than the ticket, cropped on every side, the crop being the drawing. That is a strong
mark and it costs the thing the mark is *of*: at 700 the `s` eats both chamfers and swallows
the eyelet, so the silhouette stops reading as a swing tag. Contained, the tag is a tag
again, the eyelet is an eyelet, and there is room in the clear for the rule.

**The letter and rule are painted in the ground colour and clipped to the ticket.** Painting
them in the *ground* is what makes this a punched tag rather than a printed one. The clip
stays even though nothing reaches the edge any more: it costs one call and it is the
guarantee that turning `letterHeight` up can never quietly destroy the silhouette.

**The rule spans the letter's inked width and nothing more** — the same way the rule in
`SizeRun` spans its token. It is measured from what the glyph actually inked rather than
from the font's advance width, which is wider. A rule that overhung would read as an
underscore rather than as a mark under a size.

**The letter and the rule are set as one block, centred together.** Centring the letter
alone and hanging a rule off it drifts the whole mark low the moment either measurement
changes.

**Cut corners over a flat top edge, not a gable.** The first cut ran a single apex across
the full width, and at sixty points that shape is a *house* — the eyelet was doing all the
work of saying otherwise. A real swing ticket has its two top corners taken off at 45° and
keeps a flat edge between them, and that flat edge is what the eye actually recognises.

**The block is centred in the field below the eyelet, not on the ticket.** Centred on the
outline it sits visibly low: the eyelet takes a bite out of the top and the eye reads the
field that is left.

**The dark appearance is a true inversion** — a paper ticket on a dark ground. Drawing the
ink ticket on a dark ground would be ink on ink, with no contrast whatever. So the ticket is
always the `ink` of its *own* appearance and the ground is always that appearance's `wash`.

The tinted variant is the same drawing in greys: iOS derives the hue from luminance, so it
must carry no colour of its own.

## How big the letter can get

`letterHeight` is the dial, and it has a real ceiling that is worth knowing before turning
it up.

New York's `s` is about **0.77 as wide as it is tall**, so a letter wide enough to touch
the ticket's sides is *always* taller than the ticket too. There is no size that crops only
left and right: either the letter fits inside the field, or the ticket crops it on every
axis at once. That is the ceiling, and it is why the letter is clipped to the outline — past
the field the ticket becomes the crop rather than the letter spilling onto the ground and
destroying the silhouette.

Measured on the 530 × 660 ticket, with the rule and its gap taking 76 of the field's 522:

| `letterHeight` | What happens |
|---|---|
| 300 | **Shipped.** Letter whole and legible at sixty points, rule in the clear beneath it, both chamfers and the eyelet reading. |
| ~420 | Letter fills most of the width, still whole, rule still in the clear. The boldest setting that changes nothing else. |
| ~480 | No room left under the letter — the rule would have to lie across the ticket's foot and over the letter's terminal. |
| ~540 | The eyelet merges into the letter's shoulder and the foot crops its terminal. |
| 700 | The previous icon, drawn with no rule. Terminals amputated by the ticket's edges, eyelet inside the letter's bowl. A strong mark that stops reading as a ticket. |

If a much bigger letter is wanted *and* the rule kept, make the **ticket taller** —
468 × 772 is closer to a real swing ticket's proportion anyway, and the extra height is
exactly what buys room for a letter that fills the width whole with the rule still in the
clear. That variant is drawn; it is not shipped only because it changes the silhouette as
well as the letter.

## What it replaced

A serif `s` over a vermilion rule, then `S M L` — the size run — over the same rule. The
first said nothing (a letter on off-white is what a hundred apps look like); the second said
the right thing but as typography, which is a weaker read at icon size than a silhouette.
The ticket keeps the letter and gets a shape around it.

Then the letter grew to 700 and the rule went with it — there was no clear space left to put
one in. Bringing the letter back to 300 is what returned the rule, and the rule is the half
of this mark that means something: a tag with a size marked on it, rather than a letter in a
shape.

Several ways of spending the accent were drawn: the rule in vermilion (the app's own device,
and the obvious candidate — one constant away if wanted), the eyelet in vermilion (clean,
and the dot reads as an alert), a band across the ticket's foot (the most presence, but it
cuts the silhouette), and the letter itself in vermilion (striking, and it breaks the rule
that the accent means *this is happening* rather than *this is us*).

Grounds were swept too, at this letter size: vermilion, ink, `wash`, a vermilion ticket on
paper, a vermilion ticket on ink, and a split where the letter is decoupled from the ground.
`wash` is what shipped.
