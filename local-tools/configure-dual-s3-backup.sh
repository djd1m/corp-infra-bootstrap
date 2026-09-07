#!/usr/bin/env bash
# Configure Yandex Cloud as primary and Cloud.ru as secondary offsite backup.
# Both buckets must already have versioning enabled.
# Secrets are read from /dev/tty, encrypted immediately with sops, and never
# printed or passed on a command line.
set -Eeuo pipefail

BACKUP_ROOT=/opt/corp-infra/backup
PRIMARY_TARGET="$BACKUP_ROOT/secrets/backup.enc.env"
SECONDARY_TARGET="$BACKUP_ROOT/secrets/backup-secondary.enc.env"
AGE_KEY=/root/.config/sops/age/keys.txt
PROFILE=two-vps-split-b
TMP_FILES=()

cleanup() {
    local f
    for f in "${TMP_FILES[@]}"; do
        [ -n "$f" ] && rm -f -- "$f"
    done
}
trap cleanup EXIT

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

new_tmp() {
    local variable="$1" f
    f="$(mktemp /tmp/corp-dual-s3.XXXXXX)"
    chmod 0600 "$f"
    TMP_FILES+=("$f")
    printf -v "$variable" '%s' "$f"
}

read_visible() {
    local prompt="$1" variable="$2" value
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r value </dev/tty || die "input ended unexpectedly"
    value="${value%$'\r'}"
    printf -v "$variable" '%s' "$value"
}

read_secret() {
    local prompt="$1" variable="$2" value
    printf '%s' "$prompt" >/dev/tty
    IFS= read -rs value </dev/tty || die "input ended unexpectedly"
    printf '\n' >/dev/tty
    value="${value%$'\r'}"
    printf -v "$variable" '%s' "$value"
}

validate_bucket() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
        die "bucket '$1' does not look like a valid S3 bucket name"
}

validate_prefix() {
    [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] ||
        die "prefix may contain only letters, digits, dot, underscore, slash and hyphen"
    [[ "$1" != /* && "$1" != */ ]] || die "prefix must not start or end with slash"
}

validate_credential() {
    local label="$1" value="$2"
    [ -n "$value" ] || die "$label is empty"
    [[ "$value" != *[$'\r\n\t ']* ]] || die "$label must not contain whitespace"
    [[ "$value" =~ ^[A-Za-z0-9_:+/=.@-]+$ ]] || die "$label contains an unexpected character"
}

validate_cloudru_key_id() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+[:.][A-Za-z0-9_-]+$ ]] ||
        die "Cloud.ru access key ID must be the complete tenant-id:key-id (or tenant-id.key-id) value"
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "run this helper through sudo"
fi
if [ "${1-}" != "--iam-ready" ] || [ "$#" -ne 1 ]; then
    printf '%s\n' \
        "Usage: sudo $0 --iam-ready" \
        "" \
        "--iam-ready attests that versioning is enabled on BOTH buckets and:" \
        "  Yandex key belongs to a bucket-scoped storage.uploader account;" \
        "  Cloud.ru account has bucket-scoped editor/viewer/viewer-acl roles," \
        "  an explicit bucket-policy Deny for deletes, and no tenant.edit/admin role." >&2
    exit 2
fi
[ -r "$AGE_KEY" ] || die "age private key is not readable at $AGE_KEY"
for cmd in age-keygen openssl sops install; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command is missing: $cmd"
done
[ -r "$BACKUP_ROOT/scripts/install-backup.sh" ] || die "backup repository is absent"
[ -r /dev/tty ] || die "an interactive terminal is required"

printf '%s\n' "Running the mandatory read-only backup check first."
check_rc=0
"$BACKUP_ROOT/scripts/install-backup.sh" --check --profile "$PROFILE" --offsite yandex-ru || check_rc=$?
case "$check_rc" in
    0) printf '%s\n' "Existing backup installation is healthy; encrypted configuration will be reconciled." ;;
    1) printf '%s\n' "Backup is not ready yet; configuration may proceed." ;;
    2) printf '%s\n' "Backup state is inconclusive; the canonical installer will re-check prerequisites." ;;
    *) die "unexpected check exit code: $check_rc" ;;
esac

read_visible "Yandex bucket name: " yandex_bucket
read_visible "Yandex prefix [corp-infra/primary]: " yandex_prefix
yandex_prefix="${yandex_prefix:-corp-infra/primary}"
read_visible "Yandex static access key ID: " yandex_key_id
read_secret  "Yandex static secret key (hidden): " yandex_key_secret

read_visible "Cloud.ru bucket name: " cloudru_bucket
read_visible "Cloud.ru prefix [corp-infra/secondary]: " cloudru_prefix
cloudru_prefix="${cloudru_prefix:-corp-infra/secondary}"
read_visible "Cloud.ru access key ID (tenant-id:key-id): " cloudru_key_id
read_secret  "Cloud.ru key secret (hidden): " cloudru_key_secret

