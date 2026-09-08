# The app icon

`streetw/Assets.xcassets/AppIcon.appiconset` holds three 1024² PNGs — light, dark and
tinted — and they are **generated**, not drawn. `RenderIcon.swift` is the source of truth:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftc -O Tools/AppIcon/RenderIcon.swift -o /tmp/render-icon
/tmp/render-icon streetw/Assets.xcassets/AppIcon.appiconset
```

Kept as code for the same reason the palette is: the icon is built from the app's own
colours — `Color.paper`, `wash`, `hairline` and `ink`, each appearance taking its own set —
and a hand-exported PNG drifts from those the first time one of them changes, silently, on
the one surface nobody looks at twice. Editing the constants and re-running keeps the two in
step. It has already paid for itself twice: once when the mark changed letter, and once when
it stopped having a letter at all.

Pure CoreGraphics, deliberately — importing AppKit needs an `NSApplication` and traps when
run headless, which is how this is run. (CoreText went with the letter; there is no type in
the mark now.)

## What it is

**Two swing tickets hanging from a sagging wire.** No letter, no monogram.

It was one ticket with a serif `s` punched out of it, and then a `d` when the app was
renamed from streetw to Dropwall — which is the argument against a letter, made twice: a
monogram has to be re-cut every time the name moves, and in the meantime it says nothing
that the name underneath it isn't already saying. Two tags on a line says *Dropwall*
outright. It also says the thing one tag never could, which is that the app is about a
**collection** rather than a product.

What was lost is worth naming, because it was the good half of the old mark: the rule under
the letter meant *your size, marked*, and a tag pair has nowhere to put it. That was the
price of the change, paid knowingly.

## The three rules that make it read

Each of these was arrived at by rendering the alternative and looking at it at sixty points,
which is the only size that matters.

**The tags lean toward each other.** Splayed — the front leaning left, the back leaning
right — the front tag buries the back one, and the pair reads as a single notched blob with
a wedge behind it. Converging, both silhouettes stay whole. It is the only arrangement that
still reads as *two* tags at forty points, and it was not obvious in advance: splayed looks
more natural in the head and worse on the screen.

**The back tag is smaller as well as further right.** Offset alone reads as two tags side by
side. The size difference is what makes the second one read as *behind* rather than
*beside*. `0.84` is the ratio; much below that and it stops being a tag and becomes a bump,
which is what killed an earlier cut at `0.70`.

**They rotate about their eyelets**, which is the pivot a hanging tag actually turns on. It
has a useful consequence: a circle is invariant under rotation about its own centre, so the
eyelet stays exactly where it was and the wire still threads through it with no extra
arithmetic.

## The wire

Quadratic, sagging, running off both edges. A straight rule across the icon reads as a
**divider** — furniture — and the sag is what makes it a line something is *hung from*.

Its control point sits at mid-width, and that is load-bearing rather than tidy: with
`P0.x = 0`, `P1.x = side/2` and `P2.x = side`, the quadratic's x reduces exactly to
`side · t`. So the height under any x is closed-form and the tags can be placed on the curve
without walking it.

The wire is also drawn **through** each eyelet — clipped to the hole and stroked again —
which is the detail that says the tags are threaded on the line rather than stacked in front
of it. Skip it and they read as two tags floating near a wire.

## The halo, and why it cannot be a colour

The front tag takes a bite of ground out around it, or the two silhouettes merge wherever
they overlap and the whole point of a pair is lost at exactly the sizes where it matters.

**It has to be painted with the ground, not filled with a colour sampled from it.** The
ground is a gradient. Filling the halo — or the eyelets — with the gradient's top colour
leaves a pale outline anywhere the gradient has moved on, which on this composition is the
entire bottom-right. `paintGround` clips and re-draws the same gradient instead, so a hole
is an actual hole. This is the one thing in the file that looks like an optimisation and is
a correctness fix.

Only the front tag takes a halo: the bite is needed where one silhouette crosses another,
which is one edge, not two.

## The three appearances

| | Ground | Mark |
|---|---|---|
| light | `paper` → below `hairline`, gradient | `ink` |
| dark | `wash` → `paper`, both dark values, gradient | `ink` dark |
| tinted | flat black | white |

**Dark is a true inversion** — pale tickets on a dark ground — rather than an ink ticket on
an ink ground, which would have no contrast at all.

**Tinted is flat, and it is the only one that is.** iOS derives the tinted icon's hue from
luminance, so every tone in the image becomes a different strength of the user's chosen
colour. A gradient ground therefore stops being a light falling across the mark and becomes
a *band of tint* competing with it — the thing the tags sit on turns into a second subject.
Black ground and a white mark hands the system the two-tone image it can actually tint.

## Verifying a change

Read the built bundle, never the asset catalogue — the same rule as every other Info.plist
question:

```bash
plutil -p /tmp/streetw-dd/Build/Products/Debug-iphonesimulator/streetw.app/Info.plist \
  | grep -A4 CFBundleIcons
```

And look at it small. `AppIcon60x60@2x.png` is written into the bundle root and is the
honest test — every decision above was made there, not at 1024.
