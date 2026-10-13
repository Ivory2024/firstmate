#!/usr/bin/env python3
# fm-crew-dashboard.py - READ-ONLY localhost dashboard for live firstmate crews.
# Horizontal layout (crews side by side); each lane carries its own accent colour,
# and the harness (codex / opencode / ...) is shown as a distinct coloured badge so
# two lanes on different tools never look the same. Terminal views: `--crews` lists
# live crews, `--tasks` lists open backlog tasks grouped per rail/section.
# Observes existing crew panes/state only; never writes operational state,
# never restarts a crew, never touches daemon/queue/lock/launchd/canonical.
#
# Liveness. A lane is one `state/<id>.meta` record, and a meta record outlives
# the session it describes: a torn-down or exited crew leaves its meta behind.
# So a lane's `state` word is not its liveness, and counting meta files as open
# sessions overstates the fleet. Every lane therefore carries:
#   liveness        live | dead | unknown
#   liveness_reason why that verdict was reached
#   endpoint        the backend classifier's own read of the recorded target
#                   (alive / dead / missing / unreadable, "" when none is
#                   recorded) from bin/fm-backend.sh's fm_backend_agent_state
# `dead` means dead-or-gone: positive evidence that the recorded session is no
# longer there. The endpoint read is definitive when it answers, because a
# run-step state outlives a closed pane - a finished crew keeps reporting `done`
# after its endpoint is gone. When the endpoint cannot be read, the lane falls
# back to the death evidence fm-crew-state.sh itself words ("backend target
# gone", "worktree gone", ...) and otherwise reports `unknown`; a lane is never
# promoted to `live` on absence of evidence. Dead lanes stay in the response so
# an operator still sees that the task exists with its session gone.
#
# Freshness. snap() is expensive (one fm-crew-state.sh, one pane read, and one
# git read per lane), so it is cached in-process with a TTL and single-flight
# de-duplication: concurrent misses collapse onto the one refresh already
# running instead of each paying the full cost, and there is deliberately no
# background worker. Every response says how fresh it is, in headers that do
# not change the JSON schema:
#   X-Snap-Status      fresh | stale | error
#   X-Snap-Age         seconds since the served lanes were computed (-1 = none)
#   X-Snap-Computed-At epoch the served lanes were computed
#   X-Snap-Refreshing  whether a refresh is running right now
#   X-Snap-Ttl         the configured cache TTL
#   X-Snap-Error       the last refresh failure, when there was one
# `stale` means the response was served from a snapshot older than the TTL
# because a refresh was already running; `error` means the last refresh failed
# and the served lanes are the last good ones (never presented as current).
#
# Queue board. `/board` adds the three things the backlog markdown alone cannot
# answer: what is queued, what is held for the captain, and what is blocked
# waiting on another task. `fm-tasks-axi.sh list` owns those answers, but each
# call spawns the CLI, so the triple read goes through its own TTL cache with
# the same freshness contract as the lanes, reported in X-Queue-* headers.
# The board is READ-ONLY: it lists what the queue already says and never
# transitions, adds, or holds a task.
import glob, http.server, json, os, re, socketserver, subprocess, threading, time
from pathlib import Path

FM = os.environ.get("FM_HOME") or str(Path(__file__).resolve().parent.parent)
STATE = f"{FM}/state"
BACKLOG = f"{FM}/data/backlog.md"
# The port seam exists so a second instance can be raised for verification
# without touching the one an operator is already reading.
PORT = int(os.environ.get("FM_DASHBOARD_PORT") or 8770)


def titles():
    """task id -> assigned task name from the backlog ("<id> - <title> (repo: ...)")."""
    out = {}
    try:
        for line in open(BACKLOG, errors="ignore"):
            m = re.match(r"^-\s+\[[ x]\]\s+(\S+)\s+-\s+(.*?)\s+\(repo:", line)
            if m:
                out[m.group(1)] = m.group(2).strip()
    except OSError:
        pass
    return out


OPEN_ITEM = re.compile(r"^-\s+\[ \]\s+(\S+)\s+-\s+(.*)$")
_META_STRIP = re.compile(r"\s*\((?:repo|kind|priority|since|blocked-by):[^)]*\)")


def _meta_val(rest, key):
    m = re.search(r"\(" + re.escape(key) + r":\s*([^)]*)\)", rest)
    return m.group(1).strip() if m else ""


def backlog_tasks():
    """Open (not-done) backlog items: id, title, repo, kind, priority, section."""
    out = []
    section = ""
    try:
        for line in open(BACKLOG, errors="ignore"):
            h = re.match(r"^##\s+(.*?)\s*$", line)
            if h:
                section = h.group(1)
                continue
            if section == "Done":
                continue
            m = OPEN_ITEM.match(line)
            if not m:
                continue
            tid, rest = m.group(1), m.group(2).strip()
            title = _META_STRIP.sub("", rest).strip()
            out.append(dict(id=tid, title=title or rest, repo=_meta_val(rest, "repo"),
                            kind=_meta_val(rest, "kind"), priority=_meta_val(rest, "priority"),
                            section=section))
    except OSError:
        pass
    return out


# --- backlog queue board ----------------------------------------------------
#
# The queue read is one `fm-tasks-axi.sh list` per section. Its output is TOON:
# a `count: N[ of M total]` line, then `tasks[N]{field,field,...}:`, then one
# indented line per row. A value that would be ambiguous is double-quoted, and
# the CLI writes a truncated value as an inline `\n...` marker on the same
# line, so one row is always one line.
_TASKS_HEADER = re.compile(r"^tasks\[(\d+)\]\{([^}]*)\}:\s*$")
_LIST_COUNT = re.compile(r"^count:\s*(\d+)(?:\s+of\s+(\d+)\s+total)?\s*$")


