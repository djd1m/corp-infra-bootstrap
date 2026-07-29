#!/usr/bin/env bash
# corp-infra canonical shell library (ADR-003 §5, ADR-012 §3).
#
# CANONICAL COPY. Lives in corp-infra-bootstrap; every other repo carries a
# byte-identical vendored copy plus lib/VERSION (gate G-09). Never edit a
# vendored copy: change this file, bump lib/VERSION, run scripts/sync-lib.sh.
#
# Public API: 35 functions, grouped as in plans/00-implementation-plan.md §3.1.
#   group 1 prologue/logging : log_init log warn die on_err trap_init
#   group 2 cli/modes        : parse_args confirm
#   group 3 preconditions    : require_root require_cmd require_stage retry
#   group 4 json without jq  : json_escape json_kv json_arr json_read
#   group 5 environment facts: detect_os detect_virt detect_pkg_mgr cpu_count
#                              ram_total_mb ram_avail_mb disk_total_gb
#                              disk_free_gb port_free svc_active
#                              container_healthy
#   group 6 orchestr. state  : state_get state_set state_mark state_check
#   group 7 profiles/sizing  : profile_load profile_field profile_service_field
#                              headroom_check
# Everything prefixed with _ci_ is private and is not a contract.
#
# Sourcing this file MUST NOT do anything except set variable defaults.
# Exit-code convention (plan §3.5): 0 ok / 1 fail / 2 inconclusive.

if [ -n "${_CI_COMMON_LOADED:-}" ]; then
    return 0
fi
_CI_COMMON_LOADED=1

# --------------------------------------------------------------------------
# defaults (all overridable from the environment, for tests)
# --------------------------------------------------------------------------
_CI_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${CI_ROOT:=/opt/corp-infra}"
: "${CI_STATE:=/var/lib/corp-infra}"
: "${CI_LOGDIR:=/var/log/corp-infra}"
: "${CI_ETC:=/etc/corp-infra}"
: "${CI_SRV:=/srv/corp-infra}"
: "${CI_MODE:=apply}"
: "${CI_YES:=0}"
: "${CI_QUIET:=0}"
: "${CI_DEBUG:=0}"
: "${CI_PROFILE:=}"
: "${CI_REPO:=corp-infra-unknown}"
: "${CI_SCRIPT:=unknown}"
: "${CI_REPO_VERSION:=1.0.0}"
: "${CI_LOG:=}"
: "${CI_PROFILE_DIR:=}"
: "${CI_PROVIDER_DIR:=}"
: "${CI_WARN_COUNT:=0}"

if [ -r "$_CI_LIB_DIR/VERSION" ]; then
    read -r LIB_VERSION < "$_CI_LIB_DIR/VERSION" || LIB_VERSION="0.0.0"
else
    LIB_VERSION="0.0.0"
fi
: "${LIB_VERSION:=0.0.0}"

# --------------------------------------------------------------------------
# public environment-facts / profile facade (plan §3.1, groups 5 and 7)
#
# detect_os, detect_virt, detect_pkg_mgr and profile_load set the variables
# below for the benefit of the *sourcing* script, not for this file. Every
# real consumer lives in another file, and most in another repo:
#   OS_TIER/OS_PRETTY/OS_KERNEL/OS_ARCH  bootstrap/scripts/recon.sh,
#                                        bootstrap/scripts/ensure-docker.sh
#   VIRT_DETECTED/VIRT_TYPE              bootstrap/scripts/recon.sh
#   PKG_MGR                              bootstrap/scripts/ensure-docker.sh,
#                                        security/scripts/harden.sh,
#                                        vpn-proxy/scripts/install-wireguard.sh,
#                                        backup/scripts/install-backup.sh
#   PROFILE_CONTENTION                   ent-infra/scripts/lib-service.sh
# ShellCheck cannot see those reads, so it reports SC2034 ("appears unused")
# for each facade member this file does not also happen to read internally.
#
# Declaring the facade as exported here is the remedy ShellCheck itself names
# ("or export if used externally"). It is done once, for the complete set, so
# the facade stays coherent -- deliberately in preference to a file-wide
# `disable=SC2034`, which would also hide genuine unused-variable bugs in the
# rest of this library. `export` without assignment only marks the names, it
# sets no values, so the "sourcing sets nothing but defaults" rule still holds.
# --------------------------------------------------------------------------
export OS_ID OS_VERSION_ID OS_ID_LIKE OS_PRETTY OS_KERNEL OS_ARCH OS_TIER
export VIRT_DETECTED VIRT_TYPE
export PKG_MGR
export PROFILE_NAME PROFILE_MIN_RAM_MB PROFILE_MIN_VCPU PROFILE_MIN_DISK_GB
export PROFILE_CONTENTION PROFILE_JSON

CI_ARGS=()
_CI_LOG_READY=0

# ==========================================================================
# group 1 - prologue, logging, errors
# ==========================================================================

