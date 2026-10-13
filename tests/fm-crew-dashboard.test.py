#!/usr/bin/env python3
"""Regression tests for bin/fm-crew-dashboard.py.

Covers the two confirmed dashboard defects:
  * lanes must report liveness (live / dead / unknown) so a recorded-but-gone
    session is never counted as an open one;
  * snap() must be cached in-process with single-flight de-duplication, and
    every response must say whether it is fresh, stale, or the last good data
    after a failed refresh.

Runs with no network, no real backend, and no real crew state: the crew-state
subprocesses are faked and the fixtures live in a temporary directory.
"""
import importlib.util
import json
import os
import shutil
import socketserver
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

READER_PATH = Path(__file__).parents[1] / "bin" / "fm-crew-dashboard.py"
SPEC = importlib.util.spec_from_file_location("fm_crew_dashboard", READER_PATH)
DASH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DASH)

SNAP_ZERO = {"lanes": None, "ok": False, "error": "", "computed_at": 0.0,
             "checked_at": 0.0, "refreshing": False}

# The exact fm-crew-state.sh lines the captain's report measured on the live
# fleet, plus two of the six it reported as "state: unknown".
MEASURED_DEAD_LINES = [
    "state: unknown \u00b7 source: none \u00b7 backend target gone: default:w1:p1K",
    "state: unknown \u00b7 source: none \u00b7 backend target gone: default:w1:p1J",
    "state: unknown \u00b7 source: none \u00b7 backend target gone: default:w1T:p2",
    "state: unknown \u00b7 source: none \u00b7 backend target gone: default:w1G:p2",
]
MEASURED_UNKNOWN_LINES = [
    "state: unknown \u00b7 source: run-step \u00b7 selected run code identity unverified; run ids: 01M4JR8HKC8B15EX5T1WQ6D980",
    "state: unknown \u00b7 source: run-step \u00b7 outcome: passed-with-override \u00b7 status-log superseded (run unknown) \u00b7 run: 01M4JJ8BPFHV0BMRAYCKDE542F",
]
LIVE_LINE = "state: working \u00b7 source: pane \u00b7 harness busy (native record)"
TERMINAL_LINE = "state: failed \u00b7 source: run-step \u00b7 run failed \u00b7 run: 01M4JJ5BY2SSP1MV659QP2FVZ0"

# The state line the faked fm-crew-state.sh returns. A dict rather than a global
# so a test can swap it without a `global` statement.
FAKE = {"state_line": LIVE_LINE}


def fake_run(cmd, **_kw):
    """Stand in for the three subprocesses _lane makes, keyed on the command."""
    name = os.path.basename(cmd[0])
    if name == "fm-crew-state.sh":
        return SimpleNamespace(stdout=FAKE["state_line"] + "\n", returncode=0)
    if name == "fm-peek.sh":
        return SimpleNamespace(stdout="pane output\n", returncode=0)
    return SimpleNamespace(stdout="abc1234|1700000000\n", returncode=0)


def reset_cache():
    DASH._SNAP.update(SNAP_ZERO)


class DashboardTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fm-dashboard-test.")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        self.backlog = os.path.join(self.tmp, "backlog.md")
        Path(self.backlog).write_text(
            "## In flight\n"
            "- [ ] alpha-1 - First task (repo: demo)\n"
            "- [ ] beta-2 - Second task (repo: demo) (kind: ship)\n"
            "## Queued\n"
            "- [ ] gamma-3 - Third task (repo: demo)\n"
            "## Done\n"
            "- [x] done-9 - Already finished (repo: demo)\n",
            encoding="utf-8")
        self._saved = (DASH.STATE, DASH.BACKLOG, DASH._SNAP_TTL,
                       DASH._refresh_lanes, DASH._lane, DASH.endpoint_states)
        DASH.STATE = self.state
        DASH.BACKLOG = self.backlog
        DASH._SNAP_TTL = 5.0
        reset_cache()
        self.servers = []

    def tearDown(self):
        for srv in self.servers:
            srv.shutdown()
            srv.server_close()
        (DASH.STATE, DASH.BACKLOG, DASH._SNAP_TTL,
         DASH._refresh_lanes, DASH._lane, DASH.endpoint_states) = self._saved
        reset_cache()
        shutil.rmtree(self.tmp, ignore_errors=True)

    # --- fixture helpers ----------------------------------------------------

    def write_meta(self, task_id, backend="herdr", window="default:w1:p1", harness="opencode"):
        Path(os.path.join(self.state, f"{task_id}.meta")).write_text(
            f"worktree={self.tmp}/wt\nharness={harness}\nbackend={backend}\n"
            f"window={window}\nkind=ship\n", encoding="utf-8")

    def start_server(self):
        socketserver.ThreadingTCPServer.allow_reuse_address = True
        srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), DASH.H)
        srv.daemon_threads = True
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.servers.append(srv)
        return srv.server_address[1]

    def get(self, port, path):
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=60) as resp:
            return resp.status, resp.headers, resp.read()


