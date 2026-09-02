#!/usr/bin/env python3
"""Counterfactual replay: what would a different compaction threshold have cost?

`analyze_sessions.py` answers "would this candidate have been worth compacting"
one event at a time. That undercounts, because compacting does not only avoid one
cold rebuild -- it shrinks the context that *every later turn* reads, and that term
accrues per turn for the rest of the session.

This script measures the whole thing instead of estimating it. For each threshold
it replays every session turn by turn:

  * carry an offset -- how much context has been compacted away so far
  * at an idle gap >= IDLE_MIN, if the offset-adjusted context is >= the threshold,
    compact: pay one warm read plus the summary output, then grow the offset by
    (1 - RATIO) x context
  * bill every turn at its real recorded token counts, scaled by how much smaller
    the context now is

The baseline is the same replay with compaction switched off, which reproduces the
real recorded spend. The difference is what the threshold was worth.

    python3 replay.py                      # sweep the default ladder
    python3 replay.py 300000 200000        # only these thresholds
    python3 replay.py --days 60 --json     # wider window, machine-readable

Known biases, all small and all in the same direction (they make compaction look
slightly better than it is):

  1. A compaction only fires at a window the session actually resumed from, so
     compactions wasted on sessions that never came back are not billed. Measured
     at ~0.1% of the total at a 300k threshold.
  2. The summary is modelled at a flat RATIO of the context rather than per-session.
  3. If the daemon was already running during the window, the baseline is not a
     clean no-compaction counterfactual.
"""
import argparse
import json
import os
import sys
import time

ROOT = os.path.expanduser("~/.claude/projects")

# model -> (input $/Mtok, output $/Mtok, cache-read $/Mtok). Cache writes are billed
# at the 1-hour tier: 2x input. Models absent here are free or gateway-routed and
# are skipped entirely rather than guessed at.
PRICES = {
    "claude-fable-5":            (10.0, 50.0, 1.00),
    "claude-fable-5-1":          (10.0, 50.0, 0.25),
    "claude-opus-5":             (5.0,  25.0, 0.50),
    "claude-opus-4-8":           (5.0,  25.0, 0.50),
    "claude-opus-4-7":           (5.0,  25.0, 0.50),
    "claude-opus-4-6":           (5.0,  25.0, 0.50),
    "claude-sonnet-5":           (2.0,  10.0, 0.20),
    "claude-sonnet-4-6":         (3.0,  15.0, 0.30),
    "claude-haiku-4-5-20251001": (1.0,   5.0, 0.10),
}

RATIO = 0.203      # measured C'/C across 142 real compactions
SUMMARY_OUT = 4000  # tokens the summary itself costs to write
FLOOR = 25_000      # system prompt + tools; context never replays below this
IDLE_MIN = 3000     # 50 minutes, matching compactd's lower bound

LADDER = [1_000_000, 800_000, 700_000, 600_000, 500_000, 450_000, 400_000,
          350_000, 300_000, 250_000, 200_000, 175_000, 150_000, 125_000,
          100_000, 75_000, 50_000]


def load(days):
    """Main-thread turns per session: [(epoch, read, write, uncached, out, model)]."""
    cutoff = time.time() - days * 86400
    sessions = {}
    for dirpath, _, names in os.walk(ROOT):
        if os.path.basename(dirpath) == "subagents":
            continue
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.path.getmtime(path) < cutoff:
                    continue
            except OSError:
                continue
            turns = []
            try:
                with open(path, errors="replace") as fh:
                    for line in fh:
                        if '"usage"' not in line:
                            continue
                        try:
                            rec = json.loads(line)
                        except ValueError:
                            continue
                        msg = rec.get("message") or {}
                        usage = msg.get("usage")
                        if not isinstance(usage, dict):
                            continue
                        model = msg.get("model") or ""
                        if not model or model == "<synthetic>":
                            continue
                        stamp = rec.get("timestamp") or ""
                        try:
                            when = time.mktime(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))
                        except ValueError:
                            when = 0.0
                        turns.append((
                            when,
                            usage.get("cache_read_input_tokens") or 0,
                            usage.get("cache_creation_input_tokens") or 0,
                            usage.get("input_tokens") or 0,
                            usage.get("output_tokens") or 0,
                            model,
                        ))
            except OSError:
                continue
            if turns:
                turns.sort()
                sessions[path] = turns
    return sessions


def replay(sessions, threshold):
    """Total cost in dollars, plus how many compactions that threshold fired."""
    total = 0.0
    fired = 0
    for turns in sessions.values():
        offset = 0.0
        for i, (when, read, write, uncached, out, model) in enumerate(turns):
            price = PRICES.get(model)
            if price is None:
                continue
            p_in, p_out, p_read = price
            if threshold is not None and i > 0:
                gap = when - turns[i - 1][0]
                prev = turns[i - 1]
                prev_ctx = max(prev[1] + prev[2] + prev[3] - offset, FLOOR)
                if gap >= IDLE_MIN and prev_ctx >= threshold:
                    total += prev_ctx * p_read / 1e6 + SUMMARY_OUT * p_out / 1e6
                    offset += (1 - RATIO) * prev_ctx
                    fired += 1
            ctx = read + write + uncached
            scale = 1.0 if ctx <= 0 else max(FLOOR, ctx - offset) / ctx
            total += (read * p_read + write * 2 * p_in + uncached * p_in) * scale / 1e6
            total += out * p_out / 1e6
    return total, fired


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("thresholds", nargs="*", type=int,
                    help="context thresholds to test (default: a 1M -> 50k ladder)")
    ap.add_argument("--days", type=int, default=30, help="how far back to read (default 30)")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = ap.parse_args()

    sessions = load(args.days)
    turns = sum(len(v) for v in sessions.values())
    if not turns:
        sys.exit(f"no transcripts with usage data under {ROOT} in the last {args.days} days")

    base, _ = replay(sessions, None)
    rows = []
    prev_cost, prev_fired = base, 0
    for thr in (args.thresholds or LADDER):
        cost, fired = replay(sessions, thr)
        delta_n = fired - prev_fired
        rows.append(dict(
            threshold=thr, fired=fired, cost=round(cost, 2),
            saved=round(base - cost, 2),
            pct=round((base - cost) / base * 100, 1) if base else 0.0,
            marginal=round(prev_cost - cost, 2),
            per_compaction=round((prev_cost - cost) / delta_n, 1) if delta_n > 0 else None,
        ))
        prev_cost, prev_fired = cost, fired

    if args.json:
        print(json.dumps(dict(sessions=len(sessions), turns=turns,
                              days=args.days, baseline=round(base, 2), rows=rows), indent=2))
        return

    print(f"{len(sessions):,} sessions · {turns:,} turns · last {args.days} days")
    print(f"baseline, no compaction: ${base:,.0f}\n")
    print(f"{'threshold':>10}{'fired':>8}{'cost':>12}{'saved':>12}{'share':>8}"
          f"{'marginal':>11}{'per compaction':>16}")
    for r in rows:
        per = f"${r['per_compaction']:,.0f}" if r["per_compaction"] is not None else "—"
        print(f"{r['threshold']//1000:>9}k{r['fired']:>8}{r['cost']:>12,.0f}"
              f"{r['saved']:>12,.0f}{r['pct']:>7.1f}%{r['marginal']:>+11,.0f}{per:>16}")


if __name__ == "__main__":
    main()