validate_bucket "$yandex_bucket"
validate_prefix "$yandex_prefix"
validate_credential "Yandex access key ID" "$yandex_key_id"
validate_credential "Yandex secret key" "$yandex_key_secret"
validate_bucket "$cloudru_bucket"
validate_prefix "$cloudru_prefix"
validate_credential "Cloud.ru access key ID" "$cloudru_key_id"
validate_credential "Cloud.ru secret key" "$cloudru_key_secret"
validate_cloudru_key_id "$cloudru_key_id"

recipient="$(age-keygen -y "$AGE_KEY")"
[[ "$recipient" == age1* ]] || die "could not derive the public age recipient"
restic_password="$(openssl rand -base64 48 | tr -d '\n')"

new_tmp primary_plain
new_tmp secondary_plain
new_tmp primary_cipher
new_tmp secondary_cipher

printf '%s\n' \
    "RESTIC_PASSWORD=$restic_password" \
    "RESTIC_REPOSITORY_LOCAL=/var/backups/corp-infra/restic-local" \
    "RESTIC_REPOSITORY=s3:https://storage.yandexcloud.net/$yandex_bucket/$yandex_prefix" \
    "OFFSITE_BUCKET=$yandex_bucket" \
    "OFFSITE_PREFIX=$yandex_prefix" \
    "OFFSITE_ENDPOINT=https://storage.yandexcloud.net" \
    "OFFSITE_SYNC_MODE=rclone-copy-immutable" \
    "AWS_ACCESS_KEY_ID=$yandex_key_id" \
    "AWS_SECRET_ACCESS_KEY=$yandex_key_secret" \
    "AWS_REGION=ru-central1" \
    "AWS_DEFAULT_REGION=ru-central1" \
    "OFFSITE_PROVIDER=yandex-ru" \
    "OFFSITE_RESIDENCY=RU" \
    "OFFSITE_STORAGE_CLASS=hot" \
    "OFFSITE_DELETE_DENIED=true" \
    "OFFSITE_DELETE_CONTROL=storage.uploader" \
    "OFFSITE_VERSIONING_ENABLED=true" >"$primary_plain"

printf '%s\n' \
    "RESTIC_PASSWORD=$restic_password" \
    "RESTIC_REPOSITORY=s3:https://s3.cloud.ru/$cloudru_bucket/$cloudru_prefix" \
    "OFFSITE_BUCKET=$cloudru_bucket" \
    "OFFSITE_PREFIX=$cloudru_prefix" \
    "OFFSITE_ENDPOINT=https://s3.cloud.ru" \
    "OFFSITE_SYNC_MODE=rclone-copy-immutable" \
    "AWS_ACCESS_KEY_ID=$cloudru_key_id" \
    "AWS_SECRET_ACCESS_KEY=$cloudru_key_secret" \
    "AWS_REGION=ru-central-1" \
    "AWS_DEFAULT_REGION=ru-central-1" \
    "OFFSITE_PROVIDER=cloudru" \
    "OFFSITE_RESIDENCY=RU" \
    "OFFSITE_STORAGE_CLASS=hot" \
    "OFFSITE_DELETE_DENIED=true" \
    "OFFSITE_DELETE_CONTROL=bucket-policy-deny-delete" \
    "OFFSITE_VERSIONING_ENABLED=true" \
    "OFFSITE_SECONDARY_ENABLED=true" >"$secondary_plain"

sops --config /dev/null --encrypt --age "$recipient" \
    --input-type dotenv --output-type dotenv "$primary_plain" >"$primary_cipher"
sops --config /dev/null --encrypt --age "$recipient" \
    --input-type dotenv --output-type dotenv "$secondary_plain" >"$secondary_cipher"

history_dir=/var/lib/corp-infra/backup/config-history
install -d -m 0700 -o root -g root "$history_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [ -r "$PRIMARY_TARGET" ]; then
    install -m 0600 -o root -g root "$PRIMARY_TARGET" "$history_dir/backup.enc.env.$stamp"
fi
if [ -r "$SECONDARY_TARGET" ]; then
    install -m 0600 -o root -g root "$SECONDARY_TARGET" "$history_dir/backup-secondary.enc.env.$stamp"
fi
install -m 0600 -o root -g root "$primary_cipher" "$PRIMARY_TARGET"
install -m 0600 -o root -g root "$secondary_cipher" "$SECONDARY_TARGET"

rm -f -- "$primary_plain" "$secondary_plain"
unset yandex_key_secret cloudru_key_secret restic_password
printf '%s\n' "Encrypted configurations written; plaintext temporary files removed."
installer_rc=0
"$BACKUP_ROOT/scripts/install-backup.sh" --yes --profile "$PROFILE" --offsite yandex-ru || installer_rc=$?
exit "$installer_rc"