class FmHomeResolutionTest(unittest.TestCase):
    """FM must track FM_HOME and default to this checkout, never a fixed path."""

    def load_fm(self, fm_home):
        env = dict(os.environ)
        env.pop("FM_HOME", None)
        if fm_home is not None:
            env["FM_HOME"] = fm_home
        spec = importlib.util.spec_from_file_location("fm_crew_dashboard_reload", READER_PATH)
        module = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, env, clear=True):
            spec.loader.exec_module(module)
        return module.FM

    def test_fm_home_selects_the_operational_home(self):
        home = tempfile.mkdtemp(prefix="fm-home.")
        self.addCleanup(shutil.rmtree, home, ignore_errors=True)
        self.assertEqual(self.load_fm(home), home)

    def test_fm_defaults_to_this_checkout(self):
        self.assertEqual(self.load_fm(None), str(READER_PATH.resolve().parent.parent))


class LivenessClassificationTest(DashboardTestCase):
    """A gone session must classify dead; a live one must not be misclassified."""

    def test_measured_gone_lanes_are_dead(self):
        for line in MEASURED_DEAD_LINES:
            self.assertEqual(DASH.classify_liveness(line, "missing"), (DASH.DEAD, "endpoint missing"), line)
            self.assertEqual(DASH.liveness_from_state_line(line)[0], DASH.DEAD, line)

    def test_measured_unknown_lanes_are_not_open(self):
        for line in MEASURED_UNKNOWN_LINES:
            self.assertEqual(DASH.classify_liveness(line, "missing")[0], DASH.DEAD, line)
            self.assertEqual(DASH.classify_liveness(line, "")[0], DASH.UNKNOWN, line)

    def test_live_line_is_live_without_a_probe(self):
        self.assertEqual(DASH.liveness_from_state_line(LIVE_LINE),
                         (DASH.LIVE, "harness busy (native record)"))
        self.assertEqual(DASH.classify_liveness(LIVE_LINE, "alive"),
                         (DASH.LIVE, "harness busy (native record)"))
        # an unreadable probe must not demote a lane the state line proves active
        self.assertEqual(DASH.classify_liveness(LIVE_LINE, "unreadable")[0], DASH.LIVE)

    def test_endpoint_verdict_overrides_a_terminal_state_word(self):
        # A finished run keeps reporting `failed` after its pane is gone, so the
        # endpoint read has to win or the dead session counts as open.
        self.assertEqual(DASH.classify_liveness(TERMINAL_LINE, "missing")[0], DASH.DEAD)
        self.assertEqual(DASH.classify_liveness(TERMINAL_LINE, "dead")[0], DASH.DEAD)
        # without a probe verdict the terminal word is not proof of presence
        self.assertEqual(DASH.classify_liveness(TERMINAL_LINE, "")[0], DASH.UNKNOWN)

    def test_absent_records_are_dead(self):
        for line in ("state: unknown \u00b7 source: none \u00b7 worktree gone (torn down?)",
                     "state: unknown \u00b7 source: none \u00b7 no backend target recorded",
                     "state: unknown \u00b7 source: none \u00b7 no metadata for ghost"):
            self.assertEqual(DASH.liveness_from_state_line(line)[0], DASH.DEAD, line)

    def test_missing_state_line_is_unknown(self):
        self.assertEqual(DASH.classify_liveness("", ""), (DASH.UNKNOWN, "no state line"))


class LaneFieldTest(DashboardTestCase):
    """_lane must carry the verdict, and never drop the record."""

    def setUp(self):
        super().setUp()
        self.write_meta("gone-task")
        Path(os.path.join(self.state, "gone-task.status")).write_text("working: did work\n", encoding="utf-8")
        self.meta = os.path.join(self.state, "gone-task.meta")
        self.saved_line = FAKE["state_line"]
        self.addCleanup(lambda: FAKE.update(state_line=self.saved_line))

    def lane(self, endpoint):
        with mock.patch.object(DASH, "subprocess", SimpleNamespace(run=fake_run)):
            return DASH._lane(self.meta, 0, {}, endpoint)

    def test_terminal_state_word_with_a_missing_endpoint_is_dead(self):
        FAKE["state_line"] = TERMINAL_LINE
        lane = self.lane("missing")
        self.assertEqual(lane["id"], "gone-task")
        self.assertEqual(lane["liveness"], DASH.DEAD)
        self.assertEqual(lane["liveness_reason"], "endpoint missing")
        self.assertEqual(lane["endpoint"], "missing")
        # the record itself is still served, so the operator sees the task
        self.assertIn("run failed", lane["state"])

    def test_alive_endpoint_is_live(self):
        lane = self.lane("alive")
        self.assertEqual(lane["liveness"], DASH.LIVE)
        self.assertEqual(lane["endpoint"], "alive")

    def test_unknown_state_line_with_no_probe_is_unknown(self):
        FAKE["state_line"] = MEASURED_UNKNOWN_LINES[0]
        lane = self.lane("")
        self.assertEqual(lane["liveness"], DASH.UNKNOWN)
        self.assertEqual(lane["endpoint"], "")

    def test_unreadable_probe_keeps_an_active_state_live(self):
        lane = self.lane("unreadable")
        self.assertEqual(lane["liveness"], DASH.LIVE)


