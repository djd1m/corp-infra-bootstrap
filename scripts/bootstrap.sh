#!/usr/bin/env bash
# bootstrap.sh - the single entry point. Five-stage state machine
# (FR-9, ADR-012 section 2).
#
# Stage order is hard-wired and not configurable:
#   security -> vpn-proxy -> backup -> ent-infra -> pop-agents
# Backup is installed BEFORE any data exists, so a service enters the backup
# set at the moment it is installed rather than "later".
#
# Transition rule (INV-BS-1 / INV-GLOBAL-2): stage N+1 starts only when the
# marker of stage N says ok AND the producing repo's own --check exits 0.
# A marker on its own is a claim, never a proof.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
CI_REPO="corp-infra-bootstrap"; CI_SCRIPT="$(basename "$0")"

BOOTSTRAP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STAGE_ORDER=(security vpn-proxy backup ent-infra pop-agents)

BS_STAGE=""
BS_FROM=""
BS_FORCE_PROFILE=0
BS_PROVIDER=""

usage() {
    cat <<EOF
Usage: bootstrap.sh [--check] [--yes] [--profile <name>] [--quiet]
                    [--stage <name>] [--from <name>] [--force-profile]
                    [--provider <id>]

Applies the five stages in the fixed order:
  ${STAGE_ORDER[*]}

  --check           print the stage map: marker plus live --check of each repo.
                    Zero mutations. A marker that disagrees with the live check
                    is reported as DRIFT and exits 1.
  --yes             non-interactive
  --profile <name>  select the deployment profile (bootstrap only selects it;
                    every other repo merely asserts it)
  --stage <name>    run exactly one stage
  --from <name>     resume from this stage onwards
  --force-profile   proceed when sizing_verdict is inconclusive (INV-BS-2);
                    recorded in state.json as profile_forced
  --provider <id>   pass a provider override through to recon.sh
  --quiet           log to file only; stdout is one result line
  --help / --version

STOP gates (the run pauses and asks for a human):
  1. after security  - move the private age key into escrow, then run
                       security/scripts/age-escrow.sh --attest
  2. after vpn-proxy - switch the operator onto the VPN before SSH narrows
  3. at the end      - backup/scripts/test-restore.sh --scenario vps-loss

Exit: 0 every stage ok
      1 a stage failed, a marker drifted from reality, or the sizing verdict
        is fail (a checked condition is violated)
      2 sizing inconclusive without --force-profile, a repo is missing,
        or the script is not running as root
EOF
}

# CI_EXTRA_SHIFT is the return channel to parse_args() in lib/common.sh: it
# tells the common parser how many argv entries this handler consumed. It is
# written here and read there, which shellcheck cannot see across the source.
# shellcheck disable=SC2034
ci_extra_arg() {
    case "$1" in
        --stage)
            [ "$#" -ge 2 ] || die 2 "--stage requires an argument"
            BS_STAGE="$2"; CI_EXTRA_SHIFT=2
            ;;
        --stage=*)      BS_STAGE="${1#*=}"; CI_EXTRA_SHIFT=1 ;;
        --from)
            [ "$#" -ge 2 ] || die 2 "--from requires an argument"
            BS_FROM="$2"; CI_EXTRA_SHIFT=2
            ;;
        --from=*)       BS_FROM="${1#*=}"; CI_EXTRA_SHIFT=1 ;;
        --force-profile) BS_FORCE_PROFILE=1; CI_EXTRA_SHIFT=1 ;;
        --provider)
            [ "$#" -ge 2 ] || die 2 "--provider requires an argument"
            BS_PROVIDER="$2"; CI_EXTRA_SHIFT=2
            ;;
        --provider=*)   BS_PROVIDER="${1#*=}"; CI_EXTRA_SHIFT=1 ;;
        *) return 1 ;;
    esac
    return 0
}

# --------------------------------------------------------------------------
# stage description tables - the only place that knows repo entry points
# --------------------------------------------------------------------------

stage_repo() {
    case "$1" in
        security)   printf 'security\n' ;;
        vpn-proxy)  printf 'vpn-proxy\n' ;;
        backup)     printf 'backup\n' ;;
        ent-infra)  printf 'ent-infra\n' ;;
        pop-agents) printf 'pop-agents\n' ;;
        *) return 1 ;;
    esac
}

