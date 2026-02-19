# openclaw-claude-oauth-hybrid-sync

Hybrid OAuth token sync solution for OpenClaw + Claude. Keeps Claude's OAuth tokens fresh across server and laptop environments using a push/pull sync mechanism.

## Problem

Claude's OAuth tokens expire periodically. When running OpenClaw on a remote server, there's no browser to re-authenticate. This solution bridges that gap by syncing tokens from a laptop (where browser auth happens) to the server.

## Architecture

```
┌─────────────┐     push      ┌──────────────┐
│   Laptop    │ ────────────> │    Server    │
│  (browser)  │               │  (OpenClaw)  │
│             │ <──────────── │              │
└─────────────┘     pull      └──────────────┘
```

### Components

1. **`laptop/push-claude-tokens.sh`** - Pushes fresh tokens from laptop to server via SSH/SCP
2. **`laptop/com.user.claude-token-push.plist`** - macOS LaunchAgent for automatic push on schedule
3. **`laptop/pull-claude-tokens.sh`** - Pulls current server tokens to laptop (backup/debug)
4. **`server/install.sh`** - Server-side setup script
5. **`server/validate-tokens.sh`** - Validates token freshness and alerts on expiry

### Flow

1. User authenticates Claude in browser on laptop
2. LaunchAgent triggers `push-claude-tokens.sh` on a schedule (or manually)
3. Script SCPs the token file to the server
4. OpenClaw picks up the refreshed tokens
5. Server-side validation cron alerts if tokens go stale

## Setup

### Server Side

```bash
./server/install.sh
```

### Laptop Side (macOS)

1. Copy `laptop/` contents to your machine
2. Edit the plist with your username and server details
3. Load the LaunchAgent:
   ```bash
   cp laptop/com.user.claude-token-push.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.user.claude-token-push.plist
   ```

## Configuration

Copy `.env.example` to `.env` and fill in:

```
SERVER_HOST=your-server-ip
SERVER_USER=root
SERVER_TOKEN_PATH=/path/to/claude/tokens
LAPTOP_TOKEN_PATH=~/.claude/tokens
```

## Status

🚧 **In development** - Scaffold created, awaiting laptop-side scripts for audit and integration.

## License

MIT
