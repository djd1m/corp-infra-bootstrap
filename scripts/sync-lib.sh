#!/usr/bin/env bash
# sync-lib.sh - distribute the canonical lib/common.sh to the five sibling
# repositories (ADR-012 section 3, INV-BS-3, gate G-09).
#
# The canonical copy lives here. Every other repository carries a vendored
# copy that must be byte-identical whenever lib/VERSION matches. A vendored
# copy is never edited in place: change the canonical file, bump VERSION,
# run this script.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
CI_REPO="corp-infra-bootstrap"; CI_SCRIPT="$(basename "$0")"

BOOTSTRAP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
REPOS_DIR="$(cd -- "$BOOTSTRAP_DIR/.." && pwd)"
SIBLINGS=(security vpn-proxy backup ent-infra pop-agents)

usage() {
    cat <<EOF
Usage: sync-lib.sh [--check] [--yes] [--quiet]

  --check   compare only; report drift; zero mutations
  --yes     copy lib/common.sh and lib/VERSION into the five sibling repos
  --quiet   log to file only; stdout is one result line
  --help / --version

Canonical source: $BOOTSTRAP_DIR/lib/
Sibling repos   : ${SIBLINGS[*]}

Exit: 0 every copy is identical (or was successfully refreshed)
      1 version drift, or content drift at an equal version
      2 a repository or a lib file is missing
EOF
}

run_check() {
    local canon_lib="$BOOTSTRAP_DIR/lib/common.sh"
    local canon_ver="$BOOTSTRAP_DIR/lib/VERSION"
    local rc=0

    if [ ! -r "$canon_lib" ] || [ ! -r "$canon_ver" ]; then
        log ERROR "canonical lib is incomplete in $BOOTSTRAP_DIR/lib/"
        return 2
    fi
    local version
    read -r version < "$canon_ver"
    log INFO "canonical lib/VERSION = $version"

    printf '\n  %-14s %-10s %-12s %s\n' "REPO" "VERSION" "CONTENT" "PATH"
    printf '  %s\n' "-----------------------------------------------------------------------"
    printf '  %-14s %-10s %-12s %s\n' "bootstrap" "$version" "canonical" "$canon_lib"

    local name dir lib ver theirs
    for name in "${SIBLINGS[@]}"; do
        dir="$REPOS_DIR/$name"
        lib="$dir/lib/common.sh"
        ver="$dir/lib/VERSION"
        if [ ! -d "$dir" ]; then
            printf '  %-14s %-10s %-12s %s\n' "$name" "-" "MISSING" "$dir"
            log WARN "repository '$name' is not present at $dir"
            if [ "$rc" -eq 0 ]; then rc=2; fi
            continue
        fi
        if [ ! -r "$lib" ] || [ ! -r "$ver" ]; then
            printf '  %-14s %-10s %-12s %s\n' "$name" "-" "MISSING" "$dir/lib/"
            log WARN "repository '$name' has no vendored lib"
            if [ "$rc" -eq 0 ]; then rc=2; fi
            continue
        fi
        read -r theirs < "$ver"
        if [ "$theirs" != "$version" ]; then
            printf '  %-14s %-10s %-12s %s\n' "$name" "$theirs" "VERSION-DRIFT" "$lib"
            log ERROR "repository '$name' pins lib $theirs, canonical is $version"
            rc=1
            continue
        fi
        if cmp -s "$canon_lib" "$lib"; then
            printf '  %-14s %-10s %-12s %s\n' "$name" "$theirs" "identical" "$lib"
        else
            printf '  %-14s %-10s %-12s %s\n' "$name" "$theirs" "CONTENT-DRIFT" "$lib"
            log ERROR "repository '$name' has an edited vendored lib at the same version $theirs (INV-BS-3 violated)"
            rc=1
        fi
    done
    printf '\n'
    return "$rc"
}

run_apply() {
    local canon_lib="$BOOTSTRAP_DIR/lib/common.sh"
    local canon_ver="$BOOTSTRAP_DIR/lib/VERSION"
    if [ ! -r "$canon_lib" ] || [ ! -r "$canon_ver" ]; then
        die 2 "canonical lib is incomplete in $BOOTSTRAP_DIR/lib/"
    fi

    local rc=0 name dir
    for name in "${SIBLINGS[@]}"; do
        dir="$REPOS_DIR/$name"
        if [ ! -d "$dir" ]; then
            warn "repository '$name' is not present at $dir; skipped"
            if [ "$rc" -eq 0 ]; then rc=2; fi
            continue
        fi
        # Reality check: skip repos that are already identical.
        if [ -r "$dir/lib/common.sh" ] && cmp -s "$canon_lib" "$dir/lib/common.sh" \
           && [ -r "$dir/lib/VERSION" ] && cmp -s "$canon_ver" "$dir/lib/VERSION"; then
            log INFO "$name: already identical; no copy"
            continue
        fi
        confirm "overwrite the vendored lib in repos/$name?" || {
            warn "$name: declined"
            rc=1
            continue
        }
        mkdir -p "$dir/lib"
        cp -f "$canon_lib" "$dir/lib/common.sh"
        cp -f "$canon_ver" "$dir/lib/VERSION"
        log INFO "$name: vendored lib refreshed"
    done

    local crc=0
    run_check || crc=$?
    if [ "$crc" -ne 0 ] && [ "$rc" -eq 0 ]; then
        rc="$crc"
    fi
    return "$rc"
}

main() {
    trap_init
    parse_args "$@"
    if [ "$CI_MODE" != "apply" ] || [ "$CI_YES" != "1" ]; then
        # Comparison is read-only; keep log_init from creating directories.
        CI_MODE="check"
    fi
    log_init "$CI_REPO" "$CI_SCRIPT"

    local rc=0
    if [ "$CI_MODE" = "check" ]; then
        run_check || rc=$?
    else
        run_apply || rc=$?
    fi

    case "$rc" in
        0) log INFO  "sync-lib: OK" ;;
        1) log ERROR "sync-lib: FAIL" ;;
        *) log WARN  "sync-lib: INCONCLUSIVE" ;;
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
