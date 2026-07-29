#!/usr/bin/env bash
# state.sh - human and agent facing wrapper over the group 6 state functions.
#
# Read-only by default. The only mutating subcommand is `set`, which is
# restricted to root in the bootstrap context because bootstrap is the single
# writer of state.json (plan section 3.3).
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
CI_REPO="corp-infra-bootstrap"; CI_SCRIPT="$(basename "$0")"

STAGES=(security vpn-proxy backup ent-infra pop-agents)
MARKERS=(security.hardened secrets.escrow.ok vpn.ready proxy.ready backup.ready
         ent-infra.gitlab.installed ent-infra.tracker.installed
         ent-infra.wiki.installed ent-infra.site.installed
         ent-infra.observability.installed agents.ready)

usage() {
    cat <<EOF
Usage: state.sh <command> [args] [--quiet]

Commands:
  show                 stage map from state.json plus marker status
  get <key>            one scalar from state.json (dotted path)
  markers              every known marker with its status
  recon                print the latest recon document
  set <key> <value> [type]
                       write one key into state.json (root, bootstrap only)

Common flags: --quiet, --help, --version

Exit: 0 ok
      1 a value was requested that is present but bad, or a write failed
      2 state.json or the marker is missing / unreadable

Examples:
  ./state.sh show
  ./state.sh get profile
  ./state.sh markers
EOF
}

cmd_show() {
    local file="$CI_STATE/state.json"
    printf '\ncorp-infra state\n'
    printf '  state file : %s\n' "$file"
    printf '  host id    : %s\n' "$(_ci_host_id)"

    if [ ! -r "$file" ]; then
        printf '  status     : NOT INITIALISED (bootstrap.sh has not run on this host)\n\n'
        printf '  %-14s %-10s %s\n' "STAGE" "STATE" "MARKER"
        printf '  %s\n' "---------------------------------------------"
        local s
        for s in "${STAGES[@]}"; do
            printf '  %-14s %-10s %s\n' "$s" "pending" "absent"
        done
        printf '\n'
        return 2
    fi

    local profile role stage lib
    profile="$(state_get profile 2>/dev/null || printf '?')"
    role="$(state_get node_role 2>/dev/null || printf '?')"
    stage="$(state_get current_stage 2>/dev/null || printf '?')"
    lib="$(state_get lib_version 2>/dev/null || printf '?')"
    printf '  profile    : %s (node_role %s)\n' "$profile" "$role"
    printf '  stage      : %s\n' "$stage"
    printf '  lib version: %s\n\n' "$lib"

    printf '  %-14s %-10s %s\n' "STAGE" "STATE" "MARKER"
    printf '  %s\n' "---------------------------------------------"
    local s value marker mrc
    for s in "${STAGES[@]}"; do
        value="$(state_get "stages.$s" 2>/dev/null || printf 'pending')"
        [ -n "$value" ] || value="pending"
        case "$s" in
            security)   marker="security.hardened" ;;
            vpn-proxy)  marker="vpn.ready" ;;
            backup)     marker="backup.ready" ;;
            ent-infra)  marker="ent-infra.gitlab.installed" ;;
            pop-agents) marker="agents.ready" ;;
            *)          marker="-" ;;
        esac
        mrc=0
        state_check "$marker" >/dev/null 2>&1 || mrc=$?
        case "$mrc" in
            0) printf '  %-14s %-10s %s\n' "$s" "$value" "ok ($marker)" ;;
            1) printf '  %-14s %-10s %s\n' "$s" "$value" "FAILED ($marker)" ;;
            *) printf '  %-14s %-10s %s\n' "$s" "$value" "absent ($marker)" ;;
        esac
    done
    printf '\n  Reminder: a marker is a claim, not a proof (INV-GLOBAL-2).\n'
    printf '  Use bootstrap.sh --check for the marker plus live --check view.\n\n'
    return 0
}

cmd_get() {
    local key="${1:-}"
    [ -n "$key" ] || die 2 "state.sh get: key required"
    local out rc=0
    out="$(state_get "$key")" || rc=$?
    case "$rc" in
        0) printf '%s\n' "$out" >&9; return 0 ;;
        1) log ERROR "state.sh get: key '$key' is not present in state.json"; return 1 ;;
        *) log ERROR "state.sh get: state.json is missing or unreadable"; return 2 ;;
    esac
}

cmd_markers() {
    local dir="$CI_STATE/markers"
    printf '\n  %-36s %-10s %s\n' "MARKER" "STATUS" "APPLIED AT"
    printf '  %s\n' "-------------------------------------------------------------------------"
    local any=0 m file status applied rc
    for m in "${MARKERS[@]}"; do
        file="$dir/$m.json"
        if [ ! -r "$file" ]; then
            printf '  %-36s %-10s %s\n' "$m" "absent" "-"
            continue
        fi
        any=1
        status="$(_ci_read_scalar "$file" status status || printf '?')"
        applied="$(_ci_read_scalar "$file" applied_at applied_at || printf '?')"
        rc=0
        state_check "$m" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '  %-36s %-10s %s\n' "$m" "$status" "$applied"
        else
            printf '  %-36s %-10s %s  (state_check=%s)\n' "$m" "$status" "$applied" "$rc"
        fi
    done
    printf '\n'
    [ "$any" = "1" ] && return 0
    return 2
}

cmd_recon() {
    local file="$CI_STATE/recon/latest.json"
    if [ ! -r "$file" ]; then
        log ERROR "no recon document at $file; run recon.sh first"
        return 2
    fi
    cat "$file" >&9
    return 0
}

cmd_set() {
    local key="${1:-}" value="${2:-}" type="${3:-string}"
    [ -n "$key" ] || die 2 "state.sh set: key required"
    require_root
    CI_MODE="apply"
    if state_set "$key" "$value" "$type"; then
        return 0
    fi
    return 1
}

main() {
    trap_init
    parse_args "$@"

    local cmd="${CI_ARGS[0]:-show}"
    # Every subcommand except `set` is read-only; pinning check mode keeps
    # log_init from creating directories as a side effect.
    if [ "$cmd" != "set" ]; then
        # CI_MODE is a lib-level global (lib/common.sh) read by log_init/guard_apply;
        # it is write-only here, which shellcheck cannot see across the source.
        # shellcheck disable=SC2034
        CI_MODE="check"
    fi
    log_init "$CI_REPO" "$CI_SCRIPT"

    local rc=0
    case "$cmd" in
        show)    cmd_show    || rc=$? ;;
        get)     cmd_get     "${CI_ARGS[1]:-}" || rc=$? ;;
        markers) cmd_markers || rc=$? ;;
        recon)   cmd_recon   || rc=$? ;;
        set)     cmd_set     "${CI_ARGS[1]:-}" "${CI_ARGS[2]:-}" "${CI_ARGS[3]:-string}" || rc=$? ;;
        *)       die 2 "unknown command '$cmd' (try --help)" ;;
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