# Entry scripts, in order, for a stage.
stage_entries() {
    case "$1" in
        security)   printf 'harden.sh\n' ;;
        vpn-proxy)  printf 'install-wireguard.sh\ninstall-proxy.sh\n' ;;
        backup)     printf 'install-backup.sh\n' ;;
        ent-infra)  ent_infra_entries ;;
        pop-agents) printf 'install-agent.sh\n' ;;
        *) return 1 ;;
    esac
}

# The marker that proves a stage, used by the transition rule.
stage_marker() {
    case "$1" in
        security)   printf 'security.hardened\n' ;;
        vpn-proxy)  printf 'proxy.ready\n' ;;
        backup)     printf 'backup.ready\n' ;;
        ent-infra)  printf 'ent-infra.observability.installed\n' ;;
        pop-agents) printf 'agents.ready\n' ;;
        *) return 1 ;;
    esac
}

# The live --check that must agree with the marker.
stage_check_cmd() {
    local stage="$1" repo entry
    repo="$(stage_repo "$stage")" || return 1
    entry="$(stage_entries "$stage" | head -n1)"
    printf '%s/%s/scripts/%s\n' "$CI_ROOT" "$repo" "$entry"
}

# ent-infra installs one script per service declared by the profile. Each
# install script is itself profile-aware and exits 0 when its service is not
# part of the selected profile.
ent_infra_entries() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        file="${PROFILE_JSON:-}"
    fi
    if [ -z "$file" ] || [ ! -r "$file" ]; then
        printf 'install-gitlab.sh\ninstall-wiki.sh\ninstall-site.sh\ninstall-observability.sh\ninstall-tracker.sh\n'
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for entry in data.get("services", []) or []:
    print("install-%s.sh" % entry["id"])
' "$file" 2>/dev/null && return 0
    fi
    grep -o -E '"id"[[:space:]]*:[[:space:]]*"(gitlab|tracker|wiki|site|observability)"' "$file" \
        | sed -E 's/.*"([a-z]+)"$/install-\1.sh/'
    return 0
}

# --------------------------------------------------------------------------
# --check: the stage map. Reads only.
# --------------------------------------------------------------------------

run_check() {
    local rc=0 drift=0 pending=0

    printf '\ncorp-infra bootstrap - stage map\n'
    printf '  root      : %s\n' "$CI_ROOT"
    printf '  state     : %s\n' "$CI_STATE"
    printf '  host id   : %s\n' "$(_ci_host_id)"
    printf '  lib       : %s\n\n' "$LIB_VERSION"

    printf '  %-12s %-10s %-12s %s\n' "STAGE" "MARKER" "LIVE CHECK" "VERDICT"
    printf '  %s\n' "-------------------------------------------------------------------"

    local stage marker mrc script lrc marker_txt live_txt verdict
    for stage in "${STAGE_ORDER[@]}"; do
        marker="$(stage_marker "$stage")"
        mrc=0
        state_check "$marker" >/dev/null 2>&1 || mrc=$?
        case "$mrc" in
            0) marker_txt="ok" ;;
            1) marker_txt="failed" ;;
            *) marker_txt="absent" ;;
        esac

        script="$(stage_check_cmd "$stage")"
        if [ ! -x "$script" ]; then
            live_txt="n/a"
            lrc=3
        else
            lrc=0
            "$script" --check >/dev/null 2>&1 || lrc=$?
            case "$lrc" in
                0) live_txt="ok" ;;
                1) live_txt="fail" ;;
                *) live_txt="inconclusive" ;;
            esac
        fi

        if [ "$marker_txt" = "absent" ] && [ "$lrc" -eq 3 ]; then
            verdict="pending"
            pending=$(( pending + 1 ))
        elif [ "$marker_txt" = "ok" ] && [ "$lrc" -eq 0 ]; then
            verdict="ok"
        elif [ "$marker_txt" = "ok" ] && [ "$lrc" -ne 0 ]; then
            verdict="DRIFT"
            drift=1
        elif [ "$marker_txt" = "absent" ] && [ "$lrc" -eq 0 ]; then
            verdict="DRIFT"
            drift=1
        elif [ "$marker_txt" = "failed" ]; then
            verdict="FAILED"
            rc=1
        else
            verdict="pending"
            pending=$(( pending + 1 ))
        fi

        printf '  %-12s %-10s %-12s %s\n' "$stage" "$marker_txt" "$live_txt" "$verdict"
    done

    printf '\n'
    if [ "$drift" -eq 1 ]; then
        log ERROR "marker and reality disagree on at least one stage (DRIFT); a marker is never a proof"
        rc=1
    fi
    if [ "$pending" -eq "${#STAGE_ORDER[@]}" ]; then
        log INFO "clean host: all ${#STAGE_ORDER[@]} stages are pending"
        return 0
    fi
    return "$rc"
}

