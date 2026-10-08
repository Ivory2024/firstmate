#!/usr/bin/env bash
# fm-blocker-classify-lib.sh - the single owner of the command-tower blocker
# taxonomy. Source this file; callers are bin/fm-crew-state.sh and the status
# readers in bin/fm-classify-lib.sh.
#
# Four standard types plus an explicit fallback:
#   CODE_BLOCKED | INFRA_BLOCKED | PROVIDER_BLOCKED | REVIEW_BLOCKED | UNKNOWN_BLOCKED
#
# Design rules (must hold):
#   - The failure STAGE and the blocker TYPE are independent fields.
#   - A structured error code is authoritative; free text is auxiliary evidence.
#   - When a structured code and the text evidence conflict, return UNKNOWN.
#   - Missing/insufficient evidence is UNKNOWN, never a guessed type.
#   - A provider quota hit is PROVIDER_BLOCKED at ANY stage (a quota hit during
#     review is NOT REVIEW_BLOCKED).
#   - A provider AUTH failure is NOT quota: it is UNKNOWN (needs a human).
#   - The word "review" in a message is not evidence of a review finding.
#   - The RETRY policy is computed separately from the TYPE.
#
# Public functions:
#   fm_blocker_classify <stage> <cause-text> [<structured-code>]
#       prints one tab-separated row: <TYPE>\t<subcause>\t<retry_policy>
#   fm_blocker_retry_policy <TYPE> <subcause>
#       prints one policy token: none|limited|wait|manual
#   fm_blocker_retry_after <cause-text>
#       prints an ISO-8601 UTC reset time when the text carries one, else empty

# shellcheck disable=SC2034  # public vocabulary; also read by bin/fm-classify-lib.sh
FM_BLOCKER_TYPES='CODE_BLOCKED INFRA_BLOCKED PROVIDER_BLOCKED REVIEW_BLOCKED UNKNOWN_BLOCKED'

# fm_blocker_is_type <value>  -> 0 when <value> is a known blocker type.
fm_blocker_is_type() {
  case " $FM_BLOCKER_TYPES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Lowercase helper; portable across bash 3.2.
_fm_blocker_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Map a structured error code to a TYPE+subcause. Prints "TYPE\tsubcause" or
# nothing when the code is not recognized.
_fm_blocker_from_code() {
  case "$1" in
    provider_quota|quota_exhausted|provider_quota_exhausted)
      printf 'PROVIDER_BLOCKED\tquota_exhausted' ;;
    rate_limit|provider_rate_limit)
      printf 'PROVIDER_BLOCKED\trate_limit' ;;
    provider_unavailable|provider_outage|provider_service_error)
      printf 'PROVIDER_BLOCKED\tprovider_outage' ;;
    provider_auth|provider_auth_failed|invalid_api_key|unauthorized)
      printf 'UNKNOWN_BLOCKED\tprovider_auth' ;;
    provider_payment|payment_required|billing)
      printf 'UNKNOWN_BLOCKED\tprovider_payment' ;;
    ci_runner|runner_shutdown|runner_lost|infra_runner)
      printf 'INFRA_BLOCKED\trunner' ;;
    network|network_error|dns_failure|connection_reset)
      printf 'INFRA_BLOCKED\tnetwork' ;;
    environment|env_unavailable|setup_failed)
      printf 'INFRA_BLOCKED\tenvironment' ;;
    test_assertion|assertion_failed|test_failed)
      printf 'CODE_BLOCKED\ttest_assertion' ;;
    compile_error|lint_error|type_error)
      printf 'CODE_BLOCKED\tbuild' ;;
    review_changes_requested|changes_requested|review_request)
      printf 'REVIEW_BLOCKED\tchanges_requested' ;;
    review_unapproved|unapproved_change)
      printf 'REVIEW_BLOCKED\tunapproved' ;;
  esac
}

