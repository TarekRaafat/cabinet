#!/usr/bin/env python3
"""Build the brand files in brand/assets/ (and docs/logo.svg) from brand/tokens.json.

  python3 tools/build-brand.py                       write every SVG
  python3 tools/build-brand.py --check               exit 1 when a file is missing or out of date (npm test runs this)
  python3 tools/build-brand.py --png                 also render the PNGs (macOS: uses sips)
  python3 tools/build-brand.py --outline-font F.ttf  first redraw the text outlines in brand/text-paths.json
                                                     from Schibsted Grotesk (needs: pip install fonttools uharfbuzz)

The SVGs need only the standard library. The name and the tagline are outlines, not text,
so they look the same without the font installed.
"""
import json, math, os, subprocess, sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(KIT, "brand")
ASSETS = os.path.join(BRAND, "assets")
TOKENS = json.load(open(os.path.join(BRAND, "tokens.json")))
C = {k: v["value"] for k, v in TOKENS["color"].items()}
M = TOKENS["mark"]


def n(x):
    return "%g" % round(x, 3)


# ---- the mark ----------------------------------------------------------------

def places():
    """Every place but the open one: (x, y, degrees), counterclockwise from the open place."""
    k = M["places"]
    for i in range(1, k):
        a = 2 * math.pi * i / k
        yield M["ring_radius"] * math.cos(a), -M["ring_radius"] * math.sin(a), 360 * i / k


def chair(x, y, deg, attrs=""):
    w = TOKENS["chairs"]["seat"]
    return ('<g transform="translate(%s %s) rotate(%s)"%s>' % (n(x), n(y), n(-deg), attrs) +
            '<rect x="%s" y="%s" width="%s" height="%s" rx="%s"/>' % (n(-w / 2 - 1), n(-w / 2), n(w), n(w), n(w * 0.28)) +
            '<rect x="%s" y="%s" width="%s" height="%s" rx="%s"/></g>' % (n(w / 2 + 0.6), n(-w * 0.62), n(w * 0.26), n(w * 1.24), n(w * 0.13)))


def mark(fill, outline=None, seat="dot", tile=None, tile_radius=None):
    """The mark's drawing on the 100 unit grid, centered on 0,0."""
    if seat == "chair":
        body = "".join(chair(x, y, d) for x, y, d in places())
    else:
        body = "".join('<circle cx="%s" cy="%s" r="%s"/>' % (n(x), n(y), n(M["seat_diameter"] / 2)) for x, y, d in places())
    body = '<g fill="%s">%s</g>' % (fill, body)
    if outline:
        o = M["outline"]
        attrs = ' fill="none" stroke="%s" stroke-width="%s"' % (outline, n(o["stroke"]))
        body += chair(M["ring_radius"], 0, 0, attrs) if seat == "chair" else \
            '<circle cx="%s" cy="0" r="%s"%s/>' % (n(M["ring_radius"]), n(o["radius"]), attrs)
    if tile:
        t = M["tile"]
        r = t["radius"] if tile_radius is None else tile_radius
        body = '<rect x="-50" y="-50" width="100" height="100" rx="%s" fill="%s"/><g transform="scale(%s)">%s</g>' % (n(r), tile, n(t["mark_scale"]), body)
    return body


def svg(body, box, w, h, label, note):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="%s" height="%s" role="img" aria-label="%s">\n'
            '  <!-- %s Built by tools/build-brand.py from brand/tokens.json; do not edit by hand. -->\n  %s\n</svg>\n'
            % (box, n(w), n(h), label, note, body))


def mark_svg(note, size=96, **kw):
    return svg(mark(**kw), "-50 -50 100 100", size, size, "cabinet", note)


# ---- the name: outlines from brand/text-paths.json -----------------------------

def text_paths():
    return json.load(open(os.path.join(BRAND, "text-paths.json")))


def text(t, key, size, x, baseline, fill):
    """Text `key` at `size` px with its left edge at x and its baseline at `baseline`."""
    s = size / t["upm"]
    return '<path transform="translate(%s %s) scale(%s)" fill="%s" d="%s"/>' % (n(x), n(baseline), n(s), fill, t[key]["d"])


def wordmark_svg(fill, note):
    t = text_paths(); w = t["wordmark"]; s = 64 / t["upm"]
    x0, y0, x1, y1 = [v * s for v in w["bbox"]]   # bbox in font units, y up
    body = text(t, "wordmark", 64, -x0, y1, fill)
    return svg(body, "0 0 %s %s" % (n(x1 - x0), n(y1 - y0)), x1 - x0, y1 - y0, "cabinet", note)


