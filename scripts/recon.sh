#!/usr/bin/env bash
# recon.sh - the single source of environment facts (FR-1, AC-3, INV-BS-4).
#
# Emits a versioned JSON document on stdout, generated with pure bash
# (json_escape / json_kv / json_arr from lib/common.sh). jq is NOT a dependency
# and NOT a fallback; python3 is used only to validate and to read, never to
# generate (ADR-003 section 3).
#
# HARD RULE: recon never mutates anything except its own output files, and it
# never touches the network. Port facts come from LOCAL listeners only
# (ss -Hln); scanning a foreign host is forbidden by the adminVPS offer
# (see research/08-vps-providers.md section A5) and no corp-infra script does it.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
CI_REPO="corp-infra-bootstrap"; CI_SCRIPT="$(basename "$0")"

RECON_JSON_ONLY=0
RECON_PROVIDER=""
RECON_EXIT=0

usage() {
    cat <<EOF
Usage: recon.sh [--check] [--json] [--profile <name>] [--provider <id>] [--quiet]

Collects environment facts and derives sizing judgments. Writes
\$CI_STATE/recon/latest.json plus a copy in recon/history/<ts>.json.

  --check            validate the existing latest.json; zero writes
  --json             print JSON to stdout only; zero writes, no logging
  --profile <name>   assert a profile instead of the recommended one
  --provider <id>    override the provider heuristic (adminvps-ru, adminvps-kz,
                     yandex-kz, generic)
  --quiet            log to file only; stdout is one result line
  --help / --version

Exit: 0 the profile passes sizing
      1 judgments.blockers[] is not empty
      2 MemTotal below profile.min_ram_mb, or sizing_verdict is inconclusive

Examples:
  ./recon.sh --json | python3 -m json.tool
  ./recon.sh --profile core-16
  ./recon.sh --check
EOF
}

# CI_EXTRA_SHIFT is the return channel to parse_args() in lib/common.sh: it
# tells the common parser how many argv entries this handler consumed. It is
# written here and read there, which shellcheck cannot see across the source.
# shellcheck disable=SC2034
ci_extra_arg() {
    case "$1" in
        --json)
            RECON_JSON_ONLY=1
            CI_EXTRA_SHIFT=1
            ;;
        --provider)
            [ "$#" -ge 2 ] || die 2 "--provider requires an argument"
            RECON_PROVIDER="$2"
            CI_EXTRA_SHIFT=2
            ;;
        --provider=*)
            RECON_PROVIDER="${1#*=}"
            CI_EXTRA_SHIFT=1
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

_bool() { if [ "${1:-0}" = "1" ]; then printf 'true\n'; else printf 'false\n'; fi; }

# _sw <binary> <version-command...> - one facts.software entry as raw JSON.
_sw() {
    local bin="$1"
    shift
    if ! command -v "$bin" >/dev/null 2>&1; then
        printf '{%s, %s}' "$(json_kv present false bool)" "$(json_kv version "" null)"
        return 0
    fi
    local ver=""
    ver="$("$@" 2>/dev/null | head -n1 || true)"
    ver="${ver//$'\n'/ }"
    if [ -z "$ver" ]; then
        printf '{%s, %s}' "$(json_kv present true bool)" "$(json_kv version "" null)"
    else
        printf '{%s, %s}' "$(json_kv present true bool)" "$(json_kv version "$ver")"
    fi
}

# _component <id> <detected_by> <0|1 present> <version|""> - existing_components entry.
_component() {
    local id="$1" by="$2" present="$3" ver="${4:-}"
    local vjson
    if [ -n "$ver" ]; then
        vjson="$(json_kv version "$ver")"
    else
        vjson="$(json_kv version "" null)"
    fi
    printf '{%s, %s, %s, %s}' \
        "$(json_kv id "$id")" \
        "$(json_kv present "$(_bool "$present")" bool)" \
        "$(json_kv detected_by "$by")" \
        "$vjson"
}

# --------------------------------------------------------------------------
# fact collection - measurement only, no conclusions
# --------------------------------------------------------------------------

