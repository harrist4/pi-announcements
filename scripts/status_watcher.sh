#!/usr/bin/env bash
#
# status_watcher.sh
#
# Purpose:
#   - While a conversion run is in progress, write a status snapshot
#     to _STATUS.txt in the inbox.
#   - When no run is active, remove _STATUS.txt.
#
# Behavior:
#   - If _PROCESSING.txt exists: show latest staging dir (if any).
#   - If no run is in progress: delete _STATUS.txt.

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"

# ---- Defaults (same pattern as convert_all.sh) ----
BASE="/srv/announcements"
INBOX="$BASE/inbox"
TMP="$BASE/tmp"

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

# ---- Override defaults from config (if present) ----

if val=$(get_conf_value "base_dir" 2>/dev/null); then
  [ -n "$val" ] && BASE="$val"
fi
if val=$(get_conf_value "inbox_dir" 2>/dev/null); then
  [ -n "$val" ] && INBOX="$val"
fi
if val=$(get_conf_value "temp_dir" 2>/dev/null); then
  [ -n "$val" ] && TMP="$val"
fi

OUTFILE="$INBOX/_STATUS.txt"

mkdir -p "$INBOX"
mkdir -p "$TMP"

while true; do
  if [ ! -f "$INBOX/_PROCESSING.txt" ]; then
    # No run in progress: remove all status files and do nothing else
    rm -f "$INBOX"/_STATUS*.txt 2>/dev/null || true
  else
    # Run in progress: delete old status files and write a fresh, timestamped one
    ts="$(date +%Y%m%d-%H%M%S)"
    outfile="$INBOX/_STATUS_$ts.txt"

    rm -f "$INBOX"/_STATUS*.txt 2>/dev/null || true

    {
      echo "Status updated: $(date)"
      echo
      echo "Conversion in progress."
      echo

      latest=$(ls -1td "$TMP"/staging.* 2>/dev/null | head -n 1 || true)
      if [ -n "$latest" ] && [ -d "$latest" ]; then
        echo "Latest staging directory:"
        echo "  $latest"
        echo
        ls -al "$latest"
      else
        echo "No staging directories found under:"
        echo "  $TMP"
      fi
    } > "$outfile"
  fi

  sleep 30
done
