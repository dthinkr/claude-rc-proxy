#!/usr/bin/python3
"""Rebuild usage patterns from every transcript under ~/.claude/projects.

Answers two questions:
  1. After going quiet for T_idle, how likely is a session to be used again --
     stratified by how much context it was holding at the time?
  2. Backtesting the (T_idle, T_ctx) rule: how often would it fire, how often would
     that have been worthwhile, and what is the net saving?

Terms:
  gap        the interval between two consecutive main-thread turns
  candidate  a moment where gap >= T_idle and the context before it was >= T_ctx,
             i.e. a point where the rule would fire
  hit        a candidate that was followed by further turns (the compaction paid off)

Usage: analyze_sessions.py [T_idle_minutes] [T_ctx]
"""
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone

ROOT = os.path.expanduser("~/.claude/projects")

# 1-hour tier multipliers, expressed in input-token equivalents
CACHE_WRITE_1H = 2.0
CACHE_READ = 0.1
OUTPUT_EQUIV = 5.0   # rough factor converting output tokens to input equivalents


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def ctx_of(usage):
    return (usage.get("input_tokens", 0)
            + usage.get("cache_creation_input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0))


def scan_file(path):
    """Return the main-thread turn sequence and any compaction events."""
    turns = []
    compactions = []       # (ts, pre_ctx, post_ctx)
    pending_compact_ts = None
    last_ctx = 0
    ttl_tiers = defaultdict(int)

    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if o.get("isSidechain") is True:
                continue          # subagent turns are not main-thread context

            msg = o.get("message") or {}

            # compaction boundary: a user message flagged isCompactSummary
            if o.get("type") == "user" and o.get("isCompactSummary"):
                pending_compact_ts = parse_ts(o.get("timestamp"))

            usage = msg.get("usage")
            if not usage:
                continue
            ts = parse_ts(o.get("timestamp"))
            if ts is None:
                continue
            ctx = ctx_of(usage)

            cc = usage.get("cache_creation")
            if isinstance(cc, dict):
                for k, v in cc.items():
                    if v:
                        ttl_tiers[k] += v

            if pending_compact_ts is not None:
                compactions.append((pending_compact_ts, last_ctx, ctx))
                pending_compact_ts = None

            turns.append((ts, ctx))
            last_ctx = ctx

    return turns, compactions, ttl_tiers


def main():
    t_idle_min = float(sys.argv[1]) if len(sys.argv) > 1 else 50.0
    t_ctx = int(sys.argv[2]) if len(sys.argv) > 2 else 250_000

    files = []
    for dirpath, _dirnames, filenames in os.walk(ROOT):
        for fn in filenames:
            if fn.endswith(".jsonl"):
                files.append(os.path.join(dirpath, fn))

    sessions = []
    all_compactions = []
    ttl_total = defaultdict(int)

    for path in files:
        try:
            turns, compactions, tiers = scan_file(path)
        except OSError:
            continue
        if len(turns) < 2:
            continue
        for k, v in tiers.items():
            ttl_total[k] += v
        all_compactions.extend(compactions)
        sessions.append({
            "path": path,
            "project": os.path.basename(os.path.dirname(path)),
            "turns": turns,
        })

    # ---- gap-level statistics ----
    # For each gap: duration, context before it, and whether it is a trailing gap
    # (the session never came back) or an interior one (it did).
    buckets = [(0, 100_000), (100_000, 250_000), (250_000, 500_000), (500_000, 10**9)]
    bucket_names = ["<100k", "100-250k", "250-500k", ">500k"]

    # returned[b]  = quiet periods >= T_idle that were followed by more turns
    # abandoned[b] = sessions whose final turn sits in this bucket (never came back)
    returned = defaultdict(int)
    abandoned = defaultdict(int)
    gap_hours_returned = []

    fires = 0
    hits = 0
    saved = 0.0
    wasted = 0.0

    # Estimate C'/C from real compaction events rather than guessing
    ratios = [post / pre for _ts, pre, post in all_compactions if pre > 1000 and post > 0]
    ratio = sorted(ratios)[len(ratios) // 2] if ratios else 0.12

    now = datetime.now(timezone.utc)

    per_session = []
    for s in sessions:
        turns = s["turns"]
        resurrections = 0
        for i in range(len(turns) - 1):
            ts0, ctx0 = turns[i]
            ts1, _ctx1 = turns[i + 1]
            gap_min = (ts1 - ts0).total_seconds() / 60.0
            if gap_min < t_idle_min:
                continue
            resurrections += 1
            b = next(j for j, (lo, hi) in enumerate(buckets) if lo <= ctx0 < hi)
            returned[b] += 1
            gap_hours_returned.append(gap_min / 60.0)
            # backtest: would the rule fire here?
            if ctx0 >= t_ctx:
                fires += 1
                hits += 1
                cprime = ctx0 * ratio
                do_nothing = CACHE_WRITE_1H * ctx0
                do_compact = (CACHE_READ * ctx0 + 8000 * OUTPUT_EQUIV
                              + CACHE_WRITE_1H * cprime * 2)
                saved += do_nothing - do_compact

        # trailing gap: from the last turn until now
        ts_last, ctx_last = turns[-1]
        idle_min = (now - ts_last).total_seconds() / 60.0
        if idle_min >= t_idle_min:
            b = next(j for j, (lo, hi) in enumerate(buckets) if lo <= ctx_last < hi)
            abandoned[b] += 1
            if ctx_last >= t_ctx:
                fires += 1
                cprime = ctx_last * ratio
                wasted += (CACHE_READ * ctx_last + 8000 * OUTPUT_EQUIV
                           + CACHE_WRITE_1H * cprime)

        per_session.append({
            "project": s["project"],
            "turns": len(turns),
            "resurrections": resurrections,
            "max_ctx": max(c for _t, c in turns),
            "last_ctx": ctx_last,
            "idle_h": idle_min / 60.0,
        })

    print(f"scanned {len(files)} transcripts, {len(sessions)} usable sessions")
    print(f"parameters: T_idle = {t_idle_min:.0f} min, T_ctx = {t_ctx:,}")
    print(f"measured compaction ratio C'/C = {ratio:.3f} (median of {len(ratios)} real compactions)")
    print(f"cache TTL tiers, cumulative: {dict(ttl_total)}")
    print()

    print(f"{'context band':<12} {'came back':>10} {'abandoned':>12} {'rate':>8}")
    for j, name in enumerate(bucket_names):
        r, a = returned[j], abandoned[j]
        tot = r + a
        rate = f"{100.0*r/tot:5.1f}%" if tot else "   n/a"
        print(f"{name:<12} {r:>10} {a:>12} {rate:>8}")
    print()

    if gap_hours_returned:
        g = sorted(gap_hours_returned)
        def pct(p):
            return g[min(len(g) - 1, int(len(g) * p))]
        print(f"quiet time before returning: median {pct(0.5):.1f}h  p75 {pct(0.75):.1f}h  "
              f"p90 {pct(0.9):.1f}h  max {g[-1]:.1f}h")
    print()

    print(f"backtest: {fires} fires, {hits} of them followed by a return")
    if fires:
        print(f"          hit rate {100.0*hits/fires:.1f}%")
    print(f"          saved   {saved/1e6:.1f}M input-token equivalents")
    print(f"          wasted  {wasted/1e6:.1f}M input-token equivalents")
    print(f"          net     {(saved-wasted)/1e6:+.1f}M input-token equivalents")
    print()

    print("sessions revived most often (the best candidates):")
    per_session.sort(key=lambda x: -x["resurrections"])
    print(f"{'project':<44} {'turns':>6} {'revd':>5} {'max ctx':>9} {'now ctx':>9} {'idle h':>7}")
    for s in per_session[:15]:
        print(f"{s['project'][:44]:<44} {s['turns']:>6} {s['resurrections']:>5} "
              f"{s['max_ctx']:>9,} {s['last_ctx']:>9,} {s['idle_h']:>7.1f}")


if __name__ == "__main__":
    main()
