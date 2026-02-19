#!/usr/bin/env bash
# Validate Claude OAuth token freshness on server
# Returns 0 if valid, 1 if expired/missing

set -euo pipefail

TOKEN_FILE="${1:-/root/.claude/tokens}"
MAX_AGE_HOURS="${2:-24}"

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "EXPIRED: Token file missing at $TOKEN_FILE"
  exit 1
fi

FILE_AGE_SECONDS=$(( $(date +%s) - $(stat -c %Y "$TOKEN_FILE" 2>/dev/null || stat -f %m "$TOKEN_FILE") ))
MAX_AGE_SECONDS=$(( MAX_AGE_HOURS * 3600 ))

if [[ $FILE_AGE_SECONDS -gt $MAX_AGE_SECONDS ]]; then
  echo "EXPIRED: Token file is $(( FILE_AGE_SECONDS / 3600 ))h old (max: ${MAX_AGE_HOURS}h)"
  exit 1
fi

echo "VALID: Token file is $(( FILE_AGE_SECONDS / 3600 ))h old"
exit 0
