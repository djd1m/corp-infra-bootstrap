#!/usr/bin/env bash
# sizing-check.sh - gates G1/G2/G3/G4 (condition C1).
#
# Two modes:
#   --static   recompute the gates from profiles/*.json alone, using the
#              profile's own min_ram_mb / min_disk_gb as the denominator.
#              This is the CI gate (G-07) and needs no host.
#   --check    recompute the gates against the measured facts in
#              $CI_STATE/recon/latest.json.
#
# Never mutates anything, in any mode.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
CI_REPO="corp-infra-bootstrap"; CI_SCRIPT="$(basename "$0")"

SZ_STATIC=0
SZ_ALL=0
SZ_WORST=0

usage() {
    cat <<EOF
Usage: sizing-check.sh [--static] [--all] [--check] [--profile <name>] [--quiet]

  --static           evaluate profiles against their own declared minimums;
                     no recon and no host required
  --all              every profile (only meaningful together with --static)
  --check            evaluate the selected profile against recon/latest.json
  --profile <name>   the profile to evaluate (default: the one with default:true)
  --quiet            log to file only; stdout is one result line
  --help / --version

Gates:
  G1  sum(steady_mb) <= 0.75 x RAM
  G2  sum(cap_mb)    <= 1.10 x RAM
  G3  sum(cap_mb) > 1.00 x RAM  =>  the profile must declare contention_policy
  G4  disk_total_gb  >= 1.15 x sum(disk_gb)

Exit: 0 every gate passed
      1 any gate failed
      2 no recon data, or the profile was not found

Examples:
  ./sizing-check.sh --static --all
  ./sizing-check.sh --check --profile core-16
EOF
}

# CI_EXTRA_SHIFT is the return channel to parse_args() in lib/common.sh: it
# tells the common parser how many argv entries this handler consumed. It is
# written here and read there, which shellcheck cannot see across the source.
# shellcheck disable=SC2034
ci_extra_arg() {
    case "$1" in
        --static) SZ_STATIC=1; CI_EXTRA_SHIFT=1 ;;
        --all)    SZ_ALL=1;    CI_EXTRA_SHIFT=1 ;;
        *) return 1 ;;
    esac
    return 0
}

_row() {
    printf '  %-38s %12s %12s %8s  %s\n' "$1" "$2" "$3" "$4" "$5"
}

_header() {
    printf '\n  %-38s %12s %12s %8s  %s\n' "GATE" "REQUIRED" "ACTUAL" "RATIO" "VERDICT"
    printf '  %s\n' "---------------------------------------------------------------------------------"
}

# evaluate_profile <profile.json> <ram_mb> <disk_gb> <source-label>
# Returns 0 when every gate passes, 1 otherwise.
evaluate_profile() {
    local file="$1" ram="$2" disk_total="$3" label="$4"
    local name steady cap disk contention failed=0

    name="$(_ci_read_scalar "$file" name name || basename "$file" .json)"
    steady="$(_ci_profile_sum steady_mb "$file")"
    cap="$(_ci_profile_sum cap_mb "$file")"
    disk="$(_ci_profile_sum disk_gb "$file")"
    contention="$(_ci_read_scalar "$file" contention_policy contention_policy || printf '')"

    printf '\nProfile: %s   (RAM %s MB, disk %s GB, source: %s)\n' \
        "$name" "$ram" "$disk_total" "$label"
    _header

    # G1
    local g1_req=$(( ram * 75 / 100 )) g1="PASS"
    if [ "$steady" -gt "$g1_req" ]; then g1="FAIL"; failed=1; fi
    _row "G1 sum(steady) <= 0.75 x RAM" "${g1_req} MB" "${steady} MB" \
        "$(_ci_ratio "$steady" "$ram")" "$g1"

    # G2
    local g2_req=$(( ram * 110 / 100 )) g2="PASS"
    if [ "$cap" -gt "$g2_req" ]; then g2="FAIL"; failed=1; fi
    _row "G2 sum(cap) <= 1.10 x RAM" "${g2_req} MB" "${cap} MB" \
        "$(_ci_ratio "$cap" "$ram")" "$g2"

    # G3 - overcommit must be declared, not hidden
    local g3="PASS" g3_req="-"
    if [ "$cap" -gt "$ram" ]; then
        g3_req="contention_policy"
        if [ -z "$contention" ] || [ "$contention" = "null" ]; then
            g3="FAIL"
            failed=1
        fi
    fi
    _row "G3 overcommit declares a policy" "$g3_req" "${contention:-null}" \
        "$(_ci_ratio "$cap" "$ram")" "$g3"

    # G4
    local g4_req=$(( disk * 115 / 100 )) g4="PASS"
    if [ "$disk_total" -lt "$g4_req" ]; then g4="FAIL"; failed=1; fi
    _row "G4 disk_total >= 1.15 x sum(disk)" "${g4_req} GB" "${disk_total} GB" \
        "$(_ci_ratio "$disk_total" "$g4_req")" "$g4"

    if [ "$failed" -eq 0 ]; then
        printf '\n  Result: PASS\n'
        return 0
    fi
    printf '\n  Result: FAIL\n'
    return 1
}