# log <LEVEL> <msg...>  - "<ISO8601Z> <LEVEL> <repo>/<script>: <msg>"
# DEBUG is printed only when CI_DEBUG=1.
log() {
    local level="${1:-INFO}"
    shift || true
    case "$level" in
        DEBUG)
            [ "${CI_DEBUG:-0}" = "1" ] || return 0
            ;;
        INFO|WARN|ERROR) ;;
        *)
            set -- "$level" "$@"
            level="INFO"
            ;;
    esac
    printf '%s %s %s/%s: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$CI_REPO" "$CI_SCRIPT" "$*"
}

# warn <msg...> - WARN line plus CI_WARN_COUNT increment.
warn() {
    CI_WARN_COUNT=$(( CI_WARN_COUNT + 1 ))
    log WARN "$@"
}

# die <code> <msg...> - ERROR line, log path on stderr, exit <code>.
die() {
    local code="${1:-1}"
    shift || true
    log ERROR "$*"
    if [ -n "${CI_LOG:-}" ]; then
        printf 'see log: %s\n' "$CI_LOG" >&2
    fi
    exit "$code"
}

# log_init <repo> <script> - open $CI_LOGDIR/<repo>/<script>.log and tee into it.
# Idempotent. In --check mode it never creates directories (zero mutations):
# if the log directory is absent, logging stays on stdout only.
log_init() {
    local repo="${1:-$CI_REPO}"
    local script="${2:-$CI_SCRIPT}"
    CI_REPO="$repo"
    CI_SCRIPT="$script"

    if [ "$_CI_LOG_READY" = "1" ]; then
        return 0
    fi
    _CI_LOG_READY=1

    local dir="$CI_LOGDIR/$repo"
    if [ ! -d "$dir" ]; then
        if [ "$CI_MODE" = "check" ]; then
            # --check must not create anything, not even a log directory.
            CI_LOG=""
            return 0
        fi
        if ! mkdir -p "$dir" 2>/dev/null; then
            CI_LOG=""
            log WARN "cannot create log directory $dir; logging to stdout only"
            return 0
        fi
        chmod 0750 "$dir" 2>/dev/null || true
    fi

    local target="$dir/$script.log"
    if ! : >> "$target" 2>/dev/null; then
        CI_LOG=""
        log WARN "cannot write $target; logging to stdout only"
        return 0
    fi
    CI_LOG="$target"

    if [ "$CI_QUIET" = "1" ]; then
        exec >> "$CI_LOG" 2>&1
    else
        exec > >(tee -a "$CI_LOG") 2>&1
    fi
    log DEBUG "log opened: $CI_LOG"
    return 0
}

# on_err <lineno> <cmd> - ERR trap handler: line, command, FUNCNAME stack, exit 1.
on_err() {
    local lineno="${1:-?}"
    local cmd="${2:-?}"
    local i
    log ERROR "unhandled error at ${BASH_SOURCE[1]:-$CI_SCRIPT}:${lineno} -> ${cmd}"
    for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
        log ERROR "  stack[$i]: ${FUNCNAME[$i]}() ${BASH_SOURCE[$i]:-?}:${BASH_LINENO[$(( i - 1 ))]:-?}"
    done
    if [ -n "${CI_LOG:-}" ]; then
        printf 'see log: %s\n' "$CI_LOG" >&2
    fi
    exit 1
}

# _ci_cleanup - EXIT trap. Removes temp files registered with _ci_tmpfile.
# Must not change the script exit status, so it never calls exit.
_ci_cleanup() {
    local f
    if [ "${#_CI_TMPFILES[@]}" -gt 0 ]; then
        for f in "${_CI_TMPFILES[@]}"; do
            [ -n "$f" ] && rm -f -- "$f" 2>/dev/null
        done
    fi
    return 0
}
_CI_TMPFILES=()

# _ci_tmpfile <suffix> - create a temp file that _ci_cleanup will remove.
_ci_tmpfile() {
    local suffix="${1:-tmp}"
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/corp-infra.XXXXXX.$suffix")" || return 1
    _CI_TMPFILES+=("$f")
    printf '%s\n' "$f"
}

# trap_init - strict mode plus ERR and EXIT traps.
trap_init() {
    set -Eeuo pipefail
    trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
    trap '_ci_cleanup' EXIT
    return 0
}

# ==========================================================================
# group 2 - CLI and modes
# ==========================================================================

# _ci_default_usage - fallback when a script does not define usage().
_ci_default_usage() {
    cat <<EOF
Usage: $CI_SCRIPT [--check] [--yes] [--profile <name>] [--quiet] [--help] [--version]

  --check            doctor mode; zero mutations; exit 0 ok / 1 fail / 2 inconclusive
  --yes              non-interactive; every confirmation answered yes
  --profile <name>   deployment profile (see bootstrap/profiles/)
  --quiet            log to file only; stdout is a single result line
  --help             this text
  --version          "<repo> <repo_version> lib <lib_version>"

--check and --yes are mutually exclusive (exit 2).
EOF
}

