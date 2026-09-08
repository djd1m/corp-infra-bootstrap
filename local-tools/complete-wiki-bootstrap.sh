#!/usr/bin/env bash
# Install the VPN-only BookStack wiki and immediately protect it in both S3s.
set -Eeuo pipefail

ENT_ROOT=/opt/corp-infra/ent-infra
BACKUP_ROOT=/opt/corp-infra/backup
AGE_KEY=/root/.config/sops/age/keys.txt
STATE_FILE=/var/lib/corp-infra/state.json
PROFILE=two-vps-split-b
BOOKSTACK_TAG=v26.05.3-ls278
BOOKSTACK_DIGEST=sha256:011e5cce0c387a169583c9f84a00e410854c074efdb06a1c0d3578e0568fcd78
MARIADB_TAG=11.8.8-r0-ls226
MARIADB_DIGEST=sha256:2497453facccec79cd5e3bb3c1bd304a9def22af2f48a8d6b2fc8377904ce2d5
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
    file="$(mktemp /tmp/corp-wiki.XXXXXX)"
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

env_value() {
    local file="$1" key="$2" line value
    line="$(grep -m1 -E "^${key}=" "$file" 2>/dev/null)" || return 1
    value="${line#*=}"
    value="${value#\"}"; value="${value%\"}"
    printf '%s\n' "$value"
}

valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
        && [ "$1" != "admin@admin.com" ]
}

trim_outer_space() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

remote_digest() {
    local ref="$1"
    docker buildx imagetools inspect "$ref" 2>/dev/null \
        | awk '$1 == "Digest:" && digest == "" {digest=$2}
               END {if (digest != "") print digest}'
}

[ "${EUID:-$(id -u)}" -eq 0 ] || die "run this helper through sudo"
if [ "${1-}" != "--install-private" ] || [ "$#" -ne 1 ]; then
    printf '%s\n' \
        "Usage: sudo $0 --install-private" \
        "" \
        "Creates the SOPS bundle, replaces BookStack's vendor default admin," \
        "installs wiki.corp.<domain> inside WireGuard, then backs it up to" \
        "Yandex Cloud and Cloud.ru." >&2
    exit 2
fi
[ -r /dev/tty ] || die "an interactive terminal is required"
[ -r "$STATE_FILE" ] || die "state file is missing: $STATE_FILE"
[ -r "$AGE_KEY" ] || die "age private key is missing: $AGE_KEY"
for cmd in age-keygen docker getent openssl python3 sops; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command is missing: $cmd"
done

domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$STATE_FILE")"
[[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "state.json has no valid corporate domain"
fqdn="wiki.corp.$domain"
resolved="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR==1 {print $1}')"
[[ "$resolved" == 10.8.0.* ]] || die "$fqdn must resolve into the WireGuard 10.8.0.0/24 network"
printf '%s\n' "Internal DNS is ready: $fqdn -> $resolved"

printf '%s\n' "Running the mandatory read-only BookStack check first."
rc=0
"$ENT_ROOT/scripts/install-wiki.sh" --check --profile "$PROFILE" --domain "$domain" || rc=$?
case "$rc" in
    0) printf '%s\n' "BookStack is already healthy; configuration will be reused and backup protection re-proved." ;;
    1) printf '%s\n' "BookStack is not installed/healthy yet; bootstrap may proceed." ;;
    2) die "BookStack check is inconclusive; resolve its prerequisite first" ;;
    *) die "BookStack check returned unexpected exit $rc" ;;
esac

printf '%s\n' "Verifying the two third-party image tags against their reviewed digest pins."
actual="$(remote_digest "lscr.io/linuxserver/bookstack:$BOOKSTACK_TAG")"
[ "$actual" = "$BOOKSTACK_DIGEST" ] \
    || die "BookStack tag digest changed or could not be verified (expected $BOOKSTACK_DIGEST, got ${actual:-none})"
actual="$(remote_digest "lscr.io/linuxserver/mariadb:$MARIADB_TAG")"
[ "$actual" = "$MARIADB_DIGEST" ] \
    || die "MariaDB tag digest changed or could not be verified (expected $MARIADB_DIGEST, got ${actual:-none})"

target="$ENT_ROOT/secrets/bookstack.enc.env"
if [ -r "$target" ]; then
    new_tmp existing_plain
    sops --config /dev/null --decrypt --input-type dotenv --output-type dotenv \
        "$target" >"$existing_plain" \
        || die "existing encrypted BookStack configuration cannot be decrypted"
    [ "$(env_value "$existing_plain" BOOKSTACK_IMAGE_DIGEST)" = "$BOOKSTACK_DIGEST" ] \
        || die "existing BookStack image pin differs from the reviewed release"
    [ "$(env_value "$existing_plain" BOOKSTACK_DB_IMAGE_DIGEST)" = "$MARIADB_DIGEST" ] \
        || die "existing MariaDB image pin differs from the reviewed release"
    admin_email="$(env_value "$existing_plain" BOOKSTACK_ADMIN_EMAIL)" \
        || die "existing BookStack configuration has no administrator email"
    valid_email "$admin_email" || die "existing BookStack administrator email is unsafe or invalid"
    [ "$(env_value "$existing_plain" BOOKSTACK_APP_URL)" = "https://$fqdn" ] \
        || die "existing BookStack APP_URL does not match $fqdn"
    printf '%s\n' "Reusing the existing encrypted BookStack configuration without rotating credentials."