collect_facts() {
    detect_os
    detect_virt
    detect_pkg_mgr

    F_HOST_ID="$(_ci_host_id)"

    # cpu
    F_VCPU="$(cpu_count)"
    F_CPU_MODEL="unknown"
    if [ -r /proc/cpuinfo ]; then
        F_CPU_MODEL="$(grep -m1 -E '^(model name|Model)[[:space:]]*:' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)"
        [ -n "$F_CPU_MODEL" ] || F_CPU_MODEL="unknown"
    fi

    # memory
    F_MEM_TOTAL="$(ram_total_mb)"
    F_MEM_AVAIL="$(ram_avail_mb)"
    F_SWAP_TOTAL="$(_ci_meminfo_mb SwapTotal)"

    # disks
    F_DISK_ITEMS=()
    F_DISK_ROOT_TOTAL=0
    F_DISK_ROOT_FREE=0
    local fs type total used avail cap mount
    while read -r fs type total used avail cap mount; do
        case "$fs" in Filesystem) continue ;; esac
        case "$type" in
            tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|cgroup|cgroup2|autofs|fuse.*|nsfs|tracefs|debugfs|configfs|ramfs|mqueue|hugetlbfs|binfmt_misc|pstore|efivarfs|securityfs|bpf)
                continue
                ;;
        esac
        [ -n "$mount" ] || continue
        F_DISK_ITEMS+=("$(printf '{%s, %s, %s, %s}' \
            "$(json_kv mount "$mount")" \
            "$(json_kv fstype "$type")" \
            "$(json_kv total_gb "$(( total / 1048576 ))" number)" \
            "$(json_kv free_gb "$(( avail / 1048576 ))" number)")")
        if [ "$mount" = "/" ]; then
            F_DISK_ROOT_TOTAL=$(( total / 1048576 ))
            F_DISK_ROOT_FREE=$(( avail / 1048576 ))
        fi
        # 'used' and 'cap' are read to advance the field split only.
        : "$used" "$cap"
    done < <(df -PkT 2>/dev/null || true)
    if [ "${#F_DISK_ITEMS[@]}" -eq 0 ]; then
        F_DISK_ITEMS+=("$(printf '{%s, %s, %s, %s}' \
            "$(json_kv mount "/")" \
            "$(json_kv fstype "unknown")" \
            "$(json_kv total_gb "$(disk_total_gb /)" number)" \
            "$(json_kv free_gb "$(disk_free_gb /)" number)")")
        F_DISK_ROOT_TOTAL="$(disk_total_gb /)"
        F_DISK_ROOT_FREE="$(disk_free_gb /)"
    fi

    # network - local sources only, never an outbound request
    F_HOSTNAME="$(hostname 2>/dev/null || printf 'unknown')"
    F_FQDN="$(hostname -f 2>/dev/null || printf '%s' "$F_HOSTNAME")"
    [ -n "$F_FQDN" ] || F_FQDN="$F_HOSTNAME"
    F_IFACE=""
    F_MTU=""
    if command -v ip >/dev/null 2>&1; then
        F_IFACE="$(ip -4 route show default 2>/dev/null | awk '/^default/ {for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
    fi
    if [ -n "$F_IFACE" ] && [ -r "/sys/class/net/$F_IFACE/mtu" ]; then
        read -r F_MTU < "/sys/class/net/$F_IFACE/mtu" || F_MTU=""
    fi
    [[ "$F_MTU" =~ ^[0-9]+$ ]] || F_MTU=""
    F_HAS_IPV6=0
    [ -d /proc/sys/net/ipv6 ] && F_HAS_IPV6=1
    # A globally routable IPv4 on a local interface: decided locally, the
    # address itself is never resolved through an external service.
    F_PUBLIC_IPV4_KNOWN=0
    if command -v ip >/dev/null 2>&1; then
        if ip -4 -o addr show scope global 2>/dev/null \
            | awk '{print $4}' \
            | grep -q -v -E '^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)'; then
            F_PUBLIC_IPV4_KNOWN=1
        fi
    fi

    # listening sockets - LOCAL ONLY
    F_PORTS_NULL=0
    F_PORT_ITEMS=()
    if command -v ss >/dev/null 2>&1; then
        local proto line local_addr addr port
        for proto in tcp udp; do
            local flags
            if [ "$proto" = "tcp" ]; then flags="-Hlnt"; else flags="-Hlnu"; fi
            while read -r line; do
                [ -n "$line" ] || continue
                local_addr="$(printf '%s\n' "$line" | awk '{print $4}')"
                [ -n "$local_addr" ] || continue
                port="${local_addr##*:}"
                addr="${local_addr%:*}"
                [[ "$port" =~ ^[0-9]+$ ]] || continue
                [ -n "$addr" ] || addr="*"
                F_PORT_ITEMS+=("$(printf '{%s, %s, %s}' \
                    "$(json_kv proto "$proto")" \
                    "$(json_kv addr "$addr")" \
                    "$(json_kv port "$port" number)")")
            done < <(ss "$flags" 2>/dev/null || true)
        done
    else
        F_PORTS_NULL=1
        RECON_WARNINGS+=("ss is not available; facts.ports.listening is null")
    fi

    # software inventory
    F_SW_DOCKER="$(_sw docker docker --version)"
    if command -v docker >/dev/null 2>&1; then
        F_SW_COMPOSE="$(_sw docker docker compose version)"
    else
        F_SW_COMPOSE="$(printf '{%s, %s}' "$(json_kv present false bool)" "$(json_kv version "" null)")"
    fi
    F_SW_SYSTEMD="$(_sw systemctl systemctl --version)"
    F_SW_WIREGUARD="$(_sw wg wg --version)"
    F_SW_RESTIC="$(_sw restic restic version)"
    F_SW_SOPS="$(_sw sops sops --version)"
    F_SW_AGE="$(_sw age age --version)"
    F_SW_PYTHON3="$(_sw python3 python3 --version)"
    F_SW_BASH="$(_sw bash bash --version)"
    F_SW_SHELLCHECK="$(_sw shellcheck shellcheck --version)"

    # limits
    F_CGROUP_VERSION=""
    if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
        F_CGROUP_VERSION=2
    elif [ -d /sys/fs/cgroup/memory ]; then
        F_CGROUP_VERSION=1
    fi
    F_SWAP_ENABLED=0
    [ "$F_SWAP_TOTAL" -gt 0 ] && F_SWAP_ENABLED=1
    F_NOFILE_SOFT="$(ulimit -Sn 2>/dev/null || printf '')"
    [[ "$F_NOFILE_SOFT" =~ ^[0-9]+$ ]] || F_NOFILE_SOFT=""
    F_SELINUX=""
    if command -v getenforce >/dev/null 2>&1; then
        F_SELINUX="$(getenforce 2>/dev/null || printf '')"
    elif [ -d /sys/fs/selinux ]; then
        F_SELINUX="present"
    else
        F_SELINUX="absent"
    fi
    F_APPARMOR="absent"
    if [ -r /sys/module/apparmor/parameters/enabled ]; then
        local aa=""
        read -r aa < /sys/module/apparmor/parameters/enabled || aa=""
        case "$aa" in Y|y) F_APPARMOR="enabled" ;; *) F_APPARMOR="disabled" ;; esac
    fi

    # existing components
    F_COMPONENT_ITEMS=()
    _probe_container gitlab corp-gitlab
    _probe_container caddy-public corp-caddy-public
    _probe_container caddy-internal corp-caddy-internal
    _probe_container prometheus corp-prometheus
    _probe_container grafana corp-grafana
    _probe_container loki corp-loki
    local wg_present=0 wg_by="test -e"
    if command -v ip >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
        wg_present=1
        wg_by="ip link show wg0"
    elif [ -e /etc/wireguard/wg0.conf ]; then
        wg_present=1
    fi
    F_COMPONENT_ITEMS+=("$(_component wg0 "$wg_by" "$wg_present")")
    local docker_active=0
    if svc_active docker; then docker_active=1; fi
    F_COMPONENT_ITEMS+=("$(_component docker-daemon "systemctl is-active" "$docker_active")")
    local corp_state=0
    [ -d "$CI_STATE" ] && corp_state=1
    F_COMPONENT_ITEMS+=("$(_component corp-infra-state "test -d $CI_STATE" "$corp_state")")

    # provider hint - DMI / cloud-init / hostname suffix. Never a metadata request.
    F_PROVIDER_HINT=""
    local dmi=""
    [ -r /sys/class/dmi/id/sys_vendor ] && dmi+="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true) "
    [ -r /sys/class/dmi/id/product_name ] && dmi+="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true) "
    dmi+="$F_HOSTNAME"
    shopt -s nocasematch
    if [[ "$dmi" == *yandex* ]]; then
        F_PROVIDER_HINT="yandex-kz"
    elif [[ "$dmi" == *adminvps* ]]; then
        if [[ "$dmi" == *kz* ]]; then
            F_PROVIDER_HINT="adminvps-kz"
        else
            F_PROVIDER_HINT="adminvps-ru"
        fi
    fi
    shopt -u nocasematch
    return 0
}