# --------------------------------------------------------------------------
# apply
# --------------------------------------------------------------------------

ensure_layout() {
    local d
    for d in "$CI_STATE" "$CI_STATE/markers" "$CI_STATE/manifests" \
             "$CI_STATE/recon" "$CI_STATE/recon/history" "$CI_STATE/escrow" \
             "$CI_STATE/backup" "$CI_LOGDIR" "$CI_ROOT" "$CI_SRV"; do
        if [ ! -d "$d" ]; then
            mkdir -p "$d"
            log INFO "created $d"
        fi
    done
    chmod 0750 "$CI_STATE" 2>/dev/null || true
    chmod 0750 "$CI_LOGDIR" 2>/dev/null || true
    if [ ! -d "$CI_ETC" ]; then
        mkdir -p "$CI_ETC"
        log INFO "created $CI_ETC"
    fi
    chmod 0700 "$CI_ETC" 2>/dev/null || true
    return 0
}

run_recon_if_stale() {
    local latest="$CI_STATE/recon/latest.json"
    local stale=1
    if [ -r "$latest" ]; then
        local mtime now
        mtime="$(stat -c %Y "$latest" 2>/dev/null || printf '0')"
        now="$(date -u +%s)"
        if [ $(( now - mtime )) -lt 86400 ]; then
            stale=0
        fi
    fi
    if [ "$stale" -eq 0 ]; then
        log INFO "recon data is fresh (< 24h); reusing $latest"
        return 0
    fi
    log INFO "recon data is absent or older than 24h; running recon.sh"
    local args=(--quiet)
    if [ -n "$CI_PROFILE" ]; then args+=(--profile "$CI_PROFILE"); fi
    if [ -n "$BS_PROVIDER" ]; then args+=(--provider "$BS_PROVIDER"); fi
    local rrc=0
    "$SCRIPT_DIR/recon.sh" "${args[@]}" >/dev/null || rrc=$?
    log INFO "recon.sh exited $rrc"
    return 0
}

# Decide the profile and enforce INV-BS-2.
resolve_profile() {
    local latest="$CI_STATE/recon/latest.json"
    local name="$CI_PROFILE"
    if [ -z "$name" ] && [ -r "$latest" ]; then
        name="$(json_read "$latest" judgments.profile_recommended 2>/dev/null || true)"
    fi
    if [ -z "$name" ]; then
        die 2 "cannot determine a profile; pass --profile <name>"
    fi
    profile_load "$name"
    log INFO "profile '$PROFILE_NAME' selected (min ${PROFILE_MIN_VCPU} vCPU / ${PROFILE_MIN_RAM_MB} MB / ${PROFILE_MIN_DISK_GB} GB)"

    local verdict="inconclusive"
    if [ -r "$latest" ]; then
        verdict="$(json_read "$latest" judgments.sizing_verdict 2>/dev/null || printf 'inconclusive')"
    fi
    case "$verdict" in
        pass)
            log INFO "sizing verdict: pass"
            BS_PROFILE_FORCED=false
            ;;
        fail)
            die 1 "sizing verdict is fail for profile '$PROFILE_NAME'; see judgments.blockers[] in $latest. Choose a different profile or a bigger host"
            ;;
        *)
            if [ "$BS_FORCE_PROFILE" = "1" ]; then
                warn "sizing verdict is inconclusive; proceeding because --force-profile was given (INV-BS-2)"
                BS_PROFILE_FORCED=true
            else
                die 2 "sizing verdict is inconclusive for profile '$PROFILE_NAME'; re-run with --force-profile to accept the risk (INV-BS-2)"
            fi
            ;;
    esac
    return 0
}