class CacheTest(DashboardTestCase):
    """TTL, single flight, staleness, failure, and lane-change reflection."""

    def stub_refresh(self, delay=0.0, fail=False, hold=None):
        calls = []

        def refresh():
            calls.append(time.time())
            if hold is not None:
                hold.wait(20)
            if delay:
                time.sleep(delay)
            if fail:
                raise RuntimeError("boom")
            return [{"id": f"lane-{len(calls)}", "liveness": DASH.LIVE}]

        DASH._refresh_lanes = refresh
        return calls

    def test_second_call_within_ttl_is_served_from_cache(self):
        calls = self.stub_refresh()
        lanes1, meta1 = DASH.snap()
        lanes2, meta2 = DASH.snap()
        self.assertEqual(len(calls), 1, "a second call inside the TTL must not recompute")
        self.assertEqual(meta1["status"], "fresh")
        self.assertEqual(meta2["status"], "fresh")
        self.assertEqual(lanes1, lanes2)

    def test_cache_expiry_triggers_exactly_one_new_refresh(self):
        calls = self.stub_refresh()
        DASH.snap()
        DASH._SNAP["checked_at"] -= DASH._SNAP_TTL + 1
        DASH.snap()
        DASH.snap()
        self.assertEqual(len(calls), 2)

    def test_stamp_is_taken_after_a_slow_refresh(self):
        # The original bug: the cache stamp was captured BEFORE the read, so a
        # read slower than the TTL was born expired and every request recomputed.
        self.stub_refresh(delay=0.05)
        DASH._SNAP_TTL = 0.01
        DASH.snap()
        _, meta = DASH.snap()
        self.assertEqual(meta["status"], "fresh")
        self.assertLess(meta["age"], 0.05, "the snapshot must not be born stale")

    def test_concurrent_callers_share_one_refresh(self):
        calls = self.stub_refresh(delay=0.3)
        results, lock = [], threading.Lock()

        def worker():
            lanes, meta = DASH.snap()
            with lock:
                results.append((tuple(sorted(l["id"] for l in lanes)), meta["status"]))

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(30)
        self.assertEqual(len(calls), 1, "concurrent misses must collapse onto one refresh")
        self.assertEqual(len(results), 8)
        self.assertEqual(len({r[0] for r in results}), 1, "every caller must see the same lanes")

    def test_request_during_a_refresh_is_labelled_stale(self):
        self.stub_refresh()
        DASH.snap()
        first = list(DASH._SNAP["lanes"])
        hold = threading.Event()
        self.stub_refresh(hold=hold)
        DASH._SNAP["checked_at"] -= DASH._SNAP_TTL + 1
        t = threading.Thread(target=DASH.snap)
        t.start()
        deadline = time.time() + 10
        while not DASH._SNAP["refreshing"] and time.time() < deadline:
            time.sleep(0.005)
        self.assertTrue(DASH._SNAP["refreshing"], "the refresh must be running")
        lanes, meta = DASH.snap()
        hold.set()
        t.join(30)
        self.assertEqual(meta["status"], "stale", "a response served during a refresh must say so")
        self.assertEqual(lanes, first)
        self.assertTrue(meta["refreshing"])
        self.assertGreaterEqual(meta["age"], 0.0)

    def test_refresh_failure_is_reported_and_never_presented_as_current(self):
        self.stub_refresh()
        good, _ = DASH.snap()
        self.stub_refresh(fail=True)
        DASH._SNAP["checked_at"] -= DASH._SNAP_TTL + 1
        lanes, meta = DASH.snap()
        self.assertEqual(meta["status"], "error")
        self.assertIn("boom", meta["error"])
        self.assertEqual(lanes, good, "the last good lanes are still served")
        self.assertFalse(meta["refreshing"])
        _, meta2 = DASH.snap()
        self.assertEqual(meta2["status"], "error")
        self.assertIn("boom", meta2["error"])

    def test_failure_before_any_success_serves_no_lanes_and_says_why(self):
        self.stub_refresh(fail=True)
        lanes, meta = DASH.snap()
        self.assertEqual(lanes, [])
        self.assertEqual(meta["status"], "error")
        self.assertEqual(meta["age"], -1.0)

    def test_lane_change_is_reflected_after_expiry(self):
        self.write_meta("alpha-1")
        with mock.patch.object(DASH, "endpoint_states", return_value={"alpha-1": "alive"}), \
             mock.patch.object(DASH, "subprocess", SimpleNamespace(run=fake_run)):
            lanes, _ = DASH.snap()
            self.assertEqual([l["id"] for l in lanes], ["alpha-1"])
            self.assertEqual(lanes[0]["liveness"], DASH.LIVE)
            self.write_meta("beta-2")
            DASH._SNAP["checked_at"] -= DASH._SNAP_TTL + 1
            lanes, _ = DASH.snap()
            self.assertEqual([l["id"] for l in lanes], ["alpha-1", "beta-2"])
            os.remove(os.path.join(self.state, "beta-2.meta"))
            DASH._SNAP["checked_at"] -= DASH._SNAP_TTL + 1
            lanes, _ = DASH.snap()
            self.assertEqual([l["id"] for l in lanes], ["alpha-1"])


