#!/usr/bin/env bash
# Sync Claude OAuth tokens from .credentials.json to ALL OpenClaw agent auth-profiles
# This is Part 1 of the hybrid fix: local credential propagation
#
# Source of truth: /root/.claude/.credentials.json (updated by Claude Code or laptop push)
# Targets: all /root/.openclaw/agents/*/agent/auth-profiles.json
#
# Run via cron: */5 * * * * /root/bin/sync-claude-tokens.sh >> /var/log/claude-token-sync.log 2>&1

set -euo pipefail

CREDS_FILE="/root/.claude/.credentials.json"
STATE_FILE="/root/.openclaw/token-state.json"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

log() { echo "$LOG_PREFIX $1"; }

# Check source exists
if [[ ! -f "$CREDS_FILE" ]]; then
  log "ERROR: Credentials file not found: $CREDS_FILE"
  exit 1
fi

# Extract tokens from .credentials.json
ACCESS_TOKEN=$(python3 -c "
import json
with open('$CREDS_FILE') as f:
    d = json.load(f)
oauth = d.get('claudeAiOauth', {})
print(oauth.get('accessToken', ''))
" 2>/dev/null)

REFRESH_TOKEN=$(python3 -c "
import json
with open('$CREDS_FILE') as f:
    d = json.load(f)
oauth = d.get('claudeAiOauth', {})
print(oauth.get('refreshToken', ''))
" 2>/dev/null)

EXPIRES_AT=$(python3 -c "
import json
with open('$CREDS_FILE') as f:
    d = json.load(f)
oauth = d.get('claudeAiOauth', {})
print(oauth.get('expiresAt', 0))
" 2>/dev/null)

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "None" ]]; then
  log "ERROR: No access token in $CREDS_FILE"
  exit 1
fi

# Check if ANY agent has a stale token
NEEDS_SYNC=0
for PROFILE in /root/.openclaw/agents/*/agent/auth-profiles.json; do
  [[ -f "$PROFILE" ]] || continue
  PTOK=$(python3 -c "
import json
with open('$PROFILE') as f:
    d = json.load(f)
print(d.get('profiles', {}).get('anthropic:default', {}).get('token', ''))
" 2>/dev/null)
  if [[ "$PTOK" != "$ACCESS_TOKEN" ]]; then
    NEEDS_SYNC=1
    break
  fi
done

# Also check if token-state.json is stale
STATE_TOK=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    d = json.load(f)
print(d.get('accessToken', ''))
" 2>/dev/null || echo "")
if [[ "$STATE_TOK" != "$ACCESS_TOKEN" ]]; then
  NEEDS_SYNC=1
fi

if [[ "$NEEDS_SYNC" -eq 0 ]]; then
  # Silent exit - everything in sync
  exit 0
fi

log "Token change detected, syncing to all agents..."

# Update ALL agent auth-profiles
UPDATED=0
for PROFILE in /root/.openclaw/agents/*/agent/auth-profiles.json; do
  [[ -f "$PROFILE" ]] || continue
  
  AGENT=$(echo "$PROFILE" | grep -oP 'agents/\K[^/]+')
  
  python3 -c "
import json
f = '$PROFILE'
with open(f) as fh:
    d = json.load(fh)
p = d.get('profiles', {}).get('anthropic:default', {})
if p:
    p['token'] = '$ACCESS_TOKEN'
    p['accessToken'] = '$ACCESS_TOKEN'
    p['refreshToken'] = '$REFRESH_TOKEN'
    p['expiresAt'] = $EXPIRES_AT
    # Clear any cooldown state
    stats = d.get('usageStats', {})
    for k in list(stats.keys()):
        if isinstance(stats[k], dict):
            stats[k].pop('cooldownUntil', None)
            stats[k]['errorCount'] = 0
    with open(f, 'w') as out:
        json.dump(d, out, indent=2)
" 2>/dev/null
  
  UPDATED=$((UPDATED + 1))
  log "  Updated: $AGENT"
done

# Update token-state.json too (used by refresh script)
python3 -c "
import json
from datetime import datetime, timezone
state = {
    'accessToken': '$ACCESS_TOKEN',
    'refreshToken': '$REFRESH_TOKEN',
    'expiresAt': $EXPIRES_AT,
    'updatedAt': datetime.now(timezone.utc).isoformat(),
    'source': 'sync-from-credentials'
}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null

log "Synced to $UPDATED agents + token-state.json"

# Signal gateway to pick up new tokens
pkill -SIGUSR1 -f openclaw-gateway 2>/dev/null || true
log "Gateway signaled"
