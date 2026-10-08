#!/usr/bin/env bash
# mock fm-brief.sh - stands in for bin/fm-brief.sh in the offline real-E2E test.
# It writes the scout scaffold with the same {TASK}/{FIRSTMATE_SPEC} placeholders
# the real scaffolder uses, so the adapter's fill path is exercised. Test double.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
id=${1:?usage: fm-brief.sh <task-id> <repo-name> --scout}
mkdir -p "$ROOT/data/$id"
cat > "$ROOT/data/$id/brief.md" <<'EOF'
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}

# Definition of done
Write your findings to your task's report.md.
EOF
echo "scaffolded: $ROOT/data/$id/brief.md (scout; replace {TASK} and {FIRSTMATE_SPEC})"
