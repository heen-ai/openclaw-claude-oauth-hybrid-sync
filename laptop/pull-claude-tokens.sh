#!/usr/bin/env bash
# Pull Claude OAuth tokens from server to laptop (backup/debug)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env" 2>/dev/null || { echo "ERROR: .env not found."; exit 1; }

LOCAL_CREDS="${LAPTOP_CREDS_PATH:-$HOME/.claude/.credentials.json}"
SERVER_CREDS="${SERVER_CREDS_PATH:-/root/.claude/.credentials.json}"
SERVER_HOST="${SERVER_HOST:?Set SERVER_HOST in .env}"
SERVER_USER="${SERVER_USER:-root}"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
[[ -n "${SSH_KEY_PATH:-}" ]] && SSH_OPTS="$SSH_OPTS -i ${SSH_KEY_PATH}"

# Backup local credentials first
if [[ -f "$LOCAL_CREDS" ]]; then
  cp "$LOCAL_CREDS" "${LOCAL_CREDS}.bak"
  echo "Backed up local credentials to ${LOCAL_CREDS}.bak"
fi

echo "Pulling Claude tokens from ${SERVER_HOST}..."
scp $SSH_OPTS "${SERVER_USER}@${SERVER_HOST}:${SERVER_CREDS}" "$LOCAL_CREDS"
echo "Done! Tokens pulled at $(date)"
