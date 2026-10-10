#!/usr/bin/env python3
# fm-originals-index.py - read-only discovery, provenance, and duplicate
# determination over every /retro and /stow original this host holds.
#
# Usage:
#   fm-originals-index.py [--summary-only] [--root NAME=PATH]...
#                         [--worktree-root NAME=PATH]... [--no-worktree-root]
#                         [--max-depth N] [--worktree-max-depth N]
#   fm-originals-index.py --help
#
# This command indexes and changes nothing: it never writes, moves, renames, or
# deletes an original, and it holds no promotion path at all. It exists so a
# later collector can reason about the complete original set instead of a
# hardcoded subset of it.
#
# Discovery is bounded by an explicit allowlist plus bounded dynamic worktree
# discovery, never by a filesystem-wide search:
#   allowlist roots  canonical, runtime, firstmate, orca - the fixed clones the
#                    collector is known to care about, each walked to
#                    --max-depth (default 8) directory levels.
#   worktree roots   ~/.treehouse and ~/orca - the two agent-worktree roots this
#                    host actually uses, each walked to --worktree-max-depth
#                    (default 6) levels. A directory whose resolved path is an
#                    allowlist root is pruned, so an allowlist clone nested
#                    under a worktree root is scanned once, not twice.
# No other path is searched, and a root that does not exist is reported
# present=false with zero candidates rather than treated as an error.
#
# A candidate is a file named .stow-notes.md anywhere under a root, or a
# .md/.jsonl file directly inside a directory named retro whose parent is named
# journal. Directories are never followed through symlinks, so a link cannot
# pull the walk outside its root or into a cycle.
#
# Every candidate is validated against the root it was found under:
#   a symlink whose resolved target escapes that root   -> symlink-escapes-root
#   a symlink whose resolved target does not exist      -> broken-symlink
#   anything that is not a regular file                 -> not-a-regular-file
#   a regular file that cannot be read                  -> unreadable
#   a path whose realpath is already collected          -> duplicate-realpath
# Only regular files that survive validation are collected, and a collected
# file is identified by its realpath, so two names for one file are one unit.
#
# The index reports three different counts that must not be conflated:
#   file units          distinct realpaths, one per collected file
#   unique contents     distinct byte hashes across those file units
#   record units        what each file holds when the format decomposes further
# A markdown original is one document record; a .jsonl original is one record
# per parseable non-empty line. A retro .md and its .jsonl sibling in the same
# directory are reported as a sibling pair. File-level duplicates are
# byte-identical copies of one original; record-level duplicates are the same
# record reached through more than one file, which is a different fact.
#
# Every record carries provenance (origin root and relative path) and a marker
# state. Only a record carrying the candidate marker is promotable:
#   markdown  a level-2 heading naming 후보 제안 / 지침 후보 / 독트린 후보 /
#             후보 등록 / 후보
#   jsonl     is_candidate true, lane "candidate", or a doctrine_candidate key
# A record without the marker is raw evidence: marker_state raw-evidence and
# auto_promotable false. PROMOTABLE_STATES is the single owner of which states
# may ever be promoted, so a marker-less record cannot be promoted by this or
# any later collector that reuses it.
#
# Output is one JSON document on stdout (schema fm-originals-index/v1) holding
# the roots, the aggregate totals, per-root aggregation, the exclusion ledger,
# and - unless --summary-only is given - one entry per file unit and per record.
#
# Exit status: 0 indexed; 2 invalid use; 3 no configured root exists.
import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

SCHEMA = "fm-originals-index/v1"

ALLOWLIST_ROOTS = (
    ("canonical", "/Users/irene/Developer/IMAC"),
    ("runtime", "/Users/irene/Developer/IMAC-runtime"),
    ("firstmate", "/Users/irene/Developer/kunchenguid_repos/firstmate"),
    ("orca", "/Users/irene/orca/IMAC"),
)
WORKTREE_ROOTS = (
    ("treehouse", "~/.treehouse"),
    ("orca-worktrees", "~/orca"),
)

DEFAULT_MAX_DEPTH = 8
DEFAULT_WORKTREE_MAX_DEPTH = 6

# Directories that never hold an original and are expensive to walk.
PRUNE_DIRS = frozenset({
    ".git", ".hg", ".svn", "node_modules", "__pycache__", ".venv", "venv",
    "site-packages", "dist", "build", "target", ".tox", ".mypy_cache",
    ".pytest_cache", ".ruff_cache", ".cache",
})