# Structural assertions that only make sense over the whole directory.
check_catalog() {
    local dir="$1"
    local defaults=0 rc=0 f name base
    local -r allowed_services=" gitlab tracker wiki site observability "
    local -r allowed_platform=" os-docker wireguard caddy backup opsagent runner ci-slot "

    for f in "$dir"/*.json; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .json)"
        name="$(_ci_read_scalar "$f" name name || printf '')"
        if [ "$name" != "$base" ]; then
            log ERROR "catalog: $f declares name '$name' but the file is '$base.json'"
            rc=1
        fi
        if [ "$(_ci_read_scalar "$f" default default || printf 'false')" = "true" ]; then
            defaults=$(( defaults + 1 ))
        fi
        if command -v python3 >/dev/null 2>&1; then
            local ids
            ids="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
out = []
for group in ("services", "platform"):
    for entry in data.get(group, []) or []:
        out.append(group[0] + ":" + str(entry.get("id")))
sys.stdout.write(" ".join(out))
' "$f" 2>/dev/null || printf '')"
            local item
            for item in $ids; do
                case "$item" in
                    s:*)
                        case "$allowed_services" in
                            *" ${item#s:} "*) ;;
                            *) log ERROR "catalog: $base has an out-of-set service id '${item#s:}'"; rc=1 ;;
                        esac
                        ;;
                    p:*)
                        case "$allowed_platform" in
                            *" ${item#p:} "*) ;;
                            *) log ERROR "catalog: $base has an out-of-set platform id '${item#p:}'"; rc=1 ;;
                        esac
                        ;;
                esac
            done
        fi
    done

    if [ "$defaults" -ne 1 ]; then
        log ERROR "catalog: exactly one profile must have default:true, found $defaults"
        rc=1
    else
        log INFO "catalog: exactly one default profile"
    fi
    return "$rc"
}

_default_profile_name() {
    local dir="$1" f
    for f in "$dir"/*.json; do
        [ -e "$f" ] || continue
        if [ "$(_ci_read_scalar "$f" default default || printf 'false')" = "true" ]; then
            basename "$f" .json
            return 0
        fi
    done
    return 1
}

run_static() {
    local dir
    dir="$(_ci_profile_dir)"
    if [ ! -d "$dir" ]; then
        log ERROR "profiles directory not found: $dir"
        return 2
    fi

    local rc=0
    if ! check_catalog "$dir"; then
        rc=1
    fi

    local targets=() f
    if [ "$SZ_ALL" = "1" ]; then
        for f in "$dir"/*.json; do
            [ -e "$f" ] || continue
            targets+=("$f")
        done
    else
        local name="$CI_PROFILE"
        if [ -z "$name" ]; then
            name="$(_default_profile_name "$dir")" || {
                log ERROR "no profile given and no profile has default:true"
                return 2
            }
        fi
        if [ ! -r "$dir/$name.json" ]; then
            log ERROR "profile '$name' not found in $dir"
            return 2
        fi
        targets+=("$dir/$name.json")
    fi

    if [ "${#targets[@]}" -eq 0 ]; then
        log ERROR "no profiles to evaluate in $dir"
        return 2
    fi

    local ram disk
    for f in "${targets[@]}"; do
        ram="$(_ci_read_scalar "$f" min_ram_mb min_ram_mb || printf '0')"
        disk="$(_ci_read_scalar "$f" min_disk_gb min_disk_gb || printf '0')"
        [[ "$ram" =~ ^[0-9]+$ ]] || ram=0
        [[ "$disk" =~ ^[0-9]+$ ]] || disk=0
        if [ "$ram" -eq 0 ]; then
            log ERROR "$f: min_ram_mb unreadable"
            rc=1
            continue
        fi
        if ! evaluate_profile "$f" "$ram" "$disk" "profile minimums"; then
            rc=1
        fi
    done
    return "$rc"
}

run_runtime() {
    local recon="$CI_STATE/recon/latest.json"
    if [ ! -r "$recon" ]; then
        log ERROR "no recon data at $recon; run recon.sh first"
        return 2
    fi

    local ram disk
    ram="$(json_read "$recon" facts.memory.mem_total_mb)" || {
        log ERROR "cannot read facts.memory.mem_total_mb from $recon"
        return 2
    }
    disk="$(json_read "$recon" facts.disk_root.total_gb)" || {
        log ERROR "cannot read facts.disk_root.total_gb from $recon"
        return 2
    }
    [[ "$ram" =~ ^[0-9]+$ ]] || { log ERROR "recon reports a non-numeric mem_total_mb"; return 2; }
    [[ "$disk" =~ ^[0-9]+$ ]] || { log ERROR "recon reports a non-numeric disk_root.total_gb"; return 2; }

    local dir name
    dir="$(_ci_profile_dir)"
    name="$CI_PROFILE"
    if [ -z "$name" ]; then
        name="$(state_get profile 2>/dev/null || true)"
    fi
    if [ -z "$name" ]; then
        name="$(json_read "$recon" judgments.profile_recommended 2>/dev/null || true)"
    fi
    if [ -z "$name" ]; then
        name="$(_default_profile_name "$dir")" || {
            log ERROR "cannot determine which profile to evaluate"
            return 2
        }
    fi
    if [ ! -r "$dir/$name.json" ]; then
        log ERROR "profile '$name' not found in $dir"
        return 2
    fi

    local min_ram
    min_ram="$(_ci_read_scalar "$dir/$name.json" min_ram_mb min_ram_mb || printf '0')"
    [[ "$min_ram" =~ ^[0-9]+$ ]] || min_ram=0
    if [ "$ram" -lt "$min_ram" ]; then
        log ERROR "MemTotal ${ram} MB is below profile '$name' min_ram_mb ${min_ram}"
        evaluate_profile "$dir/$name.json" "$ram" "$disk" "recon facts" || true
        return 1
    fi

    if evaluate_profile "$dir/$name.json" "$ram" "$disk" "recon facts"; then
        return 0
    fi
    return 1
}

main() {
    trap_init
    parse_args "$@"
    # This script never mutates, in any mode. Pinning check mode also stops
    # log_init from creating a log directory as a side effect.
    # CI_MODE is a lib-level global (lib/common.sh) read by log_init/guard_apply;
    # it is write-only here, which shellcheck cannot see across the source.
    # shellcheck disable=SC2034
    CI_MODE="check"
    log_init "$CI_REPO" "$CI_SCRIPT"

    if [ "$SZ_ALL" = "1" ] && [ "$SZ_STATIC" = "0" ]; then
        die 2 "--all is only meaningful together with --static"
    fi

    local rc=0
    if [ "$SZ_STATIC" = "1" ]; then
        run_static || rc=$?
    else
        run_runtime || rc=$?
    fi
    SZ_WORST="$rc"

    case "$SZ_WORST" in
        0) log INFO  "sizing-check: OK" ;;
        1) log ERROR "sizing-check: FAIL" ;;
        *) log WARN  "sizing-check: INCONCLUSIVE" ;;
    esac
    if [ "$CI_QUIET" = "1" ]; then
        case "$SZ_WORST" in
            0) printf 'OK: %s\n' "$CI_SCRIPT" >&9 ;;
            1) printf 'FAIL: %s\n' "$CI_SCRIPT" >&9 ;;
            *) printf 'INCONCLUSIVE: %s\n' "$CI_SCRIPT" >&9 ;;
        esac
    fi
    exit "$SZ_WORST"
}

exec 9>&1
main "$@"
