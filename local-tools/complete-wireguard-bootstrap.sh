#!/usr/bin/env bash
set -Eeuo pipefail

WG_INSTALLER=/opt/corp-infra/vpn-proxy/scripts/install-wireguard.sh
PROFILE=two-vps-split-b
ISSUE_CONFIRMED=0

case "${1:-}" in
    --issue-operator)
        ISSUE_CONFIRMED=1
        shift
        ;;
    --help|-h)
        printf 'Usage: sudo %s --issue-operator\n' "$0"
        printf '%s\n' 'The explicit flag confirms issuance of the first operator VPN credential.'
        exit 0
        ;;
    '') ;;
    *)
        printf 'Unknown argument: %s\n' "$1" >&2
        exit 2
        ;;
esac
if [ "$#" -ne 0 ]; then
    printf '%s\n' 'Only --issue-operator is accepted.' >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this helper with sudo.\n' >&2
    exit 2
fi

if [ ! -t 0 ] || [ ! -t 1 ]; then
    printf 'An interactive terminal is required: the first peer configuration is secret.\n' >&2
    exit 2
fi

printf '%s\n' 'Running the mandatory read-only WireGuard check first.'
set +e
"$WG_INSTALLER" --check --profile "$PROFILE"
check_rc=$?
set -e

case "$check_rc" in
    0)
        printf '%s\n' 'WireGuard is already ready; nothing to change.'
        exit 0
        ;;
    1)
        printf '%s\n' 'WireGuard is not ready yet; initial installation may proceed.'
        ;;
    2)
        if ip link show wg0 >/dev/null 2>&1 \
            && [ -s /etc/wireguard/peers/operator.conf ]; then
            printf '%s\n' \
                'WireGuard has a resumable first-peer setup with no handshake yet.' \
                'The installer will repair the encrypted copy and print the existing configuration.'
        else
            printf 'Pre-check was inconclusive (exit %s); stopping before mutation.\n' "$check_rc" >&2
            exit 2
        fi
        ;;
    *)
        printf 'Pre-check was inconclusive (exit %s); stopping before mutation.\n' "$check_rc" >&2
        exit 2
        ;;
esac

printf '%s\n' \
    'The next step grants the first operator device access to the admin VPN.' \
    'Its configuration contains a private key and will be printed only here.' \
    'Import the complete text between BEGIN/END into WireGuard on Windows 11.'
if [ "$ISSUE_CONFIRMED" -ne 1 ]; then
    printf '%s\n' \
        'Access issuance was not confirmed.' \
        "Re-run this helper with --issue-operator as an explicit command-line decision." >&2
    exit 1
fi
printf '%s\n' 'Operator access issuance explicitly confirmed by --issue-operator.'

set +e
"$WG_INSTALLER" --profile "$PROFILE" --yes
install_rc=$?
set -e

case "$install_rc" in
    0)
        printf '%s\n' 'WireGuard is ready and has a fresh handshake.'
        exit 0
        ;;
    2)
        if ip link show wg0 >/dev/null 2>&1 \
            && [ -s /etc/wireguard/peers/operator.conf ]; then
            printf '%s\n' \
                'Initial setup is complete, but a fresh handshake is still required.' \
                'On Windows: create an empty tunnel, paste the configuration shown above,' \
                'save it, and activate it. Then return to this terminal.'
        else
            printf '%s\n' \
                'WireGuard setup is inconclusive and did not create wg0 plus the operator configuration.' \
                'Stopping: do not create or activate a Windows tunnel yet.' >&2
            exit 2
        fi
        ;;
    *)
        printf 'WireGuard installer failed (exit %s); stopping.\n' "$install_rc" >&2
        exit "$install_rc"
        ;;
esac

printf 'After the Windows tunnel is active, press Enter to verify it: '
IFS= read -r _

# Applying again is idempotent. It does not issue a second peer; it publishes
# vpn.ready only after the live check sees the fresh handshake.
exec "$WG_INSTALLER" --profile "$PROFILE" --yes
