# Claude OAuth Hybrid Token Sync

Keeps Claude Max OAuth tokens fresh across a headless server (OpenClaw on Hetzner) and a laptop (MacBook Pro with browser auth).

## The Problem

Claude Max OAuth tokens expire every ~12 hours. On a headless server there's no browser to re-authenticate. Without this, you have to manually refresh and push tokens 2x/day.

## How It Works

```
┌──────────────────────────┐                     ┌──────────────────────────────────────┐
│     MacBook Pro          │                     │       Hetzner Server (tej)           │
│                          │                     │                                      │
│  Claude CLI stores       │   SSH (Tailscale)   │                                      │
│  refresh token at:       │ ──────────────────> │  .credentials.json                   │
│  ~/.claude/              │   push-claude-       │  (source of truth on server)         │
│    last-refresh-token    │   tokens.sh          │         │                            │
│                          │   (every 4h +        │         │                            │
│  LaunchAgent triggers    │    on Mac wake)      │         ▼                            │
│  push automatically      │                     │  ┌─────────────────────┐             │
│                          │                     │  │ sync-claude-tokens  │             │
│  Can also pull tokens    │                     │  │ (cron: every 5min)  │             │
│  FROM server if needed:  │                     │  │                     │             │
│  pull-claude-tokens.sh   │                     │  │ Propagates to ALL   │             │
│                          │                     │  │ OpenClaw agents'    │             │
└──────────────────────────┘                     │  │ auth-profiles.json  │             │
                                                 │  └─────────┬───────────┘             │
                                                 │            │                          │
                                                 │            ▼                          │
                                                 │  ┌─────────────────────┐             │
                                                 │  │ refresh-claude-token│             │
                                                 │  │ (cron: every 2h)   │             │
                                                 │  │                     │             │
                                                 │  │ 1. Check expiry     │             │
                                                 │  │ 2. Try CC refresh   │             │
                                                 │  │ 3. API fallback     │             │
                                                 │  │ 4. Backoff on 429   │             │
                                                 │  └─────────┬───────────┘             │
                                                 │            │                          │
                                                 │            ▼                          │
                                                 │  ┌─────────────────────┐             │
                                                 │  │ SIGUSR1 → Gateway   │             │
                                                 │  │ Hot-reload tokens   │             │
                                                 │  └─────────────────────┘             │
                                                 │                                      │
                                                 │  Agents served:                      │
                                                 │  tej, mira, raksha, waza, rupa,      │
                                                 │  satya, luz, sutra, spark, klaus,     │
                                                 │  sakshi                               │
                                                 └──────────────────────────────────────┘
```

### Three-Layer Defence

| Layer | Runs | What It Does |
|-------|------|-------------|
| **Sync** | Every 5 min (cron) | Propagates `.credentials.json` tokens → all agent `auth-profiles.json` files + `token-state.json` |
| **Refresh** | Every 2h (cron) | Proactively refreshes before expiry: tries Claude Code built-in auth first, falls back to direct API call with exponential backoff |
| **MBP Push** | Every 4h + on wake (LaunchAgent) | Laptop pushes fresh refresh token over SSH as ultimate safety net |

### Token Flow

1. **Claude CLI on Mac** stores refresh token in `~/.claude/last-refresh-token` (new format, no more `.credentials.json` on client)
2. **Push script** reads that refresh token, SSHs to server, updates server's `.credentials.json`
3. **Server refresh cron** uses the refresh token to get fresh access tokens from Anthropic API
4. **Server sync cron** propagates access + refresh tokens to all 11 OpenClaw agent auth-profiles
5. **Gateway SIGUSR1** tells OpenClaw to hot-reload the updated tokens without restart

## Server Setup

Already installed on Hetzner (hostname: `tej`):

| File | Purpose |
|------|---------|
| `/root/bin/sync-claude-tokens.sh` | Sync cron (propagates tokens to agents) |
| `/root/bin/refresh-claude-token.sh` | Refresh cron (renews expiring tokens) |
| `/root/.claude/.credentials.json` | Server-side source of truth |
| `/root/.openclaw/token-state.json` | Token state tracking |

Crontab:
```cron
*/5 * * * * /root/bin/sync-claude-tokens.sh >> /var/log/claude-token-sync.log 2>&1
0 */2 * * * /root/bin/refresh-claude-token.sh >> /var/log/claude-token-refresh.log 2>&1
```

## Laptop Setup (macOS)

```bash
# 1. Clone the repo
git clone https://github.com/heen-ai/openclaw-claude-oauth-hybrid-sync.git
cd openclaw-claude-oauth-hybrid-sync

# 2. Configure
cp .env.example .env
# Edit .env - defaults:
#   SERVER_HOST=tej        (Tailscale hostname)
#   SERVER_USER=root

# 3. Test push
chmod +x laptop/push-claude-tokens.sh
./laptop/push-claude-tokens.sh

# 4. Install automatic push (every 4h + on wake)
cp laptop/com.user.claude-token-push.plist ~/Library/LaunchAgents/com.heenal.claude-token-push.plist
launchctl load ~/Library/LaunchAgents/com.heenal.claude-token-push.plist
```

### Pull tokens (debug/recovery)

If your Mac's Claude CLI loses auth, pull from server:

```bash
./laptop/pull-claude-tokens.sh
```

This fetches the server's `.credentials.json` and writes both formats (`.credentials.json` + `last-refresh-token`).

## Verification

```bash
# Check sync log (on server)
tail -f /var/log/claude-token-sync.log

# Check refresh log (on server)
tail -f /var/log/claude-token-refresh.log

# Check token status (on server)
python3 -c "
import json, time
from datetime import datetime, timezone
with open('/root/.claude/.credentials.json') as f:
    d = json.load(f)
exp = d['claudeAiOauth']['expiresAt'] / 1000
hrs = (exp - time.time()) / 3600
print(f'Expires in {hrs:.1f}h ({datetime.fromtimestamp(exp, timezone.utc)})')
"

# Check LaunchAgent (on Mac)
launchctl list | grep claude
cat /tmp/claude-token-push.log
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Push script says "No Claude credentials found" | Run `claude login` on your Mac |
| Push fails with "Connection refused" | Check `.env` uses Tailscale hostname (`tej`), not raw IP |
| 429 rate limit on refresh | Automatic exponential backoff handles this. MBP push bypasses the API entirely. |
| Token expired, server can't refresh | Push from MBP, or run `claude login` on server (requires browser forwarding) |
| LaunchAgent not running | `launchctl list \| grep claude` and check `/tmp/claude-token-push.log` |
| Pull script fails | Ensure SSH to server works: `ssh root@tej echo ok` |

## Credential Format History

- **Old (pre-2026):** Claude CLI stored full OAuth in `~/.claude/.credentials.json` (access token, refresh token, expiry, scopes)
- **New (2026+):** Claude CLI stores only refresh token in `~/.claude/last-refresh-token`
- **Server:** Still uses `.credentials.json` format (maintained by refresh cron)
- **Push script:** Handles both formats automatically (checks `.credentials.json` first, falls back to `last-refresh-token`)
