#!/usr/bin/env bash
# fm-unattended-guard.sh - Executor Evidence Guard for the unattended batch
# coordinator.
#
# The real-canary defect this closes: a real Executor wrote a report whose
# summary numbers disagreed with the raw evidence (families 14 vs 15,
# assertions 26 vs 25). The independent Auditor caught it and the Judge held,
# but only AFTER a whole auditor crew had been spent. This guard runs BETWEEN
# evidence collection and auditor dispatch: it compares the Executor's CLAIMED
# values against machine-derived canonical values, and on any mismatch the
# coordinator holds the task (`evidence-guard-mismatch`) instead of spending the
# auditor crew. It never weakens the auditor or the judge; it fails closed.
#
# It consumes the task contract's `executor.claims` list. Each claim names a
# value the Executor's report asserts and the canonical source to check it
# against:
#
#   { "id": "families", "kind": "count",
#     "report_pattern": "패밀리\\s*([0-9]+)",          # optional; capture grp 1
#     "source": {"type": "cmd", "cmd": "bin/fm-test-run.sh --list-families",
#                "reduce": "lines"} }
#
#   kind:          count | set
#   source.type:   cmd | report
#   source.reduce: lines | count_re:<ERE>
#   required:      true (default) | false
#
# Canonical sources (principle: derive mechanically, never trust the prose):
#   cmd    - run the command in the Executor worktree and reduce its stdout.
#   report - reduce the report text itself (self-contradiction detection: the
#            summary number vs the verbatim capture the report also embeds).
# Reducers:
#   lines         - non-empty stripped lines (a list; len = count).
#   count_re:<re> - number of lines matching the ERE (a scalar).
#
# When `report_pattern` is omitted for a count claim the default structured form
# is `StructClaim: <id> = <n>` (case-insensitive). The Executor brief asks for
# that low-friction form so the model copies the exact number from a command
# instead of paraphrasing it.
#
# Fail-closed: a missing report, a required claim the report never asserts, a
# canonical command that fails, a malformed contract, or an un-evaluable claim
# is a MISMATCH (nonzero exit), never a pass. A contract that declares no claims
# is a no-op PASS (`note=no-claims-declared`) so existing contracts keep working.
#
# Read-only: it never writes the report or any evidence; only `--out` (guard.json).
#
# Usage:
#   fm-unattended-guard.sh check --contract C.json --report R.md --workdir W [--out G.json]
set -u

cmd_check() {
  local contract='' report='' workdir='' out=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --contract) contract=$2; shift 2;;
      --report)   report=$2;   shift 2;;
      --workdir)  workdir=$2;  shift 2;;
      --out)      out=$2;      shift 2;;
      *) echo "guard: bad arg $1" >&2; exit 2;;
    esac
  done
  [ -n "$contract" ] || { echo "guard: need --contract" >&2; exit 2; }
  [ -f "$contract" ] || { echo "guard: no contract at $contract" >&2; exit 2; }

  GUARD_CONTRACT="$contract" GUARD_REPORT="$report" GUARD_WORKDIR="$workdir" GUARD_OUT="$out" \
    python3 - <<'PY'
import json, os, re, subprocess, sys

contract_p = os.environ["GUARD_CONTRACT"]
report_p   = os.environ.get("GUARD_REPORT", "")
workdir    = os.environ.get("GUARD_WORKDIR", "")
out_p      = os.environ.get("GUARD_OUT", "")

def emit(doc):
    text = json.dumps(doc, ensure_ascii=False, indent=2) + "\n"
    if out_p:
        try:
            d = os.path.dirname(out_p)
            if d:
                os.makedirs(d, exist_ok=True)
            open(out_p, "w").write(text)
        except Exception as e:
            sys.stderr.write("guard: cannot write %s: %s\n" % (out_p, e))
            sys.exit(2)
    else:
        sys.stdout.write(text)

def block(reasons, claims=None, note=None):
    doc = {"verdict": "MISMATCH", "claims": claims or [], "reasons": reasons}
    if note:
        doc["note"] = note
    emit(doc)
    print("GUARD=MISMATCH reasons=" + ";".join(reasons))
    sys.exit(1)

try:
    c = json.load(open(contract_p, encoding="utf-8"))
except Exception as e:
    sys.stderr.write("guard: malformed contract %s: %s\n" % (contract_p, e))
    sys.exit(2)

# The coordinator passes the FLATTENED per-run task contract (executor at top
# level); accept a raw batch contract too (claims under tasks[0].executor).
claims = None
if isinstance(c.get("executor"), dict):
    claims = c["executor"].get("claims")
if claims is None and isinstance(c.get("claims"), list):
    claims = c["claims"]
claims = claims or []

if not claims:
    emit({"verdict": "PASS", "claims": [], "note": "no-claims-declared", "reasons": []})
    print("GUARD=PASS reasons=no-claims-declared")
    sys.exit(0)

if not report_p or not os.path.isfile(report_p):
    block(["report-missing"])

report_text = open(report_p, encoding="utf-8", errors="replace").read()

