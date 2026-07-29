#!/usr/bin/env bash
# ensure-docker.sh - the single decision about installing Docker Engine (QC#6).
#
# Explicit refusal: get.docker.com is never used. That script is `sh` plus
# `set -e` with no trap, no retry and no idempotency (ADR-003 Context), which is
# exactly the failure mode these conventions exist to prevent. We add the
# official repository ourselves and install pinned package names instead.
#
# Idempotency comes from reality checks - `command -v docker`, `docker compose
# version`, and a content comparison of /etc/docker/daemon.json - not from a
# state marker.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
CI_REPO="corp-infra-bootstrap"; CI_SCRIPT="$(basename "$0")"

DOCKER_DAEMON_JSON="/etc/docker/daemon.json"

usage() {
    cat <<EOF
Usage: ensure-docker.sh [--check] [--yes] [--quiet]

Installs and configures Docker Engine when it is absent, and reconciles
$DOCKER_DAEMON_JSON with the corp-infra target (05_architecture section 3.1):
address pool base 172.28.0.0/16 size 24, json-file logging with rotation.

  --check   assert only; zero mutations
  --yes     non-interactive
  --quiet   log to file only; stdout is one result line
  --help / --version

Exit: 0 present and configured (or successfully installed)
      1 a check failed or a mutation failed
      2 unsupported OS family
EOF
}

# The desired daemon.json. Emitted with the same pure-bash JSON helpers used
# everywhere else, so there is exactly one way this repo produces JSON.
target_daemon_json() {
    cat <<EOF
{
  $(json_kv log-driver "json-file"),
  "log-opts": {
    $(json_kv max-size "10m"),
    $(json_kv max-file "3")
  },
  "default-address-pools": [
    { $(json_kv base "172.28.0.0/16"), $(json_kv size 24 number) }
  ],
  $(json_kv live-restore true bool)
}
EOF
}

daemon_json_matches() {
    [ -r "$DOCKER_DAEMON_JSON" ] || return 1
    if ! command -v python3 >/dev/null 2>&1; then
        # Without python3 we can only compare literally.
        local want
        want="$(target_daemon_json)"
        [ "$(cat "$DOCKER_DAEMON_JSON")" = "$want" ]
        return $?
    fi
    local want
    want="$(target_daemon_json)"
    printf '%s\n' "$want" | python3 -c '
import json, sys
want = json.load(sys.stdin)
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        have = json.load(fh)
except Exception:
    sys.exit(1)
# Reconcile only the keys corp-infra owns; anything else the operator added stays.
for key, value in want.items():
    if have.get(key) != value:
        sys.exit(1)
sys.exit(0)
' "$DOCKER_DAEMON_JSON"
}

compose_v2_present() {
    command -v docker >/dev/null 2>&1 || return 1
    local out
    out="$(docker compose version 2>/dev/null || true)"
    [[ "$out" =~ v?2\. ]] || [[ "$out" =~ v?[3-9]\. ]]
}

run_check() {
    local rc=0

    if ! command -v docker >/dev/null 2>&1; then
        log ERROR "docker is not installed"
        rc=1
    else
        log INFO "docker present: $(docker --version 2>/dev/null || printf 'unknown')"
    fi

    local sa=0
    svc_active docker || sa=$?
    case "$sa" in
        0) log INFO "docker.service is active" ;;
        1) log ERROR "docker.service is not active"; rc=1 ;;
        *)
            warn "no systemd available to check docker.service"
            if [ "$rc" -eq 0 ]; then rc=2; fi
            ;;
    esac

    if compose_v2_present; then
        log INFO "docker compose v2+: $(docker compose version 2>/dev/null | head -n1)"
    else
        log ERROR "docker compose v2 plugin is missing"
        rc=1
    fi

    if daemon_json_matches; then
        log INFO "$DOCKER_DAEMON_JSON matches the corp-infra target"
    else
        log ERROR "$DOCKER_DAEMON_JSON is absent or lacks default-address-pools / log rotation"
        rc=1
    fi

    return "$rc"
}