# parse_args "$@" - common CLI. Sets CI_MODE/CI_YES/CI_PROFILE/CI_QUIET and CI_ARGS.
# Scripts with extra flags define ci_extra_arg(); it must either return 1
# (flag unknown) or set CI_EXTRA_SHIFT to the number of arguments consumed.
parse_args() {
    local saw_check=0 saw_yes=0
    CI_ARGS=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check)
                saw_check=1
                CI_MODE="check"
                ;;
            --yes|-y)
                saw_yes=1
                CI_YES=1
                ;;
            --quiet|-q)
                CI_QUIET=1
                ;;
            --profile)
                [ "$#" -ge 2 ] || die 2 "--profile requires an argument"
                CI_PROFILE="$2"
                shift
                ;;
            --profile=*)
                CI_PROFILE="${1#*=}"
                ;;
            --help|-h)
                if declare -F usage >/dev/null 2>&1; then usage; else _ci_default_usage; fi
                exit 0
                ;;
            --version)
                printf '%s %s lib %s\n' "$CI_REPO" "$CI_REPO_VERSION" "$LIB_VERSION"
                exit 0
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    CI_ARGS+=("$1")
                    shift
                done
                break
                ;;
            -*)
                CI_EXTRA_SHIFT=1
                if declare -F ci_extra_arg >/dev/null 2>&1 && ci_extra_arg "$@"; then
                    local n="${CI_EXTRA_SHIFT:-1}"
                    while [ "$n" -gt 1 ]; do
                        shift
                        n=$(( n - 1 ))
                    done
                else
                    die 2 "unknown flag: $1 (try --help)"
                fi
                ;;
            *)
                CI_ARGS+=("$1")
                ;;
        esac
        shift
    done

    if [ "$saw_check" = "1" ] && [ "$saw_yes" = "1" ]; then
        die 2 "--check and --yes are mutually exclusive"
    fi
    return 0
}

# confirm <prompt> - interactive guard before a mutation.
confirm() {
    local prompt="$*"
    if [ "$CI_MODE" = "check" ]; then
        warn "confirm() reached in --check mode (programming error): $prompt"
        return 0
    fi
    if [ "$CI_YES" = "1" ]; then
        log INFO "auto-confirmed (--yes): $prompt"
        return 0
    fi
    if [ ! -t 0 ]; then
        die 2 "no TTY for confirmation and --yes not given: $prompt"
    fi
    local answer=""
    printf '%s [y/N]: ' "$prompt"
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ==========================================================================
# group 3 - preconditions and reliability
# ==========================================================================

require_root() {
    if [ "$(id -u)" = "0" ]; then
        return 0
    fi
    die 1 "root privileges required (running as uid $(id -u))"
}

# require_cmd <cmd>... - one die with the complete list of what is missing.
require_cmd() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die 1 "missing required command(s): ${missing[*]}"
    fi
    return 0
}

# require_stage <stage> <check_cmd...> - INV-BS-1 / INV-GLOBAL-2.
# A marker is a claim, never a proof: the producer's live --check must also pass.
require_stage() {
    local stage="${1:?require_stage: stage required}"
    shift || true
    if [ "$#" -eq 0 ]; then
        die 2 "require_stage: live check command required for stage '$stage'"
    fi
    local rc=0
    state_check "$stage" || rc=$?
    case "$rc" in
        0) ;;
        1) die 2 "stage '$stage' marker reports failed" ;;
        *) die 2 "stage '$stage' marker missing, malformed or for another host" ;;
    esac
    if ! "$@" >/dev/null 2>&1; then
        die 2 "stage '$stage' marker is ok but live check failed: $*"
    fi
    log INFO "stage '$stage' confirmed: marker ok and live check ok"
    return 0
}

# retry <attempts> <base_delay_s> -- <cmd>... - exponential backoff, jitter +/-20%.
# Network operations only.
retry() {
    local attempts="${1:-3}"
    local base="${2:-2}"
    shift 2 || true
    if [ "${1:-}" = "--" ]; then
        shift
    fi
    if [ "$#" -eq 0 ]; then
        die 2 "retry: no command given"
    fi
    local n=1 rc=0 delay jitter
    while : ; do
        rc=0
        "$@" || rc=$?
        if [ "$rc" -eq 0 ]; then
            if [ "$n" -gt 1 ]; then
                log INFO "retry: '$1' succeeded on attempt $n/$attempts"
            fi
            return 0
        fi
        if [ "$n" -ge "$attempts" ]; then
            warn "retry: '$1' failed after $n attempt(s), last exit $rc"
            return "$rc"
        fi
        delay=$(( base * (2 ** (n - 1)) ))
        jitter=$(( (RANDOM % 41) - 20 ))
        delay=$(( delay + (delay * jitter / 100) ))
        [ "$delay" -lt 1 ] && delay=1
        warn "retry: '$1' exit $rc on attempt $n/$attempts; sleeping ${delay}s"
        sleep "$delay"
        n=$(( n + 1 ))
    done
}

# ==========================================================================
# group 4 - JSON without jq (ADR-003 §3)
# ==========================================================================

