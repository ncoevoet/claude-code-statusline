#!/bin/bash

set -f          # disable globbing
set -o pipefail # catch piped command failures

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ===== Configuration (overridable via env vars) =====
CACHE_DIR="${CLAUDE_STATUSLINE_CACHE_DIR:-/tmp/claude}"
API_URL="${CLAUDE_STATUSLINE_API_URL:-https://api.anthropic.com/api/oauth/usage}"
CREDS_PATH="${CLAUDE_CREDENTIALS_PATH:-$HOME/.claude/.credentials.json}"

mkdir -p "$CACHE_DIR"

# ANSI colors matching oh-my-posh theme
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;200;100;255m'
dim='\033[2m'
reset='\033[0m'

# ===== Helpers =====

# Safe integer conversion — returns 0 for non-numeric input
to_int() {
    local val="$1"
    if [[ "$val" =~ ^-?[0-9]+$ ]]; then
        echo "$val"
    else
        echo 0
    fi
}

# Format token counts (e.g., 50k / 200k)
format_tokens() {
    local num=$(to_int "$1")
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Format number with commas (e.g., 134,938)
format_commas() {
    printf "%'d" "$(to_int "$1")"
}

# Build a colored pie icon for percentage
build_pie() {
    local pct=$(to_int "$1")
    [ "$pct" -lt 0 ] && pct=0
    [ "$pct" -gt 100 ] && pct=100

    local icon
    if [ "$pct" -ge 90 ]; then icon="●"
    elif [ "$pct" -ge 66 ]; then icon="◕"
    elif [ "$pct" -ge 36 ]; then icon="◑"
    elif [ "$pct" -ge 11 ]; then icon="◔"
    else icon="○"
    fi

    local pie_color
    if [ "$pct" -ge 90 ]; then pie_color="$red"
    elif [ "$pct" -ge 70 ]; then pie_color="$yellow"
    elif [ "$pct" -ge 50 ]; then pie_color="$orange"
    else pie_color="$green"
    fi

    printf "${pie_color}${icon}${reset}"
}

# Compute adaptive TTL based on max usage percentage
compute_adaptive_ttl() {
    local max_pct=$(to_int "$1")
    if [ "$max_pct" -gt 80 ]; then echo 300
    elif [ "$max_pct" -gt 50 ]; then echo 900
    else echo 1800
    fi
}

# Format age for staleness indicator (e.g., "2m", "15m", "1h")
format_age() {
    local secs=$(to_int "$1")
    if [ "$secs" -lt 60 ]; then echo "${secs}s"
    elif [ "$secs" -lt 3600 ]; then echo "$(( secs / 60 ))m"
    else echo "$(( secs / 3600 ))h"
    fi
}

# Format ISO time as DD/MM HH:MM
format_datetime() {
    local iso_str="$1"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return
    local epoch
    epoch=$(date -d "$iso_str" +%s 2>/dev/null)
    [ -z "$epoch" ] && return
    date -d "@$epoch" +"%d/%m %H:%M"
}

# Format ISO reset time as HH:MM countdown duration
format_countdown() {
    local iso_str="$1"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return
    local epoch now remaining
    epoch=$(date -d "$iso_str" +%s 2>/dev/null)
    [ -z "$epoch" ] && return
    now=$(date +%s)
    remaining=$(( epoch - now ))

    if [ "$remaining" -le 0 ]; then
        echo "for 0m"
    else
        local hours=$(( remaining / 3600 ))
        local mins=$(( (remaining % 3600) / 60 ))
        if [ "$hours" -gt 0 ]; then
            printf "for %dh %dm" "$hours" "$mins"
        else
            printf "for %dm" "$mins"
        fi
    fi
}

# Atomic file write: write to .tmp then mv
atomic_write() {
    local target="$1"
    local content="$2"
    local tmp="${target}.tmp"
    echo "$content" > "$tmp" && mv -f "$tmp" "$target"
}

# Get cached claude version (1-hour TTL)
get_claude_version() {
    local cache="$CACHE_DIR/statusline-version-cache"
    local max_age=3600

    if [ -f "$cache" ]; then
        local mtime age
        mtime=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null)
        age=$(( $(date +%s) - mtime ))
        if [ "$age" -lt "$max_age" ]; then
            cat "$cache"
            return
        fi
    fi

    local ver
    ver=$(claude --version 2>/dev/null | awk '{print $1}')
    [ -n "$ver" ] && atomic_write "$cache" "$ver"
    echo "${ver:-unknown}"
}