class HttpRouteTest(DashboardTestCase):
    """Routes, freshness headers, id-set completeness, and restart behaviour."""

    def setUp(self):
        super().setUp()
        self.write_meta("alpha-1")
        self.write_meta("beta-2")
        self.write_meta("ghost-7")
        self.calls = []
        self.install_refresh(self.three_lanes)

    def three_lanes(self):
        self.calls.append(time.time())
        return [
            {"id": "alpha-1", "liveness": DASH.LIVE, "liveness_reason": "endpoint alive", "endpoint": "alive"},
            {"id": "beta-2", "liveness": DASH.DEAD, "liveness_reason": "endpoint missing", "endpoint": "missing"},
            {"id": "ghost-7", "liveness": DASH.UNKNOWN, "liveness_reason": "no state line", "endpoint": ""},
        ]

    def install_refresh(self, fn):
        def refresh():
            return fn()
        DASH._refresh_lanes = refresh

    def test_data_headers_are_present_and_lanes_are_complete(self):
        port = self.start_server()
        status, headers, body = self.get(port, "/data")
        self.assertEqual(status, 200)
        self.assertEqual(headers["X-Snap-Status"], "fresh")
        self.assertGreaterEqual(float(headers["X-Snap-Age"]), 0.0)
        self.assertEqual(headers["X-Snap-Refreshing"], "false")
        self.assertEqual(headers["X-Snap-Ttl"], "5.000")
        self.assertEqual(headers["Cache-Control"], "no-store")
        lanes = json.loads(body)
        ids = [lane["id"] for lane in lanes]
        # server-side set comparison against the source meta files: no loss, no
        # duplication, and nothing dropped for being dead
        self.assertEqual(sorted(ids), ["alpha-1", "beta-2", "ghost-7"])
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual({lane["liveness"] for lane in lanes}, {DASH.LIVE, DASH.DEAD, DASH.UNKNOWN})
        for lane in lanes:
            self.assertIn("liveness_reason", lane)
            self.assertIn("endpoint", lane)

    def test_tasks_ids_and_live_flag_come_from_liveness(self):
        port = self.start_server()
        status, headers, body = self.get(port, "/tasks")
        self.assertEqual(status, 200)
        self.assertEqual(headers["X-Snap-Status"], "fresh")
        tasks = json.loads(body)
        ids = [t["id"] for t in tasks]
        # the fixture's three open items, in order; the Done item must not appear
        self.assertEqual(ids, ["alpha-1", "beta-2", "gamma-3"])
        self.assertEqual(len(ids), len(set(ids)))
        by_id = {t["id"]: t for t in tasks}
        self.assertTrue(by_id["alpha-1"]["live"])
        self.assertEqual(by_id["alpha-1"]["liveness"], DASH.LIVE)
        self.assertFalse(by_id["beta-2"]["live"], "a dead session must not read as live")
        self.assertEqual(by_id["beta-2"]["liveness"], DASH.DEAD)
        self.assertTrue(by_id["beta-2"]["has_record"], "the task record is still visible")
        self.assertFalse(by_id["gamma-3"]["live"])
        self.assertFalse(by_id["gamma-3"]["has_record"])
        self.assertEqual(by_id["gamma-3"]["liveness"], DASH.UNKNOWN)

    def test_concurrent_http_requests_do_not_recompute(self):
        def slow():
            self.calls.append(time.time())
            time.sleep(0.3)
            return [{"id": "alpha-1", "liveness": DASH.LIVE}]

        self.install_refresh(slow)
        port = self.start_server()
        results, lock = [], threading.Lock()

        def hit(path):
            status, headers, body = self.get(port, path)
            with lock:
                results.append((path, status, headers["X-Snap-Status"], body))

        threads = [threading.Thread(target=hit, args=(p,))
                   for p in ("/data", "/tasks", "/data", "/tasks", "/data", "/tasks")]
        for t in threads:
            t.start()
        for t in threads:
            t.join(60)
        self.assertEqual(len(self.calls), 1, "six concurrent requests must share one refresh")
        self.assertEqual(len(results), 6)
        for _path, status, snap_status, body in results:
            self.assertEqual(status, 200)
            self.assertIn(snap_status, ("fresh", "stale"))
            self.assertIn(b"alpha-1", body)

    def test_restart_starts_cold(self):
        port = self.start_server()
        self.get(port, "/data")
        self.get(port, "/data")
        self.assertEqual(len(self.calls), 1, "a warm server must serve from cache")
        for srv in self.servers:
            srv.shutdown()
            srv.server_close()
        self.servers = []
        reset_cache()  # what a restart leaves behind: no in-process snapshot
        port2 = self.start_server()
        status, headers, body = self.get(port2, "/data")
        self.assertEqual(status, 200)
        self.assertEqual(len(self.calls), 2, "a restarted server must fetch again")
        self.assertEqual(headers["X-Snap-Status"], "fresh")
        self.assertEqual([lane["id"] for lane in json.loads(body)],
                         ["alpha-1", "beta-2", "ghost-7"])

    def test_refresh_failure_is_visible_over_http(self):
        self.get(self.start_server(), "/data")
        self.assertEqual(len(self.calls), 1)

        def boom():
            self.calls.append(time.time())
            raise RuntimeError("upstream read failed")

        self.install_refresh(boom)
        DASH._SNAP["checked_at"] -= DASH._SNAP_TTL + 1
        status, headers, body = self.get(self.start_server(), "/data")
        self.assertEqual(status, 200)
        self.assertEqual(headers["X-Snap-Status"], "error")
        self.assertIn("upstream read failed", headers["X-Snap-Error"])
        self.assertEqual([lane["id"] for lane in json.loads(body)],
                         ["alpha-1", "beta-2", "ghost-7"])