install_apt() {
    log INFO "installing Docker Engine from the official apt repository"
    export DEBIAN_FRONTEND=noninteractive

    retry 3 2 -- apt-get update -qq
    retry 3 2 -- apt-get install -y -qq ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    local keyring="/etc/apt/keyrings/docker.asc"
    if [ ! -s "$keyring" ]; then
        retry 3 3 -- curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o "$keyring"
        chmod a+r "$keyring"
        log INFO "docker apt key installed at $keyring"
    else
        log INFO "docker apt key already present"
    fi

    local codename=""
    if [ -r /etc/os-release ]; then
        codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
    fi
    if [ -z "$codename" ]; then
        die 2 "cannot determine the distribution codename for the docker repository"
    fi

    local listfile="/etc/apt/sources.list.d/docker.list"
    # Split declare and assign: `local x="$(cmd)"` masks cmd's exit status, so a
    # failing dpkg would silently produce `deb [arch= ...]` under set -e.
    local arch
    arch="$(dpkg --print-architecture)"
    [ -n "$arch" ] || die 2 "cannot determine the dpkg architecture for the docker repository"
    local line="deb [arch=${arch} signed-by=$keyring] https://download.docker.com/linux/${OS_ID} ${codename} stable"
    if [ ! -r "$listfile" ] || ! grep -qxF "$line" "$listfile"; then
        printf '%s\n' "$line" > "$listfile"
        log INFO "docker apt source written to $listfile"
        retry 3 2 -- apt-get update -qq
    else
        log INFO "docker apt source already correct"
    fi

    retry 3 4 -- apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    return 0
}

install_dnf() {
    log INFO "installing Docker Engine from the official dnf repository (best effort)"
    local mgr="$PKG_MGR"
    retry 3 2 -- "$mgr" -y install dnf-plugins-core
    if [ ! -r /etc/yum.repos.d/docker-ce.repo ]; then
        retry 3 3 -- "$mgr" config-manager --add-repo \
            "https://download.docker.com/linux/${OS_ID}/docker-ce.repo"
    fi
    retry 3 4 -- "$mgr" -y install \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    return 0
}

write_daemon_json() {
    if daemon_json_matches; then
        log INFO "$DOCKER_DAEMON_JSON already matches the target; no write"
        return 1
    fi
    confirm "write the corp-infra Docker daemon configuration to $DOCKER_DAEMON_JSON?" || {
        warn "daemon.json was not written (declined)"
        return 1
    }
    mkdir -p /etc/docker
    local tmp="${DOCKER_DAEMON_JSON}.tmp"
    if [ -r "$DOCKER_DAEMON_JSON" ]; then
        cp -a "$DOCKER_DAEMON_JSON" "${DOCKER_DAEMON_JSON}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        log INFO "existing daemon.json backed up"
    fi
    target_daemon_json > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$DOCKER_DAEMON_JSON"
    log INFO "$DOCKER_DAEMON_JSON written"
    return 0
}

run_apply() {
    require_root
    detect_os
    detect_pkg_mgr

    if [ "$OS_TIER" = "unsupported" ]; then
        die 2 "unsupported OS family: ${OS_PRETTY} (${OS_ID}); install Docker manually and re-run --check"
    fi

    local installed_now=0
    if command -v docker >/dev/null 2>&1 && compose_v2_present; then
        log INFO "docker and the compose v2 plugin are already present; skipping installation"
    else
        confirm "install Docker Engine and the compose v2 plugin on this host?" \
            || die 1 "Docker installation declined; the stack cannot continue"
        case "$PKG_MGR" in
            apt) install_apt ;;
            dnf|yum) install_dnf ;;
            *) die 2 "no supported package manager found (apt/dnf/yum)" ;;
        esac
        installed_now=1
    fi

    local restart=0
    if write_daemon_json; then
        restart=1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable docker >/dev/null 2>&1 || warn "could not enable docker.service"
        if [ "$restart" = "1" ] || [ "$installed_now" = "1" ]; then
            log INFO "restarting docker.service to apply the configuration"
            systemctl restart docker || die 1 "docker.service failed to restart"
        elif ! svc_active docker; then
            log INFO "starting docker.service"
            systemctl start docker || die 1 "docker.service failed to start"
        else
            log INFO "docker.service already active; no restart needed"
        fi
    else
        warn "systemd is absent; start the Docker daemon by other means"
    fi

    local rc=0
    run_check || rc=$?
    return "$rc"
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
        0) log INFO  "ensure-docker: OK" ;;
        1) log ERROR "ensure-docker: FAIL" ;;
        *) log WARN  "ensure-docker: INCONCLUSIVE" ;;
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
