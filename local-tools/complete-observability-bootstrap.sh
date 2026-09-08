#!/usr/bin/env bash
# Create a SOPS bundle and install observability without external alert delivery.
set -Eeuo pipefail

ENT_ROOT=/opt/corp-infra/ent-infra
AGE_KEY=/root/.config/sops/age/keys.txt
STATE_FILE=/var/lib/corp-infra/state.json
PROFILE=two-vps-split-b
TMP_FILES=()

cleanup() {
    local file
    for file in "${TMP_FILES[@]}"; do
        [ -n "$file" ] && rm -f -- "$file"
    done
}
trap cleanup EXIT

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

new_tmp() {
    local variable="$1" file
    file="$(mktemp /tmp/corp-observability.XXXXXX)"
    chmod 0600 "$file"
    TMP_FILES+=("$file")
    printf -v "$variable" '%s' "$file"
}

read_visible() {
    local prompt="$1" variable="$2" value
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r value </dev/tty || die "input ended unexpectedly"
    value="${value//$'\r'/}"
    printf -v "$variable" '%s' "$value"
}

[ "${EUID:-$(id -u)}" -eq 0 ] || die "run this helper through sudo"
if [ "${1-}" != "--install-disabled" ] || [ "$#" -ne 1 ]; then
    printf 'Usage: sudo %s --install-disabled\n' "$0" >&2
    exit 2
fi
[ -r /dev/tty ] || die "an interactive terminal is required"
[ -r "$STATE_FILE" ] || die "state file is missing: $STATE_FILE"
[ -r "$AGE_KEY" ] || die "age private key is missing: $AGE_KEY"
for cmd in age-keygen docker openssl python3 sops; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command is missing: $cmd"
done

domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$STATE_FILE")"
[[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "state.json has no valid corporate domain"

printf '%s\n' "Running the mandatory read-only observability check first."
rc=0
"$ENT_ROOT/scripts/install-observability.sh" --check --profile "$PROFILE" --domain "$domain" || rc=$?
case "$rc" in
    0) printf '%s\n' "Observability is already healthy; no credential rotation performed."; exit 0 ;;
    1) printf '%s\n' "Observability is not installed/healthy yet; bootstrap may proceed." ;;
    2) die "observability check is inconclusive; resolve its prerequisite first" ;;
    *) die "observability check returned unexpected exit $rc" ;;
esac

target="$ENT_ROOT/secrets/observability.enc.env"
if [ -e "$target" ]; then
    new_tmp existing_plain
    sops --decrypt --input-type dotenv --output-type dotenv "$target" >"$existing_plain" \
        || die "existing encrypted observability configuration cannot be decrypted"
    grep -qx 'ALERT_DELIVERY_MODE=disabled' "$existing_plain" \
        || die "existing configuration is not in disabled delivery mode; refusing to change it"
    grep -q '^GRAFANA_ADMIN_PASSWORD=.' "$existing_plain" \
        || die "existing configuration has no Grafana administrator password"
    printf '%s\n' "Reusing the existing encrypted observability configuration after the interrupted image pull."
else
    read_visible "Grafana administrator username [admin]: " grafana_user
    grafana_user="${grafana_user:-admin}"
    [[ "$grafana_user" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || die "unsupported Grafana username"

    grafana_password="$(openssl rand -hex 24)"
    agent_token="$(openssl rand -hex 32)"
    printf '\nSave this credential in KeePassXC now; it is shown only here.\n' >/dev/tty
    printf 'Grafana: URL=https://grafana.corp.%s username=%s password=%s\n\n' \
        "$domain" "$grafana_user" "$grafana_password" >/dev/tty
    read_visible "Type SAVED after the Grafana credential is in KeePassXC: " saved
    [ "$saved" = "SAVED" ] || die "credential was not confirmed saved; nothing was installed"

    recipient="$(age-keygen -y "$AGE_KEY")"
    [[ "$recipient" == age1* ]] || die "could not derive the public age recipient"
    new_tmp plain
    new_tmp cipher

    printf '%s\n' \
        'PROMETHEUS_IMAGE_TAG=v3.5.0' \
        'LOKI_IMAGE_TAG=3.5.1' \
        'GRAFANA_IMAGE_TAG=13.0.2' \
        'ALERTMANAGER_IMAGE_TAG=v0.28.1' \
        'ALLOY_IMAGE_TAG=v1.10.0' \
        'NODE_EXPORTER_IMAGE_TAG=v1.9.1' \
        'CADVISOR_IMAGE_TAG=v0.53.0' \
        'BLACKBOX_IMAGE_TAG=v0.27.0' \
        'OBS_SRV=/srv/corp-infra/observability' \
        'ENT_OBS_CONF_DIR=/opt/corp-infra/ent-infra/observability' \
        'NODE_EXPORTER_TEXTFILE_DIR=/var/lib/node_exporter/textfile' \
        "GRAFANA_FQDN=grafana.corp.$domain" \
        "PROMETHEUS_FQDN=prometheus.corp.$domain" \
        "ALERTS_FQDN=alerts.corp.$domain" \
        'PROM_RETENTION_TIME=90d' \
        'PROM_RETENTION_SIZE=25GB' \
        'LOKI_LOG_LEVEL=info' \
        "GRAFANA_ADMIN_USER=$grafana_user" \
        "GRAFANA_ADMIN_PASSWORD=$grafana_password" \
        'ALERT_DELIVERY_MODE=disabled' \
        "AGENT_WEBHOOK_TOKEN=$agent_token" >"$plain"

    sops --config /dev/null --encrypt --age "$recipient" \
        --input-type dotenv --output-type dotenv "$plain" >"$cipher"
    install -m 0600 -o root -g root "$cipher" "$target"
    rm -f -- "$plain"
    unset grafana_password agent_token
    printf '%s\n' "Encrypted observability configuration written; plaintext removed."
fi

"$ENT_ROOT/scripts/install-observability.sh" --yes --profile "$PROFILE" --domain "$domain"
"$ENT_ROOT/scripts/install-observability.sh" --check --profile "$PROFILE" --domain "$domain"
"$ENT_ROOT/scripts/install-observability.sh" --check --deep-check --profile "$PROFILE" --domain "$domain"
if [ -r /etc/corp-infra/backup/offsite-secondary.env ] && \
   grep -qx 'OFFSITE_SECONDARY_ENABLED=true' /etc/corp-infra/backup/offsite-secondary.env; then
    /opt/corp-infra/backup/scripts/backup.sh --yes --phase secondary
fi
/opt/corp-infra/backup/scripts/backup.sh --check

printf '%s\n' \
    "OK: observability is healthy and covered by backup." \
    "Alertmanager external delivery: DISABLED (intentional)." \
    "Grafana: https://grafana.corp.$domain/ (VPN only)"