def _toon_fields(body):
    """One TOON row's values, honoring double-quoted fields and \\" escapes."""
    fields, buf, quoted, i = [], [], False, 0
    while i < len(body):
        ch = body[i]
        if quoted:
            if ch == "\\" and body[i + 1:i + 2] == '"':
                buf.append('"')
                i += 2
                continue
            if ch == '"':
                quoted = False
            else:
                buf.append(ch)
        elif ch == '"':
            quoted = True
        elif ch == ",":
            fields.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    fields.append("".join(buf))
    return fields


def parse_task_list(text):
    """(rows, total) from one `tasks-axi list` TOON body.

    `rows` are dicts keyed by the header's own field names, in the order the CLI
    printed them. `total` is the CLI's own match count when it reports
    "count: N of M total" (its row cap can hide the rest), else the row count.
    """
    rows, total, fields, want = [], None, [], 0
    for line in (text or "").splitlines():
        m = _LIST_COUNT.match(line)
        if m:
            total = int(m.group(2) or m.group(1))
            continue
        header = _TASKS_HEADER.match(line)
        if header:
            want = int(header.group(1))
            fields = [f.strip() for f in header.group(2).split(",") if f.strip()]
            continue
        if not fields or len(rows) >= want or not line.startswith("  ") or not line.strip():
            continue
        vals = _toon_fields(line[2:])
        vals += [""] * (len(fields) - len(vals))
        rows.append(dict(zip(fields, vals)))
    return rows, (total if total is not None else len(rows))


# Seconds a backlog read stays fresh. Each refresh spawns three CLI processes,
# so the page's own 5s poll must not be what triggers them: at this TTL at most
# one refresh happens per interval, or per interval plus one refresh's duration,
# since the TTL is measured from the last finished read.
QUEUE_TTL = 15.0
QUEUE_LIMIT = 100   # tasks-axi's own row cap; a larger --limit returns the same
QUEUE_SHOWN = 30    # rows rendered per section; the rest is reported as a count

# The CLI appends this trailer to a value too long for its row, as one inline
# `\n...` run rather than a real newline. A glance panel shows the value's own
# prefix and a cut mark instead of that sentence, and `show <id>` still has the
# complete text.
_TRUNCATED = re.compile(r"\\n\.\.\. \(truncated, \d+ chars total[^)]*\)\s*$")


def _clean(value):
    """One field's display value: the CLI's truncation trailer becomes a cut mark."""
    return _TRUNCATED.sub("\u2026", value or "").strip()


_QUEUE_LOCK = threading.Condition()
_QUEUE = {"board": None, "ok": False, "error": "", "computed_at": 0.0,
          "checked_at": 0.0, "refreshing": False}


def tasks_axi_list(args, timeout=30):
    """(rows, total) from `fm-tasks-axi.sh list <args>`. Raises on a refusal."""
    done = subprocess.run([f"{FM}/bin/fm-tasks-axi.sh", "list", *args], cwd=FM,
                          capture_output=True, text=True, timeout=timeout)
    if done.returncode != 0:
        why = (done.stderr or done.stdout or "list failed").strip().splitlines()
        raise RuntimeError((why[0] if why else "list failed")[:200])
    return parse_task_list(done.stdout)


def _section(rows, total, *fields):
    """One board section: the first QUEUE_SHOWN rows plus honest counts."""
    items = [{k: _clean(row.get(k)) for k in fields} for row in rows]
    return {"items": items[:QUEUE_SHOWN], "count": len(items),
            "total": max(total, len(items)), "capped": total > len(rows)}


def _queue_board():
    """The board's three sections, each read straight from the queue.

    `queued` excludes the rows the CLI marks held or blocked, because those are
    the board's own other two sections and would otherwise be counted twice.
    """
    queued, queued_total = tasks_axi_list(
        ["--state", "queued", "--limit", str(QUEUE_LIMIT),
         "--fields", "priority,held,blocked,blocked_by"])
    blocked, blocked_total = tasks_axi_list(
        ["--limit", str(QUEUE_LIMIT), "--blocked", "--fields", "priority,blocked_by"])
    held, held_total = tasks_axi_list(
        ["--state", "held", "--limit", str(QUEUE_LIMIT),
         "--fields", "priority,hold_reason,hold_until"])
    # ponytail: the three reads run serially, ~4s cold on a 100-row queue and
    # ~2ms while the TTL holds. Overlap them in a thread pool if the board ever
    # needs to be fresher than its own TTL.

    def yes(value):
        return (value or "").strip().lower() == "yes"

    blocked_ids = {row.get("id") for row in blocked}
    waiting = [row for row in queued
               if not yes(row.get("held")) and not yes(row.get("blocked"))
               and row.get("id") not in blocked_ids]
    sections = {
        "queued": _section(waiting, queued_total, "id", "title", "repo", "priority"),
        "blocked": _section(blocked, blocked_total, "id", "title", "repo", "priority", "blocked_by"),
        "held": _section(held, held_total, "id", "title", "repo", "priority", "hold_reason", "hold_until"),
    }
    sections["counts"] = {name: sections[name]["count"]
                          for name in ("queued", "blocked", "held")}
    return sections


# Distinct accent per lane, assigned by stable sorted index.
LANE_PALETTE = ["#58a6ff", "#3fb950", "#e3b341", "#bc8cff", "#2dd4bf", "#f778ba", "#ff7b72", "#79c0ff"]