class EndpointProbeTest(DashboardTestCase):
    """The fleet-wide endpoint probe degrades safely."""

    def test_no_targets_is_an_empty_probe(self):
        self.assertEqual(DASH.endpoint_states([]), {})
        self.assertEqual(DASH.endpoint_states([("a", "herdr", "")]), {})

    def test_probe_failure_is_empty_not_death(self):
        with mock.patch.object(DASH, "subprocess", SimpleNamespace(run=mock.Mock(side_effect=OSError("no bash")))):
            self.assertEqual(DASH.endpoint_states([("a", "herdr", "default:w1:p1")]), {})

    def test_probe_parses_verdicts(self):
        fake = SimpleNamespace(run=mock.Mock(return_value=SimpleNamespace(
            stdout="a\talive\nb\tmissing\n", returncode=0)))
        with mock.patch.object(DASH, "subprocess", fake):
            self.assertEqual(DASH.endpoint_states([("a", "herdr", "t1"), ("b", "tmux", "t2")]),
                             {"a": "alive", "b": "missing"})


class ToonParseTest(unittest.TestCase):
    """The parser is pinned to `tasks-axi list`'s real TOON output shape."""

    # Verbatim output of
    #   bin/fm-tasks-axi.sh list --state held --limit 3 --fields priority,hold_reason,hold_until
    # (three rows, trimmed to two for the fixture), plus one row from the real
    # in_flight listing whose quoted title carries commas and the CLI's inline
    # `\n... (truncated, N chars total ...)` marker.
    MEASURED_HELD_TOON = (
        "count: 2 of 8 total\n"
        "tasks[2]{id,state,kind,repo,title,priority,hold_reason,hold_until}:\n"
        "  imac-voice-boundary-review-20260923,queued,scout,IMAC,Review voice interface status-only boundary,"
        "\"-\",캡틴 지시로 보류 2026-10-07 - 음성 인터페이스 경계 검토. 재개는 캡틴 지시 시.,2027-04-10\n"
        "  firstmate-ci-flake-watcher-lock-hup-20261007,queued,ship,firstmate,"
        "\"tests/fm-watcher-lock.test.sh times out\\n... (truncated, 318 chars total - use show "
        "firstmate-ci-flake-watcher-lock-hup-20261007 --full to see complete text)\",3,"
        "\"3회 실패 후 건너뜀 macOS Bash HUP 타임아웃 미해결\",\"-\"\n"
        "help[1]:\n"
        "  - Run `tasks-axi show <id>` for full notes on a task\n"
    )
    MEASURED_IN_FLIGHT_TOON = (
        "count: 1 of 9 total\n"
        "tasks[1]{id,state,kind,repo,title,priority}:\n"
        "  skill-usage-review-canonical-guard-20261013,in_flight,task,IMAC,"
        "\"skill-usage-review canonical 가드 실행 거부 수정 https://github.com/Ivory2024/IMAC/pull/\\n"
        "... (truncated, 83 chars total - use show skill-usage-review-canonical-guard-20261013 "
        "--full to see complete text)\",\"-\"\n"
    )

    def test_held_rows_parse_with_their_own_field_names(self):
        rows, total = DASH.parse_task_list(self.MEASURED_HELD_TOON)
        self.assertEqual(total, 8, "the CLI's own match count wins over the row cap")
        self.assertEqual(len(rows), 2)
        first = rows[0]
        self.assertEqual(first["id"], "imac-voice-boundary-review-20260923")
        self.assertEqual(first["repo"], "IMAC")
        self.assertEqual(first["priority"], "-", "a quoted dash must lose its quotes")
        self.assertEqual(first["hold_until"], "2027-04-10")
        self.assertIn("캡틴 지시로 보류", first["hold_reason"])
        # the CLI quotes this one, so its commas must not split the row
        self.assertIn("macOS Bash HUP 타임아웃 미해결", rows[1]["hold_reason"])
        self.assertEqual(rows[1]["priority"], "3")

    def test_a_quoted_value_keeps_its_commas_and_truncation_marker(self):
        rows, total = DASH.parse_task_list(self.MEASURED_IN_FLIGHT_TOON)
        self.assertEqual(total, 9)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["priority"], "-")
        self.assertIn("truncated, 83 chars total", rows[0]["title"])
        self.assertIn("Ivory2024/IMAC/pull/", rows[0]["title"])

    def test_help_lines_are_not_rows(self):
        rows, _ = DASH.parse_task_list(self.MEASURED_HELD_TOON)
        self.assertNotIn("help[1]:", [r.get("id") for r in rows])

    def test_empty_list_has_no_rows_and_a_zero_count(self):
        rows, total = DASH.parse_task_list(
            "count: 0\ntasks: 0 done repo=no-such-repo-xyz tasks in this backlog\n")
        self.assertEqual((rows, total), ([], 0))

    def test_a_count_without_a_total_is_the_total(self):
        _, total = DASH.parse_task_list("count: 100\ntasks[1]{id}:\n  a-1\n")
        self.assertEqual(total, 100)

    def test_garbage_and_none_are_not_rows(self):
        self.assertEqual(DASH.parse_task_list(""), ([], 0))
        self.assertEqual(DASH.parse_task_list(None), ([], 0))
        self.assertEqual(DASH.parse_task_list("error: boom\n")[0], [])