def canonical_of(source):
    """Return (value, error). value is a list (lines) or int (count_re)."""
    red = source.get("reduce", "lines")
    stype = source.get("type")
    if stype == "cmd":
        cmd = source.get("cmd") or ""
        if not cmd:
            return None, "canonical-cmd-missing"
        if not workdir or not os.path.isdir(workdir):
            return None, "workdir-missing"
        p = subprocess.run(["bash", "-c", cmd], cwd=workdir,
                           capture_output=True, text=True)
        if p.returncode != 0:
            return None, "canonical-cmd-failed(rc=%d)" % p.returncode
        text = p.stdout
    elif stype == "report":
        text = report_text
    else:
        return None, "bad-source-type(%s)" % stype

    if red == "lines":
        return [l.strip() for l in text.splitlines() if l.strip()], None
    if red.startswith("count_re:"):
        rx = red[len("count_re:"):]
        try:
            cre = re.compile(rx)
        except re.error as e:
            return None, "bad-count-re(%s)" % e
        return sum(1 for l in text.splitlines() if cre.search(l)), None
    return None, "bad-reduce(%s)" % red

def claimed_from(pattern, text):
    try:
        rx = re.compile(pattern)
    except re.error as e:
        return None, "bad-report-pattern(%s)" % e
    vals = []
    for m in rx.finditer(text):
        if m.lastindex:
            v = next((g for g in m.groups() if g is not None), None)
        else:
            v = m.group(0)
        if v is not None:
            vals.append(v)
    return vals, None

results = []
reasons = []
for cl in claims:
    cid = str(cl.get("id", "?"))
    kind = cl.get("kind", "count")
    required = cl.get("required", True)
    entry = {"id": cid, "kind": kind, "ok": False}

    pat = cl.get("report_pattern")
    if not pat and kind == "count":
        pat = r"(?im)^\s*StructClaim:\s*" + re.escape(cid) + r"\s*=\s*([0-9]+)\s*$"
    if not pat:
        entry["detail"] = "no-report-pattern"
        results.append(entry); reasons.append(cid + ":no-report-pattern"); continue

    vals, err = claimed_from(pat, report_text)
    if err:
        entry["detail"] = err
        results.append(entry); reasons.append(cid + ":" + err); continue
    if not vals:
        if required:
            entry["detail"] = "missing-claim"
            results.append(entry); reasons.append(cid + ":missing-claim")
        else:
            entry["ok"] = True; entry["detail"] = "optional-claim-absent"
            results.append(entry)
        continue

    canon, err = canonical_of(cl.get("source") or {})
    if err:
        entry["detail"] = err
        results.append(entry); reasons.append(cid + ":" + err); continue

    if kind == "count":
        try:
            ints = sorted({int(v) for v in vals})
        except ValueError:
            entry["detail"] = "non-numeric-claim"
            results.append(entry); reasons.append(cid + ":non-numeric-claim"); continue
        if len(ints) != 1:
            entry["claimed"] = ints; entry["detail"] = "self-conflict"
            results.append(entry); reasons.append(cid + ":self-conflict"); continue
        if not isinstance(canon, int) and not isinstance(canon, list):
            entry["detail"] = "canonical-not-scalar"
            results.append(entry); reasons.append(cid + ":canonical-not-scalar"); continue
        # `lines` yields a list for count claims too: its length is the count.
        canon_n = len(canon) if isinstance(canon, list) else canon
        entry["claimed"] = ints[0]; entry["canonical"] = canon_n
        if ints[0] == canon_n:
            entry["ok"] = True
        else:
            entry["detail"] = "value-mismatch"
            reasons.append("%s:value-mismatch(%d!=%d)" % (cid, ints[0], canon_n))
        results.append(entry)

    elif kind == "set":
        if not isinstance(canon, list):
            entry["detail"] = "canonical-not-list"
            results.append(entry); reasons.append(cid + ":canonical-not-list"); continue
        if len(vals) != len(set(vals)):
            entry["detail"] = "duplicate-items"
            results.append(entry); reasons.append(cid + ":duplicate-items"); continue
        canon_set = set(canon)
        claimed_set = set(vals)
        missing = sorted(canon_set - claimed_set)
        extra = sorted(claimed_set - canon_set)
        entry["claimed"] = len(claimed_set); entry["canonical"] = len(canon_set)
        if not missing and not extra:
            entry["ok"] = True
        else:
            entry["detail"] = "set-mismatch"
            entry["missing"] = missing[:10]; entry["extra"] = extra[:10]
            reasons.append("%s:set-mismatch(missing=%d,extra=%d)" % (cid, len(missing), len(extra)))
        results.append(entry)

    else:
        entry["detail"] = "bad-kind(%s)" % kind
        results.append(entry); reasons.append(cid + ":bad-kind")

verdict = "PASS" if not reasons else "MISMATCH"
emit({"verdict": verdict, "claims": results, "reasons": reasons})
print("GUARD=%s reasons=%s" % (verdict, ";".join(reasons) if reasons else "none"))
sys.exit(0 if verdict == "PASS" else 1)
PY
}

case "${1:-}" in
  check) shift; cmd_check "$@";;
  *) echo "usage: fm-unattended-guard.sh check --contract C.json --report R.md --workdir W [--out G.json]" >&2; exit 2;;
esac
