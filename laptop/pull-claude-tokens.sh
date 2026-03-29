#!/usr/bin/env bash
# Pull Claude OAuth tokens from server to laptop
# Useful for debugging or if your local Claude CLI session expired
#
# Pulls the server's .credentials.json which contains both access and refresh tokens.
# After pulling, Claude CLI should pick up the tokens automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env" 2>/dev/null || { echo "ERROR: .env not found."; exit 1; }

SERVER_CREDS="${SERVER_CREDS_PATH:-/root/.claude/.credentials.json}"
SERVER_HOST="${SERVER_HOST:?Set SERVER_HOST in .env}"
SERVER_USER="${SERVER_USER:-root}"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
[[ -n "${SSH_KEY_PATH:-}" ]] && SSH_OPTS="$SSH_OPTS -i ${SSH_KEY_PATH}"

LOCAL_CREDS="${HOME}/.claude/.credentials.json"
REFRESH_TOKEN_FILE="${HOME}/.claude/last-refresh-token"

# Backup existing local credentials
if [[ -f "$LOCAL_CREDS" ]]; then
  cp "$LOCAL_CREDS" "${LOCAL_CREDS}.bak"
  echo "Backed up local .credentials.json"
fi
if [[ -f "$REFRESH_TOKEN_FILE" ]]; then
  cp "$REFRESH_TOKEN_FILE" "${REFRESH_TOKEN_FILE}.bak"
  echo "Backed up local last-refresh-token"
fi

echo "Pulling Claude tokens from ${SERVER_HOST}..."

# Pull the full .credentials.json from server
scp $SSH_OPTS "${SERVER_USER}@${SERVER_HOST}:${SERVER_CREDS}" "$LOCAL_CREDS"

# Also extract the refresh token to last-refresh-token (new CLI format)
python3 -c "
import json
with open('$LOCAL_CREDS') as f:
    d = json.load(f)
rt = d.get('claudeAiOauth', {}).get('refreshToken', '')
if rt:
    with open('$REFRESH_TOKEN_FILE', 'w') as f:
        f.write(rt)
    print(f'Refresh token written to last-refresh-token')
else:
    print('WARNING: No refresh token found in server credentials')
" 2>/dev/null

echo "Done! Tokens pulled at $(date)"
echo "Claude CLI should pick up the new tokens automatically."
