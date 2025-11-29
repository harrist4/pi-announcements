#!/usr/bin/env bash
#
# announcements-watcher.sh
#
# Purpose:
#   Long-running watcher for the announcements "inbox" directory.
#   - Detects when files in the inbox change (new/updated/removed).
#   - Waits until the inbox has been quiet for QUIET_SECONDS.
#   - Runs convert_all.sh once per quiet period to rebuild slides.
#
# Configuration:
#   Reads /srv/announcements/config/announcements.conf
#     inbox_dir            = /srv/announcements/inbox
#     quiet_seconds        = 60        # how long inbox must stay idle
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

last_change=0
prev_hash=""

while true; do
  sleep "$POLL_INTERVAL"
  now=$(date +%s)

  # Build a hash of the current inbox contents (excluding our .txt marker files).
  # We hash "filename + mtime" so any add/remove/modify will change the hash.
  # When the hash stops changing for QUIET_SECONDS, we treat the inbox as "stable".
  current_hash=$(find "$INBOX" -mindepth 1 -maxdepth 1 \
  ! -name "*.txt" \
  -printf '%P %T@\n' 2>/dev/null | sort | sha1sum || echo "none")

  if [ "$current_hash" != "$prev_hash" ]; then
    prev_hash="$current_hash"
    last_change="$now"
  fi

  # Skip if currently processing
  if [ -f "$INBOX/_PROCESSING.txt" ]; then
    continue
  fi

  # Nothing to do if inbox is empty
  if ! find "$INBOX" -mindepth 1 -maxdepth 1 \
       ! -name "*.txt" | grep -q .; then
    continue
  fi

  # Not quiet long enough yet
  if (( now - last_change < QUIET_SECONDS )); then
    continue
  fi

  echo "Inbox quiet for ${QUIET_SECONDS}s, starting conversion..."

  # Mark the start of a conversion run:
  #   - remove any old _READY.txt status
  #   - create _PROCESSING.txt so other tools know work is in progress
  rm -f "$INBOX/_READY.txt"
  echo "Processing started at $(date)" > "$INBOX/_PROCESSING.txt"

  # Run the converter. On success, write a human-readable status line
  # to _READY.txt and restart the slideshow so new slides are picked up.
  if "$SCRIPT"; then
    echo "Drop folder processed successfully at $(date)." > "$INBOX/_READY.txt"
    # Restart slideshow:
    #   This script runs as the non-root service user ($SERVICE_USER), but
    #   restarting announcements-slideshow.service requires root.
    #   The installer adds a sudoers entry allowing this exact command:
    #     $SERVICE_USER ALL=(root) NOPASSWD: systemctl restart announcements-slideshow.service
    #   Therefore we invoke systemctl through sudo here.
    sudo systemctl restart announcements-slideshow.service \
      || echo "Warning: failed to restart slideshow service."
  else
    echo "ERROR during processing at $(date)." > "$INBOX/_READY.txt"
    echo "convert_all.sh failed (see logs)." >&2
  fi

  rm -f "$INBOX/_PROCESSING.txt" 2>/dev/null || true
done
