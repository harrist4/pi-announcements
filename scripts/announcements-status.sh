#!/usr/bin/env bash
#
# announcements-status.sh
#
# Purpose:
#   Long-running status helper for the announcements inbox.
#   - While a conversion run is in progress (_PROCESSING.txt present),
#     writes a fresh _STATUS_<timestamp>.txt snapshot into the inbox.
#   - When no run is active, removes all _STATUS_*.txt files.
#
# Why timestamped files?
#   Samba clients can cache directory listings aggressively. Using a
#   timestamped name forces a visible "new file" on each update so
#   users always see current status when they refresh the share.
#
# Configuration (announcements.conf):
#   base_dir   = /srv/announcements
#   inbox_dir  = /srv/announcements/inbox
#   temp_dir   = /srv/announcements/tmp

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"

# Defaults
BASE="/srv/announcements"
INBOX="$BASE/inbox"
TMP="$BASE/tmp"

# base_dir first
if val=$(get_conf_value "base_dir" 2>/dev/null); then
  [ -n "$val" ] && BASE="$val"
fi

# Re-derive inbox/tmp from BASE, then allow explicit overrides
INBOX="$BASE/inbox"
TMP="$BASE/tmp"

if val=$(get_conf_value "inbox_dir" 2>/dev/null); then
  [ -n "$val" ] && INBOX="$val"
fi
if val=$(get_conf_value "temp_dir" 2>/dev/null); then
  [ -n "$val" ] && TMP="$val"
fi

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

mkdir -p "$INBOX"
mkdir -p "$TMP"

# Every 30 seconds:
#   - If no _PROCESSING.txt is present: remove any old _STATUS_*.txt.
#   - If a run is active: write a fresh timestamped status file,
#     pointing to the latest staging.* directory (if any).

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
