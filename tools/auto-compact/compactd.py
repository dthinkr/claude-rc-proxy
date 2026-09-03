#!/usr/bin/python3
"""Compact idle Claude Code sessions while their prompt cache is still warm.

Rule: fire when idle time is in [T_IDLE_MIN, T_IDLE_MAX) and context >= T_CTX.

The upper bound matters. On a 1-hour cache tier (write 2.0x, read 0.1x):

    do nothing              user pays 2.0 * C when they come back
    compact while cold      the summary itself pays 2.0 * C, and then 2.0 * C' on top

So for the act of resuming, compacting cold costs more than leaving the session alone.
Over a longer horizon it can still pay off -- each later warm turn saves 0.1 * (C - C'),
recovering the extra 2.0 * C' after roughly six more turns -- but an idle session gives no
signal about whether those turns are coming, and compaction also costs conversation
detail. So past the window this daemon declines the bet and does nothing.

Delivery uses the side channel opened by shim/cc-stdin-shim at
/tmp/cc-inject/<pid>.sock. Sessions started before the shim was installed have no port;
they are skipped with a one-time note.

Usage: compactd.py [--dry-run] [--status]
"""
import argparse
import glob
import json
import os
import socket
import sys
import time
from datetime import datetime

# All three thresholds can be overridden, which is how you exercise the whole path
# without waiting an hour.
T_IDLE_MIN = int(os.environ.get("CC_COMPACT_IDLE_MIN", 50 * 60))
T_IDLE_MAX = int(os.environ.get("CC_COMPACT_IDLE_MAX", 58 * 60))
T_CTX = int(os.environ.get("CC_COMPACT_CTX", 450_000))
# Defaults: before 50 min the cache is still hot and the user is likely to return;
#           after 58 min the cache is close enough to expiry that the summary may pay a
#           full cold rebuild; below 450k the saved 2.0*(C-C') does not justify the lost
#           detail. Idle is measured from the last API response, so a long generation eats
#           into the margin -- which is part of why the window stops short of 60 min.

# ── Per-model context ceiling. Runs alongside the idle rule and does not interact ──
# The rule above is a cost saver. Compacting is cheapest while the prompt cache is
# still warm, so it waits for the session to go quiet. This rule is a brake. Once a
# session crosses the model's usable window the upstream rejects the request outright,
# so there is nothing left to optimize and it does not wait for idle. A session being
# used hard never goes idle for 50 minutes, and that is exactly the session that runs
# into a ceiling.
#
# Values are TRIGGER points, not the model's hard limit. Leave headroom for the growth
# between two daemon scans. Matching is by longest prefix, so one entry covers a whole
# family of model ids.
#
# Empty by default, and most people should leave it that way. It only matters if you
# reach models through a gateway, where the ids and the usable windows differ from the
# defaults Claude Code expects. Set it with CC_COMPACT_CEILINGS, a comma separated list
# of prefix=tokens pairs:
#
#     CC_COMPACT_CEILINGS='<model-id-prefix>=400000,<other-prefix>=250000'
#
# Put it in the daemon's launchd plist under EnvironmentVariables, not in your shell,
# or the daemon will not see it.
def _load_ceilings():
    out = {}
    for part in os.environ.get("CC_COMPACT_CEILINGS", "").split(","):
        part = part.strip()
        if not part:
            continue
        prefix, sep, cap = part.partition("=")
        prefix = prefix.strip()
        if not sep or not prefix:
            print(f"compactd: ignoring malformed CC_COMPACT_CEILINGS entry {part!r}",
                  file=sys.stderr)
            continue
        try:
            out[prefix] = int(cap.strip().replace("_", ""))
        except ValueError:
            print(f"compactd: ignoring non-numeric ceiling in {part!r}", file=sys.stderr)
    return out


MODEL_CEILINGS = _load_ceilings()

SESSIONS = os.path.expanduser("~/.claude/sessions")
PROJECTS = os.path.expanduser("~/.claude/projects")
SOCK_DIR = os.environ.get("CC_INJECT_DIR", "/tmp/cc-inject")
# State lives under ~/.local/state/ccw/, one directory per tool, not under
# ~/.claude/, which belongs to Anthropic. CCW_STATE_ROOT is only for tests.
STATE_ROOT = os.environ.get("CCW_STATE_ROOT",
                            os.path.expanduser("~/.local/state/ccw"))