_probe_container() {
    local id="$1" name="$2" present=0 rc=0
    container_healthy "$name" || rc=$?
    case "$rc" in
        0) present=1 ;;
        *) present=0 ;;
    esac
    F_COMPONENT_ITEMS+=("$(_component "$id" "docker inspect $name" "$present")")
}

# --------------------------------------------------------------------------
# judgments - everything derived lives here and nowhere else
# --------------------------------------------------------------------------

derive_judgments() {
    J_OS_TIER="$OS_TIER"

    # requested profile: --profile wins, then state.json
    J_PROFILE_REQUESTED=""
    if [ -n "$CI_PROFILE" ]; then
        J_PROFILE_REQUESTED="$CI_PROFILE"
    else
        local from_state=""
        from_state="$(state_get profile 2>/dev/null || true)"
        [ -n "$from_state" ] && J_PROFILE_REQUESTED="$from_state"
    fi

    # recommendation derived from measured RAM and root disk
    if [ "$F_MEM_TOTAL" -ge 32768 ] && [ "$F_DISK_ROOT_TOTAL" -ge 500 ]; then
        J_PROFILE_RECOMMENDED="all-in-one-32"
    elif [ "$F_MEM_TOTAL" -ge 16384 ] && [ "$F_DISK_ROOT_TOTAL" -ge 350 ]; then
        J_PROFILE_RECOMMENDED="core-16"
    elif [ "$F_MEM_TOTAL" -ge 12288 ] && [ "$F_DISK_ROOT_TOTAL" -ge 200 ]; then
        J_PROFILE_RECOMMENDED="two-vps-split-b"
    else
        J_PROFILE_RECOMMENDED="core-16"
        RECON_BLOCKERS+=("no profile fits this host: ${F_MEM_TOTAL} MB RAM and ${F_DISK_ROOT_TOTAL} GB root disk are below the smallest supported profile (two-vps-split-b: 12288 MB / 200 GB)")
    fi

    local effective="${J_PROFILE_REQUESTED:-$J_PROFILE_RECOMMENDED}"
    local dir file
    dir="$(_ci_profile_dir)"
    file="$dir/$effective.json"

    J_VERDICT="pass"
    local sum_steady=0 sum_cap=0 sum_disk=0 min_ram=0 min_vcpu=0 min_disk=0

    if [ ! -r "$file" ]; then
        J_VERDICT="inconclusive"
        RECON_WARNINGS+=("profile '$effective' not readable at $file; sizing is inconclusive")
        J_G1="$(_gate_json "G1 steady <= 0.75 x RAM" 0 0 0.000 inconclusive)"
        J_G2="$(_gate_json "G2 cap <= 1.10 x RAM" 0 0 0.000 inconclusive)"
        J_G4="$(_gate_json "G4 disk_total >= 1.15 x sum(disk)" 0 0 0.000 inconclusive)"
    else
        sum_steady="$(_ci_profile_sum steady_mb "$file")"
        sum_cap="$(_ci_profile_sum cap_mb "$file")"
        sum_disk="$(_ci_profile_sum disk_gb "$file")"
        min_ram="$(_ci_read_scalar "$file" min_ram_mb min_ram_mb || printf '0')"
        min_vcpu="$(_ci_read_scalar "$file" min_vcpu min_vcpu || printf '0')"
        min_disk="$(_ci_read_scalar "$file" min_disk_gb min_disk_gb || printf '0')"
        [[ "$min_ram" =~ ^[0-9]+$ ]] || min_ram=0
        [[ "$min_vcpu" =~ ^[0-9]+$ ]] || min_vcpu=0
        [[ "$min_disk" =~ ^[0-9]+$ ]] || min_disk=0

        # G1: sum(steady) must fit in 75% of measured RAM
        local g1_required=$(( F_MEM_TOTAL * 75 / 100 )) g1_verdict="pass"
        [ "$sum_steady" -le "$g1_required" ] || g1_verdict="fail"
        J_G1="$(_gate_json "G1 steady <= 0.75 x RAM" "$g1_required" "$sum_steady" "$(_ci_ratio "$sum_steady" "$F_MEM_TOTAL")" "$g1_verdict")"

        # G2: sum(cap) may overcommit up to 110% of measured RAM
        local g2_required=$(( F_MEM_TOTAL * 110 / 100 )) g2_verdict="pass"
        [ "$sum_cap" -le "$g2_required" ] || g2_verdict="fail"
        J_G2="$(_gate_json "G2 cap <= 1.10 x RAM" "$g2_required" "$sum_cap" "$(_ci_ratio "$sum_cap" "$F_MEM_TOTAL")" "$g2_verdict")"

        # G4: root disk must exceed the profile disk sum with 15% headroom
        local g4_required=$(( sum_disk * 115 / 100 )) g4_verdict="pass"
        [ "$F_DISK_ROOT_TOTAL" -ge "$g4_required" ] || g4_verdict="fail"
        J_G4="$(_gate_json "G4 disk_total >= 1.15 x sum(disk)" "$g4_required" "$F_DISK_ROOT_TOTAL" "$(_ci_ratio "$F_DISK_ROOT_TOTAL" "$g4_required")" "$g4_verdict")"

        if [ "$F_MEM_TOTAL" -lt "$min_ram" ]; then
            J_VERDICT="fail"
            RECON_BLOCKERS+=("MemTotal ${F_MEM_TOTAL} MB is below profile '$effective' min_ram_mb ${min_ram}")
            RECON_MEM_SHORT=1
        fi
        if [ "$F_VCPU" -lt "$min_vcpu" ]; then
            J_VERDICT="fail"
            RECON_BLOCKERS+=("vCPU ${F_VCPU} is below profile '$effective' min_vcpu ${min_vcpu}")
        fi
        if [ "$F_DISK_ROOT_TOTAL" -lt "$min_disk" ]; then
            J_VERDICT="fail"
            RECON_BLOCKERS+=("root disk ${F_DISK_ROOT_TOTAL} GB is below profile '$effective' min_disk_gb ${min_disk}")
        fi
        if [ "$g1_verdict" = "fail" ] || [ "$g2_verdict" = "fail" ] || [ "$g4_verdict" = "fail" ]; then
            J_VERDICT="fail"
            RECON_BLOCKERS+=("sizing gate failed on profile '$effective': G1=$g1_verdict G2=$g2_verdict G4=$g4_verdict")
        fi
    fi

    # provider policy - config, never code (plan section 9.1)
    local pid="" psource="default"
    if [ -n "$RECON_PROVIDER" ]; then
        pid="$RECON_PROVIDER"
        psource="flag"
    elif [ -n "$F_PROVIDER_HINT" ]; then
        pid="$F_PROVIDER_HINT"
        psource="heuristic"
    else
        pid="generic"
        psource="default"
    fi
    local pfile
    pfile="$(_ci_provider_dir)/$pid.json"
    local p_vpn="true" p_scan="false" p_s3="false"
    if [ -r "$pfile" ]; then
        p_vpn="$(_ci_read_scalar "$pfile" vpn_hub_allowed vpn_hub_allowed || printf 'true')"
        p_scan="$(_ci_read_scalar "$pfile" outbound_portscan_allowed outbound_portscan_allowed || printf 'false')"
        p_s3="$(_ci_read_scalar "$pfile" s3_native s3_native || printf 'false')"
    else
        RECON_WARNINGS+=("provider catalog entry '$pid' not found at $pfile; assuming permissive defaults")
        pid="generic"
        psource="default"
    fi
    [[ "$p_vpn" =~ ^(true|false)$ ]] || p_vpn="true"
    [[ "$p_scan" =~ ^(true|false)$ ]] || p_scan="false"
    [[ "$p_s3" =~ ^(true|false)$ ]] || p_s3="false"
    J_PROVIDER_POLICY="$(printf '{%s, %s, %s, %s, %s}' \
        "$(json_kv id "$pid")" \
        "$(json_kv vpn_hub_allowed "$p_vpn" bool)" \
        "$(json_kv outbound_portscan_allowed "$p_scan" bool)" \
        "$(json_kv s3_native "$p_s3" bool)" \
        "$(json_kv source "$psource")")"

    # non-blocking observations
    if [ "$OS_TIER" = "unsupported" ]; then
        RECON_BLOCKERS+=("OS tier is unsupported: ${OS_PRETTY} (${OS_ID} ${OS_VERSION_ID})")
    elif [ "$OS_TIER" = "best-effort" ]; then
        RECON_WARNINGS+=("OS tier is best-effort: ${OS_PRETTY}; the apt path is the tested one")
    fi
    if [ "$F_SWAP_ENABLED" = "1" ]; then
        RECON_WARNINGS+=("swap is enabled (${F_SWAP_TOTAL} MB); the architecture requires swap off with systemd-oomd instead (05_architecture section 1)")
    fi
    if [ "$VIRT_DETECTED" = "2" ]; then
        RECON_WARNINGS+=("systemd-detect-virt is absent; virtualisation is unknown")
    fi
    if [ "$(id -u)" != "0" ]; then
        RECON_WARNINGS+=("running without root; some facts may be incomplete")
    fi

    # exit code: inconclusive and RAM shortfall outrank blockers
    if [ "$J_VERDICT" = "inconclusive" ] || [ "${RECON_MEM_SHORT:-0}" = "1" ]; then
        RECON_EXIT=2
    elif [ "${#RECON_BLOCKERS[@]}" -gt 0 ]; then
        RECON_EXIT=1
    else
        RECON_EXIT=0
    fi
    return 0
}