STOW_NOTES_NAME = ".stow-notes.md"
RETRO_SUFFIXES = (".md", ".jsonl")

# The candidate marker contract. A record whose marker is absent stays raw
# evidence and is never auto-promoted.
CANDIDATE_HEADING = re.compile(
    r"^##\s*(?:후보\s*제안|지침\s*후보|독트린\s*후보|후보\s*등록|후보)",
    re.MULTILINE | re.IGNORECASE,
)
JSONL_CANDIDATE_KEYS = ("is_candidate", "lane", "doctrine_candidate")
PROMOTABLE_STATES = frozenset({"candidate"})
STATE_CANDIDATE = "candidate"
STATE_RAW = "raw-evidence"


def is_promotable(record):
    """True only for a record whose marker state is promotable."""
    return record.get("marker_state") in PROMOTABLE_STATES


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def canonical_json_hash(record):
    """Content hash of one JSONL record, independent of key order or spacing."""
    canonical = json.dumps(record, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return sha256_bytes(canonical.encode("utf-8"))


def realpath(path):
    return os.path.realpath(path)


def is_within(child, parent):
    """True when resolved path <child> is <parent> itself or lies underneath it."""
    child = child.rstrip(os.sep)
    parent = parent.rstrip(os.sep)
    if child == parent:
        return True
    return child.startswith(parent + os.sep)


def die(message):
    print("error: %s" % message, file=sys.stderr)
    raise SystemExit(2)


def usage():
    """The leading '#' header of this file, with the comment markers removed."""
    lines = []
    with open(__file__, encoding="utf-8") as handle:
        for index, line in enumerate(handle):
            if not line.startswith("#"):
                break
            if index == 0:
                continue
            lines.append(line[2:] if line.startswith("# ") else line[1:])
    return "".join(lines)


def parse_root_spec(spec, option):
    name, sep, path = spec.partition("=")
    if not sep or not name or not path:
        die("%s expects NAME=PATH, got %r" % (option, spec))
    return name, os.path.expanduser(path)


def parse_args(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--help", "-h", action="store_true")
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--no-worktree-root", action="store_true")
    parser.add_argument("--max-depth")
    parser.add_argument("--worktree-max-depth")
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--worktree-root", action="append", default=[])
    args, extra = parser.parse_known_args(argv)
    if extra:
        die("unexpected argument %r" % (extra[0],))
    if args.help:
        print(usage())
        return None
    roots = [parse_root_spec(s, "--root") for s in args.root] \
        or [(name, os.path.expanduser(path)) for name, path in ALLOWLIST_ROOTS]
    if args.no_worktree_root:
        worktrees = []
    elif args.worktree_root:
        worktrees = [parse_root_spec(s, "--worktree-root") for s in args.worktree_root]
    else:
        worktrees = [(name, os.path.expanduser(path)) for name, path in WORKTREE_ROOTS]
    names = [n for n, _ in roots] + [n for n, _ in worktrees]
    if len(set(names)) != len(names):
        die("root names must be unique: %s" % ", ".join(sorted(names)))
    max_depth = _depth(args.max_depth, DEFAULT_MAX_DEPTH, "--max-depth")
    worktree_max_depth = _depth(args.worktree_max_depth, DEFAULT_WORKTREE_MAX_DEPTH,
                                "--worktree-max-depth")
    return args, roots, worktrees, max_depth, worktree_max_depth


def _depth(raw, default, option):
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        die("%s expects a positive integer, got %r" % (option, raw))
    if value < 1:
        die("%s expects a positive integer, got %r" % (option, raw))
    return value


def is_retro_dir(path):
    return os.path.basename(path) == "retro" and os.path.basename(os.path.dirname(path)) == "journal"


def candidate_paths(root, max_depth, prune_realpaths):
    """Every candidate file path under <root>, bounded and link-safe."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        depth = 0 if dirpath == root else os.path.relpath(dirpath, root).count(os.sep) + 1
        keep = []
        for name in sorted(dirnames):
            child = os.path.join(dirpath, name)
            if name in PRUNE_DIRS:
                continue
            if realpath(child) in prune_realpaths:
                continue
            keep.append(name)
        dirnames[:] = [] if depth >= max_depth else keep
        for name in sorted(filenames):
            if name == STOW_NOTES_NAME:
                found.append(os.path.join(dirpath, name))
            elif is_retro_dir(dirpath) and name.endswith(RETRO_SUFFIXES):
                found.append(os.path.join(dirpath, name))
    return found


def classify(path):
    """Return the original kind for a candidate, or None when it is not one."""
    name = os.path.basename(path)
    if name == STOW_NOTES_NAME:
        return "stow-notes"
    if is_retro_dir(os.path.dirname(path)):
        return "retro-jsonl" if name.endswith(".jsonl") else "retro-md"
    return None


def validate(path, root_real):
    """Return an exclusion reason for <path>, or None when it may be collected."""
    if os.path.islink(path) or not os.path.exists(path):
        target = realpath(path)
        if not os.path.exists(target):
            return "broken-symlink"
        if not is_within(target, root_real):
            return "symlink-escapes-root"
    if not os.path.isfile(path):
        return "not-a-regular-file"
    if not os.access(path, os.R_OK):
        return "unreadable"
    return None


def markdown_marker(text):
    """Return the matched candidate heading, or None."""
    match = CANDIDATE_HEADING.search(text)
    return match.group(0).strip() if match else None


def jsonl_marker(record):
    """Return the matched candidate key, or None."""
    for key in JSONL_CANDIDATE_KEYS:
        if key not in record:
            continue
        value = record[key]
        if key == "is_candidate" and value is True:
            return "is_candidate"
        if key == "lane" and value == "candidate":
            return "lane"
        if key == "doctrine_candidate" and value:
            return "doctrine_candidate"
    return None


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def build_records(kind, root_name, relpath, data):
    """Decompose one collected file into its record units."""
    source = "%s:%s" % (root_name, relpath)
    if kind in ("stow-notes", "retro-md"):
        text = data.decode("utf-8", "replace")
        marker = markdown_marker(text)
        return [{
            "record_id": source,
            "unit": "document",
            "source": source,
            "root": root_name,
            "relpath": relpath,
            "line": None,
            "sha256": sha256_bytes(data),
            "marker_state": STATE_CANDIDATE if marker else STATE_RAW,
            "marker_kind": marker or "",
            "auto_promotable": bool(marker),
        }]
    records = []
    for index, raw_line in enumerate(data.decode("utf-8", "replace").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(parsed, dict):
            continue
        marker = jsonl_marker(parsed)
        records.append({
            "record_id": "%s:%d" % (source, index),
            "unit": "line",
            "source": source,
            "root": root_name,
            "relpath": relpath,
            "line": index,
            "sha256": canonical_json_hash(parsed),
            "marker_state": STATE_CANDIDATE if marker else STATE_RAW,
            "marker_kind": marker or "",
            "auto_promotable": bool(marker),
        })
    return records


def index(roots, worktrees, max_depth, worktree_max_depth):
    allowlist_real = {realpath(path) for _, path in roots if os.path.isdir(path)}
    root_specs = [{"name": name, "path": path, "kind": "allowlist", "max_depth": max_depth}
                  for name, path in roots]
    root_specs += [{"name": name, "path": path, "kind": "worktree", "max_depth": worktree_max_depth}
                   for name, path in worktrees]

    files = []
    excluded = []
    per_root = {}
    seen_realpath = {}
    present = 0

    for spec in root_specs:
        name, path = spec["name"], spec["path"]
        row = {"kind": spec["kind"], "path": path, "present": False, "discovered": 0,
               "collected": 0, "excluded": 0, "exclusion_reasons": {},
               "file_units": 0, "unique_contents": 0, "record_units": 0}
        spec["present"] = os.path.isdir(path)
        row["present"] = spec["present"]
        per_root[name] = row
        if not spec["present"]:
            continue
        present += 1
        root_real = realpath(path)
        prune = allowlist_real - {root_real} if spec["kind"] == "worktree" else set()
        candidates = candidate_paths(root_real, spec["max_depth"], prune)
        row["discovered"] = len(candidates)
        for candidate in candidates:
            kind = classify(candidate)
            relpath = os.path.relpath(candidate, root_real)
            reason = validate(candidate, root_real)
            if reason is None and kind is None:
                reason = "not-an-original"
            if reason is None:
                target = realpath(candidate)
                if target in seen_realpath:
                    reason = "duplicate-realpath"
            if reason is not None:
                row["excluded"] += 1
                row["exclusion_reasons"][reason] = row["exclusion_reasons"].get(reason, 0) + 1
                excluded.append({"path": candidate, "root": name, "reason": reason})
                continue
            try:
                data = read_bytes(candidate)
            except OSError:
                reason = "unreadable"
                row["excluded"] += 1
                row["exclusion_reasons"][reason] = row["exclusion_reasons"].get(reason, 0) + 1
                excluded.append({"path": candidate, "root": name, "reason": reason})
                continue
            target = realpath(candidate)
            seen_realpath[target] = True
            entry = {
                "realpath": target,
                "root": name,
                "relpath": relpath,
                "kind": kind,
                "sha256": sha256_bytes(data),
                "bytes": len(data),
                "record_units": 0,
                "duplicate_group": None,
                "duplicate_of": None,
                "sibling": "",
            }
            entry["records"] = build_records(kind, name, relpath, data)
            entry["record_units"] = len(entry["records"])
            files.append(entry)
            row["collected"] += 1

    # Duplicate determination: byte-identical file units, then identical records
    # reached through more than one file.
    assign_groups(files, lambda f: f["sha256"], "duplicate_group", "duplicate_of",
                  lambda f: f["realpath"])
    all_records = [record for f in files for record in f["records"]]
    assign_groups(all_records, lambda r: r["sha256"], "duplicate_group", "duplicate_of",
                  lambda r: r["record_id"])

    for entry in files:
        row = per_root[entry["root"]]
        row["file_units"] += 1
        row["record_units"] += entry["record_units"]
    for name, row in per_root.items():
        row["unique_contents"] = len({f["sha256"] for f in files if f["root"] == name})

    sibling_groups = sibling_pairs(files)

    totals = {
        "discovered": sum(r["discovered"] for r in per_root.values()),
        "collected": len(files),
        "excluded": len(excluded),
        "file_units": len(files),
        "unique_contents": len({f["sha256"] for f in files}),
        "duplicate_copies": len(files) - len({f["sha256"] for f in files}),
        "record_units": len(all_records),
        "unique_record_contents": len({r["sha256"] for r in all_records}),
        "duplicate_record_copies": len(all_records) - len({r["sha256"] for r in all_records}),
        "candidate_records": sum(1 for r in all_records if is_promotable(r)),
        "raw_evidence_records": sum(1 for r in all_records if not is_promotable(r)),
        "realpath_duplicates": sum(r["exclusion_reasons"].get("duplicate-realpath", 0)
                                   for r in per_root.values()),
        "sibling_groups": len(sibling_groups),
    }
    return {
        "schema": SCHEMA,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "roots": root_specs,
        "totals": totals,
        "per_root": per_root,
        "excluded": excluded,
        "sibling_groups": sibling_groups,
        "files": files,
        "present_roots": present,
    }


def assign_groups(items, key_of, group_field, of_field, id_of):
    groups = {}
    for item in items:
        groups.setdefault(key_of(item), []).append(item)
    for index, (_, members) in enumerate(sorted(groups.items()), start=1):
        canonical = id_of(members[0])
        for member in members:
            member[group_field] = index
            member[of_field] = None if id_of(member) == canonical else canonical


def sibling_pairs(files):
    """Pair each retro .md with a same-directory .jsonl of the same stem."""
    index = {}
    for entry in files:
        if entry["kind"] in ("retro-md", "retro-jsonl"):
            stem = os.path.splitext(entry["relpath"])[0]
            index.setdefault((entry["root"], stem), {})[entry["kind"]] = entry
    pairs = []
    for (root, stem), kinds in sorted(index.items()):
        md, jsonl = kinds.get("retro-md"), kinds.get("retro-jsonl")
        if md and jsonl:
            md["sibling"] = jsonl["relpath"]
            jsonl["sibling"] = md["relpath"]
            pairs.append({"root": root, "directory": os.path.dirname(md["relpath"]),
                          "stem": os.path.basename(stem),
                          "md": md["relpath"], "jsonl": jsonl["relpath"]})
    return pairs


def main(argv):
    parsed = parse_args(argv)
    if parsed is None:
        return 0
    args, roots, worktrees, max_depth, worktree_max_depth = parsed
    result = index(roots, worktrees, max_depth, worktree_max_depth)
    if result.pop("present_roots") == 0:
        print("error: none of the configured roots exist", file=sys.stderr)
        return 3
    if args.summary_only:
        result.pop("files")
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