init_state() {
    state_set schema_version 1 number
    state_set host_id "$(_ci_host_id)"
    state_set profile "$PROFILE_NAME"
    state_set profile_forced "${BS_PROFILE_FORCED:-false}" bool
    state_set node_role "$(profile_field node_role 2>/dev/null || printf 'single')"
    state_set lib_version "$LIB_VERSION"
    state_set last_recon_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local stage
    for stage in "${STAGE_ORDER[@]}"; do
        local cur
        cur="$(state_get "stages.$stage" 2>/dev/null || printf '')"
        if [ -z "$cur" ]; then
            state_set "stages.$stage" pending
        fi
    done
    state_set "repos.corp-infra-bootstrap" "$CI_REPO_VERSION"
    return 0
}

clone_repos() {
    local vfile="$BOOTSTRAP_DIR/versions.env"
    if [ ! -r "$vfile" ]; then
        warn "versions.env not found at $vfile; skipping repository checkout"
        return 0
    fi
    # shellcheck disable=SC1090  # path is computed at runtime, by design
    source "$vfile"
    local org="${CORP_INFRA_GITHUB_ORG:-}"
    if [ -z "$org" ] || [ "$org" = "<org>" ]; then
        warn "CORP_INFRA_GITHUB_ORG is not set in versions.env; skipping repository checkout"
        return 0
    fi
    require_cmd git

    local name repo version var dir
    for name in "${STAGE_ORDER[@]}"; do
        repo="corp-infra-$name"
        var="CORP_INFRA_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')_VERSION"
        version="${!var:-}"
        dir="$CI_ROOT/$name"
        if [ -z "$version" ]; then
            warn "$var is not pinned in versions.env; skipping $repo"
            continue
        fi
        if [ -d "$dir/.git" ]; then
            log INFO "$repo already checked out at $dir"
        else
            confirm "clone $org/$repo at v$version into $dir?" || {
                warn "$repo: clone declined"
                continue
            }
            retry 3 3 -- git clone --depth 1 --branch "v$version" \
                "https://github.com/$org/$repo.git" "$dir"
            log INFO "$repo cloned at v$version"
        fi
        state_set "repos.$repo" "$version"
    done
    return 0
}

stop_gate() {
    local title="$1"
    shift
    printf '\n'
    printf '  ==================================================================\n'
    printf '  STOP: %s\n' "$title"
    printf '  ==================================================================\n'
    local line
    for line in "$@"; do
        printf '    %s\n' "$line"
    done
    printf '\n'
    log WARN "STOP gate reached: $title"
    if confirm "confirm that the step above is done and continue?"; then
        return 0
    fi
    die 1 "stopped at the gate '$title' by operator decision"
}

run_stage() {
    local stage="$1"
    local repo dir entry script rc=0
    repo="$(stage_repo "$stage")"
    dir="$CI_ROOT/$repo"

    if [ ! -d "$dir" ]; then
        die 2 "stage '$stage': repository directory $dir is absent"
    fi

    state_set current_stage "$stage"
    log INFO "=== stage $stage ==="

    local entries=()
    if [ "$stage" = "ent-infra" ]; then
        mapfile -t entries < <(ent_infra_entries "$PROFILE_JSON")
    else
        mapfile -t entries < <(stage_entries "$stage")
    fi

    for entry in "${entries[@]}"; do
        script="$dir/scripts/$entry"
        if [ ! -x "$script" ]; then
            die 2 "stage '$stage': entry point $script is missing or not executable"
        fi
        log INFO "running $script --yes --profile $PROFILE_NAME"
        rc=0
        "$script" --yes --profile "$PROFILE_NAME" || rc=$?
        if [ "$rc" -ne 0 ]; then
            state_set "stages.$stage" failed
            log ERROR "stage '$stage': $entry exited $rc"
            return "$rc"
        fi
    done

    state_set "stages.$stage" ok
    log INFO "stage '$stage' complete"
    return 0
}