_gate_json() {
    printf '{%s, %s, %s, %s, %s}' \
        "$(json_kv name "$1")" \
        "$(json_kv required "$2" number)" \
        "$(json_kv actual "$3" number)" \
        "$(json_kv ratio "$4" number)" \
        "$(json_kv verdict "$5")"
}

# --------------------------------------------------------------------------
# emit
# --------------------------------------------------------------------------

emit_json() {
    local virt_detected_json
    case "$VIRT_DETECTED" in
        1) virt_detected_json="$(json_kv detected true bool)" ;;
        0) virt_detected_json="$(json_kv detected false bool)" ;;
        *) virt_detected_json="$(json_kv detected "" null)" ;;
    esac

    local ports_json
    if [ "$F_PORTS_NULL" = "1" ]; then
        ports_json="$(json_kv listening "" null)"
    else
        ports_json="$(json_arr listening raw "${F_PORT_ITEMS[@]+"${F_PORT_ITEMS[@]}"}")"
    fi

    local mtu_json
    if [ -n "$F_MTU" ]; then mtu_json="$(json_kv mtu "$F_MTU" number)"; else mtu_json="$(json_kv mtu "" null)"; fi
    local iface_json
    if [ -n "$F_IFACE" ]; then iface_json="$(json_kv default_iface "$F_IFACE")"; else iface_json="$(json_kv default_iface "" null)"; fi
    local cgroup_json
    if [ -n "$F_CGROUP_VERSION" ]; then cgroup_json="$(json_kv cgroup_version "$F_CGROUP_VERSION" number)"; else cgroup_json="$(json_kv cgroup_version "" null)"; fi
    local nofile_json
    if [ -n "$F_NOFILE_SOFT" ]; then nofile_json="$(json_kv nofile_soft "$F_NOFILE_SOFT" number)"; else nofile_json="$(json_kv nofile_soft "" null)"; fi
    local hint_json
    if [ -n "$F_PROVIDER_HINT" ]; then hint_json="$(json_kv provider_hint "$F_PROVIDER_HINT")"; else hint_json="$(json_kv provider_hint "" null)"; fi
    local req_json
    if [ -n "$J_PROFILE_REQUESTED" ]; then req_json="$(json_kv profile_requested "$J_PROFILE_REQUESTED")"; else req_json="$(json_kv profile_requested "" null)"; fi

    cat <<EOF
{
  $(json_kv schema_version 1 number),
  $(json_kv generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"),
  $(json_kv host_id "$F_HOST_ID"),
  "generator": {
    $(json_kv repo "corp-infra-bootstrap"),
    $(json_kv script "recon.sh"),
    $(json_kv lib_version "$LIB_VERSION")
  },
  "facts": {
    "os": {
      $(json_kv id "$OS_ID"),
      $(json_kv version_id "$OS_VERSION_ID"),
      $(json_kv id_like "$OS_ID_LIKE"),
      $(json_kv pretty_name "$OS_PRETTY"),
      $(json_kv kernel "$OS_KERNEL"),
      $(json_kv arch "$OS_ARCH")
    },
    "virt": {
      ${virt_detected_json},
      $(json_kv type "$VIRT_TYPE")
    },
    "cpu": {
      $(json_kv vcpu "$F_VCPU" number),
      $(json_kv model "$F_CPU_MODEL")
    },
    "memory": {
      $(json_kv mem_total_mb "$F_MEM_TOTAL" number),
      $(json_kv mem_available_mb "$F_MEM_AVAIL" number),
      $(json_kv swap_total_mb "$F_SWAP_TOTAL" number)
    },
    $(json_arr disk raw "${F_DISK_ITEMS[@]+"${F_DISK_ITEMS[@]}"}"),
    "disk_root": {
      $(json_kv total_gb "$F_DISK_ROOT_TOTAL" number),
      $(json_kv free_gb "$F_DISK_ROOT_FREE" number)
    },
    "network": {
      $(json_kv hostname "$F_HOSTNAME"),
      $(json_kv fqdn "$F_FQDN"),
      ${iface_json},
      ${mtu_json},
      $(json_kv has_ipv6 "$(_bool "$F_HAS_IPV6")" bool),
      $(json_kv public_ipv4_known "$(_bool "$F_PUBLIC_IPV4_KNOWN")" bool)
    },
    "ports": {
      ${ports_json}
    },
    "software": {
      $(json_kv docker "$F_SW_DOCKER" raw),
      $(json_kv compose "$F_SW_COMPOSE" raw),
      $(json_kv systemd "$F_SW_SYSTEMD" raw),
      $(json_kv wireguard "$F_SW_WIREGUARD" raw),
      $(json_kv restic "$F_SW_RESTIC" raw),
      $(json_kv sops "$F_SW_SOPS" raw),
      $(json_kv age "$F_SW_AGE" raw),
      $(json_kv python3 "$F_SW_PYTHON3" raw),
      $(json_kv bash "$F_SW_BASH" raw),
      $(json_kv shellcheck "$F_SW_SHELLCHECK" raw)
    },
    "limits": {
      ${cgroup_json},
      $(json_kv swap_enabled "$(_bool "$F_SWAP_ENABLED")" bool),
      ${nofile_json},
      $(json_kv selinux "$F_SELINUX"),
      $(json_kv apparmor "$F_APPARMOR")
    },
    $(json_arr existing_components raw "${F_COMPONENT_ITEMS[@]+"${F_COMPONENT_ITEMS[@]}"}"),
    ${hint_json}
  },
  "judgments": {
    $(json_kv os_tier "$J_OS_TIER"),
    ${req_json},
    $(json_kv profile_recommended "$J_PROFILE_RECOMMENDED"),
    $(json_kv sizing_verdict "$J_VERDICT"),
    "gates": {
      $(json_kv g1 "$J_G1" raw),
      $(json_kv g2 "$J_G2" raw),
      $(json_kv g4 "$J_G4" raw)
    },
    $(json_kv provider_policy "$J_PROVIDER_POLICY" raw),
    $(json_arr blockers string "${RECON_BLOCKERS[@]+"${RECON_BLOCKERS[@]}"}"),
    $(json_arr warnings string "${RECON_WARNINGS[@]+"${RECON_WARNINGS[@]}"}"),
    $(json_kv exit_code "$RECON_EXIT" number)
  }
}
EOF
}

