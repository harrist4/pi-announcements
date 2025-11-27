#!/usr/bin/env bash
#
# start_slideshow.sh
#
# Purpose:
#   - Launch pqiv fullscreen slideshow.
#   - Uses main deck by default, or off-schedule deck if requested.
#
# Configuration (announcements.conf):
#   - live_dir
#   - off_schedule_dir
#   - off_schedule_slides
#   - slide_duration
#   - fade_duration
#   - slideshow_sort
#   - slideshow_hide_info

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"

MAIN_DIR="/srv/announcements/live"
OFF_DIR="/srv/announcements/off_schedule"
OFF_SLIDES=false

# Defaults
SLIDE_DURATION=10
FADE_DURATION=0.7
SORT_FLAG="-n"   # pqiv -n (natural sort)
HIDE_INFO="-i"   # pqiv -i (hide info box)

MODE_FILE="/tmp/announcements_slides_mode"  # "normal" | "off" | empty

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
if val=$(get_conf_value "off_schedule_dir" 2>/dev/null); then
  [ -n "$val" ] && OFF_DIR="$val"
fi

# Flags
if val=$(get_conf_value "off_schedule_slides" 2>/dev/null); then
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  case "$val" in
    true|yes|1)  OFF_SLIDES=true ;;
    false|no|0)  OFF_SLIDES=false ;;
  esac
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

# Decide which deck to show
DIR="$MAIN_DIR"
if $OFF_SLIDES && [ -f "$MODE_FILE" ]; then
  mode=$(cat "$MODE_FILE" 2>/dev/null || echo "")
  if [ "$mode" = "off" ]; then
    DIR="$OFF_DIR"
  fi
fi

ARGS=(/usr/bin/pqiv -f -s -d "$SLIDE_DURATION" -F -t)

[ -n "$SORT_FLAG" ] && ARGS+=("$SORT_FLAG")
[ -n "$HIDE_INFO" ] && ARGS+=("$HIDE_INFO")

ARGS+=(--fade-duration="$FADE_DURATION" "$DIR")

exec "${ARGS[@]}"

