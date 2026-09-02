#!/usr/bin/env python3
"""Render the README's two charts as light/dark SVG pairs.

The numbers are the output of `python3 replay.py` over 1,179 local Claude Code
sessions (302,213 assistant turns, 30 days). Re-derive them there; this file
only draws.

Layout is hand-placed, so every label position is checked against `tw()` --
the rendered width of a monospace string -- rather than eyeballed. If you move
a label, re-check it against its neighbours.

    python3 charts/make_charts.py        # writes charts/*.svg
"""
import math
import os

OUT = os.path.dirname(os.path.abspath(__file__))

# threshold (k tokens), % of baseline saved, compactions fired in 30 days
CURVE = [
    (1000, 0.0, 0), (800, 44.4, 21), (700, 50.3, 29), (600, 49.6, 31),
    (500, 55.6, 44), (450, 57.6, 53), (400, 58.7, 58), (350, 59.8, 66),
    (300, 62.8, 77), (250, 64.6, 102), (200, 66.5, 127), (175, 67.3, 139),
    (150, 68.1, 157), (125, 68.7, 174), (100, 69.6, 201), (75, 70.1, 233),
    (50, 70.4, 266),
]

# idle gap bucket, count, mean cold-rebuild tokens on the resuming turn, cache gone?
GAPS = [
    ("5-30m", 3452, 29565, False), ("30-50m", 454, 68263, False),
    ("50-60m", 130, 84459, False), ("1-2h", 312, 329684, True),
    ("2-6h", 341, 328284, True), ("6-24h", 282, 313560, True),
    (">24h", 132, 243000, True),
]

THEMES = {
    "light": dict(ink="#1F2328", ink2="#4A5560", muted="#6E7781",
                  grid="#DCE3E8", rule="#B9C4CC", axis="#8A959E",
                  read="#1E7EA8", write="#D2691E", face="#FFFFFF"),
    "dark":  dict(ink="#E6EDF3", ink2="#B3C0CB", muted="#8B98A4",
                  grid="#2A333B", rule="#3D4A54", axis="#5A6772",
                  read="#3E97BD", write="#D2762F", face="#0D1117"),
}
FONT = "ui-monospace,SFMono-Regular,Menlo,monospace"
ADV = 0.6  # monospace advance width, as a fraction of the font size


def tw(s, size):
    """Rendered width of a monospace string -- used to keep labels apart."""
    return len(s) * size * ADV


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, fill, size=11, anchor="middle", weight="400"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" fill="{fill}" '
            f'font-size="{size}" font-weight="{weight}" font-family="{FONT}">{esc(s)}</text>')


def rule(x1, y1, x2, y2, color, dash=None, w=1):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return (f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            f'stroke="{color}" stroke-width="{w}"{d}/>')


def svg(w, h, label, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'width="{w}" height="{h}" role="img" aria-label="{esc(label)}">{body}</svg>')


def savings_chart(t):
    W, H = 800, 470
    PL, PR = 64, 26
    TA, BA = 56, 268   # panel A -- share of the bill removed
    TB, BB = 322, 404  # panel B -- compactions fired
    lo, hi = math.log10(50), math.log10(1000)
    xs = lambda k: PL + (hi - math.log10(k)) / (hi - lo) * (W - PL - PR)
    ya = lambda p: TA + (1 - p / 75.0) * (BA - TA)
    NMAX = 290
    yb = lambda n: BB - (n / NMAX) * (BB - TB)

    g = [
        text(PL, 16, "share of the bill compaction removes", t["ink"], 12, "start", "600"),
        text(PL, 33, "1,179 sessions · 302,213 turns · 30 days, replayed at every threshold",
             t["muted"], 10.5, "start"),
    ]

    # panel A: grid, then axes on top of it
    for v in (20, 40, 60):
        g.append(rule(PL, ya(v), W - PR, ya(v), t["grid"]))
    for v in (0, 20, 40, 60):
        g.append(rule(PL - 4, ya(v), PL, ya(v), t["axis"]))
        g.append(text(PL - 9, ya(v) + 4, f"{v}%", t["muted"], 11, "end"))
    g.append(rule(PL, TA, PL, BA, t["axis"]))
    g.append(rule(PL, BA, W - PR, BA, t["axis"]))

    # reference thresholds -- labels sit above the panel, clear of the curve
    for k, lab in ((450, "450k default"), (300, "300k current")):
        g.append(rule(xs(k), TA, xs(k), BA, t["rule"], dash="3 3"))
        g.append(text(xs(k), TA - 8, lab, t["ink2"], 10.5))

    pts = [(xs(k), ya(p)) for k, p, _ in CURVE]
    d = " ".join(("M" if i == 0 else "L") + f"{x:.1f} {y:.1f}" for i, (x, y) in enumerate(pts))
    g.append(f'<path d="{d} L {pts[-1][0]:.1f} {BA:.1f} L {pts[0][0]:.1f} {BA:.1f} Z" '
             f'fill="{t["read"]}" fill-opacity="0.10"/>')
    g.append(f'<path d="{d}" fill="none" stroke="{t["read"]}" stroke-width="2" '
             f'stroke-linejoin="round" stroke-linecap="round"/>')
    for k, p, _ in CURVE:
        big = k in (450, 300, 200)
        g.append(f'<circle cx="{xs(k):.1f}" cy="{ya(p):.1f}" r="{4.6 if big else 2.8}" '
                 f'fill="{t["read"]}" stroke="{t["face"]}" stroke-width="1.8"/>')
        if big:
            g.append(text(xs(k), ya(p) - 11, f"{p}%", t["ink"], 11, "middle", "600"))

    # panel B: grid, axes, bars
    g.append(text(PL, TB - 14, "compactions fired over the same 30 days",
                  t["ink"], 12, "start", "600"))
    for v in (100, 200):
        g.append(rule(PL, yb(v), W - PR, yb(v), t["grid"]))
        g.append(rule(PL - 4, yb(v), PL, yb(v), t["axis"]))
        g.append(text(PL - 9, yb(v) + 4, str(v), t["muted"], 11, "end"))
    g.append(rule(PL - 4, BB, PL, BB, t["axis"]))
    g.append(text(PL - 9, BB + 4, "0", t["muted"], 11, "end"))
    g.append(rule(PL, TB, PL, BB, t["axis"]))
    g.append(rule(PL, BB, W - PR, BB, t["axis"]))
    for k, _, n in CURVE:
        if not n:
            continue
        bx = min(xs(k) - 4, W - PR - 8)
        g.append(f'<rect x="{bx:.1f}" y="{yb(n):.1f}" width="8" '
                 f'height="{BB - yb(n):.1f}" rx="2" fill="{t["write"]}"/>')
    for k in (1000, 500, 300, 200, 100, 50):
        g.append(rule(xs(k), BB, xs(k), BB + 4, t["axis"]))
        anchor = "start" if k == 1000 else ("end" if k == 50 else "middle")
        g.append(text(xs(k), BB + 19, f"{k}k", t["muted"], 11, anchor))
    g.append(text((PL + W - PR) / 2, H - 12,
                  "compaction threshold — the context size that arms the daemon",
                  t["muted"], 11))

    return svg(W, H, "Savings rise steeply from a 1M threshold down to about 500k and then "
                     "flatten, while the number of compactions keeps climbing", "".join(g))