persist() {
    local payload="$1"
    local dir="$CI_STATE/recon"
    if ! mkdir -p "$dir/history" 2>/dev/null; then
        warn "cannot create $dir/history; recon output was not persisted"
        return 0
    fi
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    printf '%s\n' "$payload" > "$dir/latest.json.tmp"
    chmod 0644 "$dir/latest.json.tmp" 2>/dev/null || true
    mv -f "$dir/latest.json.tmp" "$dir/latest.json"
    printf '%s\n' "$payload" > "$dir/history/$ts.json"
    chmod 0644 "$dir/history/$ts.json" 2>/dev/null || true
    log INFO "recon written to $dir/latest.json and history/$ts.json"
    return 0
}

# --check: assert the existing latest.json, mutate nothing.
run_check() {
    local file="$CI_STATE/recon/latest.json"
    local rc=0

    if [ ! -r "$file" ]; then
        log ERROR "recon --check: $file is absent"
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" >/dev/null 2>&1; then
            log ERROR "recon --check: $file does not parse as JSON"
            return 1
        fi
    else
        warn "recon --check: python3 absent, cannot parse-check $file"
        rc=2
    fi

    local schema="$SCRIPT_DIR/../schemas/recon.schema.json"
    if command -v python3 >/dev/null 2>&1 && [ -r "$schema" ]; then
        local vout vrc=0
        vout="$(python3 -c '
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(3)
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
with open(sys.argv[2], "r", encoding="utf-8") as fh:
    schema = json.load(fh)
try:
    jsonschema.validate(doc, schema)
except jsonschema.ValidationError as exc:
    sys.stdout.write(str(exc.message))
    sys.exit(1)
' "$file" "$schema" 2>/dev/null)" || vrc=$?
        case "$vrc" in
            0)
                log INFO "recon --check: schema valid"
                ;;
            3)
                warn "recon --check: python3 jsonschema module absent; schema validation skipped"
                if [ "$rc" -eq 0 ]; then rc=2; fi
                ;;
            *)
                log ERROR "recon --check: schema validation failed: ${vout:-unknown}"
                return 1
                ;;
        esac
    else
        warn "recon --check: cannot validate against schema"
        if [ "$rc" -eq 0 ]; then rc=2; fi
    fi

    local mtime now age
    mtime="$(stat -c %Y "$file" 2>/dev/null || printf '0')"
    now="$(date -u +%s)"
    age=$(( now - mtime ))
    if [ "$age" -ge 86400 ]; then
        log WARN "recon --check: latest.json is $(( age / 3600 ))h old (limit 24h)"
        rc=2
    else
        log INFO "recon --check: age $(( age / 60 ))m, within the 24h limit"
    fi

    local recorded current
    recorded="$(_ci_read_scalar "$file" host_id host_id || printf '')"
    current="$(_ci_host_id)"
    if [ "$recorded" != "$current" ]; then
        log WARN "recon --check: host_id mismatch (file $recorded, host $current)"
        rc=2
    fi

    return "$rc"
}

