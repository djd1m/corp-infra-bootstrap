#!/usr/bin/env bash
# doctor.sh - aggregate self-diagnosis (FR-8).
#
# Runs every --check this repository owns and prints one summary table.
# Never mutates anything.
#
# Aggregation rule: a fail outranks an inconclusive. The overall result is 1
# if any child failed, otherwise 2 if any child was inconclusive, otherwise 0.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
CI_REPO="corp-infra-bootstrap"; CI_SCRIPT="$(basename "$0")"

usage() {
    cat <<EOF
Usage: doctor.sh [--check] [--profile <name>] [--quiet]

Runs, in order:
  recon.sh --check
  sizing-check.sh --check
  sync-lib.sh --check
  bootstrap.sh --check

  --check           accepted for symmetry; doctor is always read-only
  --profile <name>  passed through to sizing-check.sh
  --quiet           log to file only; stdout is one result line
  --help / --version

Exit: 0 everything green
      1 at least one child check failed
      2 nothing failed but at least one child was inconclusive
EOF
}

RESULT_NAMES=()
RESULT_CODES=()

run_one() {
    local label="$1"
    shift
    local rc=0
    log INFO "--- $label ---"
    "$@" || rc=$?
    RESULT_NAMES+=("$label")
    RESULT_CODES+=("$rc")
    log INFO "$label exited $rc"
    return 0
}

verdict_of() {
    case "$1" in
        0) printf 'OK\n' ;;
        1) printf 'FAIL\n' ;;
        *) printf 'INCONCLUSIVE\n' ;;
    esac
}

main() {
    trap_init
    parse_args "$@"
    # doctor never mutates; pinning check mode also stops log_init from
    # creating a log directory as a side effect.
    # CI_MODE is a lib-level global (lib/common.sh) read by log_init/guard_apply;
    # it is write-only here, which shellcheck cannot see across the source.
    # shellcheck disable=SC2034
    CI_MODE="check"
    log_init "$CI_REPO" "$CI_SCRIPT"

    local pass_profile=()
    if [ -n "$CI_PROFILE" ]; then
        pass_profile=(--profile "$CI_PROFILE")
    fi

    run_one "recon"        "$SCRIPT_DIR/recon.sh" --check
    run_one "sizing-check" "$SCRIPT_DIR/sizing-check.sh" --check "${pass_profile[@]+"${pass_profile[@]}"}"
    run_one "sync-lib"     "$SCRIPT_DIR/sync-lib.sh" --check
    run_one "bootstrap"    "$SCRIPT_DIR/bootstrap.sh" --check

    printf '\n  %-16s %s\n' "CHECK" "VERDICT"
    printf '  %s\n' "-------------------------------------"
    local i any_fail=0 any_inc=0
    for (( i = 0; i < ${#RESULT_NAMES[@]}; i++ )); do
        printf '  %-16s %s\n' "${RESULT_NAMES[$i]}" "$(verdict_of "${RESULT_CODES[$i]}")"
        case "${RESULT_CODES[$i]}" in
            0) ;;
            1) any_fail=1 ;;
            *) any_inc=1 ;;
        esac
    done
    printf '\n'

    local rc=0
    if [ "$any_fail" = "1" ]; then
        rc=1
    elif [ "$any_inc" = "1" ]; then
        rc=2
    fi

    case "$rc" in
        0) log INFO  "doctor: OK" ;;
        1) log ERROR "doctor: FAIL" ;;
        *) log WARN  "doctor: INCONCLUSIVE" ;;
    esac
    if [ "$CI_QUIET" = "1" ]; then
        case "$rc" in
            0) printf 'OK: %s\n' "$CI_SCRIPT" >&9 ;;
            1) printf 'FAIL: %s\n' "$CI_SCRIPT" >&9 ;;
            *) printf 'INCONCLUSIVE: %s\n' "$CI_SCRIPT" >&9 ;;
        esac
    fi
    exit "$rc"
}

exec 9>&1
main "$@"
