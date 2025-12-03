#!/usr/bin/env bash
#
# announcements-watcher.sh
#
# Purpose:
#   Long-running watcher for announcements directories.
#   - Watches the "live" directory for changes and restarts the slideshow
#     after QUIET_SECONDS of inactivity.
#   - Watches the "inbox" directory for changes and, after QUIET_SECONDS
#     of inactivity, runs convert_all.sh to rebuild slides.
#
# Configuration:
#   Reads /srv/announcements/config/announcements.conf
#     inbox_dir            = /srv/announcements/inbox
#     live_dir             = /srv/announcements/live
#     quiet_seconds        = 60        # how long a dir must stay idle
#     watch_poll_interval  = 10        # how often to rescan for changes
#
# Marker files in the inbox:
#   _PROCESSING.txt   = conversion in progress
#   _READY.txt        = last completed run status/result
#
# This script does not do any conversion itself; it only decides
# *when* to call convert_all.sh based on inbox activity.

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"
BASE="/srv/announcements"
INBOX="$BASE/inbox"
SCRIPT="$BASE/convert_all.sh"
LIVE="$BASE/live"

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

# Override LIVE from config if present
if val=$(get_conf_value "live_dir" 2>/dev/null); then
  [ -n "$val" ] && LIVE="$val"
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

# If the Pi was rebooted or the service crashed mid-run, we may find
# a stale _PROCESSING.txt and temporary scratch directories. On
# startup we:
#   - rename _PROCESSING.txt to _FAILED_<timestamp>.txt (if possible)
#   - clean up any previous tmp/inbox_snapshot and tmp/staging.* dirs
# This keeps the next run from being blocked by old state.

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
echo "Also watching $LIVE for direct slide updates..."

last_change=0
prev_hash=""

live_prev_hash=""
live_last_change=0
live_pending_restart=0

while true; do
  sleep "$POLL_INTERVAL"
  now=$(date +%s)

  # $LIVE content change detection
  if [ -d "$LIVE" ]; then
    # Build a hash of the current live contents.
    live_hash=$(find "$LIVE" -mindepth 1 -maxdepth 1 \
      -type f \
      -printf '%P %T@\n' 2>/dev/null | sort | sha1sum || echo "none")

    # First-time initialization: just seed the hash, no pending action
    if [ -z "$live_prev_hash" ]; then
      live_prev_hash="$live_hash"

    # Subsequent changes: detect real modifications
    elif [ "$live_hash" != "$live_prev_hash" ]; then
      echo "Live dir content has changed; waiting for it to settle..."
      live_prev_hash="$live_hash"
      live_last_change="$now"
      live_pending_restart=1
    fi

    # If we *know* something changed and it's been quiet long enough, restart pqiv
    if (( live_pending_restart == 1 && now - live_last_change >= QUIET_SECONDS )); then
      if find "$LIVE" -mindepth 1 -maxdepth 1 -type f | grep -q .; then
        echo "Live dir quiet for ${QUIET_SECONDS}s; restarting slideshow..."
        # Restart slideshow:
        #   This script runs as the non-root service user ($SERVICE_USER), but
        #   restarting announcements-slideshow.service requires root.
        #   Therefore we invoke systemctl through sudo here.
        sudo systemctl restart announcements-slideshow.service \
          || echo "Warning: failed to restart slideshow service."
      fi
      live_pending_restart=0
      continue
    fi
  fi

  # Build a hash of the current inbox contents (excluding our .txt marker files).
  # We hash "filename + mtime" so any add/remove/modify will change the hash.
  # When the hash stops changing for QUIET_SECONDS, we treat the inbox as "stable".
  current_hash=$(find "$INBOX" -mindepth 1 -maxdepth 1 \
    ! -name "*.txt" \
    -printf '%P %T@\n' 2>/dev/null | sort | sha1sum || echo "none")

  if [ "$current_hash" != "$prev_hash" ]; then
    echo "Inbox dir content has changed; waiting for it to settle..."
    prev_hash="$current_hash"
    last_change="$now"
  fi

  # Skip if currently processing
  if [ -f "$INBOX/_PROCESSING.txt" ]; then
    continue
  fi

  # Nothing to do if inbox is empty
  if ! find "$INBOX" -mindepth 1 -maxdepth 1 \
      ! -name "*.txt" 2>/dev/null | grep -q .; then
    continue
  fi

  # Not quiet long enough yet
  if (( now - last_change < QUIET_SECONDS )); then
    continue
  fi

  echo "Inbox quiet for ${QUIET_SECONDS}s; starting conversion..."

  # Mark the start of a conversion run:
  #   - remove any old _READY.txt status
  #   - create _PROCESSING.txt so other tools know work is in progress
  rm -f "$INBOX/_READY.txt"
  echo "Processing started at $(date)" > "$INBOX/_PROCESSING.txt"

  # Run the converter. On success, write a human-readable status line
  # to _READY.txt. The live watcher will restart the slideshow if output changes.
  if "$SCRIPT"; then
    echo "Drop folder processed successfully at $(date)." > "$INBOX/_READY.txt"
  else
    echo "ERROR during processing at $(date)." > "$INBOX/_READY.txt"
    echo "convert_all.sh failed (see logs)." >&2
  fi

  rm -f "$INBOX/_PROCESSING.txt" 2>/dev/null || true
done
