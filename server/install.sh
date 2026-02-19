#!/usr/bin/env bash
# Server-side setup for Claude OAuth token sync
set -euo pipefail

echo "Setting up Claude OAuth token sync (server side)..."

TOKEN_DIR="$(dirname "${SERVER_TOKEN_PATH:-/root/.claude/tokens}")"
mkdir -p "$TOKEN_DIR"
chmod 700 "$TOKEN_DIR"

echo "Token directory ready at $TOKEN_DIR"
echo ""
echo "Next steps:"
echo "  1. Configure .env on your laptop"
echo "  2. Run laptop/push-claude-tokens.sh to test"
echo "  3. Load the LaunchAgent for automatic sync"