def lockup_svg(fill, note):
    # Horizontal: the mark 1.1em, a gap of 0.32em, the name; the mark centered on the name's height.
    t = text_paths(); w = t["wordmark"]; size = 64; s = size / t["upm"]
    x0, y0, x1, y1 = [v * s for v in w["bbox"]]
    m = 1.1 * size; gap = 0.32 * size; h = max(m, y1 - y0)
    cy = h / 2
    body = '<g transform="translate(%s %s) scale(%s)">%s</g>' % (n(m / 2), n(cy), n(m / 100), mark(fill))
    body += text(t, "wordmark", size, m + gap - x0, cy + (y1 + y0) / 2, fill)
    return svg(body, "0 0 %s %s" % (n(m + gap + x1 - x0), n(h)), m + gap + x1 - x0, h, "cabinet", note)


def lockup_stacked_svg(fill, note):
    # Stacked: the mark 2.25em over the name, 0.44em apart, both centered.
    t = text_paths(); w = t["wordmark"]; size = 64; s = size / t["upm"]
    x0, y0, x1, y1 = [v * s for v in w["bbox"]]
    m = 2.25 * size; gap = 0.44 * size; tw = x1 - x0; width = max(m, tw); h = m + gap + (y1 - y0)
    body = '<g transform="translate(%s %s) scale(%s)">%s</g>' % (n(width / 2), n(m / 2), n(m / 100), mark(fill))
    body += text(t, "wordmark", size, (width - tw) / 2 - x0, m + gap + y1, fill)
    return svg(body, "0 0 %s %s" % (n(width), n(h)), width, h, "cabinet", note)


def social_svg(note):
    # 1280 x 640, paper: the mark 300px at the left margin, the name and two lines of tagline beside it.
    t = text_paths(); W, H = 1280, 640; pad = 102; m = 300; gap = 77
    body = '<rect width="%d" height="%d" fill="%s"/>' % (W, H, C["paper"])
    body += '<g transform="translate(%s %s) scale(%s)">%s</g>' % (n(pad + m / 2), n(H / 2), n(m / 100), mark(C["ink"]))
    ws, ts, lh, between = 132, 34, 51, 18
    wb = [v * ws / t["upm"] for v in t["wordmark"]["bbox"]]
    block = (wb[3]) + between + lh * 2
    top = (H - block) / 2
    x = pad + m + gap
    body += text(t, "wordmark", ws, x - wb[0], top + wb[3], C["ink"])
    body += text(t, "tagline1", ts, x, top + wb[3] + between + lh * 0.8, C["slate"])
    body += text(t, "tagline2", ts, x, top + wb[3] + between + lh * 1.8, C["slate"])
    return svg(body, "0 0 %d %d" % (W, H), W, H, "cabinet: a team of AI agents and one owner who signs off", note)


def favicon_svg():
    body = "<style>circle{fill:%s}@media (prefers-color-scheme:dark){circle{fill:%s}}</style>" % (C["ink"], C["mist"])
    body += "".join('<circle cx="%s" cy="%s" r="%s"/>' % (n(x), n(y), n(M["seat_diameter"] / 2)) for x, y, d in places())
    return svg(body, "-50 -50 100 100", 32, 32, "cabinet", "The favicon: the plain mark, light seats when the browser is dark.")


# ---- every file ----------------------------------------------------------------

def files():
    ink, mist, paper, night = C["ink"], C["mist"], C["paper"], C["night"]
    out = {
        "mark.svg": mark_svg("The mark: dark seats, for light backgrounds.", fill=ink),
        "mark-light.svg": mark_svg("The mark: light seats, for dark backgrounds.", fill=mist),
        "mark-outlined.svg": mark_svg("The mark with the owner's open seat in brass, for light backgrounds.", fill=ink, outline=C["brass"]),
        "mark-outlined-light.svg": mark_svg("The mark with the owner's open seat in brass, for dark backgrounds.", fill=mist, outline=C["brass-light"]),
        "logo.svg": mark_svg("The mark on its own light tile: reads the same on light and dark pages.", fill=ink, tile=paper),
        "app-icon.svg": mark_svg("The dark app icon and avatar, with the owner's open seat.", 512, fill=mist, outline=C["brass-light"], tile=night),
        "app-icon-light.svg": mark_svg("The light app icon and avatar, plain.", 512, fill=ink, tile=paper),
        "apple-touch-icon.svg": mark_svg("The dark app icon, square: the system rounds the corners.", 180, fill=mist, outline=C["brass-light"], tile=night, tile_radius=0),
        "favicon.svg": favicon_svg(),
        "chairs.svg": mark_svg("The chairs: an illustration of the mark, 96px or more, never the logo.", 192, fill=ink, seat="chair"),
        "chairs-light.svg": mark_svg("The chairs, light, for dark backgrounds and video.", 192, fill=mist, seat="chair"),
        "chairs-owner-light.svg": mark_svg("The chairs with the owner's empty chair in brass, for dark backgrounds.", 192, fill=mist, seat="chair", outline=C["brass-light"]),
        "wordmark.svg": wordmark_svg(ink, "The name, as outlines: dark, for light backgrounds."),
        "wordmark-light.svg": wordmark_svg(mist, "The name, as outlines: light, for dark backgrounds."),
        "lockup.svg": lockup_svg(ink, "The mark and the name side by side: dark, for light backgrounds."),
        "lockup-light.svg": lockup_svg(mist, "The mark and the name side by side: light, for dark backgrounds."),
        "lockup-stacked.svg": lockup_stacked_svg(ink, "The mark over the name: dark, for light backgrounds."),
        "lockup-stacked-light.svg": lockup_stacked_svg(mist, "The mark over the name: light, for dark backgrounds."),
        "social-preview.svg": social_svg("The social preview, 1280 x 640, for the repository's link preview."),
    }
    return {os.path.join(ASSETS, k): v for k, v in out.items()}


