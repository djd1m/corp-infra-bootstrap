#!/usr/bin/env bash
# Repair only the Cloud.ru S3 credential after validating it read-only.
# The existing restic password, bucket and all Yandex settings are preserved.
set -Eeuo pipefail

BACKUP_ROOT=/opt/corp-infra/backup
SECONDARY_TARGET="$BACKUP_ROOT/secrets/backup-secondary.enc.env"
RUNTIME_ENV=/etc/corp-infra/backup/offsite-secondary.env
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
    f="$(mktemp /tmp/corp-cloudru-repair.XXXXXX)"
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

read_field() {
    local file="$1" key="$2" variable="$3" line value=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*) value="${line#*=}" ;;
        esac
    done <"$file"
    [ -n "$value" ] || return 1
    printf -v "$variable" '%s' "$value"
}

validate_credential() {
    local label="$1" value="$2"
    [ -n "$value" ] || die "$label is empty"
    [[ "$value" != *[$'\r\n\t ']* ]] || die "$label must not contain whitespace"
    [[ "$value" =~ ^[A-Za-z0-9_:+/=.@-]+$ ]] || die "$label contains an unexpected character"
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "run this helper through sudo"
fi
if [ "${1-}" != "--iam-ready" ] || [ "$#" -ne 1 ]; then
    printf '%s\n' \
        "Usage: sudo $0 --iam-ready" \
        "" \
        "This repairs only the Cloud.ru key. --iam-ready attests that the account" \
        "has bucket roles editor/viewer/viewer-acl, an explicit bucket-policy" \
        "Deny for deletes, and no tenant.edit/admin role." >&2
    exit 2
fi
for cmd in age-keygen rclone sops install; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command is missing: $cmd"
done
[ -r "$AGE_KEY" ] || die "age private key is not readable at $AGE_KEY"
[ -r "$SECONDARY_TARGET" ] || die "encrypted Cloud.ru configuration is absent"
[ -r "$RUNTIME_ENV" ] || die "rendered Cloud.ru configuration is absent"

printf '%s\n' "Running the mandatory read-only backup check first."
check_rc=0
"$BACKUP_ROOT/scripts/install-backup.sh" --check --profile "$PROFILE" --offsite yandex-ru || check_rc=$?
case "$check_rc" in
    0) printf '%s\n' "Backup is already healthy; no credential was changed."; exit 0 ;;
    1|2) printf '%s\n' "Backup is not healthy yet; Cloud.ru credential repair may proceed." ;;
    *) die "unexpected check exit code: $check_rc" ;;
esac

read_field "$RUNTIME_ENV" OFFSITE_BUCKET bucket || die "Cloud.ru bucket is missing"
read_field "$RUNTIME_ENV" OFFSITE_ENDPOINT endpoint || die "Cloud.ru endpoint is missing"
read_field "$RUNTIME_ENV" AWS_REGION region || die "Cloud.ru region is missing"

read_visible "Cloud.ru complete access key ID (tenant-id:key-id): " cloudru_key_id
read_secret "Cloud.ru key secret (hidden): " cloudru_key_secret
validate_credential "Cloud.ru access key ID" "$cloudru_key_id"
validate_credential "Cloud.ru key secret" "$cloudru_key_secret"
[[ "$cloudru_key_id" =~ ^[A-Za-z0-9_-]+[:.][A-Za-z0-9_-]+$ ]] ||
    die "Cloud.ru access key ID must be tenant-id:key-id (or tenant-id.key-id)"

printf '%s\n' "Validating the replacement key and live bucket versioning read-only."
versioning_rc=0
versioning_output="$( (
    export RCLONE_CONFIG_CORPOFFSITE_TYPE=s3
    export RCLONE_CONFIG_CORPOFFSITE_PROVIDER=Other
    export RCLONE_CONFIG_CORPOFFSITE_ACCESS_KEY_ID="$cloudru_key_id"
    export RCLONE_CONFIG_CORPOFFSITE_SECRET_ACCESS_KEY="$cloudru_key_secret"
    export RCLONE_CONFIG_CORPOFFSITE_ENDPOINT="$endpoint"
    export RCLONE_CONFIG_CORPOFFSITE_REGION="$region"
    export RCLONE_CONFIG_CORPOFFSITE_NO_CHECK_BUCKET=true
    rclone backend versioning "corpoffsite:$bucket" --config /dev/null 2>&1
) )" || versioning_rc=$?
if [ "$versioning_rc" -ne 0 ]; then
    case "$versioning_output" in
        *InvalidAccessKeyId*) die "Cloud.ru does not recognise this access key ID" ;;
        *AccessDenied*) die "Cloud.ru recognised the key but denied GetBucketVersioning; assign s3e.viewer-acl (or s3e.bucket.viewPolicy) on this bucket" ;;
        *) die "Cloud.ru versioning check failed (rclone exit $versioning_rc)" ;;
    esac
fi
versioning="$versioning_output"
[ "$versioning" = "Enabled" ] || die "Cloud.ru bucket versioning is '$versioning', expected 'Enabled'"
printf '%s\n' "Cloud.ru key accepted; live bucket versioning is Enabled."

recipient="$(age-keygen -y "$AGE_KEY")"
[[ "$recipient" == age1* ]] || die "could not derive the public age recipient"
new_tmp old_plain
new_tmp new_plain
new_tmp new_cipher
sops --config /dev/null --decrypt --input-type dotenv --output-type dotenv \
    "$SECONDARY_TARGET" >"$old_plain"

seen_id=false
seen_secret=false
seen_control=false
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        AWS_ACCESS_KEY_ID=*)
            printf 'AWS_ACCESS_KEY_ID=%s\n' "$cloudru_key_id" >>"$new_plain"
            seen_id=true
            ;;
        AWS_SECRET_ACCESS_KEY=*)
            printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$cloudru_key_secret" >>"$new_plain"
            seen_secret=true
            ;;
        OFFSITE_DELETE_CONTROL=*)
            printf 'OFFSITE_DELETE_CONTROL=bucket-policy-deny-delete\n' >>"$new_plain"
            seen_control=true
            ;;
        *) printf '%s\n' "$line" >>"$new_plain" ;;
    esac
done <"$old_plain"
$seen_id || die "encrypted Cloud.ru configuration has no AWS_ACCESS_KEY_ID"
$seen_secret || die "encrypted Cloud.ru configuration has no AWS_SECRET_ACCESS_KEY"
$seen_control || die "encrypted Cloud.ru configuration has no OFFSITE_DELETE_CONTROL"

sops --config /dev/null --encrypt --age "$recipient" \
    --input-type dotenv --output-type dotenv "$new_plain" >"$new_cipher"
history_dir=/var/lib/corp-infra/backup/config-history
install -d -m 0700 -o root -g root "$history_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
install -m 0600 -o root -g root "$SECONDARY_TARGET" \
    "$history_dir/backup-secondary.enc.env.$stamp"
install -m 0600 -o root -g root "$new_cipher" "$SECONDARY_TARGET"
rm -f -- "$old_plain" "$new_plain"
unset cloudru_key_secret

printf '%s\n' "Encrypted Cloud.ru credential repaired; continuing the canonical installer."
"$BACKUP_ROOT/scripts/install-backup.sh" --yes --profile "$PROFILE" --offsite yandex-ru