# Auxiliary text classification (only when no structured code decided otherwise).
_fm_blocker_from_text() {
  local t=$1
  case "$t" in
    # Provider rate limit is transient and is checked before quota.
    *"rate limit"*|*"rate-limit"*)
      printf 'PROVIDER_BLOCKED\trate_limit' ;;
    # Provider quota / usage limit / outage.
    *"usage limit"*|*"quota"*|*"exceeded its invocation budget"*|*"try again at"*)
      printf 'PROVIDER_BLOCKED\tquota_exhausted' ;;
    *"connection reset"*|*"network is unreachable"*|*"dns"*|*"no space left"*|*"runner"*|*"failed to start"*)
      printf 'INFRA_BLOCKED\tinfra' ;;
    *"assertion"*|*"but got"*|*"test failed"*|*"not ok"*)
      printf 'CODE_BLOCKED\ttest_assertion' ;;
    # Only EXPLICIT review-request phrasing, never the bare word "review".
    *"changes requested"*|*"change request"*|*"requested changes"*|*"review request"*|*"approval required"*|*"unapproved"*)
      printf 'REVIEW_BLOCKED\tchanges_requested' ;;
  esac
}

# fm_blocker_classify <stage> <cause-text> [<structured-code>]
fm_blocker_classify() {
  # shellcheck disable=SC2034  # stage is part of the contract; the type is deliberately stage-independent
  local stage=$1 cause=$2 code=${3:-}
  local text_code='' from_text='' from_code=''
  local type sub policy text_type
  text_code=$(printf '%s' "$cause" | tr '[:upper:]' '[:lower:]')

  if [ -n "$code" ]; then
    from_code=$(_fm_blocker_from_code "$(_fm_blocker_lc "$code")")
    if [ -z "$from_code" ]; then
      # A structured code we do not recognize: do not guess from text.
      printf 'UNKNOWN_BLOCKED\tunknown_code\tnone\n'
      return 0
    fi
    from_text=$(_fm_blocker_from_text "$text_code")
    if [ -n "$from_text" ]; then
      text_type=${from_text%%$'\t'*}
      code_type=${from_code%%$'\t'*}
      if [ "$text_type" != "$code_type" ]; then
        # Structured evidence and text conflict -> safe UNKNOWN.
        printf 'UNKNOWN_BLOCKED\tconflicting_evidence\tnone\n'
        return 0
      fi
    fi
    type=${from_code%%$'\t'*}
    sub=${from_code#*$'\t'}
  else
    from_text=$(_fm_blocker_from_text "$text_code")
    if [ -z "$from_text" ]; then
      printf 'UNKNOWN_BLOCKED\tno_evidence\tnone\n'
      return 0
    fi
    type=${from_text%%$'\t'*}
    sub=${from_text#*$'\t'}
  fi

  fm_blocker_is_type "$type" || type=UNKNOWN_BLOCKED
  policy=$(fm_blocker_retry_policy "$type" "$sub")
  printf '%s\t%s\t%s\n' "$type" "$sub" "$policy"
}

# fm_blocker_retry_policy <TYPE> <subcause>
fm_blocker_retry_policy() {
  case "$1" in
    CODE_BLOCKED|REVIEW_BLOCKED) printf 'none' ;;
    INFRA_BLOCKED)               printf 'limited' ;;
    PROVIDER_BLOCKED)
      case "$2" in
        rate_limit) printf 'limited' ;;
        *)          printf 'wait' ;;
      esac ;;
    UNKNOWN_BLOCKED)
      case "$2" in
        provider_auth|provider_payment) printf 'manual' ;;
        *)                              printf 'manual' ;;
      esac ;;
    *) printf 'manual' ;;
  esac
}

# fm_blocker_retry_after <cause-text>  -> "H:MM" / "H:MM AM|PM" or empty
fm_blocker_retry_after() {
  printf '%s' "$1" \
    | sed -n 's/.*try again at \([0-9][0-9]*:[0-9][0-9]\([[:space:]][APap][Mm]\)\{0,1\}\).*/\1/p' \
    | head -1
}