# json_escape <string> - pure bash JSON string escaping (no external process).
json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\b'/\\b}"
    if [[ "$s" =~ [[:cntrl:]] ]]; then
        local out="" i n c
        n=${#s}
        for (( i = 0; i < n; i++ )); do
            c="${s:i:1}"
            if [[ "$c" =~ [[:cntrl:]] ]]; then
                printf -v c '\\u%04x' "'$c"
            fi
            out+="$c"
        done
        s="$out"
    fi
    printf '%s' "$s"
}

# json_kv <key> <value> [string|number|bool|raw|null] - '"key": <value>', no comma.
json_kv() {
    local key="${1-}"
    local value="${2-}"
    local type="${3:-string}"
    case "$type" in
        string)
            printf '"%s": "%s"' "$(json_escape "$key")" "$(json_escape "$value")"
            ;;
        number)
            if [[ ! "$value" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
                die 1 "json_kv: value '$value' is not a JSON number (key '$key')"
            fi
            printf '"%s": %s' "$(json_escape "$key")" "$value"
            ;;
        bool)
            if [[ ! "$value" =~ ^(true|false)$ ]]; then
                die 1 "json_kv: value '$value' is not a JSON boolean (key '$key')"
            fi
            printf '"%s": %s' "$(json_escape "$key")" "$value"
            ;;
        raw)
            printf '"%s": %s' "$(json_escape "$key")" "$value"
            ;;
        null)
            printf '"%s": null' "$(json_escape "$key")"
            ;;
        *)
            die 1 "json_kv: unknown type '$type' (key '$key')"
            ;;
    esac
}

# json_arr <key> <type> <item>... - '"key": [ ... ]'; empty list -> [].
json_arr() {
    local key="${1-}"
    local type="${2:-string}"
    shift 2 || true
    local body="" first=1 item
    for item in "$@"; do
        if [ "$first" = "1" ]; then first=0; else body+=", "; fi
        case "$type" in
            string)
                body+="\"$(json_escape "$item")\""
                ;;
            number)
                if [[ ! "$item" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
                    die 1 "json_arr: item '$item' is not a JSON number (key '$key')"
                fi
                body+="$item"
                ;;
            bool)
                if [[ ! "$item" =~ ^(true|false)$ ]]; then
                    die 1 "json_arr: item '$item' is not a JSON boolean (key '$key')"
                fi
                body+="$item"
                ;;
            raw)
                body+="$item"
                ;;
            *)
                die 1 "json_arr: unknown type '$type' (key '$key')"
                ;;
        esac
    done
    printf '"%s": [%s]' "$(json_escape "$key")" "$body"
}

# json_read <file> <dotted.path> - scalar read. 0 value / 1 absent / 2 cannot check.
# python3 is guaranteed by research/07; without it the answer is inconclusive,
# never a failure.
json_read() {
    local file="${1-}"
    local path="${2-}"
    if [ ! -r "$file" ]; then
        log DEBUG "json_read: cannot read '$file'"
        return 2
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log DEBUG "json_read: python3 unavailable, result inconclusive"
        return 2
    fi
    local out rc=0
    out="$(python3 -c '
import json, sys
path, target = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        node = json.load(fh)
except Exception:
    sys.exit(2)
for part in [p for p in target.split(".") if p != ""]:
    if isinstance(node, list):
        try:
            node = node[int(part)]
        except (ValueError, IndexError):
            sys.exit(1)
    elif isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(1)
if isinstance(node, bool):
    sys.stdout.write("true" if node else "false")
elif node is None:
    sys.stdout.write("")
elif isinstance(node, (dict, list)):
    sys.stdout.write(json.dumps(node, separators=(",", ":")))
else:
    sys.stdout.write(str(node))
' "$file" "$path" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out"
        return 0
    fi
    return "$rc"
}

# _ci_json_scalar <file> <key> - grep fallback for flat top-level keys, used when
# python3 is unavailable. Only valid for files this repo generates itself.
_ci_json_scalar() {
    local file="${1-}" key="${2-}" line value
    [ -r "$file" ] || return 2
    line="$(grep -m1 -E "\"${key}\"[[:space:]]*:" "$file" 2>/dev/null)" || return 1
    value="${line#*:}"
    value="${value%,}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s\n' "$value"
    return 0
}

# _ci_read_scalar <file> <dotted.path> <flat_key> - json_read, then grep fallback.
_ci_read_scalar() {
    local file="$1" path="$2" flat="${3:-}"
    local out rc=0
    out="$(json_read "$file" "$path")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out"
        return 0
    fi
    if [ "$rc" -eq 2 ] && [ -n "$flat" ]; then
        _ci_json_scalar "$file" "$flat"
        return $?
    fi
    return "$rc"
}

# ==========================================================================
# group 5 - environment facts
# ==========================================================================

