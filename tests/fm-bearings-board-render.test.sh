#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits. This suite is about
  # what the template renders, not about session liveness, which
  # tests/fm-bearings-board.test.sh owns.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.61\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/render",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Like render_board, but also carries captains_call (so the Unanswered
# Questions table has real rows) and an optional metrics object.
render_full() {  # <home> <captains_call-json> <underway-json> <metrics-json>
  local home=$1 captains_call=$2 underway=$3 metrics=$4 data="$1/payload.json"
  jq -n --argjson captains_call "$captains_call" --argjson underway "$underway" \
    --argjson metrics "$metrics" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$captains_call, underway:$underway, landed:[],
    charted:[], metrics:$metrics}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_present_metrics_render_real_values_and_absent_ones_say_no_data() {
  local home out
  home=$(make_home metrics-mixed)
  out=$(render_full "$home" '[]' '[]' '{
    "cost_cumulative": {"spent": 90.71, "cap": 300.0},
    "cache_hit_rate": 72.5,
    "tool_error_rate": {"errors": 3, "total": 120}
  }')
  printf '%s' "$out" | jq -e '
    (.error == "")
    and ([.statsCost[] | select(.label == "cumulative cost") | .value] == ["$90.71 / $300.00"])
    and ([.statsCost[] | select(.label == "cumulative cost") | .noData] == [false])
    and ([.statsCost[] | select(.label == "session cost") | .value] == ["no data"])
    and ([.statsCost[] | select(.label == "session cost") | .noData] == [true])
    and ([.statsCost[] | select(.label == "cache hit rate") | .value] == ["72.5%"])
    and ([.statsCost[] | select(.label == "tool error rate") | .value] == ["3 / 120 (2.5%)"])
    and ([.statsFleet[] | select(.label == "context read misses") | .value] == ["no data"])
  ' >/dev/null || fail "present metrics did not render real values or absent ones were not honestly labeled: $out"
  pass "present metrics render real values, and metrics with no data source say so instead of a fabricated number"
}

test_unanswered_questions_count_and_table_read_off_captains_call() {
  local home out
  home=$(make_home questions)
  out=$(render_full "$home" '[
    {"key":"decision-one","type":"decision","repo":"sample","title":"Adopt the new cache?",
     "options":[{"value":"yes","label":"Adopt"}]},
    {"key":"merge.sample-task","type":"merge","repo":"sample","title":"Merge: sample change",
     "risk":"low","options":[{"value":"merge","label":"Merge now"}]}
  ]' '[]' '{}')
  printf '%s' "$out" | jq -e '
    (.error == "")
    and ([.statsFleet[] | select(.label == "unanswered questions") | .value] == ["2"])
    and (.questions | length) == 2
    and (.questions[0] == {id:"decision-one", question:"Adopt the new cache?", urgency:"-", action:"ages to Charted Next"})
    and (.questions[1] == {id:"merge.sample-task", question:"Merge: sample change", urgency:"-", action:"PR stays unmerged"})
  ' >/dev/null || fail "the unanswered-questions count or table did not read off captains_call: $out"
  pass "the unanswered questions table reads real call data and reports unavailable urgency honestly"
}


test_unified_task_table_maps_real_states_and_question_urgency() {
  local home out
  home=$(make_home unified-table)
  out=$(render_full "$home" '[
    {"key":"fresh","type":"decision","repo":"sample","title":"Fresh question?","filed":"2026-09-25","blocking":false,"options":[{"value":"yes","label":"Yes"}]},
    {"key":"old-blocker","type":"decision","repo":"sample","title":"Old blocking question?","filed":"2026-09-20","blocking":true,"options":[{"value":"yes","label":"Yes"}]},
    {"key":"undated","type":"decision","repo":"sample","title":"Undated?","blocking":true,"options":[{"value":"yes","label":"Yes"}]}
  ]' '[
    {"id":"run-1","repo":"sample","name":"Running","state":"validating","kind":"ship","doing":"checking"}
  , {"id":"run-2","repo":"sample","name":"Blocked","state":"working","kind":"ship","doing":"waiting","blocker":"blocked by gate"}
  ]' '{}')
  printf '%s' "$out" | jq -e '
    (.error == "")
    and (.tasks | any(.[]; . == ["run-1","진행중","Running","-"]))
    and (.tasks | any(.[]; . == ["run-2","대기","Blocked","blocked by gate"]))
    and ([.questions[].urgency] == ["보통","높음","-"])
  ' >/dev/null || fail "task mapping or urgency did not match real fields: $out"
  pass "unified table maps underway states and urgency uses filed age/blocking"
}

test_zero_tool_calls_have_no_percentage() {
  local home out
  home=$(make_home zero-tool-calls)
  out=$(render_full "$home" '[]' '[]' '{"tool_error_rate":{"errors":0,"total":0}}')
  printf '%s' "$out" | jq -e '[.statsCost[] | select(.label == "tool error rate") | .value] == ["0 / 0 (-)"]' >/dev/null \
    || fail "zero calls rendered a percentage: $out"
  pass "zero tool calls show unavailable percentage with real counts"
}

test_underway_and_charted_blocker_columns_render_real_or_honest_absence() {
  local home out
  home=$(make_home blocker-columns)
  out=$(render_board "$home" '[
    {"id":"blocked-task","repo":"sample","name":"Blocked task","state":"working","kind":"ship",
     "doing":"implementing","blocker":"waiting on decision-one"},
    {"id":"clear-task","repo":"sample","name":"Clear task","state":"working","kind":"ship",
     "doing":"implementing"}
  ]' '[
    {"id":"gated","repo":"sample","title":"Gated work","reason":"blocked on blocked-task","dispatchable":true},
    {"id":"free","repo":"sample","title":"Free work","reason":"","dispatchable":true}
  ]')
  printf '%s' "$out" | jq -e '
    (.error == "")
    and ([.underway[] | select(.title == "Blocked task") | .blocker] == ["waiting on decision-one"])
    and ([.underway[] | select(.title == "Clear task") | .blocker] == [null])
    and ([.charted[] | select(.title == "Gated work") | .blocker] == ["blocked on blocked-task"])
    and ([.charted[] | select(.title == "Free work") | .blocker] == ["no blocker"])
    and ([.charted[] | select(.title == "Free work") | .blockerNone] == [true])
  ' >/dev/null || fail "the blocker column did not render real text or honest absence: $out"
  pass "the blocker column shows real structured blocker text, and honestly labels no blocker rather than a placeholder"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_present_metrics_render_real_values_and_absent_ones_say_no_data
test_unanswered_questions_count_and_table_read_off_captains_call
test_underway_and_charted_blocker_columns_render_real_or_honest_absence
test_unified_task_table_maps_real_states_and_question_urgency
test_zero_tool_calls_have_no_percentage
