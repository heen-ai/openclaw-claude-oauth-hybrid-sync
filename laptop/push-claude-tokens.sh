#!/usr/bin/env bash
# Push Claude OAuth tokens from laptop to Hetzner server
# 
# This reads ~/.claude/.credentials.json from your Mac, extracts the OAuth tokens,
# and pushes them to the server's .credentials.json. The server-side sync cron
# then propagates to all OpenClaw agents.
#
# Usage: ./push-claude-tokens.sh
# Or set up the LaunchAgent for automatic push every 4 hours.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env" 2>/dev/null || { echo "ERROR: .env not found. Copy .env.example to .env and configure."; exit 1; }

# Default paths
LOCAL_CREDS="${LAPTOP_CREDS_PATH:-$HOME/.claude/.credentials.json}"
SERVER_CREDS="${SERVER_CREDS_PATH:-/root/.claude/.credentials.json}"
SERVER_HOST="${SERVER_HOST:?Set SERVER_HOST in .env}"
SERVER_USER="${SERVER_USER:-root}"
PUSH_TIMESTAMP_FILE="${SERVER_PUSH_TIMESTAMP:-/root/.openclaw/last-laptop-push}"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
[[ -n "${SSH_KEY_PATH:-}" ]] && SSH_OPTS="$SSH_OPTS -i ${SSH_KEY_PATH}"

# Check local credentials exist
if [[ ! -f "$LOCAL_CREDS" ]]; then
  echo "ERROR: No credentials at $LOCAL_CREDS"
  echo "Run 'claude login' in your terminal first."
  exit 1
fi

# Extract token info for logging
EXPIRY=$(python3 -c "
import json
from datetime import datetime, timezone
with open('$LOCAL_CREDS') as f:
    d = json.load(f)
exp = d.get('claudeAiOauth', {}).get('expiresAt', 0) / 1000
print(datetime.fromtimestamp(exp, timezone.utc).strftime('%Y-%m-%d %H:%M UTC'))
" 2>/dev/null || echo "unknown")

echo "Pushing Claude tokens to ${SERVER_HOST}..."
echo "  Token expires: $EXPIRY"

# Push the credentials file
scp $SSH_OPTS "$LOCAL_CREDS" "${SERVER_USER}@${SERVER_HOST}:${SERVER_CREDS}"

# Update the push timestamp on server (so the hybrid logic knows laptop is active)
ssh $SSH_OPTS "${SERVER_USER}@${SERVER_HOST}" "date +%s > $PUSH_TIMESTAMP_FILE"

# Trigger immediate sync on server
ssh $SSH_OPTS "${SERVER_USER}@${SERVER_HOST}" "/root/bin/sync-claude-tokens.sh" 2>/dev/null || true

echo "Done! Tokens synced at $(date)"
echo "Server will pick up the new token within 5 minutes (or immediately if sync ran)."
