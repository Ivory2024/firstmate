#!/usr/bin/env bash
# pr-classify.test.sh - read-only PR classifier cases (pstack babysit/shipping
# adaptation). No network, no GitHub write: each case is a local JSON fixture.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PC="$UCX/../verification/pr-classify.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/uc-pr.XXXXXX")
mk() { printf '%s\n' "$2" > "$W/$1.json"; }
cls() { bash "$PC" "$W/$1.json"; }

mk ready '{"state":"OPEN","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","authorized":false,"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
[ "$(cls ready)" = ready-not-authorized ] && ok "ready but not authorized" || no "ready (got $(cls ready))"

mk auth '{"state":"OPEN","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","authorized":true,"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
[ "$(cls auth)" = ready-and-authorized ] && ok "ready and authorized" || no "auth (got $(cls auth))"

mk red '{"state":"OPEN","mergeStateStatus":"CLEAN","authorized":true,"statusCheckRollup":[{"conclusion":"FAILURE"}]}'
[ "$(cls red)" = blocked ] && ok "red CI => blocked even if authorized" || no "red (got $(cls red))"

mk conflict '{"state":"OPEN","mergeStateStatus":"DIRTY","authorized":true,"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
[ "$(cls conflict)" = blocked ] && ok "conflict => blocked" || no "conflict (got $(cls conflict))"

mk closed '{"state":"CLOSED","authorized":true}'
[ "$(cls closed)" = blocked ] && ok "closed PR => blocked" || no "closed (got $(cls closed))"

mk merged '{"state":"MERGED"}'
[ "$(cls merged)" = merged ] && ok "merged PR reported merged" || no "merged (got $(cls merged))"

mk authnr '{"state":"OPEN","mergeStateStatus":"BEHIND","authorized":true,"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
[ "$(cls authnr)" = authorized-not-ready ] && ok "authorized but not ready" || no "authnr (got $(cls authnr))"

rm -rf "$W"
echo "# pr-classify.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
