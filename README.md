# claude-code-statusline

Custom status line for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that surfaces model, context window usage, 5-hour and 7-day rate-limit utilization, git branch, and working directory — with adaptive caching and 429 backoff against the Anthropic OAuth usage endpoint.

![screenshot](screenshot.png)

## Features

- Model display name
- Context window utilization (colored pie + percent)
- 5-hour rate-limit utilization with countdown to reset
- 7-day rate-limit utilization with reset date/time
- Git branch (per-workspace cached)
- Current working directory
- Adaptive cache TTL (5/15/30 min) based on max utilization
- 429 rate-limit backoff with visible indicator
- Auth-expired indicator (`🔑 auth?`)
- Forced refresh when a rate-limit window resets — never shows post-reset stale numbers

## Requirements

- `bash`, `jq`, `curl`, `git`, `awk`, `date` (GNU)
- A logged-in Claude Code CLI (`~/.claude/.credentials.json`)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ncoevoet/claude-code-statusline/main/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

## Configuration

Override defaults via environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_STATUSLINE_CACHE_DIR` | `/tmp/claude` | Cache directory for usage + git + version |
| `CLAUDE_STATUSLINE_API_URL` | `https://api.anthropic.com/api/oauth/usage` | Usage endpoint |
| `CLAUDE_CREDENTIALS_PATH` | `~/.claude/.credentials.json` | OAuth credentials file |

## Refresh logic

- Adaptive TTL: 30 min by default, drops to 15 min above 50% utilization, 5 min above 80%
- HTTP 429 → 15 min backoff
- HTTP 401 → 5 min backoff + `🔑 auth?` indicator
- Other errors → 5 min backoff, stale cache preserved
- **Forced refresh:** if the cached `five_hour.resets_at` or `seven_day.resets_at` has passed, the next render bypasses the TTL and backoff and fetches fresh data

## License

MIT
