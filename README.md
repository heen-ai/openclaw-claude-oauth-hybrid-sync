# Claude OAuth Hybrid Token Sync

Keeps Claude Max OAuth tokens fresh across a headless server (OpenClaw on Hetzner) and a laptop (MacBook Pro with browser auth).

## The Problem

Claude Max OAuth tokens expire every ~12 hours. On a headless server there's no browser to re-authenticate. Without this, you have to manually refresh and push tokens 2x/day.

## Architecture

```
┌─────────────────────┐                    ┌─────────────────────┐
│   MacBook Pro       │                    │   Hetzner Server    │
│                     │     SCP push       │                     │
│ claude login        │ ─────────────────> │ .credentials.json   │
│ .credentials.json   │   (every 4h via    │        │            │
│                     │    LaunchAgent)     │        ▼            │
└─────────────────────┘                    │ sync-claude-tokens  │
                                           │ (cron every 5min)   │
                                           │        │            │
                                           │        ▼            │
                                           │ auth-profiles.json  │
                                           │ (all 5 agents)      │
                                           │        │            │
                                           │        ▼            │
                                           │ refresh-claude-token│
                                           │ (cron every 2h)     │
                                           │ - tries CC refresh  │
                                           │ - API fallback      │
                                           └─────────────────────┘
```

### Three-Layer Defence

1. **Sync (every 5 min):** Propagates `.credentials.json` tokens to all OpenClaw agent auth-profiles
2. **Refresh (every 2h):** Proactively refreshes before expiry using Claude Code's built-in auth or direct API
3. **MBP Push (every 4h):** Laptop pushes fresh tokens as a safety net (when Mac is open)

## Server Setup

Already installed at:
- `/root/bin/sync-claude-tokens.sh` - sync cron
- `/root/bin/refresh-claude-token.sh` - refresh cron
- Crontab entries for both

## Laptop Setup (macOS)

```bash
# 1. Clone the repo
git clone https://github.com/heen-ai/openclaw-claude-oauth-hybrid-sync.git
cd openclaw-claude-oauth-hybrid-sync

# 2. Configure
cp .env.example .env
# Edit .env if needed (defaults should work for Heenal's setup)

# 3. Test push
chmod +x laptop/push-claude-tokens.sh
./laptop/push-claude-tokens.sh

# 4. Install automatic push (every 4h + on wake)
cp laptop/com.heenal.claude-token-push.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.heenal.claude-token-push.plist
```

## Verification

```bash
# Check sync log
tail -f /var/log/claude-token-sync.log

# Check refresh log
tail -f /var/log/claude-token-refresh.log

# Check token status
python3 -c "
import json, time
from datetime import datetime, timezone
with open('/root/.claude/.credentials.json') as f:
    d = json.load(f)
exp = d['claudeAiOauth']['expiresAt'] / 1000
hrs = (exp - time.time()) / 3600
print(f'Expires in {hrs:.1f}h ({datetime.fromtimestamp(exp, timezone.utc)})')
"
```

## Troubleshooting

- **429 rate limit on refresh:** Exponential backoff handles this automatically. The MBP push bypasses the API entirely.
- **Token expired, server can't refresh:** Push from MBP or run `claude login` on the server (requires browser forwarding).
- **LaunchAgent not running:** Check `launchctl list | grep claude` and `/tmp/claude-token-push.log`