# Harness identity: its own colour + short label, independent of the lane accent.
HARNESS = {
    "codex":    {"label": "CODEX",    "color": "#a371f7"},
    "opencode": {"label": "OPENCODE", "color": "#2dd4bf"},
    "claude":   {"label": "CLAUDE",   "color": "#f0883e"},
    "gemini":   {"label": "GEMINI",   "color": "#58a6ff"},
    "pi":       {"label": "PI",       "color": "#3fb950"},
    "pi-signed": {"label": "PI-SIGNED", "color": "#3fb950"},
    "grok":     {"label": "GROK",     "color": "#db61a2"},
    "kimi":     {"label": "KIMI",     "color": "#d29922"},
    "cursor":   {"label": "CURSOR",   "color": "#e3b341"},
    "muse":     {"label": "MUSE",     "color": "#bc8cff"},
    "agy":      {"label": "AGY",      "color": "#58a6ff"},
    "omp":      {"label": "OMP",      "color": "#8b949e"},
}

LIVE, DEAD, UNKNOWN = "live", "dead", "unknown"

# fm-crew-state.sh's canonical line, e.g.
#   "state: unknown · source: none · backend target gone: default:w1:p1K"
# SEP is U+00B7 MIDDLE DOT with a space on each side (bin/fm-crew-state.sh).
_SEP = "\u00b7"
_STATE_LINE = re.compile(
    r"^state:\s*(?P<state>[^" + _SEP + r"]*?)"
    r"(?:\s*" + _SEP + r"\s*source:\s*(?P<source>[^" + _SEP + r"]*?))?"
    r"(?:\s*" + _SEP + r"\s*(?P<detail>.*))?$"
)

# Positive evidence that the recorded session is gone, as fm-crew-state.sh
# itself words it. A detail that merely says "unknown" is not death evidence.
DEATH_DETAILS = (
    "backend target gone",
    "worktree gone",
    "no backend target recorded",
    "no metadata for",
)

# States that mean an agent is doing something or waiting on something. `done`
# and `failed` are terminal, and a finished crew can still hold an open pane, so
# a terminal state word is not by itself proof the session is there.
ACTIVE_STATES = ("working", "parked", "blocked", "paused")


def liveness_from_state_line(line):
    """(liveness, reason) from one fm-crew-state.sh line, without a probe."""
    m = _STATE_LINE.match(line or "")
    if not m:
        return UNKNOWN, "no state line"
    state = (m.group("state") or "").strip().lower()
    source = (m.group("source") or "").strip().lower()
    detail = (m.group("detail") or "").strip()
    low = detail.lower()
    for needle in DEATH_DETAILS:
        if needle in low:
            return DEAD, detail
    if state in ACTIVE_STATES and source and source != "none":
        return LIVE, detail
    return UNKNOWN, detail or f"state '{state or '?'}' with no live source"


def classify_liveness(line, endpoint):
    """(liveness, reason) from the state line plus the recorded endpoint verdict.

    `endpoint` is the backend classifier's read of the recorded target
    (bin/fm-backend.sh's fm_backend_agent_state): alive / dead / missing /
    unreadable, or "" when the task records no target. The endpoint read wins
    when it is definitive; otherwise the state line's own evidence decides, and
    anything left over is `unknown` rather than `live`.
    """
    state_liveness, reason = liveness_from_state_line(line)
    if endpoint == "alive":
        return LIVE, reason or "endpoint alive"
    if endpoint in ("dead", "missing"):
        return DEAD, f"endpoint {endpoint}"
    return state_liveness, reason


# One bounded bash process answers the endpoint question for the whole fleet, so
# a lane does not each pay its own interpreter start-up. A task with no recorded
# target, a missing backend library, or a probe that fails for any reason
# contributes nothing and its lane falls back to the state line's own evidence.
_PROBE = r'''
SCRIPT_DIR=$1
. "$SCRIPT_DIR/fm-backend.sh" >/dev/null 2>&1 || exit 1
while IFS=$'\t' read -r id backend target; do
  [ -n "$id" ] || continue
  printf '%s\t%s\n' "$id" "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null | head -1)"
done
'''


