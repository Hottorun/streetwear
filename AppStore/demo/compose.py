#!/usr/bin/env python3
"""Composes the App Store images: a headline over each raw screen in a device frame.

    python3 AppStore/demo/compose.py

Reads AppStore/demo/raw/*.png (from shoot.sh), writes AppStore/screenshots/NN-name.jpg at
1320x2868 — the 6.9" size. JPEG because App Store Connect refuses PNGs with an alpha channel.
Rendered by headless Chrome so the type is real type, not a bitmap font.
"""
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
RAW = HERE / "raw"
OUT = HERE.parent / "screenshots"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1320, 2868

PAPER, INK, SIGNAL, MUTED = "#F4F3EE", "#14140F", "#D93A1E", "#8A8A80"

# (file, kicker, headline, subline, dark)
SHOTS = [
    ("feed", "Every brand, one feed", "Never miss<br>a drop again.",
     "New releases, restocks and price cuts from the labels you follow.", False),
    ("product", "Restock alerts", "Back in your size?<br>You'll know.",
     "Your sizes, picked out on every product.", False),
    ("discover", "Discover", "Pieces that go<br>with what you own.",
     "Every card is matched against your wardrobe.", True),
    ("saved", "Your collection", "Save it now.<br>Decide later.",
     "One wall for everything you're eyeing.", False),
    ("style", "Style", "Outfits from your<br>own wardrobe.",
     "See what works together, and what's missing.", False),
    ("fit", "Fit studio", "Lay out the fit<br>before you buy it.",
     "Every piece cut out. Drag, scale, rotate, pick a ground.", False),
    ("calendar", "Drop calendar", "Know the date.<br>Get the reminder.",
     "A heads-up the morning of, and again at release.", False),
]

PAGE = """<!doctype html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Newsreader:opsz,wght@6..72,500&family=IBM+Plex+Mono:wght@500&display=block" rel="stylesheet">
<style>
  * {{ margin: 0; box-sizing: border-box; }}
  html, body {{ width: {W}px; height: {H}px; overflow: hidden; background: {bg}; }}
  .kicker {{ position: absolute; left: 110px; top: 190px; font: 500 34px 'IBM Plex Mono', monospace;
             letter-spacing: 0.22em; text-transform: uppercase; color: {SIGNAL}; }}
  .kicker::before {{ content: ""; display: inline-block; width: 18px; height: 18px; border-radius: 50%;
                     background: {SIGNAL}; margin-right: 22px; vertical-align: 3px; }}
  h1 {{ position: absolute; left: 106px; right: 90px; top: 262px; font: 500 122px/1.02 'Newsreader', serif;
        letter-spacing: -0.02em; color: {fg}; }}
  p {{ position: absolute; left: 110px; right: 140px; top: 548px; font: 400 44px/1.3 'Newsreader', serif;
       color: {sub}; }}
  .device {{ position: absolute; left: 50%; top: 760px; transform: translateX(-50%);
             width: 948px; padding: 16px; border-radius: 128px; background: {bezel};
             box-shadow: 0 60px 120px rgba(20,20,15,{shadow}), 0 0 0 2px {rim}; }}
  .device img {{ display: block; width: 100%; border-radius: 112px; }}
</style></head><body>
  <div class="kicker">{kicker}</div>
  <h1>{headline}</h1>
  <p>{subline}</p>
  <div class="device"><img src="{src}"></div>
</body></html>"""


def main() -> None:
    OUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for index, (name, kicker, headline, subline, dark) in enumerate(SHOTS, start=1):
            html = PAGE.format(
                W=W, H=H, SIGNAL=SIGNAL,
                bg=INK if dark else PAPER,
                fg=PAPER if dark else INK,
                sub="#A5A59B" if dark else MUTED,
                bezel="#2A2A26" if dark else "#14140F",
                rim="#3A3A35" if dark else "#14140F",
                shadow="0.5" if dark else "0.22",
                kicker=kicker, headline=headline, subline=subline,
                src=(RAW / f"{name}.png").as_uri(),
            )
            page = pathlib.Path(tmp) / f"{name}.html"
            page.write_text(html)
            png = pathlib.Path(tmp) / f"{name}.png"
            subprocess.run([
                CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
                "--force-device-scale-factor=1", "--allow-file-access-from-files",
                "--virtual-time-budget=8000", f"--window-size={W},{H}",
                f"--screenshot={png}", page.as_uri(),
            ], check=True, capture_output=True)
            target = OUT / f"{index:02d}-{name}.jpg"
            subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "92",
                            str(png), "--out", str(target)], check=True, capture_output=True)
            print(target.relative_to(HERE.parent.parent))


if __name__ == "__main__":
    main()
