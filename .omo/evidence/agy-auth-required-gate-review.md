# AGY auth_required gate review

recommendation: REJECT

## originalIntent

Review the stated source diff read-only and trace an AGY `auth_required` quota snapshot through rule floors, candidate ranking, the legacy chooser, and process-event wake classification.

## desiredOutcome

Every changed auth-required branch must be reachable from its public boundary and must avoid treating stale quota values as dispatchable evidence. Resolver candidates must remain eligible but unranked, expose the exact authentication cause, fabricate no quota values, and emit no AGY dispatch profile.

## userOutcomeReview

The resolver and process-event paths satisfy the requested snapshot behavior. `fm-dispatch-resolve.sh` makes an AGY auth-required rule floor unverifiable before selection, then makes the candidate eligible/unranked before stale rows can veto or rank it; rendering preserves the exact cause and cannot emit an AGY profile when it is the only candidate. `fm-procevent-quota.sh` excludes auth-required AGY rows from quota classification, returns a terminal `error`, and carries the exact auth cause in details.

The chooser path does not satisfy the requested end-to-end review outcome. Its new auth-required guard is unreachable for public AGY candidates because the shared harness-to-provider boundary still has no `agy` arm. The chooser validates that boundary before calling the changed function, and its test explicitly requires `agy:default` to fail as `unknown harness: agy`. This is dead production logic and false coverage for the stated cross-path auth-required handling.

## blockers

- violatedCriterion: VERIFY-CHOOSER-AUTH-SNAPSHOT
  observation: The changed AGY `auth_required` branch in `effective_for_provider_model` cannot be reached through the chooser's public candidate path.
  evidencePointer: `bin/fm-quota-choose.sh:329`, `bin/fm-quota-choose.sh:350-359`, `bin/fm-quota-axi-lib.sh:116-134`, `tests/fm-quota-choose.test.sh:563-569`
  requiredFix: Either add the intended shared `agy -> agy` mapping and a public auth-required chooser regression, or remove the unreachable chooser guard if AGY is intentionally resolver-only.

## notes

- `bin/fm-dispatch-resolve.sh:291-313,357-365,382-420` correctly preserves unknown floors, unranked ranking, exact cause, and no AGY profile.
- `bin/fm-procevent-quota.sh:113-146,151-185,244-270` correctly classifies auth-required AGY as a terminal error wake while excluding stale quota rows from `best`.
- Slop/overfit pass: `bin/fm-quota-choose.sh:329` is unreachable code; `tests/fm-quota-choose.test.sh:563-569` locks the sibling boundary that makes it unreachable instead of exercising the changed behavior. No other blocking overfit, tautological, deletion-only, implementation-mirroring, or unnecessary abstraction issue was found in scope.
- No tests were run, per assignment.

## checkedArtifacts

- `bin/fm-dispatch-resolve.sh`
- `bin/fm-quota-axi-lib.sh`
- `bin/fm-quota-choose.sh`
- `bin/fm-procevent-quota.sh`
- `tests/fm-dispatch-resolve.test.sh`
- `tests/fm-quota-choose.test.sh`
- `tests/fm-procevent-quota.test.sh`
- commits `384c69f^..9dd1473`
- `/Users/irene/.no-mistakes/logs/01M2YDVN44XTTFK4V5HKSEQMHN/review.log`

## evidenceGaps

- No original brief, success-criteria artifact, manual-QA matrix, or notepad was present in the worktree/evidence directory.
- The available review log contains repeated empty findings with no reviewed paths or evidence, so it does not demonstrate an independent programming/slop pass.
- Runtime tests were intentionally not executed; conclusions are source-trace only.