def gaps_chart(t):
    W, H = 800, 318
    PL, PR, T, B = 64, 26, 78, 246
    slot = (W - PL - PR) / len(GAPS)
    NMAX = 3800  # headroom so the tallest bar's label stays inside the panel
    ys = lambda v: B - (v / NMAX) * (B - T)

    g = [
        text(PL, 16, "5,103 idle gaps between consecutive turns", t["ink"], 12, "start", "600"),
        text(PL, 34, "orange = the cache has certainly expired, so the resuming turn pays a "
                     "full cold rebuild", t["muted"], 10.5, "start"),
    ]
    for v in (1000, 2000, 3000):
        g.append(rule(PL, ys(v), W - PR, ys(v), t["grid"]))
        g.append(rule(PL - 4, ys(v), PL, ys(v), t["axis"]))
        g.append(text(PL - 9, ys(v) + 4, f"{v:,}", t["muted"], 11, "end"))
    g.append(rule(PL - 4, B, PL, B, t["axis"]))
    g.append(text(PL - 9, B + 4, "0", t["muted"], 11, "end"))
    g.append(rule(PL, T - 6, PL, B, t["axis"]))
    g.append(rule(PL, B, W - PR, B, t["axis"]))

    for i, (lab, cnt, cold, expired) in enumerate(GAPS):
        x = PL + (i + 0.5) * slot
        w = slot * 0.5
        g.append(f'<rect x="{x - w / 2:.1f}" y="{ys(cnt):.1f}" width="{w:.1f}" '
                 f'height="{B - ys(cnt):.1f}" rx="3" fill="{t["write"] if expired else t["read"]}"/>')
        g.append(text(x, ys(cnt) - 7, f"{cnt:,}", t["ink2"], 10.5))
        g.append(rule(x, B, x, B + 4, t["axis"]))
        g.append(text(x, B + 19, lab, t["ink2"], 11))
        g.append(text(x, B + 34, f"{cold / 1000:.0f}k cold", t["muted"], 10))

    # firing window sits on the 50-60m bucket; stop the marker above that bar's label
    xw = PL + 2.5 * slot
    g.append(rule(xw, T - 6, xw, ys(GAPS[2][1]) - 16, t["rule"], dash="3 3"))
    g.append(text(xw, T - 14, "daemon fires here", t["ink"], 10.5, "middle", "600"))
    g.append(text((PL + W - PR) / 2, H - 12,
                  "idle gap length — bar height is how many gaps, the label under each bar is "
                  "the mean cold rebuild on resume", t["muted"], 10.5))

    return svg(W, H, "One in five idle gaps outlives the cache and pays a cold rebuild of "
                     "about 320k tokens", "".join(g))


for name, fn in (("savings-curve", savings_chart), ("idle-gaps", gaps_chart)):
    for mode, tokens in THEMES.items():
        path = os.path.join(OUT, f"{name}-{mode}.svg")
        with open(path, "w") as fh:
            fh.write(fn(tokens))
        print("wrote", os.path.relpath(path, os.path.dirname(OUT)))