STATE_DIR = os.path.join(STATE_ROOT, "auto-compact")
STATE = os.path.join(STATE_DIR, "state.json")
LOG = os.path.join(STATE_DIR, "compactd.log")
TAIL_BYTES = 512 * 1024


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {msg}"
    print(line)
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def load_state():
    try:
        with open(STATE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(st):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(st, fh, indent=1)
    os.replace(tmp, STATE)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def transcript_for(session_id):
    """Glob by sessionId rather than reimplementing the cwd -> directory-name escaping."""
    hits = glob.glob(os.path.join(PROJECTS, "*", f"{session_id}.jsonl"))
    return max(hits, key=os.path.getmtime) if hits else None


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def read_tail(path):
    """Return (context_tokens, timestamp of the last real API request).

    Idle time must be measured from the last request, not from the file's mtime:
    `queue-operation`, `bridge-session` and `last-prompt` entries touch the transcript
    without any API call, so mtime can say "active" for a session whose cache is old.

    Note this is still the *completion* time of that request. A long generation runs the
    cache clock while producing nothing new to anchor on, so it eats into the margin --
    which is why the window stops well short of the TTL.

    Sidechain entries belong to subagents and do not count toward the main thread.
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            fh.seek(max(0, size - TAIL_BYTES))
            chunk = fh.read()
    except OSError:
        return None, None
    lines = chunk.split(b"\n")
    if size > TAIL_BYTES:
        lines = lines[1:]                      # first line is probably truncated
    for raw in reversed(lines):
        if not raw.strip():
            continue
        try:
            o = json.loads(raw)
        except json.JSONDecodeError:
            continue
        # Between a compaction and the next turn there is no fresh usage record, so the
        # last one still shows the pre-compaction size. Whichever is nearer the tail wins.
        cm = o.get("compactMetadata")
        if cm and cm.get("postTokens") is not None:
            return cm["postTokens"], parse_ts(o.get("timestamp"))
        if o.get("type") != "assistant" or o.get("isSidechain"):
            continue
        u = (o.get("message") or {}).get("usage")
        if not u:
            continue
        ctx = (u.get("input_tokens", 0)
               + u.get("cache_creation_input_tokens", 0)
               + u.get("cache_read_input_tokens", 0))
        return ctx, parse_ts(o.get("timestamp"))
    return None, None


def inject(pid, text):
    path = os.path.join(SOCK_DIR, f"{pid}.sock")
    if not os.path.exists(path):
        return False, "no side channel (shim not active; restart the session)"
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(path)
        s.sendall((text + "\n").encode())
        reply = s.recv(64).decode().strip()
        s.close()
        return reply == "ok", reply or "(no reply)"
    except OSError as exc:
        return False, str(exc)


def scan():
    now = time.time()
    out = []
    for f in glob.glob(os.path.join(SESSIONS, "*.json")):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        pid, sid = d.get("pid"), d.get("sessionId")
        if not pid or not sid or not alive(pid):
            continue
        tp = transcript_for(sid)
        if tp is None:
            continue
        ctx, last_req = read_tail(tp)
        if last_req is None:
            try:
                last_req = os.path.getmtime(tp)     # fall back if timestamps are missing
            except OSError:
                continue
        idle = now - last_req
        out.append({"name": d.get("name") or sid[:8], "pid": pid, "sid": sid,
                    "started": d.get("startedAt", 0), "twins": [], "ctx": ctx,
                    "last_req": last_req,
                    "cwd": d.get("cwd", ""), "transcript": tp, "idle": idle,
                    "sock": os.path.exists(os.path.join(SOCK_DIR, f"{pid}.sock"))})

    # One conversation can be resumed in two windows at once: two live processes sharing
    # a sessionId and a transcript. Sending /compact to both just pays for two summaries
    # of the same thing, so keep one per sessionId -- prefer the one with a port, then
    # the most recently started.
    best = {}
    for r in out:
        cur = best.get(r["sid"])
        if cur is None or (r["sock"], r["started"]) > (cur["sock"], cur["started"]):
            best[r["sid"]] = r
    for r in out:
        if best[r["sid"]] is not r:
            best[r["sid"]]["twins"].append(r["name"])
    return list(best.values())


def ceiling_for(model):
    """Usable ceiling for this model id, or None if no entry covers it.

    Longest prefix wins rather than exact equality. Gateway model ids carry suffixes,
    so an exact match would let a whole family slip past its ceiling unnoticed.
    """
    if not model:
        return None
    hit = None
    for name, cap in MODEL_CEILINGS.items():
        if model.startswith(name) and (hit is None or len(name) > len(hit[0])):
            hit = (name, cap)
    return hit[1] if hit else None


def at_ceiling(ctx, model):
    cap = ceiling_for(model)
    return cap is not None and ctx is not None and ctx >= cap


def model_for(path):
    """Model id on the last assistant record in the tail, or None if unreadable.

    This scans the tail again instead of having read_tail return one more value, so
    the existing idle rule's code is left untouched. The extra read comes out of the
    page cache and happens once every two minutes, so the cost is negligible.
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            fh.seek(max(0, size - TAIL_BYTES))
            chunk = fh.read()
    except OSError:
        return None
    lines = chunk.split(b"\n")
    if size > TAIL_BYTES:
        lines = lines[1:]                      # first line is probably truncated
    for raw in reversed(lines):
        if not raw.strip():
            continue
        try:
            o = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if o.get("type") != "assistant" or o.get("isSidechain"):
            continue
        m = (o.get("message") or {}).get("model")
        if m:
            return m
    return None


def run_ceilings(st, rows, dry):
    """Ceiling rule: compact once the session reaches the model's usable window,
    regardless of idle time.

    Shares ent["armed"] with the idle rule. Firing sets it False, and the idle rule
    sets it True again once context drops back under T_CTX. That is what stops both
    rules sending /compact to the same session in one pass: this loop runs after that
    one, so any session it just fired on already reads as armed=False here.
    """
    fired = 0
    for r in rows:
        ctx = r["ctx"]
        if ctx is None:
            continue
        ent = st.setdefault(r["sid"], {"armed": True})
        if not isinstance(ent, dict) or not ent.get("armed", True):
            continue
        model = model_for(r["transcript"])
        if not at_ceiling(ctx, model):
            continue
        if not r["sock"]:
            continue          # the idle rule already warned about a missing shim
        cap = ceiling_for(model)
        if dry:
            log(f"[dry-run] would compact {r['name']}  ceiling {cap:,} ({model})  "
                f"context {ctx:,}")
            fired += 1
            continue
        ok, detail = inject(r["pid"], "/compact")
        if ok:
            ent.update(armed=False, last_fired=time.time(), last_ctx=ctx,
                       ceiling_fired_at=time.time())
            log(f"compacted {r['name']}  ceiling {cap:,} ({model})  context {ctx:,}"
                f"  (past the model's usable window, not a cache bet)")
            fired += 1
        else:
            # This retries every 2 minutes, so throttle the failure log or it floods.
            if time.time() - ent.get("ceiling_fail_logged_at", 0) > 1800:
                log(f"ceiling injection failed for {r['name']}: {detail}")
                ent["ceiling_fail_logged_at"] = time.time()
    return fired


def cmd_status():
    rows = scan()
    st = load_state()
    meta = st.get("_meta") or {}
    if meta.get("last_run"):
        age = time.time() - meta["last_run"]
        stale = "   <- over 5 min ago, check launchctl" if age > 300 else ""
        print(f"daemon last ran {age/60:.1f} min ago "
              f"(idle {T_IDLE_MIN//60}-{T_IDLE_MAX//60} min / context {T_CTX:,}){stale}")
    else:
        print("daemon has not run yet -- launchctl list | grep ccw.auto-compact")
    print(f"{'session':<26}{'idle':>8}{'context':>12}  port  verdict")
    for r in sorted(rows, key=lambda x: -x["idle"]):
        ctx = r["ctx"]
        ent = st.get(r["sid"], {})
        if not r["sock"]:
            note = "no shim (restart this session)"
        elif ctx is None:
            note = "no usage record found"
        elif ctx < T_CTX:
            note = "context below threshold"
        elif r["idle"] < T_IDLE_MIN:
            note = f"too early by {(T_IDLE_MIN-r['idle'])/60:.0f} min"
        elif r["idle"] >= T_IDLE_MAX:
            note = "window missed (compacting cold costs more)"
        elif not ent.get("armed", True):
            note = "already compacted, waiting for context to grow"
        else:
            note = ">>> due"
        if r["twins"]:
            note += f"   [same conversation also open as {', '.join(r['twins'])}; only this one is sent to]"
        print(f"{r['name']:<26}{r['idle']/60:>7.0f}m{(ctx or 0):>12,}"
              f"{'   yes' if r['sock'] else '    no'}  {note}")

    # View for the ceiling rule. Listed separately; the table above is unchanged.
    if not MODEL_CEILINGS:
        print("\nceilings: none configured (set CC_COMPACT_CEILINGS to enable)")
        return
    caps = ", ".join(f"{m}* {c//1000}k" for m, c in sorted(MODEL_CEILINGS.items()))
    print(f"\nceilings (fire regardless of idle): {caps}")
    for r in sorted(rows, key=lambda x: -(x["ctx"] or 0)):
        model = model_for(r["transcript"])
        cap = ceiling_for(model)
        if cap is None:
            continue
        left = cap - (r["ctx"] or 0)
        verdict = ">>> due" if left <= 0 else f"{left:,} to go"
        print(f"  {r['name']:<24}{model:<16}{(r['ctx'] or 0):>10,}  {verdict}")


def cmd_run(dry):
    st = load_state()
    rows = scan()
    live = {r["sid"] for r in rows}
    for sid in list(st):
        if sid != "_meta" and sid not in live:
            del st[sid]

    fired = 0
    for r in rows:
        ctx = r["ctx"]
        if ctx is None:
            continue
        ent = st.setdefault(r["sid"], {"armed": True})
        if not isinstance(ent, dict):
            ent = st[r["sid"]] = {"armed": True}

        if ctx < T_CTX:
            ent["armed"] = True                # dropped back down, re-arm
            continue
        if not T_IDLE_MIN <= r["idle"] < T_IDLE_MAX:
            continue
        if not ent.get("armed", True):
            continue
        if not r["sock"]:
            if not ent.get("warned_no_sock"):
                log(f"skipping {r['name']}: no side channel -- this session predates the "
                    f"shim; restart it to enable")
                ent["warned_no_sock"] = True
            continue

        # Re-check immediately before sending, in case the user just came back.
        _ctx, fresh = read_tail(r["transcript"])
        if fresh is not None and time.time() - fresh < T_IDLE_MIN:
            log(f"skipping {r['name']}: activity detected just before sending")
            continue

        if dry:
            log(f"[dry-run] would compact {r['name']}  idle {r['idle']/60:.0f}m  "
                f"context {ctx:,}")
            fired += 1
            continue

        ok, detail = inject(r["pid"], "/compact")
        if ok:
            ent.update(armed=False, last_fired=time.time(), last_ctx=ctx)
            log(f"compacted {r['name']}  idle {r['idle']/60:.0f}m  context {ctx:,}"
                f"  (saves roughly {int(ctx*0.8*2.0):,} input-token equivalents)")
            fired += 1
        else:
            log(f"injection failed for {r['name']}: {detail}")

    fired += run_ceilings(st, rows, dry)

    # Heartbeat. The daemon is silent when it has nothing to do, so without this there is
    # no way to tell "running, nothing due" from "not running".
    st["_meta"] = {"last_run": time.time(), "last_fired_count": fired,
                   "thresholds": [T_IDLE_MIN, T_IDLE_MAX, T_CTX]}
    save_state(st)
    return fired


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="decide and log, send nothing")
    ap.add_argument("--status", action="store_true", help="show the verdict for every session")
    a = ap.parse_args()
    if a.status:
        cmd_status()
        return 0
    cmd_run(a.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
