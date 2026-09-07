#!/usr/bin/env bash
set -Eeuo pipefail

TOKEN_FILE=/root/.secrets/github_token

case "${1:-get}" in
    get)
        # Consume Git's credential context without echoing any of it.
        while IFS= read -r line; do
            [ -n "$line" ] || break
        done
        printf 'username=x-access-token\n'
        printf 'password='
        sudo cat "$TOKEN_FILE"
        printf '\n'
        ;;
    store|erase)
        # This helper is deliberately ephemeral and stores nothing.
        ;;
    *)
        exit 2
        ;;
esac
