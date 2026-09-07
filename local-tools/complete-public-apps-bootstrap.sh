#!/usr/bin/env bash
# Create encrypted Mattermost/OpenProject secrets and install both public apps.
# Secrets are shown/read only on /dev/tty and are never written to logs.
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

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

new_tmp() {
    local variable="$1" file
    file="$(mktemp /tmp/corp-public-apps.XXXXXX)"
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

valid_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "run this helper through sudo"
fi
if [ "${1-}" != "--install" ] || [ "$#" -ne 1 ]; then
    printf '%s\n' \
        "Usage: sudo $0 --install" \
        "" \
        "Creates host-local SOPS files, shows two generated admin passwords" \
        "once on this terminal, and installs public Mattermost and OpenProject." >&2
    exit 2
fi
[ -r /dev/tty ] || die "an interactive terminal is required"
[ -r "$STATE_FILE" ] || die "state file is missing: $STATE_FILE"
[ -r "$AGE_KEY" ] || die "age private key is missing: $AGE_KEY"
for cmd in age-keygen docker getent ip openssl python3 sops; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command is missing: $cmd"
done

domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$STATE_FILE")"
[[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "state.json has no valid corporate domain"

public_if="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
[ -n "$public_if" ] || die "could not determine the default IPv4 interface"
public_ip="$(ip -4 -o addr show dev "$public_if" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
[ -n "$public_ip" ] || die "could not determine this VPS public IPv4"
for host in "chat.$domain" "projects.$domain"; do
    resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')"
    [ "$resolved" = "$public_ip" ] || die "$host does not resolve to this VPS"
done
printf '%s\n' "DNS is ready for both public application names."

printf '%s\n' "Running mandatory read-only checks first."
for installer in install-mattermost.sh install-tracker.sh; do
    rc=0
    "$ENT_ROOT/scripts/$installer" --check --profile "$PROFILE" --domain "$domain" || rc=$?
    case "$rc" in
        0) printf '%s\n' "$installer is already healthy; it will be reconciled." ;;
        1) printf '%s\n' "$installer is not installed/healthy yet; installation may proceed." ;;
        2) die "$installer check is inconclusive; resolve its precondition before installation" ;;
        *) die "$installer returned unexpected check exit $rc" ;;
    esac
done

mm_target="$ENT_ROOT/secrets/mattermost.enc.env"
op_target="$ENT_ROOT/secrets/openproject.enc.env"
reuse_configs=0
if [ -r "$mm_target" ] || [ -r "$op_target" ]; then
    [ -r "$mm_target" ] && [ -r "$op_target" ] \
        || die "only one encrypted service config exists; refusing to overwrite a partial credential set"
    reuse_configs=1
    printf '%s\n' "Both encrypted service configs already exist; reusing them without rotating credentials."
fi

if [ "$reuse_configs" -eq 0 ]; then
read_visible "Administrator email for both services: " admin_email
valid_email "$admin_email" || die "administrator email is invalid"
read_visible "Mattermost admin username [admin]: " mm_username
mm_username="${mm_username:-admin}"
[[ "$mm_username" =~ ^[a-z][a-z0-9._-]{2,21}$ ]] \
    || die "Mattermost username must be 3-22 lower-case characters"
read_visible "OpenProject admin display name [Corp Admin]: " op_admin_name
op_admin_name="${op_admin_name:-Corp Admin}"
[[ "$op_admin_name" =~ ^[A-Za-z0-9][A-Za-z0-9._[:space:]-]{1,62}[A-Za-z0-9]$ ]] \
    || die "OpenProject admin name contains unsupported characters"

mm_db_password="$(openssl rand -hex 32)"
mm_admin_password="$(openssl rand -hex 24)"
op_db_password="$(openssl rand -hex 32)"
op_secret_key="$(openssl rand -hex 64)"
op_admin_password="$(openssl rand -hex 24)"

printf '\nSave these credentials in KeePassXC now; they are shown only here.\n' >/dev/tty
printf 'Mattermost: username=%s password=%s\n' "$mm_username" "$mm_admin_password" >/dev/tty
printf 'OpenProject: username=admin password=%s\n\n' "$op_admin_password" >/dev/tty
read_visible "Type SAVED after both passwords are in KeePassXC: " saved
[ "$saved" = "SAVED" ] || die "credentials were not confirmed saved; nothing was installed"

recipient="$(age-keygen -y "$AGE_KEY")"
[[ "$recipient" == age1* ]] || die "could not derive the public age recipient"
new_tmp mm_plain
new_tmp mm_cipher
new_tmp op_plain
new_tmp op_cipher

