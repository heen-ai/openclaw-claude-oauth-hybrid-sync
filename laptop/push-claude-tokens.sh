#!/usr/bin/env bash
# Push Claude OAuth tokens from laptop to server
# Usage: ./push-claude-tokens.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env" 2>/dev/null || { echo "ERROR: .env not found. Copy .env.example to .env and configure."; exit 1; }

TOKEN_FILE="${LAPTOP_TOKEN_PATH:-$HOME/.claude/tokens}"
SSH_OPTS=""
[[ -n "${SSH_KEY_PATH:-}" ]] && SSH_OPTS="-i ${SSH_KEY_PATH}"

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "ERROR: Token file not found at $TOKEN_FILE"
  echo "Authenticate Claude in your browser first."
  exit 1
fi

echo "Pushing Claude tokens to ${SERVER_HOST}..."
scp $SSH_OPTS "$TOKEN_FILE" "${SERVER_USER}@${SERVER_HOST}:${SERVER_TOKEN_PATH}"
echo "Done. Tokens synced at $(date)"