# PNG: (file, from, size). sips renders SVG on macOS.
PNGS = [
    ("favicon-16.png", "logo.svg", 16), ("favicon-32.png", "logo.svg", 32), ("favicon-48.png", "logo.svg", 48),
    ("apple-touch-icon.png", "apple-touch-icon.svg", 180),
    ("app-icon-192.png", "app-icon.svg", 192), ("app-icon-512.png", "app-icon.svg", 512),
    ("social-preview.png", "social-preview.svg", 1280),
]


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def outline_font(font_path):
    """Redraw brand/text-paths.json from the font: shaped with its kerning, at the guide's weights and tracking."""
    import io
    import uharfbuzz as hb
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.pens.boundsPen import BoundsPen

    def shape(text, weight, tracking_em):
        f = instancer.instantiateVariableFont(TTFont(font_path), {"wght": weight})
        buf = io.BytesIO(); f.save(buf); data = buf.getvalue()
        hbf = hb.Font(hb.Face(data)); b = hb.Buffer(); b.add_str(text); b.guess_segment_properties(); hb.shape(hbf, b, {})
        gs = f.getGlyphSet(); order = f.getGlyphOrder(); upm = f["head"].unitsPerEm
        svgpen = SVGPathPen(gs); bounds = BoundsPen(gs); x = 0
        for info, pos in zip(b.glyph_infos, b.glyph_positions):
            g = order[info.codepoint]
            # Font units are y up; the SVG is y down, so flip.
            gs[g].draw(TransformPen(svgpen, (1, 0, 0, -1, x + pos.x_offset, -pos.y_offset)))
            gs[g].draw(TransformPen(bounds, (1, 0, 0, 1, x + pos.x_offset, pos.y_offset)))
            x += pos.x_advance + tracking_em * upm
        return upm, {"text": text, "weight": weight, "tracking_em": tracking_em, "d": svgpen.getCommands(),
                     "bbox": [round(v, 1) for v in bounds.bounds]}

    fd = TOKENS["font"]
    upm, wm = shape(TOKENS["name"], fd["display"]["weight"], fd["display"]["tracking_em"])
    _, t1 = shape("A team of AI agents and one owner", fd["body"]["weight"], 0)
    _, t2 = shape("who signs off.", fd["body"]["weight"], 0)
    out = {"upm": upm, "font": "Schibsted Grotesk (SIL Open Font License 1.1)", "wordmark": wm, "tagline1": t1, "tagline2": t2}
    with open(os.path.join(BRAND, "text-paths.json"), "w") as f:
        json.dump(out, f, indent=1); f.write("\n")


def main(argv):
    if "--outline-font" in argv:
        outline_font(argv[argv.index("--outline-font") + 1])
    want = files()
    want[os.path.join(KIT, "docs", "logo.svg")] = want[os.path.join(ASSETS, "logo.svg")]
    if "--check" in argv:
        bad = [os.path.relpath(p, KIT) for p, s in want.items() if not os.path.exists(p) or open(p).read() != s]
        for name, _, size in PNGS:
            p = os.path.join(ASSETS, name); dim = png_size(p) if os.path.exists(p) else None
            if not dim or dim[0] != size:
                bad.append(os.path.relpath(p, KIT))
        html = open(os.path.join(BRAND, "index.html")).read()
        bad += ["brand/index.html: color %s %s" % (k, v) for k, v in C.items() if v.upper() not in html.upper()]
        bad += ["brand/index.html links a missing assets/%s" % a for a in set(__import__("re").findall(r'assets/([a-z0-9.-]+)', html))
                if not os.path.exists(os.path.join(ASSETS, a))]
        if bad:
            print("out of date (python3 tools/build-brand.py --png):\n  " + "\n  ".join(sorted(bad)), file=sys.stderr)
            return 1
        return 0
    os.makedirs(ASSETS, exist_ok=True)
    for p, s in want.items():
        with open(p, "w") as f:
            f.write(s)
    if "--png" in argv:
        for name, src, size in PNGS:
            out = os.path.join(ASSETS, name)
            subprocess.run(["sips", "-s", "format", "png", "-Z", str(size), os.path.join(ASSETS, src), "--out", out],
                           check=True, stdout=subprocess.DEVNULL)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
