#!/usr/bin/env bash
set -Eeuo pipefail

ESCROW_SCRIPT=/opt/corp-infra/security/scripts/age-escrow.sh

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this helper with sudo.\n' >&2
    exit 2
fi

if [ ! -t 0 ]; then
    printf 'A terminal is required to enter the escrow-copy fingerprint.\n' >&2
    exit 2
fi

printf 'Paste fingerprint calculated from the KeePassXC escrow copy: '
IFS= read -r fingerprint
fingerprint="${fingerprint//$'\r'/}"

if [[ ! "$fingerprint" =~ ^[[:xdigit:]]{64}$ ]]; then
    printf 'Expected exactly 64 hexadecimal characters.\n' >&2
    exit 1
fi

exec "$ESCROW_SCRIPT" \
    --yes \
    --attest "$fingerprint" \
    --add-location 'team-password-manager:KeePassXC:2' \
    --add-location 'offline:safe:1'
