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

SESSIONS = os.path.expanduser("~/.claude/sessions")
PROJECTS = os.path.expanduser("~/.claude/projects")
SOCK_DIR = os.environ.get("CC_INJECT_DIR", "/tmp/cc-inject")
STATE_DIR = os.path.expanduser("~/.local/state/claude-auto-compact")
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
        print("daemon has not run yet -- launchctl list | grep claude-auto-compact")
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