class QueueBoardTest(DashboardTestCase):
    """The board's section split, its row cap, and its freshness contract."""

    QUEUED = [
        {"id": "q-1", "title": "Queued plain", "repo": "firstmate", "priority": "1",
         "held": "no", "blocked": "no", "blocked_by": "none"},
        {"id": "q-2", "title": "Queued held", "repo": "firstmate", "priority": "2",
         "held": "yes", "blocked": "no", "blocked_by": "none"},
        {"id": "q-3", "title": "Queued blocked", "repo": "IMAC", "priority": "2",
         "held": "no", "blocked": "yes", "blocked_by": "q-9"},
    ]
    BLOCKED = [{"id": "q-3", "title": "Queued blocked", "repo": "IMAC", "priority": "2",
                "blocked_by": "q-9"}]
    HELD = [{"id": "q-2", "title": "Queued held", "repo": "firstmate", "priority": "2",
             "hold_reason": "캡틴 지시로 보류", "hold_until": "2027-04-10"}]

    def setUp(self):
        super().setUp()
        self.saved_queue = (dict(DASH._QUEUE), DASH.QUEUE_TTL, DASH.QUEUE_SHOWN,
                            DASH.tasks_axi_list)
        DASH._QUEUE.update({"board": None, "ok": False, "error": "", "computed_at": 0.0,
                            "checked_at": 0.0, "refreshing": False})
        self.reads = []
        self.args = []

    def tearDown(self):
        (queue, DASH.QUEUE_TTL, DASH.QUEUE_SHOWN, DASH.tasks_axi_list) = self.saved_queue
        DASH._QUEUE.update(queue)
        super().tearDown()

    def fake_axi(self, totals=None):
        totals = totals or {}
        board = {"queued": self.QUEUED, "blocked": self.BLOCKED, "held": self.HELD}

        def run(args, timeout=30):
            section = "queued"
            for i, arg in enumerate(args):
                if arg == "--blocked":
                    section = "blocked"
                elif arg == "--state" and args[i + 1] in ("held", "queued"):
                    section = args[i + 1]
            self.reads.append(section)
            self.args.append(list(args))
            rows = board[section]
            return [dict(r) for r in rows], totals.get(section, len(rows))

        DASH.tasks_axi_list = run

    def test_no_field_outside_tasks_axis_own_extra_list_is_requested(self):
        # `repo` is a base column the CLI always prints, and asking for it in
        # --fields is refused with `Unknown field(s): repo` - one such name
        # takes the whole board down. The extras list is the CLI's own:
        # blocked, blocked_by, held, hold_kind, hold_reason, hold_until,
        # priority, and friends (see `list --help`).
        self.fake_axi()
        DASH._queue_board()
        requested = set()
        for args in self.args:
            requested.update(args[args.index("--fields") + 1].split(","))
        self.assertEqual(requested - {"priority", "held", "blocked", "blocked_by",
                                     "hold_reason", "hold_until"}, set(),
                         "only fields the CLI advertises as extras may be requested")

    def test_held_and_blocked_rows_are_not_progress_planned(self):
        self.fake_axi()
        board = DASH._queue_board()
        self.assertEqual([t["id"] for t in board["queued"]["items"]], ["q-1"],
                         "a held or blocked row belongs to its own section, not this one")
        self.assertEqual(board["queued"]["count"], 1)
        self.assertEqual([t["id"] for t in board["blocked"]["items"]], ["q-3"])
        self.assertEqual([t["id"] for t in board["held"]["items"]], ["q-2"])

    def test_sections_carry_the_fields_the_panel_renders(self):
        self.fake_axi()
        board = DASH._queue_board()
        self.assertEqual(set(board["held"]["items"][0]),
                         {"id", "title", "repo", "priority", "hold_reason", "hold_until"})
        self.assertEqual(board["blocked"]["items"][0]["blocked_by"], "q-9")
        self.assertEqual(board["held"]["items"][0]["hold_reason"], "캡틴 지시로 보류")
        self.assertEqual(set(board["queued"]["items"][0]), {"id", "title", "repo", "priority"})

    def test_the_row_cap_keeps_the_rest_as_a_count(self):
        DASH.QUEUE_SHOWN = 2
        self.QUEUED = [
            {"id": "q-1", "title": "One", "repo": "firstmate", "priority": "1",
             "held": "no", "blocked": "no", "blocked_by": "none"},
            {"id": "q-4", "title": "Two", "repo": "firstmate", "priority": "1",
             "held": "no", "blocked": "no", "blocked_by": "none"},
            {"id": "q-5", "title": "Three", "repo": "firstmate", "priority": "1",
             "held": "no", "blocked": "no", "blocked_by": "none"},
        ]
        self.fake_axi(totals={"queued": 7, "blocked": 1, "held": 1})
        board = DASH._queue_board()
        self.assertEqual([t["id"] for t in board["queued"]["items"]], ["q-1", "q-4"],
                         "the cap is the rendered row count")
        self.assertEqual(board["queued"]["count"], 3, "the count still sees every row read")
        self.assertEqual(board["queued"]["total"], 7)
        self.assertTrue(board["queued"]["capped"], "the CLI cap hid rows; say so")

    def test_section_counts_displayed_and_capped(self):
        section = DASH._section([{"id": "a"}, {"id": "b"}], 9, "id")
        self.assertEqual(section["count"], 2)
        self.assertEqual(section["total"], 9)
        self.assertTrue(section["capped"])

    def test_the_clis_truncation_trailer_becomes_a_cut_mark(self):
        row = {"id": "x-1", "priority": "2",
               "title": "Some long title cut here\\n... (truncated, 318 chars total - use show "
                        "x-1 --full to see complete text)"}
        section = DASH._section([row], 1, "id", "title", "priority")
        self.assertEqual(section["items"][0]["title"], "Some long title cut here\u2026")
        self.assertEqual(section["items"][0]["priority"], "2")

    def test_an_ordinary_value_is_left_alone(self):
        self.assertEqual(DASH._clean("plain title, with a comma"), "plain title, with a comma")
        self.assertEqual(DASH._clean(None), "")
        self.assertEqual(DASH._clean("ends with (truncated) but no marker"), 
                         "ends with (truncated) but no marker")

    def test_board_read_is_cached_and_single_flight(self):
        self.fake_axi()
        first, meta1 = DASH.queue()
        second, meta2 = DASH.queue()
        self.assertEqual(len(self.reads), 3, "one refresh reads the three sections once")
        self.assertEqual(meta1["status"], "fresh")
        self.assertEqual(meta2["status"], "fresh")
        self.assertEqual(first, second)
        DASH._QUEUE["checked_at"] -= DASH.QUEUE_TTL + 1
        DASH.queue()
        self.assertEqual(len(self.reads), 6, "an expired TTL reads again")
        self.assertEqual(DASH.queue()[1]["ttl"], DASH.QUEUE_TTL)

    def test_a_failed_read_serves_the_last_good_board_and_says_so(self):
        self.fake_axi()
        good, _ = DASH.queue()

        def boom(args, timeout=30):
            raise RuntimeError("fm-tasks-axi.sh: exit 2")

        DASH.tasks_axi_list = boom
        DASH._QUEUE["checked_at"] -= DASH.QUEUE_TTL + 1
        board, meta = DASH.queue()
        self.assertEqual(meta["status"], "error")
        self.assertIn("exit 2", meta["error"])
        self.assertEqual(board, good, "the last good board is still served")
        self.assertGreaterEqual(meta["age"], 0.0, "and it is never presented as current")

    def test_failure_before_any_success_serves_no_board(self):
        DASH.tasks_axi_list = mock.Mock(side_effect=OSError("no CLI"))
        board, meta = DASH.queue()
        self.assertEqual(board, {})
        self.assertEqual(meta["status"], "error")
        self.assertEqual(meta["age"], -1.0)