# detect_os - sets OS_ID OS_VERSION_ID OS_ID_LIKE OS_PRETTY OS_KERNEL OS_ARCH OS_TIER.
detect_os() {
    OS_ID="unknown"
    OS_VERSION_ID=""
    OS_ID_LIKE=""
    OS_PRETTY="unknown"
    OS_KERNEL="$(uname -r 2>/dev/null || printf 'unknown')"
    OS_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
    OS_TIER="unsupported"

    if [ -r /etc/os-release ]; then
        local line key value
        while IFS= read -r line; do
            case "$line" in
                ''|'#'*) continue ;;
            esac
            key="${line%%=*}"
            value="${line#*=}"
            value="${value%\"}"
            value="${value#\"}"
            case "$key" in
                ID) OS_ID="$value" ;;
                VERSION_ID) OS_VERSION_ID="$value" ;;
                ID_LIKE) OS_ID_LIKE="$value" ;;
                PRETTY_NAME) OS_PRETTY="$value" ;;
            esac
        done < /etc/os-release
    fi

    case "${OS_ID}:${OS_VERSION_ID}" in
        ubuntu:22.04|ubuntu:24.04|debian:12)
            OS_TIER="supported"
            ;;
        *)
            case " $OS_ID $OS_ID_LIKE " in
                *rhel*|*fedora*|*centos*)
                    OS_TIER="best-effort"
                    ;;
                *)
                    OS_TIER="unsupported"
                    ;;
            esac
            ;;
    esac
    return 0
}

# detect_virt - wrapper over systemd-detect-virt.
# INVERSION PINNED: systemd-detect-virt exits 0 when virtualisation IS present
# and 1 when the host is bare metal. Sets:
#   VIRT_DETECTED = 1 virtualised / 0 bare metal / 2 unknown (tool absent)
#   VIRT_TYPE     = kvm|none|... / "unknown"
detect_virt() {
    VIRT_TYPE="unknown"
    VIRT_DETECTED=2
    if ! command -v systemd-detect-virt >/dev/null 2>&1; then
        return 0
    fi
    local out="" rc=0
    out="$(systemd-detect-virt 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        VIRT_DETECTED=1
        VIRT_TYPE="${out:-unknown}"
    else
        VIRT_DETECTED=0
        VIRT_TYPE="${out:-none}"
    fi
    return 0
}

# detect_pkg_mgr - sets PKG_MGR in apt|dnf|yum|unknown.
detect_pkg_mgr() {
    PKG_MGR="unknown"
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    fi
    return 0
}

cpu_count() {
    local n=""
    if command -v nproc >/dev/null 2>&1; then
        n="$(nproc 2>/dev/null || printf '')"
    fi
    if [ -z "$n" ] && [ -r /proc/cpuinfo ]; then
        n="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '')"
    fi
    [[ "$n" =~ ^[0-9]+$ ]] || n=1
    printf '%s\n' "$n"
}

# _ci_meminfo_mb <MemTotal|MemAvailable|SwapTotal>
_ci_meminfo_mb() {
    local key="$1" k v rest kb=0
    if [ -r /proc/meminfo ]; then
        while read -r k v rest; do
            if [ "$k" = "${key}:" ]; then
                kb="$v"
                break
            fi
        done < /proc/meminfo
    fi
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    printf '%s\n' "$(( kb / 1024 ))"
}

ram_total_mb() { _ci_meminfo_mb MemTotal; }
ram_avail_mb() { _ci_meminfo_mb MemAvailable; }

# _ci_df_field <path> <2=total|4=available> - kilobytes from df -Pk.
_ci_df_field() {
    local path="${1:-/}" field="${2:-2}" out=""
    out="$(df -Pk "$path" 2>/dev/null | awk -v f="$field" 'NR==2 {print $f}')" || out=""
    [[ "$out" =~ ^[0-9]+$ ]] || out=0
    printf '%s\n' "$out"
}

disk_total_gb() {
    local kb
    kb="$(_ci_df_field "${1:-/}" 2)"
    printf '%s\n' "$(( kb / 1048576 ))"
}

disk_free_gb() {
    local kb
    kb="$(_ci_df_field "${1:-/}" 4)"
    printf '%s\n' "$(( kb / 1048576 ))"
}

# port_free <port> <tcp|udp> - 0 free / 1 in use / 2 nothing to check with.
# LOCAL LISTENERS ONLY. Outbound scanning of foreign hosts is forbidden
# (adminVPS offer, section 13 - see research/08-vps-providers.md §A5).
port_free() {
    local port="${1:?port_free: port required}"
    local proto="${2:-tcp}"
    case "$proto" in
        tcp|udp) ;;
        *) return 2 ;;
    esac

    if command -v ss >/dev/null 2>&1; then
        local flags out=""
        if [ "$proto" = "tcp" ]; then flags="-Hlnt"; else flags="-Hlnu"; fi
        out="$(ss "$flags" 2>/dev/null)" || return 2
        if printf '%s\n' "$out" | awk -v p=":${port}" '$4 ~ (p "$") { found = 1 } END { exit found ? 0 : 1 }'; then
            return 1
        fi
        return 0
    fi

    local procfile="/proc/net/${proto}"
    if [ ! -r "$procfile" ]; then
        return 2
    fi
    local hexport
    printf -v hexport '%04X' "$port"
    local want_state
    if [ "$proto" = "tcp" ]; then want_state="0A"; else want_state="07"; fi
    if awk -v hp=":$hexport" -v st="$want_state" \
        'NR>1 && index($2, hp) && toupper($4) == st { found = 1 } END { exit found ? 0 : 1 }' \
        "$procfile"; then
        return 1
    fi
    return 0
}

