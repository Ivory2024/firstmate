#!/usr/bin/env python3
"""Behavioral coverage for bin/fm-originals-index.py.

Covers the discovery contract (explicit allowlist plus bounded worktree
discovery), realpath de-duplication, symlink boundary validation, record-unit
decomposition, provenance, duplicate determination, the marker contract that
keeps a marker-less record raw evidence, and mechanical aggregation.

The two regression cases reproduce the omissions the audit found on the real
host: a .stow-notes.md that lives only under an agent worktree, and a retro
record that lives only under an orca worktree. Each case proves the recorded
old collector misses the original and the new index finds it.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
INDEX = REPO / "bin" / "fm-originals-index.py"
OLD_ROOT = Path(os.environ.get("FM_ORIGINALS_OLD_ROOT", "/Users/irene/Developer/IMAC"))

CANDIDATE_MD = """# Retro

## 후보 제안

### Alpha

- 추가일: 2026-01-01
"""

WORKTREE_CANDIDATE_MD = """# Sunday doctrine audit candidates

## 후보 제안

### SundayDoctrine

- 추가일: 2026-09-11
"""


def plain(tag):
    """A distinct marker-less retro body, so only intended copies collide."""
    return "# Retro\n\n## Summary\n\nNothing was proposed for %s.\n" % tag

JSONL_LINES = [
    {"is_candidate": True, "title": "Alpha"},
    {"title": "raw one", "observed_at": "2026-01-01"},
    {"lane": "candidate", "title": "Beta"},
    {"doctrine_candidate": {"gate": 1}, "title": "Gamma"},
    {"lane": "evidence", "title": "raw two"},
]


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def old_contract_scan(canonical, clone_roots):
    """The audit's recorded old collector, reimplemented from its own sources.

    stow_notes_merge.KNOWN_CLONE_ROOTS is the hardcoded pair (orca/IMAC,
    firstmate), and merge_stow_notes reads only <root>/.stow-notes.md from each.
    retro_doctrine_autolink.sync_retro_stow_candidates(root_dir=CANONICAL_ROOT)
    reads only CANONICAL_ROOT/journal/retro/*.md, CANONICAL_ROOT/.stow-notes.md,
    CANONICAL_ROOT/journal/retro/*.jsonl, and the canonical retro-evidence
    ledger. Nothing else is reachable, so nothing under a worktree is.
    """
    found = []
    retro = Path(canonical) / "journal" / "retro"
    if retro.is_dir():
        found += sorted(retro.glob("*.md")) + sorted(retro.glob("*.jsonl"))
    stow = Path(canonical) / ".stow-notes.md"
    if stow.is_file():
        found.append(stow)
    for root in clone_roots:
        source = Path(root) / ".stow-notes.md"
        if source.is_file():
            found.append(source)
    return sorted(str(p) for p in found)


class Fixture:
    """A synthetic host: four allowlist roots plus two worktree roots."""

    def __init__(self, base):
        self.base = Path(base)
        self.canonical = self.base / "canonical"
        self.runtime = self.base / "runtime"
        self.firstmate = self.base / "firstmate"
        self.orca = self.base / "orca" / "IMAC"
        self.treehouse = self.base / "treehouse"
        self.orca_worktrees = self.base / "orca"

        # Allowlist roots.
        write(self.canonical / ".stow-notes.md", "canonical notes\n")
        write(self.canonical / "journal" / "retro" / "2026-01-01-a-retro.md", CANDIDATE_MD)
        write(self.canonical / "journal" / "retro" / "2026-01-01-a-retro.jsonl",
              "".join(json.dumps(line, ensure_ascii=False) + "\n" for line in JSONL_LINES))
        write(self.runtime / "journal" / "retro" / "2026-01-03-c-retro.md", plain("c"))
        write(self.firstmate / ".stow-notes.md", "firstmate notes\n")
        write(self.firstmate / "projects" / "IMAC" / "journal" / "retro"
              / "2026-01-02-b-retro.md", plain("b"))
        write(self.orca / ".stow-notes.md", "orca notes\n")
        write(self.orca / "journal" / "retro" / "2026-01-04-d-retro.md", plain("d"))

        # Real omission case 2: a retro record reachable only through an orca
        # worktree, exactly as the audit found under
        # orca/IMAC/.worktrees/disk-cleanup-active/.
        self.orca_worktree_record = (
            self.orca / ".worktrees" / "disk-cleanup-active" / "journal" / "retro"
            / "2026-09-11-sunday-doctrine-audit-candidates.md")
        write(self.orca_worktree_record, WORKTREE_CANDIDATE_MD)

        # Real omission case 1: a .stow-notes.md reachable only through an
        # agent worktree, exactly as the audit found under
        # ~/.treehouse/IMAC-292463/{11,19,26}/IMAC/.
        self.worktree_stow_notes = (
            self.treehouse / "IMAC-292463" / "11" / "IMAC" / ".stow-notes.md")
        write(self.worktree_stow_notes, "worktree notes\n")
        write(self.treehouse / "IMAC-292463" / "11" / "IMAC" / "journal" / "retro"
              / "2026-01-05-e-retro.md", plain("e"))

        # A second worktree root, holding a plain retro original.
        write(self.orca_worktrees / "IMAC-agy-quota-visibility" / "journal" / "retro"
              / "2026-01-06-f-retro.md", plain("f"))

        # A directory named retro whose parent is not journal must never be
        # discovered.
        write(self.canonical / "skill-store" / "packages" / "retro" / "SKILL.md", "# skill\n")

    def roots_args(self):
        return [
            "--root", "canonical=%s" % self.canonical,
            "--root", "runtime=%s" % self.runtime,
            "--root", "firstmate=%s" % self.firstmate,
            "--root", "orca=%s" % self.orca,
            "--worktree-root", "treehouse=%s" % self.treehouse,
            "--worktree-root", "orca-worktrees=%s" % self.orca_worktrees,
        ]

    def run_index(self, extra=()):
        command = [sys.executable, str(INDEX)] + self.roots_args() + list(extra)
        done = subprocess.run(command, capture_output=True, text=True, check=False)
        return done


class OriginalsIndexTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="fm-originals-index.")
        self.addCleanup(self._tmp.cleanup)
        # macOS resolves TMPDIR through /private, and the index reports
        # resolved paths, so the fixture is rooted at its realpath.
        self.base = Path(os.path.realpath(self._tmp.name))
        self.fixture = Fixture(self.base)
        self.result = self.full()
        self.summary = self.result

    def full(self):
        done = self.fixture.run_index()
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def collected_paths(self, result=None):
        result = result or self.full()
        return {entry["relpath"] for entry in result["files"]}

    # --- discovery contract -------------------------------------------------

    def test_allowlist_and_worktree_roots_are_all_discovered(self):
        totals = self.summary["totals"]
        # canonical: 1 stow + 1 md + 1 jsonl; runtime: 1 md; firstmate: 1 stow
        # + 1 md; orca: 1 stow + 1 md + 1 worktree md; treehouse: 1 stow + 1 md;
        # orca-worktrees: 1 md. The non-journal skill-store/packages/retro file
        # is not an original.
        self.assertEqual(totals["discovered"], 12)
        self.assertEqual(totals["collected"], 12)
        self.assertEqual(totals["excluded"], 0)
        self.assertEqual(totals["file_units"], 12)

    def test_every_root_is_reported_with_its_kind(self):
        kinds = {spec["name"]: spec["kind"] for spec in self.summary["roots"]}
        self.assertEqual(kinds, {
            "canonical": "allowlist", "runtime": "allowlist",
            "firstmate": "allowlist", "orca": "allowlist",
            "treehouse": "worktree", "orca-worktrees": "worktree",
        })
        for spec in self.summary["roots"]:
            self.assertTrue(spec["present"], spec["name"])

    def test_allowlist_root_nested_under_a_worktree_root_is_scanned_once(self):
        # orca is both an allowlist root and a child of the orca-worktrees
        # worktree root; pruning by resolved path keeps one unit per file.
        per_root = self.summary["per_root"]
        self.assertEqual(per_root["orca"]["collected"], 3)
        self.assertEqual(per_root["orca-worktrees"]["collected"], 1)
        self.assertEqual(per_root["orca-worktrees"]["exclusion_reasons"].get("duplicate-realpath", 0), 0)

    def test_non_journal_retro_directory_is_never_discovered(self):
        self.assertNotIn("skill-store/packages/retro/SKILL.md", self.collected_paths())

    def test_depth_bound_is_enforced(self):
        deep = (self.fixture.canonical / "deep" / "a" / "b" / "c" / "d" / "e" / "f" / "g"
                / "journal" / "retro" / "deep-retro.md")
        write(deep, plain("deep"))
        shallow = (self.fixture.canonical / "shallow" / "journal" / "retro" / "shallow-retro.md")
        write(shallow, plain("shallow"))
        paths = self.collected_paths()
        self.assertIn("shallow/journal/retro/shallow-retro.md", paths)
        self.assertNotIn("deep/a/b/c/d/e/f/g/journal/retro/deep-retro.md", paths)

    # --- the two real omissions --------------------------------------------

    def test_worktree_stow_notes_omission_is_resolved(self):
        canonical = str(self.fixture.canonical)
        old = old_contract_scan(canonical, [str(self.fixture.orca), str(self.fixture.firstmate)])
        target = str(self.fixture.worktree_stow_notes)
        self.assertNotIn(target, old)  # old code: FAIL to discover
        result = self.full()
        collected = {entry["realpath"] for entry in result["files"]}
        self.assertIn(str(self.fixture.worktree_stow_notes.resolve()), collected)  # new code: PASS
        entry = next(e for e in result["files"]
                     if e["realpath"] == str(self.fixture.worktree_stow_notes.resolve()))
        self.assertEqual(entry["kind"], "stow-notes")
        self.assertEqual(entry["root"], "treehouse")
        self.assertEqual(entry["relpath"], "IMAC-292463/11/IMAC/.stow-notes.md")

    def test_orca_worktree_retro_omission_is_resolved(self):
        canonical = str(self.fixture.canonical)
        old = old_contract_scan(canonical, [str(self.fixture.orca), str(self.fixture.firstmate)])
        target = str(self.fixture.orca_worktree_record)
        self.assertNotIn(target, old)  # old code: FAIL to discover
        result = self.full()
        collected = {entry["realpath"] for entry in result["files"]}
        self.assertIn(str(self.fixture.orca_worktree_record.resolve()), collected)  # new code: PASS
        entry = next(e for e in result["files"]
                     if e["realpath"] == str(self.fixture.orca_worktree_record.resolve()))
        self.assertEqual(entry["root"], "orca")
        self.assertEqual(entry["relpath"],
                         ".worktrees/disk-cleanup-active/journal/retro/"
                         "2026-09-11-sunday-doctrine-audit-candidates.md")

    def test_real_old_collectors_miss_the_same_two_cases(self):
        retro_module = OLD_ROOT / "AutomationSync" / "retro_doctrine_autolink.py"
        merge_module = OLD_ROOT / "pipelines" / "misc-check" / "stow_notes_merge.py"
        if not retro_module.is_file() or not merge_module.is_file():
            print("skip: live: canonical old collector not found at %s" % OLD_ROOT)
            self.skipTest("canonical old collector not found")

        probe = r'''
import json, sys
from pathlib import Path
root, canonical, orca, firstmate = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
sys.path.insert(0, str(Path(root) / "AutomationSync"))
sys.path.insert(0, str(Path(root) / "pipelines" / "misc-check"))
import retro_doctrine_autolink as rda
import stow_notes_merge as snm
retro = rda.sync_retro_stow_candidates(
    doctrine_file=canonical / "doctrine.md", root_dir=canonical, dry_run=True)
stow = snm.merge_stow_notes(canonical_root=canonical, clone_roots=(orca, firstmate),
                            today="2026-10-11", archive_sources=False)
print(json.dumps({
    "retro_titles": [c["title"] for c in retro["new_candidates"]],
    "stow_sources": [m["source"] for m in stow["merged_from"]],
}))
'''
        done = subprocess.run(
            [sys.executable, "-c", probe, str(OLD_ROOT), str(self.fixture.canonical),
             str(self.fixture.orca), str(self.fixture.firstmate)],
            capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        observed = json.loads(done.stdout)

        # The real retro collector never sees the orca-worktree candidate.
        self.assertIn("Alpha", observed["retro_titles"])
        self.assertNotIn("SundayDoctrine", observed["retro_titles"])
        # The real stow merger never sees the worktree .stow-notes.md.
        self.assertEqual(sorted(observed["stow_sources"]),
                         sorted([str(self.fixture.orca / ".stow-notes.md"),
                                 str(self.fixture.firstmate / ".stow-notes.md")]))
        self.assertNotIn(str(self.fixture.worktree_stow_notes), observed["stow_sources"])

    # --- validation, de-duplication, provenance -----------------------------

    def test_symlink_boundary_validation(self):
        escaping = self.fixture.canonical / "journal" / "retro" / "escapes-retro.md"
        escaping.symlink_to(self.fixture.treehouse / "IMAC-292463" / "11" / "IMAC"
                            / ".stow-notes.md")
        broken = self.fixture.canonical / "journal" / "retro" / "broken-retro.md"
        broken.symlink_to(self.fixture.canonical / "journal" / "retro" / "gone.md")
        inside = self.fixture.canonical / "journal" / "retro" / "inside-retro.md"
        inside.symlink_to(self.fixture.canonical / "journal" / "retro" / "2026-01-01-a-retro.md")
        result = self.full()
        reasons = {item["path"]: item["reason"] for item in result["excluded"]}
        self.assertEqual(reasons[str(escaping)], "symlink-escapes-root")
        self.assertEqual(reasons[str(broken)], "broken-symlink")
        # A link that stays inside its root resolves to the same realpath as its
        # target, so it is one file unit and the link is the duplicate.
        self.assertEqual(reasons[str(inside)], "duplicate-realpath")
        self.assertEqual(result["totals"]["realpath_duplicates"], 1)
        self.assertEqual(result["totals"]["excluded"], 3)
        inside_realpath = str(inside.resolve())
        matching = [e for e in result["files"] if e["realpath"] == inside_realpath]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["relpath"], "journal/retro/2026-01-01-a-retro.md")

    def test_byte_identical_copies_are_duplicates_of_one_record(self):
        copy = self.fixture.treehouse / "IMAC-292463" / "11" / "IMAC" / "journal" / "retro" / "copy-retro.md"
        copy.write_text(plain("c"), encoding="utf-8")
        result = self.full()
        original = next(e for e in result["files"]
                        if e["relpath"] == "journal/retro/2026-01-03-c-retro.md")
        duplicate = next(e for e in result["files"] if e["relpath"].endswith("copy-retro.md"))
        self.assertEqual(original["sha256"], duplicate["sha256"])
        self.assertEqual(original["duplicate_group"], duplicate["duplicate_group"])
        self.assertIsNone(original["duplicate_of"])
        self.assertEqual(duplicate["duplicate_of"], original["realpath"])
        self.assertEqual(result["totals"]["file_units"], 13)
        self.assertEqual(result["totals"]["duplicate_copies"], 1)
        self.assertEqual(result["totals"]["unique_contents"], 12)

    def test_distinct_records_are_not_reported_as_copies(self):
        result = self.full()
        groups = {}
        for entry in result["files"]:
            groups.setdefault(entry["sha256"], []).append(entry["relpath"])
        for relpaths in groups.values():
            if len(relpaths) > 1:
                self.fail("unexpected duplicate group: %s" % relpaths)
        self.assertEqual(result["totals"]["duplicate_copies"], 0)

    # --- record units, siblings, marker contract ----------------------------

    def test_record_units_and_sibling_pairing(self):
        result = self.full()
        md = next(e for e in result["files"]
                  if e["relpath"] == "journal/retro/2026-01-01-a-retro.md")
        jsonl = next(e for e in result["files"]
                     if e["relpath"] == "journal/retro/2026-01-01-a-retro.jsonl")
        self.assertEqual(md["record_units"], 1)
        self.assertEqual(jsonl["record_units"], len(JSONL_LINES))
        self.assertEqual(md["sibling"], jsonl["relpath"])
        self.assertEqual(jsonl["sibling"], md["relpath"])
        self.assertEqual(result["sibling_groups"], [{
            "root": "canonical", "directory": "journal/retro",
            "stem": "2026-01-01-a-retro",
            "md": md["relpath"], "jsonl": jsonl["relpath"],
        }])
        # One file unit, five record units: the file/record relationship the
        # aggregation must keep separate.
        self.assertEqual(result["totals"]["file_units"], 12)
        self.assertEqual(result["totals"]["record_units"], 12 + len(JSONL_LINES) - 1)

    def test_markerless_records_stay_raw_evidence_and_unpromotable(self):
        result = self.full()
        records = [record for entry in result["files"] for record in entry["records"]]
        for record in records:
            self.assertEqual(record["auto_promotable"], record["marker_state"] == "candidate",
                             record["record_id"])
        states = {}
        for record in records:
            states.setdefault(record["marker_state"], []).append(record)
        raw = states["raw-evidence"]
        self.assertTrue(raw)
        for record in raw:
            self.assertFalse(record["auto_promotable"])
            self.assertEqual(record["marker_kind"], "")
        candidates = states["candidate"]
        self.assertEqual(sorted(r["marker_kind"] for r in candidates),
                         ["## 후보 제안", "## 후보 제안", "doctrine_candidate",
                          "is_candidate", "lane"])
        self.assertEqual(result["totals"]["candidate_records"], 5)
        self.assertEqual(result["totals"]["raw_evidence_records"],
                         12 + len(JSONL_LINES) - 1 - 5)

    def test_promotable_states_owner_refuses_every_other_state(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("fm_originals_index", INDEX)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.PROMOTABLE_STATES, {"candidate"})
        self.assertTrue(module.is_promotable({"marker_state": "candidate"}))
        for state in ("raw-evidence", "", "RAW-EVIDENCE", "candidate-ish", None):
            self.assertFalse(module.is_promotable({"marker_state": state}), repr(state))
        self.assertFalse(module.is_promotable({}))

    # --- mechanical aggregation --------------------------------------------

    def test_aggregation_is_mechanical_and_adds_up(self):
        result = self.full()
        totals = result["totals"]
        discovered = sum(row["discovered"] for row in result["per_root"].values())
        collected = sum(row["collected"] for row in result["per_root"].values())
        excluded = sum(row["excluded"] for row in result["per_root"].values())
        self.assertEqual(discovered, totals["discovered"])
        self.assertEqual(collected, totals["collected"])
        self.assertEqual(excluded, totals["excluded"])
        self.assertEqual(discovered, collected + excluded)
        self.assertEqual(collected, totals["file_units"])
        self.assertEqual(len(result["excluded"]), totals["excluded"])
        for row in result["per_root"].values():
            self.assertEqual(row["discovered"], row["collected"] + row["excluded"], row["path"])
            self.assertEqual(sum(row["exclusion_reasons"].values()), row["excluded"], row["path"])
        self.assertEqual(totals["unique_contents"] + totals["duplicate_copies"], totals["file_units"])
        self.assertEqual(totals["unique_record_contents"] + totals["duplicate_record_copies"],
                         totals["record_units"])
        self.assertEqual(totals["candidate_records"] + totals["raw_evidence_records"],
                         totals["record_units"])

    def test_exclusion_ledger_carries_a_reason_per_excluded_path(self):
        escaping = self.fixture.canonical / "journal" / "retro" / "escapes-retro.md"
        escaping.symlink_to("/etc/hosts")
        result = self.full()
        self.assertEqual(result["excluded"], [{
            "path": str(escaping), "root": "canonical", "reason": "symlink-escapes-root",
        }])
        self.assertEqual(result["per_root"]["canonical"]["exclusion_reasons"],
                         {"symlink-escapes-root": 1})

    # --- indexing is not mutation ------------------------------------------

    def test_indexing_never_changes_an_original(self):
        before = snapshot(self.fixture.base)
        self.fixture.run_index(["--summary-only"])
        self.fixture.run_index()
        self.assertEqual(snapshot(self.fixture.base), before)

    # --- process contract ---------------------------------------------------

    def test_missing_root_is_reported_and_not_fatal(self):
        done = self.fixture.run_index(["--summary-only", "--root", "gone=%s/gone" % self.fixture.base])
        self.assertEqual(done.returncode, 0, done.stderr)
        result = json.loads(done.stdout)
        self.assertFalse(result["per_root"]["gone"]["present"])
        self.assertEqual(result["per_root"]["gone"]["discovered"], 0)

    def test_no_present_root_exits_three(self):
        done = subprocess.run(
            [sys.executable, str(INDEX), "--no-worktree-root",
             "--root", "gone=%s/gone" % self.fixture.base],
            capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 3)
        self.assertIn("none of the configured roots exist", done.stderr)

    def test_invalid_use_exits_two(self):
        for argv in (["--root", "nonsense"], ["--bogus"],
                     ["--root", "a=/x", "--root", "a=/y", "--no-worktree-root"],
                     ["--max-depth", "0"]):
            done = subprocess.run([sys.executable, str(INDEX)] + argv,
                                  capture_output=True, text=True, check=False)
            self.assertEqual(done.returncode, 2, argv)
            self.assertTrue(done.stderr.startswith("error: "), argv)

    def test_help_prints_the_contract_and_exits_zero(self):
        done = subprocess.run([sys.executable, str(INDEX), "--help"],
                              capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 0)
        self.assertIn("fm-originals-index.py - read-only discovery", done.stdout)
        self.assertIn("Exit status: 0 indexed; 2 invalid use; 3 no configured root exists.",
                      done.stdout)

    def test_summary_only_omits_the_per_file_detail(self):
        done = self.fixture.run_index(["--summary-only"])
        self.assertEqual(done.returncode, 0, done.stderr)
        summary = json.loads(done.stdout)
        self.assertNotIn("files", summary)
        self.assertIn("per_root", summary)
        self.assertIn("excluded", summary)
        self.assertEqual(summary["totals"], self.result["totals"])


def snapshot(base):
    """Content and mtime identity of every path under <base>."""
    state = {}
    for dirpath, dirnames, filenames in os.walk(base):
        for name in sorted(dirnames) + sorted(filenames):
            path = os.path.join(dirpath, name)
            info = os.lstat(path)
            digest = ""
            if os.path.isfile(path) and not os.path.islink(path):
                digest = hashlib.sha256(Path(path).read_bytes()).hexdigest()
            state[os.path.relpath(path, base)] = (info.st_mtime_ns, info.st_size, digest)
    return state


if __name__ == "__main__":
    unittest.main(verbosity=2)
