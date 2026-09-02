#!/usr/bin/env python3
"""Render the README's two charts as light/dark SVG pairs.

The numbers are the output of the measurement described in README.md § What the
numbers say — a per-turn replay of 1,179 local Claude Code sessions (302,213
assistant turns, 30 days). Re-derive them with analyze_sessions.py; this file
only draws.

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

# idle gap bucket, count, mean cold-rebuild tokens on the resuming turn
GAPS = [
    ("5–30m", 3452, 29565, False), ("30–50m", 454, 68263, False),
    ("50–60m", 130, 84459, False), ("1–2h", 312, 329684, True),
    ("2–6h", 341, 328284, True), ("6–24h", 282, 313560, True),
    (">24h", 132, 243000, True),
]

THEMES = {
    "light": dict(ink="#1F2328", ink2="#4A5560", muted="#6E7781",
                  grid="#DCE3E8", rule="#B9C4CC",
                  read="#1E7EA8", write="#D2691E", face="#FFFFFF"),
    "dark":  dict(ink="#E6EDF3", ink2="#B3C0CB", muted="#8B98A4",
                  grid="#2A333B", rule="#3D4A54",
                  read="#3E97BD", write="#D2762F", face="#0D1117"),
}
FONT = "ui-monospace,SFMono-Regular,Menlo,monospace"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, fill, size=11, anchor="middle", weight="400"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" fill="{fill}" '
            f'font-size="{size}" font-weight="{weight}" font-family="{FONT}">{esc(s)}</text>')


def savings_chart(t):
    W, H = 760, 400
    PL, PRr = 56, 30
    # panel 1: curve
    T1, B1 = 26, 232
    # panel 2: counts
    T2, B2 = 268, 356
    lo, hi = math.log10(50), math.log10(1000)
    xs = lambda k: PL + (hi - math.log10(k)) / (hi - lo) * (W - PL - PRr)
    ys = lambda p: T1 + (1 - p / 75.0) * (B1 - T1)
    nmax = 280
    yn = lambda n: B2 - (n / nmax) * (B2 - T2)

    g = []
    g.append(text(PL, 14, "share of the bill compaction removes", t["ink"], 12, "start", "600"))
    for v in (0, 20, 40, 60):
        g.append(f'<line x1="{PL}" y1="{ys(v):.1f}" x2="{W-PRr}" y2="{ys(v):.1f}" '
                 f'stroke="{t["grid"]}" stroke-width="1"/>')
        g.append(text(PL - 8, ys(v) + 4, f"{v}%", t["muted"], 11, "end"))

    # reference lines
    for k, lab in ((450, "450k default"), (300, "300k current")):
        pt = next(c for c in CURVE if c[0] == k)
        g.append(f'<line x1="{xs(k):.1f}" y1="{T1}" x2="{xs(k):.1f}" y2="{B1}" '
                 f'stroke="{t["rule"]}" stroke-width="1" stroke-dasharray="3 3"/>')
        g.append(text(xs(k), T1 + 12, f"{lab} · {pt[1]}%", t["ink2"], 10.5))

    pts = [(xs(k), ys(p)) for k, p, _ in CURVE]
    d = " ".join(("M" if i == 0 else "L") + f"{x:.1f} {y:.1f}" for i, (x, y) in enumerate(pts))
    g.append(f'<path d="{d} L {pts[-1][0]:.1f} {ys(0):.1f} L {pts[0][0]:.1f} {ys(0):.1f} Z" '
             f'fill="{t["read"]}" fill-opacity="0.11"/>')
    g.append(f'<path d="{d}" fill="none" stroke="{t["read"]}" stroke-width="2" stroke-linejoin="round"/>')
    for k, p, _ in CURVE:
        r = 4.6 if k in (450, 300, 200) else 3
        g.append(f'<circle cx="{xs(k):.1f}" cy="{ys(p):.1f}" r="{r}" fill="{t["read"]}" '
                 f'stroke="{t["face"]}" stroke-width="1.8"/>')
    p200 = next(c for c in CURVE if c[0] == 200)
    g.append(text(xs(200) + 9, ys(p200[1]) - 6, f"200k · {p200[1]}%", t["ink"], 11, "start", "600"))
    g.append(text(xs(800), ys(44.1) + 20, "one compaction here is worth $1,620",
                  t["ink2"], 10.5, "start"))

    # panel 2
    g.append(text(PL, T2 - 12, "compactions fired in the same 30 days", t["ink"], 12, "start", "600"))
    g.append(f'<line x1="{PL}" y1="{B2}" x2="{W-PRr}" y2="{B2}" stroke="{t["rule"]}" stroke-width="1"/>')
    for v in (100, 200):
        g.append(f'<line x1="{PL}" y1="{yn(v):.1f}" x2="{W-PRr}" y2="{yn(v):.1f}" '
                 f'stroke="{t["grid"]}" stroke-width="1"/>')
        g.append(text(PL - 8, yn(v) + 4, str(v), t["muted"], 11, "end"))
    for k, _, n in CURVE:
        if not n:
            continue
        g.append(f'<rect x="{xs(k)-4:.1f}" y="{yn(n):.1f}" width="8" height="{B2-yn(n):.1f}" '
                 f'rx="2" fill="{t["write"]}"/>')
    for k in (1000, 500, 300, 200, 100, 50):
        anchor = "start" if k == 1000 else ("end" if k == 50 else "middle")
        dx = -4 if k == 1000 else (4 if k == 50 else 0)
        g.append(text(xs(k) + dx, B2 + 18, f"{k}k", t["muted"], 11, anchor))
    g.append(text((PL + W - PRr) / 2, H - 8, "compaction threshold — context size that arms the daemon",
                  t["muted"], 11))

    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
            f'role="img" aria-label="Savings saturate below a 300k threshold while compaction '
            f'frequency keeps climbing">{"".join(g)}</svg>')


def gaps_chart(t):
    W, H = 760, 300
    PL, PRr, T, B = 56, 26, 40, 226
    n = len(GAPS)
    slot = (W - PL - PRr) / n
    nmax = max(g[1] for g in GAPS)
    ys = lambda v: B - (v / nmax) * (B - T)

    g = []
    g.append(text(PL, 16, "5,103 idle gaps between consecutive turns, 1,179 sessions",
                  t["ink"], 12, "start", "600"))
    g.append(text(PL, 32, "orange = cache has certainly expired; the resuming turn pays a full cold rebuild",
                  t["muted"], 10.5, "start"))
    g.append(f'<line x1="{PL}" y1="{B}" x2="{W-PRr}" y2="{B}" stroke="{t["rule"]}" stroke-width="1"/>')

    for i, (lab, cnt, cold, expired) in enumerate(GAPS):
        x = PL + i * slot + slot * 0.5
        w = slot * 0.56
        col = t["write"] if expired else t["read"]
        g.append(f'<rect x="{x-w/2:.1f}" y="{ys(cnt):.1f}" width="{w:.1f}" '
                 f'height="{B-ys(cnt):.1f}" rx="3" fill="{col}"/>')
        g.append(text(x, ys(cnt) - 7, f"{cnt:,}", t["ink2"], 10.5))
        g.append(text(x, B + 17, lab, t["ink2"], 11))
        g.append(text(x, B + 32, f"{cold/1000:.0f}k cold", t["muted"], 10))

    # firing window marker sits on the 50-60m bucket
    xw = PL + 2 * slot + slot * 0.5
    g.append(f'<line x1="{xw:.1f}" y1="{T-6}" x2="{xw:.1f}" y2="{B}" stroke="{t["rule"]}" '
             f'stroke-width="1" stroke-dasharray="3 3"/>')
    g.append(text(xw, T - 12, "daemon fires here", t["ink"], 10.5, "middle", "600"))
    g.append(text((PL + W - PRr) / 2, H - 8,
                  "idle gap length — bar height is how many gaps, label below is the mean cold rebuild on resume",
                  t["muted"], 10.5))

    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
            f'role="img" aria-label="One in five idle gaps outlives the cache and pays a cold '
            f'rebuild of about 320k tokens">{"".join(g)}</svg>')


for name, fn in (("savings-curve", savings_chart), ("idle-gaps", gaps_chart)):
    for mode, tokens in THEMES.items():
        path = os.path.join(OUT, f"{name}-{mode}.svg")
        with open(path, "w") as fh:
            fh.write(fn(tokens))
        print("wrote", os.path.relpath(path, os.path.dirname(OUT)))