# svc_active <unit> - 0 active / 1 inactive / 2 no systemd.
svc_active() {
    local unit="${1:?svc_active: unit required}"
    if ! command -v systemctl >/dev/null 2>&1; then
        return 2
    fi
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        return 0
    fi
    return 1
}

# container_healthy <name> - 0 healthy (or running without healthcheck)
#                            1 present but not healthy / absent
#                            2 docker unavailable.
container_healthy() {
    local name="${1:?container_healthy: name required}"
    if ! command -v docker >/dev/null 2>&1; then
        return 2
    fi
    if ! docker info >/dev/null 2>&1; then
        return 2
    fi
    local status="" rc=0
    status="$(docker inspect -f \
        '{{if .State.Health}}{{.State.Health.Status}}{{else if .State.Running}}running{{else}}stopped{{end}}' \
        "$name" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    case "$status" in
        healthy|running) return 0 ;;
        *) return 1 ;;
    esac
}

# ==========================================================================
# group 6 - orchestration state
# ==========================================================================

# _ci_host_id - sha256:<hex> of /etc/machine-id (plan §3.2).
_ci_host_id() {
    local src=""
    if [ -r /etc/machine-id ]; then
        read -r src < /etc/machine-id || src=""
    fi
    if [ -z "$src" ] && [ -r /var/lib/dbus/machine-id ]; then
        read -r src < /var/lib/dbus/machine-id || src=""
    fi
    if [ -z "$src" ]; then
        src="fallback:$(hostname 2>/dev/null || printf 'unknown')"
    fi
    local hex=""
    if command -v sha256sum >/dev/null 2>&1; then
        hex="$(printf '%s' "$src" | sha256sum | cut -d' ' -f1)"
    elif command -v openssl >/dev/null 2>&1; then
        hex="$(printf '%s' "$src" | openssl dgst -sha256 -r | cut -d' ' -f1)"
    elif command -v python3 >/dev/null 2>&1; then
        hex="$(printf '%s' "$src" | python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
    fi
    if [[ ! "$hex" =~ ^[0-9a-f]{64}$ ]]; then
        hex="0000000000000000000000000000000000000000000000000000000000000000"
    fi
    printf 'sha256:%s\n' "$hex"
}

# state_get <key> - read from $CI_STATE/state.json. Missing file -> empty, exit 2.
state_get() {
    local key="${1:?state_get: key required}"
    local file="$CI_STATE/state.json"
    if [ ! -r "$file" ]; then
        log DEBUG "state_get: $file absent"
        return 2
    fi
    local rc=0 out
    out="$(json_read "$file" "$key")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out"
        return 0
    fi
    return "$rc"
}

# state_set <key> <value> [type] - atomic rewrite of state.json, 0640 root:root.
# Only the bootstrap repo may write it.
state_set() {
    local key="${1:?state_set: key required}"
    local value="${2-}"
    local type="${3:-string}"
    if [ "$CI_REPO" != "corp-infra-bootstrap" ]; then
        warn "state_set refused: only corp-infra-bootstrap may write state.json (caller: $CI_REPO)"
        return 1
    fi
    if [ "$CI_MODE" = "check" ]; then
        warn "state_set reached in --check mode (programming error): $key"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log ERROR "state_set: python3 unavailable, cannot rewrite state.json"
        return 1
    fi
    local dir="$CI_STATE"
    mkdir -p "$dir" || { log ERROR "state_set: cannot create $dir"; return 1; }
    local file="$dir/state.json"
    local tmp="$file.tmp"
    if ! python3 -c '
import json, os, sys
path, key, value, vtype = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}
if vtype == "number":
    parsed = float(value) if ("." in value or "e" in value.lower()) else int(value)
elif vtype == "bool":
    parsed = value == "true"
elif vtype == "null":
    parsed = None
elif vtype == "raw":
    parsed = json.loads(value)
else:
    parsed = value
node = data
parts = key.split(".")
for part in parts[:-1]:
    if not isinstance(node.get(part), dict):
        node[part] = {}
    node = node[part]
node[parts[-1]] = parsed
data.setdefault("schema_version", 1)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
' "$file" "$key" "$value" "$type"; then
        rm -f "$tmp" 2>/dev/null || true
        log ERROR "state_set: failed to write $key to $file"
        return 1
    fi
    chmod 0640 "$file" 2>/dev/null || true
    log INFO "state.json: $key = $value"
    return 0
}