def endpoint_states(pairs, timeout=30):
    """id -> raw backend classifier verdict for [(id, backend, target), ...]."""
    payload = "".join(f"{i}\t{b}\t{t}\n" for i, b, t in pairs if t)
    if not payload:
        return {}
    try:
        done = subprocess.run(["bash", "-c", _PROBE, "_", f"{FM}/bin"],
                              input=payload, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return {}
    out = {}
    for line in done.stdout.splitlines():
        if "\t" in line:
            key, val = line.split("\t", 1)
            if key:
                out[key] = val.strip()
    return out

# In-process snapshot cache. A refresh runs in the request thread that missed
# the TTL - there is deliberately no background worker - and concurrent misses
# collapse onto the refresh already running (single flight), so a slow
# fm-crew-state.sh read is paid once per interval instead of once per request.
# The TTL matches the page's own 5s poll so both routes of one poll window share
# a snapshot; the effective refresh interval is the TTL plus one refresh's own
# duration, since the TTL is measured from the last finished refresh.
_SNAP_LOCK = threading.Condition()
_SNAP_TTL = 5.0
_SNAP_WAIT = 90.0
_SNAP = {"lanes": None, "ok": False, "error": "", "computed_at": 0.0,
         "checked_at": 0.0, "refreshing": False}


def mask(s):
    return re.sub(r"(TOKEN|SECRET|PASSWORD|API_KEY|AUTHORIZATION|BEARER|COOKIE)([=: ]+)\S+",
                  r"\1\2<redacted>", s or "", flags=re.I)


def field(path, key):
    v = ""
    try:
        for line in open(path, errors="ignore"):
            if line.startswith(key + "="):
                v = line.rstrip("\n").split("=", 1)[1]
    except OSError:
        pass
    return v


def _lane(m, idx, title_of, endpoint=""):
    cid = os.path.basename(m)[:-5]
    try:
        st = subprocess.run([f"{FM}/bin/fm-crew-state.sh", cid], cwd=FM,
                            capture_output=True, text=True, timeout=20).stdout.splitlines()[:1]
    except Exception:
        st = []
    try:
        age = int(time.time() - os.path.getmtime(f"{STATE}/{cid}.status"))
    except OSError:
        age = -1
    try:
        last = open(f"{STATE}/{cid}.status", errors="ignore").read().splitlines()[-1]
    except (OSError, IndexError):
        last = ""
    try:
        pk = subprocess.run([f"{FM}/bin/fm-peek.sh", cid, "8"], cwd=FM,
                            capture_output=True, text=True, timeout=25).stdout
    except Exception:
        pk = ""
    try:
        wd = field(m, "worktree")
        cm = subprocess.run(["git", "-C", wd, "log", "-1", "--format=%h|%ct"], cwd=FM,
                            capture_output=True, text=True, timeout=10).stdout.strip()
        commit_short, cts = cm.split("|", 1)
        commit_age = int(time.time() - int(cts))
    except Exception:
        commit_short, commit_age = "", -1
    harness = field(m, "harness")
    liveness, liveness_reason = classify_liveness(st[0] if st else "", endpoint)
    return dict(id=cid, title=title_of.get(cid, ""), model=field(m, "model"), harness=harness,
                window=field(m, "window"), state=(st[0] if st else ""),
                liveness=liveness, liveness_reason=liveness_reason, endpoint=endpoint,
                age=age, stalled=(age >= 1200), last=mask(last),
                commit_short=commit_short, commit_age=commit_age,
                color=LANE_PALETTE[idx % len(LANE_PALETTE)],
                output=mask(pk).strip() or "(no output captured)")


def _refresh_lanes():
    metas = sorted(glob.glob(f"{STATE}/*.meta"))
    title_of = titles()
    pairs = [(os.path.basename(m)[:-5], field(m, "backend") or "tmux", field(m, "window"))
             for m in metas]
    endpoints = endpoint_states(pairs)
    return [_lane(m, i, title_of, endpoints.get(os.path.basename(m)[:-5], ""))
            for i, m in enumerate(metas)]


def _cache_meta(state, ttl, status, error=""):
    """Freshness record for the value one cache is serving. Its lock must be held."""
    now = time.time()
    computed = state["computed_at"]
    return {
        "status": status,
        "computed_at": computed,
        "checked_at": state["checked_at"],
        "age": (now - computed) if computed else -1.0,
        "refreshing": state["refreshing"],
        "error": error or state["error"],
        "ttl": ttl,
    }


def _cached(lock, state, key, ttl, refresh, empty):
    """(value, meta) from one TTL cache with single flight and honest freshness.

    Both read paths (the lanes and the queue board) share this one contract so
    neither can drift: a value inside the TTL is served as it is; a miss runs
    `refresh` once, with concurrent misses collapsing onto the read already
    running and being labelled `stale`; a failed refresh keeps serving the last
    good value and never presents it as current. `empty` is served when nothing
    good exists yet.
    """
    with lock:
        now = time.time()
        if state["checked_at"] and now - state["checked_at"] < ttl:
            return (state[key] if state[key] is not None else empty,
                    _cache_meta(state, ttl, "fresh" if state["ok"] else "error"))
        if state["refreshing"]:
            # Single flight: another thread already owns the refresh. Serve what
            # we have and label it stale rather than starting a second read; with
            # nothing to serve yet, join the refresh instead of duplicating it.
            if state[key] is not None:
                return state[key], _cache_meta(state, ttl, "stale")
            deadline = now + _SNAP_WAIT
            while state["refreshing"] and time.time() < deadline:
                lock.wait(deadline - time.time())
            if state[key] is None:
                return empty, _cache_meta(state, ttl, "error",
                                          error="refresh in progress with nothing to serve yet")
            return state[key], _cache_meta(state, ttl, "fresh" if state["ok"] else "error")
        state["refreshing"] = True
    value, error = None, ""
    try:
        value = refresh()
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
    with lock:
        state["refreshing"] = False
        # Stamped AFTER the read: a snapshot whose own computation outran the TTL
        # used to be born already expired, so every request recomputed it.
        state["checked_at"] = time.time()
        if value is None:
            state["ok"] = False
            state["error"] = error or "refresh failed"
        else:
            state[key] = value
            state["ok"] = True
            state["error"] = ""
            state["computed_at"] = state["checked_at"]
        lock.notify_all()
        if state[key] is None:
            return empty, _cache_meta(state, ttl, "error")
        return state[key], _cache_meta(state, ttl, "fresh" if state["ok"] else "error")


def snap():
    """(lanes, meta): every recorded lane plus how fresh it is.

    meta always says whether the served lanes are fresh, were served stale while
    a refresh ran, or are the last good ones after a failed refresh; it never
    presents stale lanes as current.
    """
    return _cached(_SNAP_LOCK, _SNAP, "lanes", _SNAP_TTL, _refresh_lanes, [])


def queue():
    """(board, meta): the backlog sections plus how fresh they are.

    meta follows snap()'s contract exactly, so a reader can tell a freshly read
    queue from one served while a read was running and from the last good read
    after the CLI refused.
    """
    return _cached(_QUEUE_LOCK, _QUEUE, "board", QUEUE_TTL, _queue_board, {})


def cached_lanes():
    """(lanes, ready): the page's lane snapshot, never triggering its read.

    The panel must not wait on the page's own lane read: that one peeks every
    pane and reads one commit per lane, which measured 68s on a cold server for
    an 11-lane home. The board reports the live lanes the page has already
    computed, and `ready` says whether any have been computed at all, so a cold
    board says "not computed yet" instead of an authoritative-looking zero.
    """
    with _SNAP_LOCK:
        return list(_SNAP["lanes"] or []), _SNAP["lanes"] is not None


PAGE = r"""<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>FirstCrew monitor</title>
<style>
:root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#c9d1d9;--mut:#8b949e;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--acc:#58a6ff}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.45 ui-monospace,Menlo,monospace;display:flex;flex-direction:column}
header{padding:8px 16px;border-bottom:1px solid var(--bd);display:flex;gap:14px;align-items:center;flex:0 0 auto;flex-wrap:wrap}
header b{color:var(--acc)}.mut{color:var(--mut)}
.legend{display:flex;gap:8px;flex-wrap:wrap}
.main{flex:1 1 auto;display:flex;gap:10px;padding:10px;min-height:0}
.grid{flex:1 1 auto;display:grid;grid-auto-flow:column;grid-auto-columns:minmax(340px,1fr);grid-template-rows:1fr;gap:10px;overflow:auto;min-height:0}
.tasks{flex:0 0 300px;background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:8px;overflow:auto;min-height:0}
.tasks .th{font-weight:700;color:var(--acc);border-bottom:1px solid var(--bd);padding-bottom:6px;margin-bottom:6px;position:sticky;top:0;background:var(--card)}
.tk{padding:5px 6px;border-left:3px solid var(--bd);margin-bottom:5px;border-radius:4px;background:#0f141b}
.tk.live{border-left-color:var(--ok)}
.tk .tkline{display:flex;gap:6px;align-items:baseline}
.tk .tktitle{flex:1 1 auto;min-width:0;font-size:12px;color:#e6edf3;overflow-wrap:anywhere;word-break:break-word}
.tk .dot{color:var(--ok);font-size:10px}
.tk .tkmeta{color:var(--mut);font-size:10px;overflow-wrap:anywhere;word-break:break-word}
@media(max-width:900px){.main{flex-direction:column}.tasks{flex:0 0 auto;max-height:32vh}
.ttl,.meta,.last,.tk .tktitle,.tk .tkmeta,.hd .id{white-space:normal;overflow:visible;text-overflow:clip;word-break:break-word;overflow-wrap:anywhere}
.hd{flex-wrap:wrap}.tk .tkline{flex-wrap:wrap}}
.panel{background:var(--card);border:1px solid var(--bd);border-left:4px solid var(--lane);border-radius:8px;padding:10px;display:flex;flex-direction:column;min-height:0}
.panel.gone{opacity:.55;border-left-color:var(--bad)}
.hd{display:flex;justify-content:space-between;gap:8px;align-items:center;border-bottom:1px solid var(--bd);padding-bottom:6px;margin-bottom:6px;flex-wrap:wrap}
.hd .id{font-weight:600;color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ttl{flex:1 1 auto;min-width:0;font-weight:700;color:var(--lane);overflow-wrap:anywhere;word-break:break-word}
.ttl .sep{color:var(--bd);font-weight:400;margin:0 6px}
.ttl .sid{color:var(--mut);font-weight:600}
.badge{font-size:11px;font-weight:700;letter-spacing:.04em;padding:2px 8px;border-radius:10px;color:#0d1117;background:var(--hcolor);white-space:nowrap}
.chip{font-size:11px;padding:1px 7px;border-radius:10px;border:1px solid var(--bd);color:var(--mut);white-space:nowrap}
.chip.ok{color:var(--ok);border-color:var(--ok)}.chip.warn{color:var(--warn);border-color:var(--warn)}.chip.bad{color:var(--bad);border-color:var(--bad)}
.meta{color:var(--mut);font-size:11px;margin-bottom:4px;overflow-wrap:anywhere;word-break:break-word}
.meta .mod{color:var(--lane)}
.st{font-size:12px;margin-bottom:4px}.last{color:var(--mut);font-size:11px;margin-bottom:6px;overflow-wrap:anywhere;word-break:break-word}
.st.ok{color:var(--ok)}.st.warn{color:var(--warn)}.st.bad{color:var(--bad)}
.age.ok{color:var(--ok)}.age.warn{color:var(--warn)}.age.bad{color:var(--bad)}
.out{flex:1;min-height:0;overflow:auto;background:#0b0f14;border:1px solid var(--bd);border-radius:6px;padding:6px;white-space:pre-wrap;word-break:break-word;font-size:11px;color:#adbac7}
.qwrap{flex:0 0 auto;border-bottom:1px solid var(--bd);padding:6px 16px;font:12px/1.45 ui-monospace,Menlo,monospace}
.qwrap>summary{cursor:pointer;color:var(--acc);font-weight:700}
.qwrap>summary .ro{color:var(--mut);font-weight:400}
.qwrap>summary b{color:var(--fg)}
.qbar{display:flex;gap:10px;padding-top:8px;align-items:flex-start;flex-wrap:wrap}
.qcol{flex:1 1 300px;min-width:0;background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:7px 8px;max-height:40vh;overflow:auto}
.qcol h4{margin:0 0 6px;font-size:11px;letter-spacing:.04em;color:var(--acc);border-bottom:1px solid var(--bd);padding-bottom:5px}
.qcol h4 .mut{font-weight:400}
.qrow{padding:4px 6px;border-left:3px solid var(--bd);margin-bottom:4px;border-radius:4px;background:#0f141b}
.qrow.live{border-left-color:var(--ok)}.qrow.blk{border-left-color:var(--bad)}.qrow.hld{border-left-color:var(--warn)}
.qrow .qt{font-size:12px;color:#e6edf3;overflow-wrap:anywhere;word-break:break-word}
.qrow .qm{color:var(--mut);font-size:10px;overflow-wrap:anywhere;word-break:break-word}
.qrow .qm.one{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.qrow .sid{color:var(--mut)}
</style></head><body>
<header>
  <b>FirstCrew monitor</b>
  <span class=mut id=ts></span>
  <span class=mut>read-only · 5s</span>
  <span class=mut id=lcount></span>
  <span class=mut id=fresh></span>
  <span class=legend id=legend></span>
</header>
<details class=qwrap id=qwrap open><summary>작업 현황 · 진행중 <b id=qc-flight>?</b> · 진행예정 <b id=qc-queued>?</b> · 걸림 <b id=qc-stuck>?</b> <span class=ro id=qmeta>읽기 전용</span></summary>
<div class=qbar>
  <div class=qcol><h4>진행중 (라이브 워커) <span class=mut id=qn-flight></span></h4><div id=q-flight></div></div>
  <div class=qcol><h4>진행예정 (백로그 대기) <span class=mut id=qn-queued></span></h4><div id=q-queued></div></div>
  <div class=qcol><h4>걸림 (차단 + 보류) <span class=mut id=qn-stuck></span></h4><div id=q-stuck></div></div>
</div></details>
<div class=main>
  <div class=grid id=grid></div>
  <aside class=tasks><div class=th>할당된 업무 <span class=mut id=tcount></span></div><div id=tlist></div></aside>
</div>
<script>
function esc(s){return (s||"").replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function chip(s){let c="chip";if(/working|done/.test(s))c+=" ok";if(/parked|paused|needs-decision/.test(s))c+=" warn";if(/blocked|failed|unknown|stall/.test(s))c+=" bad";return c}
function ageClass(a){if(a<0)return"";if(a>=1200)return"bad";if(a>=300)return"warn";return"ok"}
function lvClass(l){return l==='live'?'ok':(l==='dead'?'bad':'warn')}
function lvLabel(l){return l==='live'?'LIVE':(l==='dead'?'GONE':'UNKNOWN')}
let lastLegend="";
function freshness(r){const s=r.headers.get('X-Snap-Status')||'?';const a=r.headers.get('X-Snap-Age');
 const e=r.headers.get('X-Snap-Error');let t='snapshot '+s;
 if(a!==null&&a!==undefined&&Number(a)>=0)t+=' · age '+Number(a).toFixed(1)+'s';
 if(r.headers.get('X-Snap-Refreshing')==='true')t+=' · refreshing';
 if(e)t+=' · '+e;return t}
async function tick(){try{const r=await fetch('/data',{cache:'no-store'});const d=await r.json();
document.getElementById('ts').textContent=new Date().toLocaleTimeString();
document.getElementById('fresh').textContent=freshness(r);
const n={live:0,dead:0,unknown:0};d.forEach(c=>{n[c.liveness]=(n[c.liveness]||0)+1});
document.getElementById('lcount').textContent='live '+n.live+' · gone '+n.dead+' · unknown '+n.unknown;
const g=document.getElementById('grid');
g.innerHTML=d.map(c=>`<div class="panel ${c.liveness==='dead'?'gone':''}" style="--lane:${esc(c.color)};--hcolor:${esc(c.hcolor||'#8b949e')}">
 <div class=hd>
   <span class=ttl>${esc(c.title||c.id)}<span class=sep> - </span><span class=sid>${esc(c.id)}</span></span>
   <span class=badge>${esc(c.hlabel||c.harness||'?')}</span>
   <span class="chip ${lvClass(c.liveness)}" title="${esc(c.liveness_reason||'')}">${lvLabel(c.liveness)}</span>
   <span class="${c.stalled?'chip bad':chip(c.state)}">${c.stalled?'STALLED':esc((c.state.split('·')[0]||'').replace('state:','').trim()||'?')}</span>
 </div>
 <div class=meta><span class=mod>${esc(c.model||'?')}</span> · ${esc(c.harness||'?')} · ${esc(c.window||'')} · status <span class="age ${ageClass(c.age)}">${c.age<0?'?':c.age+'s'}</span> · 진척 commit ${esc(c.commit_short||'?')} <span class="age ${ageClass(c.commit_age)}">${c.commit_age<0?'?':c.commit_age+'s'}</span>${(c.commit_age>=1200&&!/done/.test(c.state))?' <span class="chip bad">진척없음</span>':''}</div>
 <div class="st ${chip(c.state).replace('chip','').trim()}">${esc(c.state)}</div>
 <div class=last>${esc(c.last)}</div>
 <div class=out>${esc(c.output)}</div>
</div>`).join('') || '<div class=panel><div class=hd><span class=id>no crews</span></div></div>';
const lg=[...new Map(d.map(c=>[c.hlabel||c.harness,[c.hlabel||c.harness,c.hcolor||'#8b949e']])).values()]
  .map(([l,co])=>`<span class=badge style="--hcolor:${esc(co)}">${esc(l)}</span>`).join('');
if(lg!==lastLegend){document.getElementById('legend').innerHTML=lg;lastLegend=lg;}
}catch(e){document.getElementById('ts').textContent='fetch error';}}
async function tickTasks(){try{const r=await fetch('/tasks',{cache:'no-store'});const d=await r.json();
document.getElementById('tcount').textContent='('+d.length+')';
const l=document.getElementById('tlist');
l.innerHTML=d.map(t=>`<div class="tk ${t.live?'live':''}">
 <div class=tkline><span class=tktitle>${esc(t.title||t.id)}</span>${t.live?'<span class=dot title="session alive">●</span>':''}</div>
 <div class=tkmeta>${esc(t.section)} · ${esc(t.repo||'-')}${t.kind?' · '+esc(t.kind):''} · <span class=sid>${esc(t.id)}</span></div>
</div>`).join('')||'<div class=mut>없음</div>';}catch(e){}}
function qrow(cls,title,meta,one){return `<div class="qrow ${cls}"><div class=qt>${esc(title)}</div><div class="qm${one?' one':''}">${meta}</div></div>`}
function qextra(s){const extra=Math.max(0,(s.count||0)-(s.items||[]).length);const bits=[];
 if(extra)bits.push('그 외 '+extra+'건');
 if(s.capped)bits.push('조회 상한(100건) 도달');
 return bits.length?`<div class=qnote>${bits.join(' · ')}</div>`:''}
async function tickBoard(){try{const r=await fetch('/board',{cache:'no-store'});const d=await r.json();
 const c=d.counts||{},q=d.queued||{},b=d.blocked||{},h=d.held||{};
 const set=(id,v)=>{document.getElementById(id).textContent=v};
 const put=(id,v)=>{document.getElementById(id).innerHTML=v};
 const ready=d.lanes_ready!==false;
 set('qc-flight',ready?(c.in_flight||0):'…');set('qc-queued',c.queued||0);set('qc-stuck',(c.blocked||0)+(c.held||0));
 let tag='읽기 전용';const qs=r.headers.get('X-Queue-Status')||'?';
 if(d.computed_at)tag+=' · 갱신 '+new Date(d.computed_at*1000).toLocaleTimeString();
 if(qs!=='fresh')tag+=' · '+(qs==='stale'?'이전 값(갱신 중)':'갱신 실패 '+(r.headers.get('X-Queue-Error')||''));
 set('qmeta',tag);
 set('qn-flight','('+(d.in_flight||[]).length+')');
 set('qn-queued','('+(q.total||0)+')');
 set('qn-stuck','차단 '+(b.count||0)+' · 보류 '+(h.count||0));
 const empty='<div class=mut>없음</div>';
 const flight=(d.in_flight||[]).map(t=>qrow('live',t.title||t.id,
   esc(t.harness||'')+' · '+esc(t.window||'')+' · <span class=sid>'+esc(t.id)+'</span><br>'+esc(t.last||'(상태 줄 없음)'),true)).join('');
 const queued=(q.items||[]).map(t=>qrow('',t.title||t.id,
   'P'+esc(t.priority||'-')+' · '+esc(t.repo||'-')+' · <span class=sid>'+esc(t.id)+'</span>',false)).join('');
 const stuck=(b.items||[]).map(t=>qrow('blk',t.title||t.id,
   '차단: '+esc(t.blocked_by||'-')+' · '+esc(t.repo||'-')+' · <span class=sid>'+esc(t.id)+'</span>',true)).join('')
  +(h.items||[]).map(t=>qrow('hld',t.title||t.id,
   '보류: '+esc(t.hold_reason||'-')+(t.hold_until&&t.hold_until!=='-'?' (~'+esc(t.hold_until)+')':'')+' · <span class=sid>'+esc(t.id)+'</span>',true)).join('');
 put('q-flight',flight||(ready?empty:'<div class=mut>라이브 워커 계산 중 (메인 뷰가 준비되면 표시)</div>'));
 put('q-queued',(queued+qextra(q))||empty);
 put('q-stuck',(stuck+qextra(b)+qextra(h))||empty);
}catch(e){document.getElementById('qmeta').textContent='읽기 전용 · /board 실패';}}
tick();setInterval(tick,5000);
tickTasks();setInterval(tickTasks,5000);
tickBoard();setInterval(tickBoard,5000);
</script></body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def _send(self, body, content_type, meta=None, qmeta=None):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        # Freshness travels in headers so the JSON schema stays exactly what it
        # was: an array of lanes (/data) or of tasks (/tasks).
        self.send_header("Cache-Control", "no-store")
        if meta:
            self.send_header("X-Snap-Status", meta["status"])
            self.send_header("X-Snap-Age", f"{meta['age']:.3f}")
            self.send_header("X-Snap-Computed-At", f"{meta['computed_at']:.3f}")
            self.send_header("X-Snap-Refreshing", "true" if meta["refreshing"] else "false")
            self.send_header("X-Snap-Ttl", f"{meta['ttl']:.3f}")
            if meta["error"]:
                self.send_header("X-Snap-Error", meta["error"].replace("\n", " ")[:200])
        # The queue board's own freshness, same shape, so a reader of /board can
        # tell a fresh backlog read from one served while a read was running.
        if qmeta:
            self.send_header("X-Queue-Status", qmeta["status"])
            self.send_header("X-Queue-Age", f"{qmeta['age']:.3f}")
            self.send_header("X-Queue-Computed-At", f"{qmeta['computed_at']:.3f}")
            self.send_header("X-Queue-Refreshing", "true" if qmeta["refreshing"] else "false")
            self.send_header("X-Queue-Ttl", f"{qmeta['ttl']:.3f}")
            if qmeta["error"]:
                self.send_header("X-Queue-Error", qmeta["error"].replace("\n", " ")[:200])
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/board"):
            # The board's freshness is the queue's, so it carries X-Queue-*
            # only: no X-Snap-* header here, because those describe lanes this
            # route deliberately does not compute.
            board, qmeta = queue()
            lanes, ready = cached_lanes()
            payload = dict(board)
            payload["in_flight"] = [
                {"id": lane["id"], "title": lane.get("title") or "",
                 "state": lane.get("state") or "", "last": lane.get("last") or "",
                 "window": lane.get("window") or "",
                 "harness": HARNESS.get(lane.get("harness") or "", {}).get(
                     "label", (lane.get("harness") or "?").upper())}
                for lane in lanes if lane.get("liveness") == LIVE]
            payload["lanes_ready"] = ready
            counts = dict(payload.get("counts") or {})
            counts["in_flight"] = len(payload["in_flight"])
            payload["counts"] = counts
            payload["readonly"] = True
            payload["computed_at"] = qmeta["computed_at"]
            self._send(json.dumps(payload).encode(), "application/json", None, qmeta)
        elif self.path.startswith("/tasks"):
            lanes, meta = snap()
            # `live` now means a session is actually alive, not that a meta
            # record exists; `liveness` carries the three-way verdict and
            # `has_record` keeps the old "a task record exists" fact.
            live = {lane["id"] for lane in lanes if lane.get("liveness") == LIVE}
            present = {lane["id"] for lane in lanes}
            tasks = backlog_tasks()
            for t in tasks:
                t["live"] = t["id"] in live
                t["has_record"] = t["id"] in present
                lane = next((x for x in lanes if x["id"] == t["id"]), None)
                t["liveness"] = lane.get("liveness", UNKNOWN) if lane else UNKNOWN
                t["liveness_reason"] = lane.get("liveness_reason", "no lane record") if lane else "no lane record"
            self._send(json.dumps(tasks).encode(), "application/json", meta)
        elif self.path.startswith("/data"):
            lanes, meta = snap()
            for lane in lanes:
                harness = HARNESS.get(lane.get("harness") or "", {})
                lane["hlabel"] = harness.get("label", (lane.get("harness") or "?").upper())
                lane["hcolor"] = harness.get("color", "#8b949e")
            self._send(json.dumps(lanes).encode(), "application/json", meta)
        else:
            self._send(PAGE.encode(), "text/html; charset=utf-8",
                       {"status": "n/a", "age": -1.0, "computed_at": 0.0,
                        "refreshing": False, "error": "", "ttl": _SNAP_TTL})

    def log_message(self, *a):
        pass


def print_crews():
    """Terminal view: one line per LIVE crew (lane), then the non-live count."""
    lanes, meta = snap()
    live = [lane for lane in lanes if lane.get("liveness") == LIVE]
    if not live:
        print("(no live crews)")
    for lane in live:
        h = HARNESS.get(lane.get("harness") or "", {}).get("label", (lane.get("harness") or "?").upper())
        age = "?" if lane.get("age", -1) < 0 else f"{lane['age']}s"
        print(f"{lane['id']:<46} {h:<9} {lane.get('model') or '?':<40} {lane.get('state') or '?'}")
        print(f"    task: {lane.get('title') or '-'}   age={age}   window={lane.get('window') or '-'}")
    gone = [lane for lane in lanes if lane.get("liveness") == DEAD]
    unknown = [lane for lane in lanes if lane.get("liveness") == UNKNOWN]
    if gone or unknown:
        print(f"({len(gone)} dead-or-gone, {len(unknown)} unknown - recorded tasks with no live session)")
        for lane in gone + unknown:
            print(f"    {lane['liveness']:<7} {lane['id']:<46} {lane.get('liveness_reason') or ''}")
    print(f"snapshot {meta['status']} · age {meta['age']:.1f}s"
          + (f" · {meta['error']}" if meta["error"] else ""))
    return 0


def print_tasks():
    """Terminal view: open backlog tasks grouped by rail/section, live ones marked."""
    lanes, _ = snap()
    live = {lane["id"] for lane in lanes if lane.get("liveness") == LIVE}
    tasks = backlog_tasks()
    if not tasks:
        print("(no open tasks)")
        return 0
    by_section = {}
    for t in tasks:
        by_section.setdefault(t["section"] or "-", []).append(t)
    for section, items in by_section.items():
        print(f"== {section} ({len(items)}) ==")
        for t in items:
            mark = "[live] " if t["id"] in live else "       "
            meta = " · ".join(x for x in (t.get("repo"), t.get("kind"), t.get("priority")) if x)
            print(f"  {mark}{t['id']:<46} {t['title'][:78]}")
            if meta:
                print(f"            {meta}")
        print()
    return 0


def _term_width():
    try:
        return os.get_terminal_size().columns
    except OSError:
        return int(os.environ.get("COLUMNS", "160"))


def _pad(s, w):
    s = s[:w]
    return s + " " * max(0, w - len(s))


def print_watch():
    """Live terminal dashboard: crews side by side, then open tasks per rail."""
    try:
        while True:
            lanes, meta = snap()
            tasks = backlog_tasks()
            live = {l["id"] for l in lanes if l.get("liveness") == LIVE}
            w = _term_width()
            out = [f"FirstCrew monitor · http://127.0.0.1:{PORT}/ · {time.strftime('%H:%M:%S')} · Ctrl-C to exit",
                   f"snapshot {meta['status']} · age {meta['age']:.1f}s"
                   + (f" · {meta['error']}" if meta["error"] else ""), ""]
            n = max(1, len(lanes))
            colw = max(24, (w - (n - 1) * 2) // n)
            cols = []
            for lane in lanes:
                h = HARNESS.get(lane.get("harness") or "", {}).get("label", (lane.get("harness") or "?").upper())
                age = "?" if lane.get("age", -1) < 0 else f"{lane['age']}s"
                block = [lane["id"], f"{h} · {lane.get('model') or '?'}",
                         f"[{lane.get('liveness') or '?'}] {lane.get('state') or '?'}",
                         f"age {age} · {lane.get('window') or '-'}"]
                title = lane.get("title") or "-"
                while title:
                    block.append(title[:colw]); title = title[colw:]
                cols.append(block)
            for r in range(max((len(c) for c in cols), default=0)):
                out.append("  ".join(_pad((c[r] if r < len(c) else ""), colw) for c in cols))
            out.append("")
            out.append("── 레일별 업무 ──")
            by_section = {}
            for t in tasks:
                by_section.setdefault(t["section"] or "-", []).append(t)
            for section, items in by_section.items():
                out.append(f"[{section}] ({len(items)})")
                for t in items:
                    mark = "●" if t["id"] in live else " "
                    out.append(f"  {mark} {t['id']:<46} {t['title'][:60]}")
            print("\033[2J\033[H" + "\n".join(out), flush=True)
            time.sleep(5)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    import sys
    if "--watch" in sys.argv or "--tui" in sys.argv:
        raise SystemExit(print_watch())
    if "--tasks" in sys.argv:
        raise SystemExit(print_tasks())
    if "--crews" in sys.argv:
        raise SystemExit(print_crews())
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer.daemon_threads = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), H) as srv:
        print(f"http://127.0.0.1:{PORT}/")
        srv.serve_forever()
