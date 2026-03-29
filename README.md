# Claude OAuth Hybrid Token Sync

Keeps Claude Max OAuth tokens fresh across a headless server running [OpenClaw](https://github.com/openclaw/openclaw) and a laptop with browser access for authentication.

## The Problem

Claude Max OAuth tokens expire every ~12 hours. On a headless server there's no browser to re-authenticate. Without automation, you'd need to manually refresh and push tokens twice a day.

This system solves it with three independent, self-healing loops that cover each other's failure modes.

## Architecture

![Architecture Diagram](docs/architecture.png)

### How Tokens Flow

1. **Claude CLI on your Mac** stores a refresh token in `~/.claude/last-refresh-token` after you run `claude login` (browser auth)
2. **Push script** reads that token, SSHs to the server, and updates the server's `.credentials.json`
3. **Server refresh cron** uses the refresh token to get fresh access tokens from the Anthropic API
4. **Server sync cron** propagates tokens to all OpenClaw agent auth-profiles
5. **Gateway signal** (`SIGUSR1`) tells OpenClaw to hot-reload tokens without restart

### Three-Layer Defence

| Layer | Frequency | Script | What It Does |
|-------|-----------|--------|-------------|
| **Refresh** | Every 2h (cron) | `server/refresh-claude-token.sh` | Checks token expiry. If <2h remaining: tries `claude auth status` first, falls back to direct API call. Exponential backoff on 429. |
| **Sync** | Every 5min (cron) | `server/sync-claude-tokens.sh` | Diffs `.credentials.json` against each agent's `auth-profiles.json`. Updates only on change. Signals gateway for hot-reload. |
| **Push** | Every 4h + wake (LaunchAgent) | `laptop/push-claude-tokens.sh` | Reads refresh token from Mac, pushes to server via SSH. Safety net — the only layer that can inject a token from browser auth. |

## Setup

### Prerequisites

- A headless server running [OpenClaw](https://github.com/openclaw/openclaw) with Claude Max
- A Mac (or any machine) where you can run `claude login` in a browser
- SSH access from laptop to server (Tailscale, VPN, or direct)

### Server

```bash
# 1. Copy scripts to server
scp server/sync-claude-tokens.sh your-server:/root/bin/
scp server/refresh-claude-token.sh your-server:/root/bin/
chmod +x /root/bin/sync-claude-tokens.sh /root/bin/refresh-claude-token.sh

# 2. Ensure .credentials.json exists (run claude login once, or create manually)
# The file lives at /root/.claude/.credentials.json

# 3. Add cron jobs
crontab -e
# Add these lines:
# */5 * * * * /root/bin/sync-claude-tokens.sh >> /var/log/claude-token-sync.log 2>&1
# 0 */2 * * * /root/bin/refresh-claude-token.sh >> /var/log/claude-token-refresh.log 2>&1
```

### Laptop (macOS)

```bash
# 1. Clone the repo
git clone https://github.com/heen-ai/openclaw-claude-oauth-hybrid-sync.git
cd openclaw-claude-oauth-hybrid-sync

# 2. Configure
cp .env.example .env
# Edit .env:
#   SERVER_HOST=your-server    (hostname, Tailscale name, or IP)
#   SERVER_USER=root           (or your SSH user)

# 3. Test the push
chmod +x laptop/push-claude-tokens.sh
./laptop/push-claude-tokens.sh

# 4. Install the LaunchAgent for automatic push
# First, edit the plist to set your install path:
INSTALL_DIR="$(pwd)"
sed "s|__INSTALL_DIR__|${INSTALL_DIR}|g" laptop/com.user.claude-token-push.plist > ~/Library/LaunchAgents/com.user.claude-token-push.plist
launchctl load ~/Library/LaunchAgents/com.user.claude-token-push.plist
```

### Pull tokens (debug/recovery)

If your Mac's Claude CLI loses auth, pull from server:

```bash
chmod +x laptop/pull-claude-tokens.sh
./laptop/pull-claude-tokens.sh
```

This fetches the server's `.credentials.json` and writes both formats (`.credentials.json` + `last-refresh-token`).

## Verification

```bash
# Check sync log (server)
tail -f /var/log/claude-token-sync.log

# Check refresh log (server)
tail -f /var/log/claude-token-refresh.log

# Check token expiry (server)
python3 -c "
import json, time
from datetime import datetime, timezone
with open('/root/.claude/.credentials.json') as f:
    d = json.load(f)
exp = d['claudeAiOauth']['expiresAt'] / 1000
hrs = (exp - time.time()) / 3600
print(f'Expires in {hrs:.1f}h ({datetime.fromtimestamp(exp, timezone.utc)})')
"

# Check LaunchAgent (Mac)
launchctl list | grep claude-token
cat /tmp/claude-token-push.log
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Push says "No Claude credentials found" | Run `claude login` on your Mac |
| Push fails with "Connection refused" | Check `.env` uses correct hostname/IP. If using Tailscale, use the Tailscale hostname. |
| 429 rate limit on API refresh | Handled automatically with exponential backoff. MBP push bypasses the API entirely. |
| Token expired, server can't refresh | Push from Mac, or run `claude login` on server if browser forwarding is available |
| LaunchAgent not running | `launchctl list \| grep claude-token` and check `/tmp/claude-token-push.log` |

## Credential Format History

- **Old (pre-2026):** Claude CLI stored full OAuth in `~/.claude/.credentials.json` (access token, refresh token, expiry, scopes)
- **New (2026+):** Claude CLI stores only the refresh token in `~/.claude/last-refresh-token`
- **Server:** Still uses `.credentials.json` format (maintained by refresh cron)
- **Push script:** Handles both formats automatically (checks `.credentials.json` first, falls back to `last-refresh-token`)

## File Structure

```
├── .env.example              # Server connection config template
├── laptop/
│   ├── push-claude-tokens.sh # Push refresh token from Mac → server
│   ├── pull-claude-tokens.sh # Pull tokens from server → Mac (debug)
│   └── com.user.claude-token-push.plist  # macOS LaunchAgent
├── server/
│   ├── sync-claude-tokens.sh    # Propagate tokens to all agents
│   ├── refresh-claude-token.sh  # Proactively refresh expiring tokens
│   ├── install.sh               # Server setup helper
│   └── validate-tokens.sh       # Token freshness checker
└── docs/
    └── architecture.png         # System architecture diagram
```

## How It Handles Failures

The system is designed to self-heal:

- **Refresh cron fails?** → MBP push injects fresh refresh token on next cycle
- **Mac is closed/offline?** → Server refresh cron handles renewal independently
- **API returns 429?** → Exponential backoff (5min → 15min → 30min → 1h → 2h cap)
- **Token fully expired?** → Run `claude login` on Mac once, push handles the rest
- **Agent has stale token?** → Sync cron catches and fixes within 5 minutes

The only unrecoverable scenario is if Anthropic revokes the refresh token entirely (e.g., you log out everywhere). In that case, run `claude login` on the Mac and the system recovers automatically.

## License

MIT