# state_mark <stage> <ok|failed|pending> [evidence_json] - atomic marker, 0644.
state_mark() {
    local stage="${1:?state_mark: stage required}"
    local status="${2:?state_mark: status required}"
    local evidence="${3:-}"
    [ -n "$evidence" ] || evidence='{}'
    case "$status" in
        ok|failed|pending) ;;
        *) log ERROR "state_mark: invalid status '$status'"; return 1 ;;
    esac
    if [ "$CI_MODE" = "check" ]; then
        warn "state_mark reached in --check mode (programming error): $stage"
        return 1
    fi
    local dir="$CI_STATE/markers"
    if ! mkdir -p "$dir" 2>/dev/null; then
        log ERROR "state_mark: cannot create $dir"
        return 1
    fi
    local file="$dir/$stage.json"
    local tmp="$file.tmp"
    {
        printf '{\n'
        printf '  %s,\n' "$(json_kv schema_version 1 number)"
        printf '  %s,\n' "$(json_kv stage "$stage")"
        printf '  %s,\n' "$(json_kv status "$status")"
        printf '  %s,\n' "$(json_kv repo "$CI_REPO")"
        printf '  %s,\n' "$(json_kv repo_version "$CI_REPO_VERSION")"
        printf '  %s,\n' "$(json_kv lib_version "$LIB_VERSION")"
        printf '  %s,\n' "$(json_kv applied_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
        printf '  %s,\n' "$(json_kv host_id "$(_ci_host_id)")"
        printf '  %s\n' "$(json_kv evidence "$evidence" raw)"
        printf '}\n'
    } > "$tmp" || { rm -f "$tmp" 2>/dev/null || true; log ERROR "state_mark: write failed"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file" || { log ERROR "state_mark: rename failed"; return 1; }
    log INFO "marker $stage = $status"
    return 0
}

# state_check <stage> - 0 ok / 1 failed / 2 missing, malformed or wrong host.
state_check() {
    local stage="${1:?state_check: stage required}"
    local file="$CI_STATE/markers/$stage.json"
    if [ ! -r "$file" ]; then
        log DEBUG "state_check: marker $file absent"
        return 2
    fi
    local schema status host rc=0
    schema="$(_ci_read_scalar "$file" "schema_version" "schema_version")" || rc=$?
    if [ "$rc" -ne 0 ] || [ "$schema" != "1" ]; then
        log DEBUG "state_check: marker $stage has unexpected schema_version '$schema'"
        return 2
    fi
    status="$(_ci_read_scalar "$file" "status" "status")" || return 2
    host="$(_ci_read_scalar "$file" "host_id" "host_id")" || return 2
    if [ "$host" != "$(_ci_host_id)" ]; then
        log DEBUG "state_check: marker $stage belongs to another host"
        return 2
    fi
    case "$status" in
        ok) return 0 ;;
        failed) return 1 ;;
        *) return 2 ;;
    esac
}

# ==========================================================================
# group 7 - profiles and sizing
# ==========================================================================

_ci_profile_dir() {
    if [ -n "${CI_PROFILE_DIR:-}" ]; then
        printf '%s\n' "$CI_PROFILE_DIR"
    elif [ -d "$CI_ROOT/bootstrap/profiles" ]; then
        printf '%s\n' "$CI_ROOT/bootstrap/profiles"
    else
        printf '%s\n' "$_CI_LIB_DIR/../profiles"
    fi
}

_ci_provider_dir() {
    if [ -n "${CI_PROVIDER_DIR:-}" ]; then
        printf '%s\n' "$CI_PROVIDER_DIR"
    elif [ -d "$CI_ROOT/bootstrap/providers" ]; then
        printf '%s\n' "$CI_ROOT/bootstrap/providers"
    else
        printf '%s\n' "$_CI_LIB_DIR/../providers"
    fi
}

# profile_load <name> - sets PROFILE_NAME PROFILE_MIN_RAM_MB PROFILE_MIN_VCPU
# PROFILE_MIN_DISK_GB PROFILE_CONTENTION PROFILE_JSON.
profile_load() {
    local name="${1:?profile_load: name required}"
    local dir file
    dir="$(_ci_profile_dir)"
    file="$dir/$name.json"
    if [ ! -r "$file" ]; then
        die 2 "profile '$name' not found at $file"
    fi
    PROFILE_JSON="$file"
    PROFILE_NAME="$(_ci_read_scalar "$file" "name" "name")" || PROFILE_NAME="$name"
    PROFILE_MIN_RAM_MB="$(_ci_read_scalar "$file" "min_ram_mb" "min_ram_mb")" || PROFILE_MIN_RAM_MB=""
    PROFILE_MIN_VCPU="$(_ci_read_scalar "$file" "min_vcpu" "min_vcpu")" || PROFILE_MIN_VCPU=""
    PROFILE_MIN_DISK_GB="$(_ci_read_scalar "$file" "min_disk_gb" "min_disk_gb")" || PROFILE_MIN_DISK_GB=""
    PROFILE_CONTENTION="$(_ci_read_scalar "$file" "contention_policy" "contention_policy")" || PROFILE_CONTENTION=""
    if [[ ! "$PROFILE_MIN_RAM_MB" =~ ^[0-9]+$ ]]; then
        die 2 "profile '$name': min_ram_mb unreadable (need python3 or a well-formed profile)"
    fi
    [[ "$PROFILE_MIN_VCPU" =~ ^[0-9]+$ ]] || PROFILE_MIN_VCPU=0
    [[ "$PROFILE_MIN_DISK_GB" =~ ^[0-9]+$ ]] || PROFILE_MIN_DISK_GB=0
    log DEBUG "profile '$PROFILE_NAME' loaded from $PROFILE_JSON"
    return 0
}

