#!/usr/bin/env bash
# Push Claude OAuth refresh token from laptop to Hetzner server
#
# Claude CLI now stores only the refresh token in ~/.claude/last-refresh-token
# (no more .credentials.json on the client side).
#
# This script reads the refresh token, pushes it to the server, and triggers
# the server-side sync which handles access token refresh + agent propagation.
#
# Usage: ./push-claude-tokens.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env" 2>/dev/null || { echo "ERROR: .env not found. Copy .env.example to .env and configure."; exit 1; }

# Paths
REFRESH_TOKEN_FILE="${HOME}/.claude/last-refresh-token"
LOCAL_CREDS="${HOME}/.claude/.credentials.json"
SERVER_CREDS="${SERVER_CREDS_PATH:-/root/.claude/.credentials.json}"
SERVER_HOST="${SERVER_HOST:?Set SERVER_HOST in .env}"
SERVER_USER="${SERVER_USER:-root}"
PUSH_TIMESTAMP_FILE="${SERVER_PUSH_TIMESTAMP:-/root/.openclaw/last-laptop-push}"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
[[ -n "${SSH_KEY_PATH:-}" ]] && SSH_OPTS="$SSH_OPTS -i ${SSH_KEY_PATH}"

# Try .credentials.json first (legacy), fall back to last-refresh-token
if [[ -f "$LOCAL_CREDS" ]]; then
  echo "Found .credentials.json (legacy format), pushing directly..."
  scp $SSH_OPTS "$LOCAL_CREDS" "${SERVER_USER}@${SERVER_HOST}:${SERVER_CREDS}"

elif [[ -f "$REFRESH_TOKEN_FILE" ]]; then
  REFRESH_TOKEN=$(cat "$REFRESH_TOKEN_FILE" | tr -d '[:space:]')

  if [[ -z "$REFRESH_TOKEN" ]]; then
    echo "ERROR: Refresh token file is empty: $REFRESH_TOKEN_FILE"
    echo "Run 'claude login' in your terminal first."
    exit 1
  fi

  echo "Found refresh token (new CLI format), updating server credentials..."

  # Update ONLY the refresh token in the server's existing .credentials.json
  # The server-side refresh logic will use it to get a new access token
  ssh $SSH_OPTS "${SERVER_USER}@${SERVER_HOST}" "python3 -c \"
import json
creds_path = '${SERVER_CREDS}'
try:
    with open(creds_path) as f:
        creds = json.load(f)
except:
    creds = {'claudeAiOauth': {}}

oauth = creds.setdefault('claudeAiOauth', {})
oauth['refreshToken'] = '${REFRESH_TOKEN}'
with open(creds_path, 'w') as f:
    json.dump(creds, f, indent=2)
print('Updated refresh token on server')
\""

else
  echo "ERROR: No Claude credentials found."
  echo "  Checked: $LOCAL_CREDS (legacy)"
  echo "  Checked: $REFRESH_TOKEN_FILE (new CLI)"
  echo "Run 'claude login' in your terminal first."
  exit 1
fi

# Update the push timestamp on server
ssh $SSH_OPTS "${SERVER_USER}@${SERVER_HOST}" "date +%s > $PUSH_TIMESTAMP_FILE"

# Trigger immediate sync on server
ssh $SSH_OPTS "${SERVER_USER}@${SERVER_HOST}" "/root/bin/sync-claude-tokens.sh" 2>/dev/null || true

echo "Done! Tokens synced at $(date)"