else
    read_visible "BookStack administrator email: " admin_email
    # Windows terminal paste can leave an invisible leading/trailing space.
    # It is not part of an email address, so normalize it before validation.
    admin_email="$(trim_outer_space "$admin_email")"
    valid_email "$admin_email" || die "administrator email is unsafe or invalid"
    read_visible "BookStack administrator display name [Corp Admin]: " admin_name
    admin_name="${admin_name:-Corp Admin}"
    [ "${#admin_name}" -ge 2 ] && [ "${#admin_name}" -le 64 ] \
        && [[ "$admin_name" =~ ^[A-Za-z0-9][A-Za-z0-9._[:space:]-]*$ ]] \
        || die "administrator display name contains unsupported characters"

    app_key="base64:$(openssl rand -base64 32 | tr -d '\n')"
    db_password="$(openssl rand -hex 32)"
    db_root_password="$(openssl rand -hex 32)"
    admin_password="$(openssl rand -hex 24)"

    printf '\nSave this credential in KeePassXC now; it is shown only here.\n' >/dev/tty
    printf 'BookStack: URL=https://%s email=%s password=%s\n\n' \
        "$fqdn" "$admin_email" "$admin_password" >/dev/tty
    read_visible "Type SAVED after the credential is in KeePassXC: " saved
    [ "$saved" = "SAVED" ] || die "credential was not confirmed saved; nothing was installed"

    recipient="$(age-keygen -y "$AGE_KEY")"
    [[ "$recipient" == age1* ]] || die "could not derive the public age recipient"
    new_tmp plain
    new_tmp cipher
    printf '%s\n' \
        "BOOKSTACK_IMAGE_DIGEST=$BOOKSTACK_DIGEST" \
        "BOOKSTACK_DB_IMAGE_DIGEST=$MARIADB_DIGEST" \
        "BOOKSTACK_APP_URL=https://$fqdn" \
        'BOOKSTACK_SRV=/srv/corp-infra/bookstack' \
        'BOOKSTACK_TRUSTED_PROXIES=172.28.20.0/24' \
        'CORP_TZ=Etc/UTC' \
        "BOOKSTACK_APP_KEY=$app_key" \
        'BOOKSTACK_PUID=1000' \
        'BOOKSTACK_PGID=1000' \
        "BOOKSTACK_ADMIN_EMAIL=$admin_email" \
        "BOOKSTACK_ADMIN_NAME=\"$admin_name\"" \
        "BOOKSTACK_ADMIN_PASSWORD=$admin_password" \
        'BOOKSTACK_DB_NAME=bookstack' \
        'BOOKSTACK_DB_USER=bookstack' \
        "BOOKSTACK_DB_PASSWORD=$db_password" \
        "BOOKSTACK_DB_ROOT_PASSWORD=$db_root_password" \
        'BOOKSTACK_DB_MEM_LIMIT=512m' >"$plain"

    sops --config /dev/null --encrypt --age "$recipient" \
        --input-type dotenv --output-type dotenv "$plain" >"$cipher"
    install -m 0600 -o root -g root "$cipher" "$target"
    rm -f -- "$plain"
    unset app_key db_password db_root_password admin_password
    printf '%s\n' "Encrypted BookStack configuration written; plaintext removed."
fi

"$ENT_ROOT/scripts/install-wiki.sh" --yes --profile "$PROFILE" --domain "$domain"
"$ENT_ROOT/scripts/install-wiki.sh" --check --profile "$PROFILE" --domain "$domain"

# A service is not accepted until a fresh primary snapshot/offsite copy exists,
# followed by the independent Cloud.ru copy and a final health check.
"$BACKUP_ROOT/scripts/backup.sh" --yes --service wiki
if [ -r /etc/corp-infra/backup/offsite-secondary.env ] && \
   grep -qx 'OFFSITE_SECONDARY_ENABLED=true' /etc/corp-infra/backup/offsite-secondary.env; then
    "$BACKUP_ROOT/scripts/backup.sh" --yes --phase secondary
else
    die "Cloud.ru secondary backup is not enabled"
fi
"$BACKUP_ROOT/scripts/backup.sh" --check

printf '%s\n' \
    "OK: BookStack is healthy, VPN-only, and present in both object stores." \
    "BookStack: https://$fqdn/"