main() {
    trap_init
    parse_args "$@"

    RECON_BLOCKERS=()
    RECON_WARNINGS=()
    RECON_MEM_SHORT=0

    # --json is a pure read: no log file, no state writes.
    if [ "$RECON_JSON_ONLY" = "0" ]; then
        log_init "$CI_REPO" "$CI_SCRIPT"
    fi

    if [ "$CI_MODE" = "check" ]; then
        local crc=0
        run_check || crc=$?
        case "$crc" in
            0) log INFO  "recon --check: OK" ;;
            1) log ERROR "recon --check: FAIL" ;;
            *) log WARN  "recon --check: INCONCLUSIVE" ;;
        esac
        if [ "$CI_QUIET" = "1" ]; then
            case "$crc" in
                0) printf 'OK: %s\n' "$CI_SCRIPT" >&9 ;;
                1) printf 'FAIL: %s\n' "$CI_SCRIPT" >&9 ;;
                *) printf 'INCONCLUSIVE: %s\n' "$CI_SCRIPT" >&9 ;;
            esac
        fi
        exit "$crc"
    fi

    collect_facts
    derive_judgments

    local payload
    payload="$(emit_json)"

    if [ "$RECON_JSON_ONLY" = "1" ]; then
        printf '%s\n' "$payload"
        exit "$RECON_EXIT"
    fi

    persist "$payload"

    if [ "$CI_QUIET" = "1" ]; then
        case "$RECON_EXIT" in
            0) printf 'OK: %s\n' "$CI_SCRIPT" >&9 ;;
            1) printf 'FAIL: %s\n' "$CI_SCRIPT" >&9 ;;
            *) printf 'INCONCLUSIVE: %s\n' "$CI_SCRIPT" >&9 ;;
        esac
    else
        printf '%s\n' "$payload" >&9
    fi
    exit "$RECON_EXIT"
}

# fd 9 is the real stdout, kept aside so that log_init's tee never mixes log
# lines into the JSON document (gate G-06 runs `recon.sh > file`).
exec 9>&1
main "$@"