# ===== Git branch (cached, per-workspace) =====
get_git_branch() {
    # Hash cwd into cache filename for per-workspace isolation
    local cwd_hash
    cwd_hash=$(echo -n "$cwd" | md5sum 2>/dev/null | cut -c1-8)
    local cache_file="$CACHE_DIR/statusline-git-${cwd_hash:-default}"
    local max_age=10
    local branch=""
    local refresh=true

    if [ -f "$cache_file" ]; then
        local mtime now age
        mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        now=$(date +%s)
        age=$(( now - mtime ))
        [ "$age" -lt "$max_age" ] && refresh=false && branch=$(cat "$cache_file")
    fi

    if $refresh; then
        if [ -n "$cwd" ] && [ -d "$cwd" ]; then
            branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
            if [ "$branch" = "HEAD" ]; then
                branch="detached:$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || echo unknown)"
            fi
        fi
        atomic_write "$cache_file" "$branch"
    fi
    echo "$branch"
}

# ===== Extract data from JSON (single jq call) =====
IFS='|' read -r model_name size input_tokens cache_create cache_read cwd < <(
    echo "$input" | jq -r '[
        (.model.display_name // "Claude"),
        (.context_window.context_window_size // 200000),
        (.context_window.current_usage.input_tokens // 0),
        (.context_window.current_usage.cache_creation_input_tokens // 0),
        (.context_window.current_usage.cache_read_input_tokens // 0),
        (.workspace.current_dir // "")
    ] | join("|")'
)

size=$(to_int "$size")
input_tokens=$(to_int "$input_tokens")
cache_create=$(to_int "$cache_create")
cache_read=$(to_int "$cache_read")
[ "$size" -eq 0 ] && size=200000
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi
pct_remain=$(( 100 - pct_used ))

used_comma=$(format_commas $current)
remain_comma=$(format_commas $(( size - current )))

# ===== LINE 1: branch | Model | context bar | usage limits =====
branch_name=$(get_git_branch)
line1=""
line1+="${blue}${model_name}${reset}"
line1+=" ${dim}|${reset} "
context_pie=$(build_pie "$pct_used")
line1+="${context_pie} ${cyan}${pct_used}%${reset}"


# ===== Usage limits with adaptive caching and rate-limit backoff =====
cache_file="$CACHE_DIR/statusline-usage-cache.json"

needs_refresh=true
usage_data=""
fetched_at=0
adaptive_ttl=1800
now=$(date +%s)
is_stale=false
is_backoff=false

# Read cache — single jq call for validation + field extraction, data extracted separately
if [ -f "$cache_file" ]; then
    cache_meta=$(jq -r '
        if .fetched_at then
            [(.fetched_at // 0), (.adaptive_ttl // 1800), (.backoff_until // 0)]
            | join(" ")
        else "invalid" end
    ' < "$cache_file" 2>/dev/null)

    if [ "$cache_meta" != "invalid" ] && [ -n "$cache_meta" ]; then
        read -r fetched_at adaptive_ttl backoff_until <<< "$cache_meta"
        fetched_at=$(to_int "$fetched_at")
        adaptive_ttl=$(to_int "$adaptive_ttl")
        backoff_until=$(to_int "$backoff_until")
        [ "$adaptive_ttl" -eq 0 ] && adaptive_ttl=1800

        usage_data=$(jq -c '.data // empty' < "$cache_file" 2>/dev/null)

        cache_age=$(( now - fetched_at ))
        if [ "$cache_age" -lt "$adaptive_ttl" ]; then
            needs_refresh=false
        else
            is_stale=true
        fi

        # Rate-limit backoff: skip fetch if in cooldown
        if $needs_refresh && [ "$backoff_until" -gt "$now" ]; then
            needs_refresh=false
            is_stale=true
            is_backoff=true
        fi
    fi
fi

# Force refresh if either rate-limit window has reset since last fetch
if ! $needs_refresh && [ -n "$usage_data" ]; then
    IFS='|' read -r cached_5h_reset cached_7d_reset < <(
        echo "$usage_data" | jq -r '[
            (.five_hour.resets_at // ""),
            (.seven_day.resets_at // "")
        ] | join("|")'
    )
    for reset_iso in "$cached_5h_reset" "$cached_7d_reset"; do
        [ -z "$reset_iso" ] || [ "$reset_iso" = "null" ] && continue
        reset_epoch=$(date -d "$reset_iso" +%s 2>/dev/null)
        if [ -n "$reset_epoch" ] && [ "$now" -ge "$reset_epoch" ]; then
            needs_refresh=true
            is_backoff=false
            backoff_until=0
            break
        fi
    done
fi

# Fetch fresh data if cache is stale
if $needs_refresh; then
    if [ -f "$CREDS_PATH" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS_PATH" 2>/dev/null)
        if [ -n "$token" ]; then
            claude_ver=$(get_claude_version)
            tmp_body="$CACHE_DIR/statusline-response.tmp"

            http_code=$(curl -s --max-time 5 \
                -o "$tmp_body" -w '%{http_code}' \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/$claude_ver" \
                "$API_URL" 2>/dev/null)

            response=""
            [ -f "$tmp_body" ] && response=$(cat "$tmp_body") && rm -f "$tmp_body"

            if [ "$http_code" = "401" ]; then
                # Token expired/invalid — mark for display, set short backoff
                is_stale=true
                is_backoff=false
                auth_expired=true
                backoff_until=$(( now + 300 ))
                if [ -n "$usage_data" ]; then
                    atomic_write "$cache_file" "$(jq -nc --argjson data "$usage_data" \
                        --argjson ts "$fetched_at" \
                        --argjson ttl "$adaptive_ttl" \
                        --argjson bo "$backoff_until" \
                        '{fetched_at: $ts, adaptive_ttl: $ttl, backoff_until: $bo, data: $data}')"
                fi
            elif [ "$http_code" = "429" ]; then
                # Rate limited — set 15-minute backoff, keep stale data
                backoff_until=$(( now + 900 ))
                is_backoff=true
                if [ -n "$usage_data" ]; then
                    atomic_write "$cache_file" "$(jq -nc --argjson data "$usage_data" \
                        --argjson ts "$fetched_at" \
                        --argjson ttl "$adaptive_ttl" \
                        --argjson bo "$backoff_until" \
                        '{fetched_at: $ts, adaptive_ttl: $ttl, backoff_until: $bo, data: $data}')"
                else
                    atomic_write "$cache_file" "$(jq -nc \
                        --argjson ts "$now" --argjson bo "$backoff_until" \
                        '{fetched_at: $ts, adaptive_ttl: 900, backoff_until: $bo, data: null}')"
                    fetched_at=$now
                    adaptive_ttl=900
                fi
                is_stale=true
            elif [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
                usage_data="$response"
                is_stale=false
                is_backoff=false

                # Compute adaptive TTL from max utilization
                max_util=$(echo "$response" | jq -r '[
                    (.five_hour.utilization // 0),
                    (.seven_day.utilization // 0)
                ] | map(. | tonumber) | max | floor')
                adaptive_ttl=$(compute_adaptive_ttl "$max_util")

                atomic_write "$cache_file" "$(jq -nc --argjson data "$response" \
                    --argjson ts "$now" \
                    --argjson ttl "$adaptive_ttl" \
                    '{fetched_at: $ts, adaptive_ttl: $ttl, backoff_until: 0, data: $data}')"
            else
                # Other HTTP error (5xx, network failure) — short backoff (5 min)
                backoff_until=$(( now + 300 ))
                is_stale=true
                if [ -n "$usage_data" ]; then
                    atomic_write "$cache_file" "$(jq -nc --argjson data "$usage_data" \
                        --argjson ts "$fetched_at" \
                        --argjson ttl "$adaptive_ttl" \
                        --argjson bo "$backoff_until" \
                        '{fetched_at: $ts, adaptive_ttl: $ttl, backoff_until: $bo, data: $data}')"
                fi
            fi
        fi
    fi
    # Fall back to stale cache if fetch failed
    if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
        usage_data=$(jq -c '.data // empty' < "$cache_file" 2>/dev/null)
        is_stale=true
    fi
fi

sep=" ${dim}|${reset} "

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    # Single jq call to extract all usage fields
    IFS='|' read -r five_hour_pct five_hour_reset_iso seven_day_pct seven_day_reset_iso < <(
        echo "$usage_data" | jq -r '[
            (.five_hour.utilization // 0 | tostring | split(".")[0]),
            (.five_hour.resets_at // ""),
            (.seven_day.utilization // 0 | tostring | split(".")[0]),
            (.seven_day.resets_at // "")
        ] | join("|")'
    )

    # Build refresh indicator
    refresh_indicator=""
    if [ "$fetched_at" -gt 0 ] 2>/dev/null; then
        last_refresh=$(date -d "@$fetched_at" +"%H:%M" 2>/dev/null)
        next_refresh=$(date -d "@$(( fetched_at + adaptive_ttl ))" +"%H:%M" 2>/dev/null)
        if $is_backoff; then
            # Rate-limited backoff — distinct indicator
            backoff_time=$(date -d "@$backoff_until" +"%H:%M" 2>/dev/null)
            refresh_indicator="${sep}${red}⏸ ${last_refresh} → ${backoff_time}${reset}"
        elif $is_stale; then
            refresh_indicator="${sep}${dim}↻ ${last_refresh} →${reset} ${yellow}${next_refresh}${reset}"
        else
            refresh_indicator="${sep}${dim}↻ ${last_refresh} → ${next_refresh}${reset}"
        fi
    fi

    # Auth expired indicator
    if [ "${auth_expired:-false}" = "true" ]; then
        refresh_indicator="${sep}${red}🔑 auth?${reset}"
    fi

    # ---- 5-hour (current) ----
    five_hour_pie=$(build_pie "$five_hour_pct")
    five_hour_reset=$(format_countdown "$five_hour_reset_iso")

    line1+="${sep}${five_hour_pie} ${cyan}${five_hour_pct}%${reset}"
    [ -n "$five_hour_reset" ] && line1+=" ${dim}(${five_hour_reset})${reset}"

    # ---- 7-day (weekly) ----
    seven_day_pie=$(build_pie "$seven_day_pct")
    seven_day_reset=$(format_datetime "$seven_day_reset_iso")

    line1+="${sep}${seven_day_pie} ${cyan}${seven_day_pct}%${reset}"
    [ -n "$seven_day_reset" ] && line1+=" ${dim}(${seven_day_reset})${reset}"

else
    # No usage data — show placeholder pies and refresh indicator if we have timing info
    line1+="${sep}${dim}○${reset} ${dim}--%${reset}"
    line1+="${sep}${dim}○${reset} ${dim}--%${reset}"

    # Auth expired indicator
    if [ "${auth_expired:-false}" = "true" ]; then
        line1+="${sep}${red}🔑 auth?${reset}"
    elif [ "$fetched_at" -gt 0 ] 2>/dev/null; then
        last_refresh=$(date -d "@$fetched_at" +"%H:%M" 2>/dev/null)
        if $is_backoff && [ "$backoff_until" -gt "$now" ] 2>/dev/null; then
            next_refresh=$(date -d "@$backoff_until" +"%H:%M" 2>/dev/null)
            line1+="${sep}${red}⏸ ${last_refresh} → ${next_refresh}${reset}"
        else
            next_refresh=$(date -d "@$(( fetched_at + adaptive_ttl ))" +"%H:%M" 2>/dev/null)
            line1+="${sep}${dim}↻ ${last_refresh} →${reset} ${yellow}${next_refresh}${reset}"
        fi
    fi
fi

# Append refresh indicator at the very end of line 1
if [ -n "${refresh_indicator:-}" ]; then
    line1+="${refresh_indicator}"
fi

# Line 2: branch + working directory path
line2=""
if [ -n "$branch_name" ]; then
    line2+="${magenta}${branch_name}${reset}"
fi
if [ -n "$cwd" ]; then
    [ -n "$line2" ] && line2+=" ${dim}|${reset} "
    line2+="${dim}${cwd}${reset}"
fi

# Output
printf "%b" "$line1"
[ -n "$line2" ] && printf "\n%b" "$line2"