printf '%s\n' \
    "MATTERMOST_IMAGE_TAG=11.7.8" \
    "MATTERMOST_PG_IMAGE_TAG=16.9-alpine" \
    "MATTERMOST_SITE_URL=https://chat.$domain" \
    "MATTERMOST_SRV=/srv/corp-infra/mattermost" \
    "MATTERMOST_DB_NAME=mattermost" \
    "MATTERMOST_DB_USER=mattermost" \
    "MATTERMOST_DB_PASSWORD=$mm_db_password" \
    "MATTERMOST_ADMIN_EMAIL=$admin_email" \
    "MATTERMOST_ADMIN_USERNAME=$mm_username" \
    "MATTERMOST_ADMIN_PASSWORD=$mm_admin_password" \
    "MATTERMOST_APP_MEM_LIMIT=3072m" \
    "MATTERMOST_APP_MEM_RESERVATION=1536m" \
    "MATTERMOST_DB_MEM_LIMIT=768m" \
    "CORP_TZ=Etc/UTC" >"$mm_plain"

printf '%s\n' \
    "OPENPROJECT_IMAGE_TAG=17.8.0-slim" \
    "OPENPROJECT_PG_IMAGE_TAG=17.10-alpine" \
    "OPENPROJECT_MEMCACHED_IMAGE_TAG=1.6.39-alpine" \
    "OPENPROJECT_HOST_NAME=projects.$domain" \
    "OPENPROJECT_SRV=/srv/corp-infra/openproject" \
    "OPENPROJECT_SEED_LOCALE=ru" \
    "OPENPROJECT_ADMIN_EMAIL=$admin_email" \
    "OPENPROJECT_ADMIN_NAME=\"$op_admin_name\"" \
    "OPENPROJECT_ADMIN_PASSWORD=$op_admin_password" \
    "OPENPROJECT_DB_NAME=openproject" \
    "OPENPROJECT_DB_USER=openproject" \
    "OPENPROJECT_DB_PASSWORD=$op_db_password" \
    "OPENPROJECT_SECRET_KEY_BASE=$op_secret_key" \
    "OPENPROJECT_WEB_WORKERS=2" \
    "OPENPROJECT_MIN_THREADS=4" \
    "OPENPROJECT_MAX_THREADS=8" \
    "OPENPROJECT_WORKER_MEM_LIMIT=768m" \
    "OPENPROJECT_CRON_MEM_LIMIT=384m" \
    "OPENPROJECT_SEEDER_MEM_LIMIT=512m" \
    "OPENPROJECT_CACHE_MEM_LIMIT=128m" \
    "OPENPROJECT_DB_MEM_LIMIT=768m" \
    "OPENPROJECT_WEB_MEM_LIMIT=2048m" \
    "OPENPROJECT_WEB_MEM_RESERVATION=1536m" >"$op_plain"

sops --config /dev/null --encrypt --age "$recipient" \
    --input-type dotenv --output-type dotenv "$mm_plain" >"$mm_cipher"
sops --config /dev/null --encrypt --age "$recipient" \
    --input-type dotenv --output-type dotenv "$op_plain" >"$op_cipher"

history_dir=/var/lib/corp-infra/ent-infra/config-history
install -d -m 0700 -o root -g root "$history_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
for name in mattermost openproject; do
    target="$ENT_ROOT/secrets/$name.enc.env"
    [ ! -r "$target" ] || install -m 0600 -o root -g root "$target" "$history_dir/$name.enc.env.$stamp"
done
install -m 0600 -o root -g root "$mm_cipher" "$ENT_ROOT/secrets/mattermost.enc.env"
install -m 0600 -o root -g root "$op_cipher" "$ENT_ROOT/secrets/openproject.enc.env"
rm -f -- "$mm_plain" "$op_plain"
unset mm_db_password mm_admin_password op_db_password op_secret_key op_admin_password
printf '%s\n' "Encrypted service configurations written; plaintext temporary files removed."
fi

"$ENT_ROOT/scripts/install-mattermost.sh" --yes --profile "$PROFILE" --domain "$domain"
"$ENT_ROOT/scripts/install-mattermost.sh" --check --profile "$PROFILE" --domain "$domain"
"$ENT_ROOT/scripts/install-tracker.sh" --yes --profile "$PROFILE" --domain "$domain"
"$ENT_ROOT/scripts/install-tracker.sh" --check --profile "$PROFILE" --domain "$domain"
"/opt/corp-infra/backup/scripts/backup.sh" --check
"/opt/corp-infra/backup/scripts/backup.sh" --yes --phase secondary
"/opt/corp-infra/backup/scripts/backup.sh" --check

printf '%s\n' \
    "OK: Mattermost and OpenProject are healthy, public, and covered by backup." \
    "Mattermost: https://chat.$domain/" \
    "OpenProject: https://projects.$domain/"
