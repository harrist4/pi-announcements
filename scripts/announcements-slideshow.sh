#!/usr/bin/env bash
#
# announcements-slideshow.sh
#
# Purpose:
#   Launch a fullscreen pqiv slideshow on one of two decks:
#     - "normal" mode => MAIN_DIR (live announcements)
#     - "off"    mode => OFF_DIR  (off-hours / black slides)
#     - "none"        => do not run a slideshow at all (exit)
#
# Mode control:
#   - Reads /tmp/announcements_slides_mode (written by announcements-display.sh)
#     and chooses which directory to show based on that value.
#
# Configuration (announcements.conf):
#   live_dir            = /srv/announcements/live
#   off_dir             = /srv/announcements/off
#   slide_duration      = 10        # seconds per slide
#   fade_duration       = 0         # seconds (float, passed to pqiv)
#   slideshow_sort      = natural | none
#   slideshow_hide_info = true | false | yes | no | 1 | 0
#
# Notes:
#   - This script does NOT manage schedule or HDMI; it only decides which
#     directory to display and how pqiv should behave.

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"

MAIN_DIR="/srv/announcements/live"
OFF_DIR="/srv/announcements/off"

# Defaults
SLIDE_DURATION=10
FADE_DURATION=0
SORT_FLAG="-n"   # pqiv -n (natural sort)
HIDE_INFO="-i"   # pqiv -i (hide info box)

MODE_FILE="/tmp/announcements_slides_mode"  # "normal" | "off" | "none"

get_conf_value() {
  local key="$1"
  [ -f "$CONFIG" ] || return 1
  local line val
  line=$(grep -i "^${key}[[:space:]]*=" "$CONFIG" | tail -n1 || true)
  [ -n "$line" ] || return 1
  val="${line#*=}"
  val="${val%%#*}"  # strip inline comments
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s\n' "$val"
}

# Paths
if val=$(get_conf_value "live_dir" 2>/dev/null); then
  [ -n "$val" ] && MAIN_DIR="$val"
fi
if val=$(get_conf_value "off_dir" 2>/dev/null); then
  [ -n "$val" ] && OFF_DIR="$val"
fi

# slide_duration (integer seconds)
if val=$(get_conf_value "slide_duration" 2>/dev/null); then
  [[ "$val" =~ ^[0-9]+$ ]] && SLIDE_DURATION="$val"
fi

# fade_duration (float)
if val=$(get_conf_value "fade_duration" 2>/dev/null); then
  [ -n "$val" ] && FADE_DURATION="$val"
fi

# slideshow_sort (natural | none)
if val=$(get_conf_value "slideshow_sort" 2>/dev/null); then
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  case "$val" in
    natural) SORT_FLAG="-n" ;;
    none)    SORT_FLAG=""   ;;
  esac
fi

# slideshow_hide_info (true/false/yes/no/1/0)
if val=$(get_conf_value "slideshow_hide_info" 2>/dev/null); then
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  case "$val" in
    true|yes|1)  HIDE_INFO="-i" ;;
    false|no|0)  HIDE_INFO=""   ;;
  esac
fi

# Decide which deck to show based solely on MODE_FILE (set by scheduler)
mode="normal"

if [ -f "$MODE_FILE" ]; then
  mode=$(cat "$MODE_FILE" 2>/dev/null || echo "normal")
fi

case "$mode" in
  off)
    DIR="$OFF_DIR"
    ;;
  none)
    # No slideshow at all
    exit 0
    ;;
  *)
    # normal or anything unknown -> main deck
    DIR="$MAIN_DIR"
    ;;
esac

ARGS=(/usr/bin/pqiv -f -s -d "$SLIDE_DURATION" -F -t)

[ -n "$SORT_FLAG" ] && ARGS+=("$SORT_FLAG")
[ -n "$HIDE_INFO" ] && ARGS+=("$HIDE_INFO")

ARGS+=(--fade-duration="$FADE_DURATION" "$DIR")

exec "${ARGS[@]}"