# profile_field <dotted.path> - scalar read from the loaded profile.
profile_field() {
    local path="${1:?profile_field: path required}"
    if [ -z "${PROFILE_JSON:-}" ]; then
        log ERROR "profile_field: no profile loaded (call profile_load first)"
        return 2
    fi
    json_read "$PROFILE_JSON" "$path"
}

# profile_service_field <svc_id> <field> - services[] first, then platform[].
# 0 value / 1 service absent / 2 cannot read.
profile_service_field() {
    local svc="${1:?profile_service_field: service id required}"
    local field="${2:?profile_service_field: field required}"
    if [ -z "${PROFILE_JSON:-}" ]; then
        log ERROR "profile_service_field: no profile loaded"
        return 2
    fi
    if command -v python3 >/dev/null 2>&1; then
        local out rc=0
        out="$(python3 -c '
import json, sys
path, svc, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(2)
for group in ("services", "platform"):
    for entry in data.get(group, []) or []:
        if entry.get("id") == svc:
            if field not in entry:
                sys.exit(1)
            value = entry[field]
            if isinstance(value, bool):
                sys.stdout.write("true" if value else "false")
            elif isinstance(value, (dict, list)):
                sys.stdout.write(json.dumps(value, separators=(",", ":")))
            elif value is None:
                sys.stdout.write("")
            else:
                sys.stdout.write(str(value))
            sys.exit(0)
sys.exit(1)
' "$PROFILE_JSON" "$svc" "$field" 2>/dev/null)" || rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "$out"
            return 0
        fi
        return "$rc"
    fi
    # Fallback: profiles are generated with one service object per line.
    local line value
    line="$(grep -m1 -E "\"id\"[[:space:]]*:[[:space:]]*\"${svc}\"" "$PROFILE_JSON" 2>/dev/null)" || return 1
    value="$(printf '%s' "$line" | grep -o -E "\"${field}\"[[:space:]]*:[[:space:]]*[^,}]*" | head -n1)" || return 1
    [ -n "$value" ] || return 1
    value="${value#*:}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s\n' "$value"
    return 0
}

# _ci_profile_sum <steady_mb|cap_mb|disk_gb> <profile.json> - total over
# services[] plus platform[]. Private helper shared by recon.sh and
# sizing-check.sh so the two can never disagree about the arithmetic.
_ci_profile_sum() {
    local field="$1" file="$2"
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c '
import json, sys
field, path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
total = 0
for group in ("services", "platform"):
    for entry in data.get(group, []) or []:
        total += int(entry.get(field, 0) or 0)
sys.stdout.write(str(total))
' "$field" "$file" 2>/dev/null; then
            return 0
        fi
    fi
    # Fallback: profiles are generated with one entry object per line.
    local total=0 v
    while read -r v; do
        [[ "$v" =~ ^[0-9]+$ ]] && total=$(( total + v ))
    done < <(grep -o -E "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]+" "$file" 2>/dev/null \
             | grep -o -E '[0-9]+$' || true)
    printf '%s' "$total"
    return 0
}

# _ci_ratio <num> <den> - fixed point ratio with three decimals. No floats:
# every sizing number in this repo is integer arithmetic.
_ci_ratio() {
    local n="${1:-0}" d="${2:-0}" v
    if [ "$d" -le 0 ]; then
        printf '0.000\n'
        return 0
    fi
    v=$(( n * 1000 / d ))
    printf '%d.%03d\n' "$(( v / 1000 ))" "$(( v % 1000 ))"
}

# headroom_check <svc_id> - gate G5 / INV-ENT-4.
# MemAvailable must be at least steady_mb + gates.g5_headroom_mb (default 512).
headroom_check() {
    local svc="${1:?headroom_check: service id required}"
    local steady headroom avail need rc=0
    steady="$(profile_service_field "$svc" steady_mb)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        log ERROR "headroom_check: service '$svc' has no steady_mb in profile ${PROFILE_NAME:-?}"
        return 1
    fi
    [[ "$steady" =~ ^[0-9]+$ ]] || steady=0
    headroom="$(profile_field "gates.g5_headroom_mb" 2>/dev/null || printf '512')"
    [[ "$headroom" =~ ^[0-9]+$ ]] || headroom=512
    avail="$(ram_avail_mb)"
    need=$(( steady + headroom ))
    if [ "$avail" -ge "$need" ]; then
        log INFO "headroom ok for '$svc': MemAvailable ${avail} MB >= required ${need} MB (steady ${steady} + headroom ${headroom})"
        return 0
    fi
    log ERROR "headroom FAIL for '$svc': MemAvailable ${avail} MB < required ${need} MB (steady ${steady} + headroom ${headroom})"
    return 1
}
