#!/usr/bin/env bash
# Pull Claude OAuth tokens from server to laptop (backup/debug)
# Usage: ./pull-claude-tokens.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env" 2>/dev/null || { echo "ERROR: .env not found."; exit 1; }

TOKEN_FILE="${LAPTOP_TOKEN_PATH:-$HOME/.claude/tokens}"
SSH_OPTS=""
[[ -n "${SSH_KEY_PATH:-}" ]] && SSH_OPTS="-i ${SSH_KEY_PATH}"

echo "Pulling Claude tokens from ${SERVER_HOST}..."
scp $SSH_OPTS "${SERVER_USER}@${SERVER_HOST}:${SERVER_TOKEN_PATH}" "$TOKEN_FILE"
echo "Done. Tokens pulled at $(date)"
