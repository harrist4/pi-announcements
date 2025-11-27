#!/usr/bin/env bash
#
# watch_inbox.sh
#
# Purpose:
#   - Monitor the inbox directory for changes.
#   - Wait until files are "quiet" for QUIET_SECONDS.
#   - Run convert_all.sh once per quiet period.
#
# Configuration:
#   - Reads /srv/announcements/config/announcements.conf
#     - inbox_dir
#     - quiet_seconds
#     - watch_poll_interval

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"
BASE="/srv/announcements"
INBOX="$BASE/inbox"
SCRIPT="$BASE/convert_all.sh"

# Defaults
QUIET_SECONDS=60
POLL_INTERVAL=10

get_conf_value() {
  local key="$1"
  [ -f "$CONFIG" ] || return 1
  local line val
  line=$(grep -i "^${key}[[:space:]]*=" "$CONFIG" | tail -n1 || true)
  [ -n "$line" ] || return 1
  val="${line#*=}"
  # strip inline comments
  val="${val%%#*}"
  # trim whitespace
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s\n' "$val"
}

# Override INBOX from config if present
if val=$(get_conf_value "inbox_dir" 2>/dev/null); then
  [ -n "$val" ] && INBOX="$val"
fi

# Override QUIET_SECONDS if configured
if val=$(get_conf_value "quiet_seconds" 2>/dev/null); then
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    QUIET_SECONDS="$val"
  fi
fi

# Override POLL_INTERVAL if configured
if val=$(get_conf_value "watch_poll_interval" 2>/dev/null); then
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    POLL_INTERVAL="$val"
  fi
fi

# --- Crash recovery on startup ---
if [ -f "$INBOX/_PROCESSING.txt" ]; then
  ts=$(date +%Y%m%d-%H%M%S)
  echo "Stale _PROCESSING.txt found at startup, assuming interrupted run."
  mv "$INBOX/_PROCESSING.txt" "$INBOX/_FAILED_$ts.txt" 2>/dev/null || rm -f "$INBOX/_PROCESSING.txt"
fi

if [ -d "$BASE/tmp" ]; then
  rm -rf "$BASE/tmp/inbox_snapshot" 2>/dev/null || true
  rm -rf "$BASE/tmp/staging."* 2>/dev/null || true
fi
# --- End crash recovery ---

echo "Watching $INBOX (quiet=${QUIET_SECONDS}s, poll=${POLL_INTERVAL}s)..."

last_change=0
prev_hash=""

while true; do
  now=$(date +%s)

  # Detect any file changes in INBOX (excluding our marker files)
  current_hash=$(find "$INBOX" -mindepth 1 -maxdepth 1 \
  ! -name "*.txt" \
  -printf '%P %T@\n' 2>/dev/null | sort | sha1sum || echo "none")

  if [ "$current_hash" != "$prev_hash" ]; then
    prev_hash="$current_hash"
    last_change="$now"
  fi

  # Skip if currently processing
  if [ -f "$INBOX/_PROCESSING.txt" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Nothing to do if inbox is empty
  if ! find "$INBOX" -mindepth 1 -maxdepth 1 \
       ! -name "*.txt" | grep -q .; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Not quiet long enough yet
  if (( now - last_change < QUIET_SECONDS )); then
    sleep "$POLL_INTERVAL"
    continue
  fi

  echo "Inbox quiet for ${QUIET_SECONDS}s, starting conversion..."

  rm -f "$INBOX/_READY.txt"
  echo "Processing started at $(date)" > "$INBOX/_PROCESSING.txt"
  "$SCRIPT" || echo "convert_all.sh failed (see logs)."
  rm -f "$INBOX/_PROCESSING.txt" 2>/dev/null || true

  sleep "$POLL_INTERVAL"
done

