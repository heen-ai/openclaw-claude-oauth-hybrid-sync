#!/usr/bin/env bash
# Claude OAuth Token Refresh v6
# 
# Reality check: on a headless server, we can't do browser auth.
# Method 1 (claude auth status) doesn't actually refresh tokens.
# Method 2 (direct API) gets 429'd consistently.
# 
# The ONLY reliable token source is the Mac pushing via SSH.
# 
# This script's job is now:
#   1. Monitor token health
#   2. If expiring soon: try API refresh (with sane backoff)
#   3. If API fails: trigger MBP push by writing a flag file
#   4. If token is expired: log loudly so we know
#
# Run via cron: 0 * * * * /root/bin/refresh-claude-token.sh >> /var/log/claude-token-refresh.log 2>&1

set -euo pipefail

CREDS_FILE="/root/.claude/.credentials.json"
STATE_FILE="/root/.openclaw/token-state.json"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL="https://console.anthropic.com/v1/oauth/token"
LOCKFILE="/tmp/claude-refresh.lock"
BACKOFF_FILE="/tmp/claude-refresh-backoff"
MIN_REMAINING_HOURS=4  # Start trying to refresh when <4h remaining

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [refresh] $1"
}

cleanup() {
  rm -rf "$LOCKFILE"
}
trap cleanup EXIT

# Prevent concurrent runs
if ! mkdir "$LOCKFILE" 2>/dev/null; then
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

# Token is healthy - clear backoff, sync, done
if python3 -c "exit(0 if float('$REMAINING_HOURS') > $MIN_REMAINING_HOURS else 1)" 2>/dev/null; then
  rm -f "$BACKOFF_FILE"
  log "Token still valid (${REMAINING_HOURS}h remaining), running sync only"
  /root/bin/sync-claude-tokens.sh 2>&1 || true
  exit 0
fi

# Token is expired or expiring
TOKEN_EXPIRED=false
if python3 -c "exit(0 if float('$REMAINING_HOURS') < 0 else 1)" 2>/dev/null; then
  TOKEN_EXPIRED=true
  log "CRITICAL: Token is EXPIRED (${REMAINING_HOURS}h)"
else
  log "Token expiring soon (${REMAINING_HOURS}h remaining), attempting refresh..."
fi

# Check backoff - but NEVER block if token is already expired
if [[ -f "$BACKOFF_FILE" ]] && [[ "$TOKEN_EXPIRED" != "true" ]]; then
  LAST_ATTEMPT=$(head -1 "$BACKOFF_FILE" 2>/dev/null)
  FAIL_COUNT=$(tail -1 "$BACKOFF_FILE" 2>/dev/null)
  NOW=$(date +%s)
  # Backoff: 5min, 10min, 20min, 30min max
  BACKOFF_SECS=$((300 * (2 ** (FAIL_COUNT < 3 ? FAIL_COUNT : 3))))
  [[ $BACKOFF_SECS -gt 1800 ]] && BACKOFF_SECS=1800
  if [[ $((NOW - LAST_ATTEMPT)) -lt $BACKOFF_SECS ]]; then
    WAIT_MINS=$(( (BACKOFF_SECS - (NOW - LAST_ATTEMPT)) / 60 ))
    log "Backoff active: waiting ${WAIT_MINS}m before next attempt (${FAIL_COUNT} failures)"
    exit 0
  fi
fi

# Clear backoff if expired (emergency mode)
[[ "$TOKEN_EXPIRED" == "true" ]] && rm -f "$BACKOFF_FILE"

# Try API refresh
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

log "Attempting API refresh..."
RESPONSE_FILE=$(mktemp)
HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN&client_id=$CLIENT_ID" \
  --max-time 15)

log "API response: HTTP $HTTP_CODE"

if [[ "$HTTP_CODE" == "200" ]]; then
  NEW_ACCESS=$(python3 -c "import json; print(json.load(open('$RESPONSE_FILE')).get('access_token',''))" 2>/dev/null)
  NEW_REFRESH=$(python3 -c "import json; print(json.load(open('$RESPONSE_FILE')).get('refresh_token',''))" 2>/dev/null)
  
  if [[ -n "$NEW_ACCESS" ]]; then
    [[ -z "$NEW_REFRESH" ]] && NEW_REFRESH="$REFRESH_TOKEN"
    
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
    /root/bin/sync-claude-tokens.sh 2>&1 || true
    exit 0
  fi
fi

# API failed - increment backoff
FAIL_COUNT=0
[[ -f "$BACKOFF_FILE" ]] && FAIL_COUNT=$(tail -1 "$BACKOFF_FILE" 2>/dev/null || echo 0)
FAIL_COUNT=$((FAIL_COUNT + 1))
echo "$(date +%s)" > "$BACKOFF_FILE"
echo "$FAIL_COUNT" >> "$BACKOFF_FILE"

ERROR_DETAIL=""
[[ "$HTTP_CODE" == "429" ]] && ERROR_DETAIL="rate limited"
[[ -z "$ERROR_DETAIL" ]] && ERROR_DETAIL=$(python3 -c "import json; d=json.load(open('$RESPONSE_FILE')); print(d.get('error_description', d.get('error', 'unknown')))" 2>/dev/null || echo "unknown")

log "API refresh failed: HTTP $HTTP_CODE ($ERROR_DETAIL). Backoff count: $FAIL_COUNT"
log "Waiting for MBP push (LaunchAgent runs every 4h + on wake)"

rm -f "$RESPONSE_FILE"

# If token is expired and API failed, this is critical
if [[ "$TOKEN_EXPIRED" == "true" ]]; then
  log "CRITICAL: Token expired and API refresh failed. Agents are down until MBP pushes new tokens."
  log "Manual fix: run ./laptop/push-claude-tokens.sh from your Mac"
fi
