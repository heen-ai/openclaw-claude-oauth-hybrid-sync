#!/usr/bin/env bash
# Claude OAuth Token Refresh v5 - Hybrid Approach
# 
# Strategy:
#   1. Check if .credentials.json token is still valid (>1h until expiry)
#   2. If expiring soon, try `claude auth status` to trigger CC's built-in refresh
#   3. If that fails, do manual refresh via API (but with backoff to avoid 429)
#   4. After any refresh, sync-claude-tokens.sh propagates to all agents
#
# Run via cron: 0 */2 * * * /root/bin/refresh-claude-token.sh >> /var/log/claude-token-refresh.log 2>&1

set -euo pipefail

CREDS_FILE="/root/.claude/.credentials.json"
STATE_FILE="/root/.openclaw/token-state.json"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL="https://console.anthropic.com/v1/oauth/token"
LOCKFILE="/tmp/claude-refresh.lock"
BACKOFF_FILE="/tmp/claude-refresh-backoff"
MIN_REMAINING_HOURS=2  # Refresh when less than 2h remaining

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [refresh] $1"
}

cleanup() {
  rm -rf "$LOCKFILE"
}
trap cleanup EXIT

# Prevent concurrent runs
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  # Check if lock is stale (>10 min)
  if [[ -d "$LOCKFILE" ]] && [[ $(($(date +%s) - $(stat -c %Y "$LOCKFILE"))) -gt 600 ]]; then
    rm -rf "$LOCKFILE"
    mkdir "$LOCKFILE"
  else
    log "Another refresh is running, skipping"
    exit 0
  fi
fi

# Check if credentials file exists
if [[ ! -f "$CREDS_FILE" ]]; then
  log "ERROR: No credentials file at $CREDS_FILE"
  exit 1
fi

# Check token expiry
REMAINING_HOURS=$(python3 -c "
import json, time
with open('$CREDS_FILE') as f:
    d = json.load(f)
exp = d.get('claudeAiOauth', {}).get('expiresAt', 0) / 1000
remaining = (exp - time.time()) / 3600
print(f'{remaining:.1f}')
" 2>/dev/null)

if [[ -z "$REMAINING_HOURS" ]]; then
  log "ERROR: Could not read expiry from credentials"
  exit 1
fi

log "Token expires in ${REMAINING_HOURS}h"

# If token has plenty of time left, just sync and exit
if python3 -c "exit(0 if float('$REMAINING_HOURS') > $MIN_REMAINING_HOURS else 1)" 2>/dev/null; then
  log "Token still valid (${REMAINING_HOURS}h remaining), running sync only"
  /root/bin/sync-claude-tokens.sh 2>&1 || true
  exit 0
fi

log "Token expiring soon, attempting refresh..."

# Check exponential backoff (avoid hammering Anthropic)
if [[ -f "$BACKOFF_FILE" ]]; then
  LAST_ATTEMPT=$(cat "$BACKOFF_FILE" 2>/dev/null | head -1)
  FAIL_COUNT=$(cat "$BACKOFF_FILE" 2>/dev/null | tail -1)
  NOW=$(date +%s)
  # Backoff: 5min, 15min, 30min, 1h, 2h (capped)
  BACKOFF_SECS=$((300 * (2 ** (FAIL_COUNT < 5 ? FAIL_COUNT : 5))))
  if [[ $((NOW - LAST_ATTEMPT)) -lt $BACKOFF_SECS ]]; then
    WAIT_MINS=$(( (BACKOFF_SECS - (NOW - LAST_ATTEMPT)) / 60 ))
    log "Backoff active: waiting ${WAIT_MINS}m before next attempt (${FAIL_COUNT} failures)"
    exit 0
  fi
fi

# Method 1: Try triggering Claude Code's own refresh
# Running a minimal command forces CC to check/refresh its auth
log "Method 1: Triggering Claude Code auth check..."
BEFORE_MTIME=$(stat -c %Y "$CREDS_FILE")

# Run claude auth status - this triggers internal refresh if needed
timeout 30 claude auth status > /dev/null 2>&1 || true

sleep 2
AFTER_MTIME=$(stat -c %Y "$CREDS_FILE")

if [[ "$AFTER_MTIME" -gt "$BEFORE_MTIME" ]]; then
  log "SUCCESS: Claude Code refreshed the token"
  rm -f "$BACKOFF_FILE"
  /root/bin/sync-claude-tokens.sh 2>&1 || true
  exit 0
fi

# Method 2: Direct API refresh (fallback)
log "Method 2: Direct API refresh..."

REFRESH_TOKEN=$(python3 -c "
import json
with open('$CREDS_FILE') as f:
    d = json.load(f)
print(d.get('claudeAiOauth', {}).get('refreshToken', ''))
" 2>/dev/null)

if [[ -z "$REFRESH_TOKEN" ]]; then
  log "ERROR: No refresh token available"
  exit 1
fi

RESPONSE_FILE=$(mktemp)
HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN&client_id=$CLIENT_ID" \
  --max-time 15)

log "API response: HTTP $HTTP_CODE"

if [[ "$HTTP_CODE" == "429" ]]; then
  # Rate limited - increment backoff
  FAIL_COUNT=0
  [[ -f "$BACKOFF_FILE" ]] && FAIL_COUNT=$(tail -1 "$BACKOFF_FILE" 2>/dev/null || echo 0)
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "$(date +%s)" > "$BACKOFF_FILE"
  echo "$FAIL_COUNT" >> "$BACKOFF_FILE"
  log "Rate limited (429). Backoff count: $FAIL_COUNT"
  rm -f "$RESPONSE_FILE"
  exit 1
fi

NEW_ACCESS=$(python3 -c "import json; print(json.load(open('$RESPONSE_FILE')).get('access_token',''))" 2>/dev/null)
NEW_REFRESH=$(python3 -c "import json; print(json.load(open('$RESPONSE_FILE')).get('refresh_token',''))" 2>/dev/null)

if [[ -z "$NEW_ACCESS" ]]; then
  ERROR=$(python3 -c "import json; d=json.load(open('$RESPONSE_FILE')); print(d.get('error_description', d.get('error', 'unknown')))" 2>/dev/null || echo "parse error")
  log "ERROR: Refresh failed - $ERROR"
  FAIL_COUNT=0
  [[ -f "$BACKOFF_FILE" ]] && FAIL_COUNT=$(tail -1 "$BACKOFF_FILE" 2>/dev/null || echo 0)
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "$(date +%s)" > "$BACKOFF_FILE"
  echo "$FAIL_COUNT" >> "$BACKOFF_FILE"
  rm -f "$RESPONSE_FILE"
  exit 1
fi

[[ -z "$NEW_REFRESH" ]] && NEW_REFRESH="$REFRESH_TOKEN"

# Apply new tokens to .credentials.json
python3 -c "
import json, time
with open('$CREDS_FILE') as f:
    d = json.load(f)
d['claudeAiOauth']['accessToken'] = '$NEW_ACCESS'
d['claudeAiOauth']['refreshToken'] = '$NEW_REFRESH'
d['claudeAiOauth']['expiresAt'] = int(time.time() * 1000) + (12 * 60 * 60 * 1000)
with open('$CREDS_FILE', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null

log "SUCCESS: Token refreshed via API"
rm -f "$BACKOFF_FILE" "$RESPONSE_FILE"

# Sync to all agents
/root/bin/sync-claude-tokens.sh 2>&1 || true