class BoardRouteTest(QueueBoardTest):
    """/board over HTTP: read-only payload, freshness headers, live lanes."""

    def setUp(self):
        super().setUp()
        self.write_meta("alpha-1")
        self.fake_axi()
        self.lane_reads = []

        def lanes():
            self.lane_reads.append(time.time())
            return [{"id": "alpha-1", "liveness": DASH.LIVE, "title": "First task",
                     "state": "state: working \u00b7 source: pane", "last": "working: step 2",
                     "harness": "opencode", "window": "default:w1:p1"},
                    {"id": "beta-2", "liveness": DASH.DEAD, "title": "Gone task",
                     "state": "", "last": "", "harness": "codex", "window": ""}]

        DASH._refresh_lanes = lanes

    def test_a_cold_board_never_pays_the_lane_read(self):
        # The lane read peeks every pane and measured 68s on a real 11-lane
        # home, so the panel must not trigger it; it says "not computed yet".
        port = self.start_server()
        started = time.time()
        status, headers, body = self.get(port, "/board")
        elapsed = time.time() - started
        self.assertEqual(status, 200)
        self.assertEqual(self.lane_reads, [], "the board must not start the lane read")
        self.assertLess(elapsed, 10.0, f"the board must answer promptly, took {elapsed:.1f}s")
        data = json.loads(body)
        self.assertFalse(data["lanes_ready"])
        self.assertEqual(data["in_flight"], [])
        self.assertEqual(data["counts"]["queued"], 1, "the backlog half is still complete")

    def test_board_payload_and_headers(self):
        DASH.snap()  # what the page's own poll leaves behind
        self.assertEqual(len(self.lane_reads), 1)
        port = self.start_server()
        status, headers, body = self.get(port, "/board")
        self.assertEqual(status, 200)
        self.assertEqual(headers["X-Queue-Status"], "fresh")
        self.assertEqual(headers["X-Queue-Ttl"], "15.000")
        self.assertGreaterEqual(float(headers["X-Queue-Age"]), 0.0)
        self.assertNotIn("X-Snap-Status", headers,
                         "no lane header on a route that does not compute lanes")
        self.assertEqual(len(self.lane_reads), 1, "the board reuses the page's snapshot")
        data = json.loads(body)
        self.assertTrue(data["readonly"], "the board must declare itself read-only")
        self.assertTrue(data["lanes_ready"])
        self.assertEqual(data["counts"],
                         {"queued": 1, "blocked": 1, "held": 1, "in_flight": 1})
        self.assertEqual([t["id"] for t in data["in_flight"]], ["alpha-1"],
                         "only a live session is in flight; a gone record is not")
        self.assertEqual(data["in_flight"][0]["harness"], "OPENCODE")
        self.assertEqual(data["in_flight"][0]["last"], "working: step 2")
        self.assertEqual([t["id"] for t in data["queued"]["items"]], ["q-1"])
        self.assertEqual(data["held"]["items"][0]["hold_until"], "2027-04-10")
        self.assertGreater(data["computed_at"], 0)

    def test_board_survives_a_cli_refusal_with_the_last_good_board(self):
        port = self.start_server()
        self.get(port, "/board")

        def boom(args, timeout=30):
            raise RuntimeError("fm-tasks-axi.sh: exit 2")

        DASH.tasks_axi_list = boom
        DASH._QUEUE["checked_at"] -= DASH.QUEUE_TTL + 1
        status, headers, body = self.get(port, "/board")
        self.assertEqual(status, 200)
        self.assertEqual(headers["X-Queue-Status"], "error")
        self.assertIn("exit 2", headers["X-Queue-Error"])
        self.assertEqual(len(json.loads(body)["queued"]["items"]), 1)

    def test_existing_routes_still_answer(self):
        port = self.start_server()
        for path in ("/", "/data", "/tasks"):
            status, _headers, body = self.get(port, path)
            self.assertEqual(status, 200, path)
            self.assertTrue(body, path)
        self.assertIn(b"\xec\x9e\x91\xec\x97\x85 \xed\x98\x84\xed\x99\xa9",  # 작업 현황
                      self.get(port, "/")[2], "the panel must be in the page")


if __name__ == "__main__":
    unittest.main(verbosity=2)