run_apply() {
    require_root
    ensure_layout
    run_recon_if_stale
    resolve_profile
    init_state
    clone_repos

    local drc=0
    "$SCRIPT_DIR/ensure-docker.sh" --yes || drc=$?
    if [ "$drc" -ne 0 ]; then
        die "$drc" "ensure-docker.sh exited $drc; Docker Engine is a hard prerequisite"
    fi

    # Which stages to run
    local todo=() started=0 stage
    if [ -n "$BS_STAGE" ]; then
        stage_repo "$BS_STAGE" >/dev/null || die 2 "unknown stage '$BS_STAGE'"
        todo=("$BS_STAGE")
    elif [ -n "$BS_FROM" ]; then
        stage_repo "$BS_FROM" >/dev/null || die 2 "unknown stage '$BS_FROM'"
        for stage in "${STAGE_ORDER[@]}"; do
            if [ "$stage" = "$BS_FROM" ]; then started=1; fi
            if [ "$started" = "1" ]; then todo+=("$stage"); fi
        done
    else
        todo=("${STAGE_ORDER[@]}")
    fi

    local prev="" idx=0 rc=0
    for stage in "${todo[@]}"; do
        # Transition rule: everything before this stage must be proven, both by
        # its marker and by the producing repo's live --check.
        for (( idx = 0; idx < ${#STAGE_ORDER[@]}; idx++ )); do
            prev="${STAGE_ORDER[$idx]}"
            if [ "$prev" = "$stage" ]; then
                break
            fi
            # Only enforce predecessors we are not about to run in this pass.
            local in_todo=0 t
            for t in "${todo[@]}"; do
                if [ "$t" = "$prev" ]; then
                    in_todo=1
                fi
            done
            if [ "$in_todo" = "1" ]; then
                continue
            fi
            require_stage "$(stage_marker "$prev")" "$(stage_check_cmd "$prev")" --check
        done

        rc=0
        run_stage "$stage" || rc=$?
        if [ "$rc" -ne 0 ]; then
            log ERROR "aborting: stage '$stage' failed with exit $rc"
            return "$rc"
        fi

        case "$stage" in
            security)
                stop_gate "move the private age key into escrow" \
                    "1. The private age key was printed once and was NOT written to the log." \
                    "2. Store it in at least two independent places: the TEAM password" \
                    "   manager safe (>= 2 holders) and one offline copy." \
                    "3. Then run, on this host:" \
                    "     $CI_ROOT/security/scripts/age-escrow.sh --attest <fingerprint>" \
                    "   It asks you to retype the fingerprint FROM the escrow copy - that" \
                    "   is what proves the copy exists and is readable."
                require_stage "secrets.escrow.ok" \
                    "$CI_ROOT/security/scripts/age-escrow.sh" --check
                ;;
            vpn-proxy)
                stop_gate "switch your session onto the VPN" \
                    "1. Import the peer config that install-wireguard.sh printed." \
                    "2. Bring the tunnel up and confirm you can reach 10.8.0.1." \
                    "3. Keep the current SSH session open until the new path works:" \
                    "   the next stages narrow SSH down to the VPN subnet." \
                    "4. Break-glass: a provider console or one whitelisted admin IP" \
                    "   must exist before you continue."
                ;;
        esac
    done

    state_set current_stage "done"
    state_set last_check_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    stop_gate "run the disaster recovery drill" \
        "The installation is not considered complete until a restore has been" \
        "proven, not assumed. Run:" \
        "  $CI_ROOT/backup/scripts/test-restore.sh --scenario vps-loss" \
        "The measured duration is appended to" \
        "  $CI_STATE/backup/drills.jsonl"

    local crc=0
    run_check || crc=$?
    return "$crc"
}

main() {
    trap_init
    parse_args "$@"
    log_init "$CI_REPO" "$CI_SCRIPT"

    local rc=0
    if [ "$CI_MODE" = "check" ]; then
        run_check || rc=$?
    else
        run_apply || rc=$?
    fi

    case "$rc" in
        0) log INFO  "bootstrap: OK" ;;
        1) log ERROR "bootstrap: FAIL" ;;
        *) log WARN  "bootstrap: INCONCLUSIVE" ;;
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
