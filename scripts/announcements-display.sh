#!/usr/bin/env bash
#
# announcements-display.sh
#
# Runs as a long-lived daemon (via systemd) that:
#   - Periodically reloads /srv/announcements/config/announcements.conf
#   - Decides whether the screen should be ON or OFF based on day/time
#   - Tells the slideshow which "mode" to use:
#       * normal  = show live announcements
#       * off     = show "off-hours" deck (e.g., black slide)
#       * none    = don't run slideshow at all
#
# This script does NOT know anything about PPT/PDF conversion. It only
# knows "on schedule vs off schedule" and how to nudge the display and
# slideshow accordingly.
#
# -------------------------------
# Config file (announcements.conf)
# -------------------------------
#
# Expected keys:
#
#   schedule_poll_interval = 60
#   hdmi_control           = true
#
#   mon = 08:00-12:00,14:00-17:00
#   tue = 08:00-12:00
#   wed = 08:00-12:00,14:00-17:00
#   thu = 08:00-12:00
#   fri = 08:00-12:00
#   sat = 09:00-13:00
#   sun = 09:00-13:00
#
# Notes:
#   - Times are 24-hour HH:MM.
#   - Each day can have one or more "start-end" ranges, comma separated.
#   - Ranges are inclusive of the start, exclusive of the end
#       e.g. 08:00-09:00 is active for 08:00 <= time < 09:00.
#   - Ranges cannot cross midnight. (If you need that, split into two.)
#
#   hdmi_control:
#     - true  = when off-schedule, we are allowed to turn HDMI/backlight OFF
#               (and we stop the slideshow: mode = "none").
#     - false = when off-schedule, leave HDMI ON (TV stays awake) and just
#               switch the slideshow to "off" mode (blank/off-hours deck).
#
# Runtime notes:
#   - This service is intended to run as root so it can:
#       * write to BACKLIGHT and HDMI_STATUS sysfs nodes
#       * restart announcements-slideshow.service directly via systemctl
#   - Non-root execution is not supported and will break display control.
#

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"

# Sysfs knobs for display control.
# On modern Raspberry Pi OS with KMS:
#   - BACKLIGHT may exist for certain panels/official displays.
#   - HDMI_STATUS is often read-only (we try to write, but it may no-op).
BACKLIGHT="/sys/class/backlight/10-0045/bl_power"
HDMI_STATUS="/sys/class/drm/card0-HDMI-A-1/status"

# Mode file read by the slideshow launcher script:
#   "normal" = live slides
#   "off"    = off-hours deck (e.g. black slide)
#   "none"   = do not run slideshow at all
MODE_FILE="/tmp/announcements_slides_mode"  # "normal" | "off" | "none"

# Default config values; can be overridden by announcements.conf
CHECK_INTERVAL=60
HDMI_CONTROL=true

# LAST_DISPLAY_STATE remembers the last display state we *requested*
# so we don’t keep rewriting sysfs nodes every poll. On restart the
# variable resets, which is the correct behavior.
LAST_DISPLAY_STATE=""

# --------------------
# Config helper logic
# --------------------

get_conf_value() {
  local key="$1"
  [ -f "$CONFIG" ] || return 1
  local line val

  # Grab the last matching line (allows overrides later in the file)
  line=$(grep -i "^${key}[[:space:]]*=" "$CONFIG" | tail -n1 || true)
  [ -n "$line" ] || return 1

  val="${line#*=}"
  val="${val%%#*}"  # strip inline comments
  # trim leading/trailing whitespace
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s\n' "$val"
}

reload_config() {
  # reset to defaults first
  CHECK_INTERVAL=60
  HDMI_CONTROL=true

  # schedule_poll_interval
  if val=$(get_conf_value "schedule_poll_interval" 2>/dev/null); then
    [[ "$val" =~ ^[0-9]+$ ]] && CHECK_INTERVAL="$val"
  fi

  # hdmi_control (true/false/yes/no/1/0)
  if val=$(get_conf_value "hdmi_control" 2>/dev/null); then
    val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
    case "$val" in
      true|yes|1)  HDMI_CONTROL=true ;;
      false|no|0)  HDMI_CONTROL=false ;;
    esac
  fi
}

# -----------------
# Time / schedule
# -----------------

day_key_for_today() {
  # date +%u: 1=Mon .. 7=Sun
  case "$(date +%u)" in
    1) echo mon ;;
    2) echo tue ;;
    3) echo wed ;;
    4) echo thu ;;
    5) echo fri ;;
    6) echo sat ;;
    7) echo sun ;;
  esac
}

time_to_minutes() {
  # Convert HH:MM -> minutes since midnight
  local t="$1"
  local h="${t%%:*}"
  local m="${t##*:}"
  # 10# avoids treating leading zeros as octal
  printf '%d\n' "$((10#$h * 60 + 10#$m))"
}

# Returns 0 ("true") if we are currently inside any active range for today.
# Returns 1 ("false") otherwise.
should_be_on() {
  local daykey
  daykey=$(day_key_for_today)

  [ -f "$CONFIG" ] || return 1

  local now_hm
  now_hm=$(time_to_minutes "$(date +%H:%M)")

  while IFS= read -r line; do
    # Strip comments and surrounding whitespace
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue

    local key value
    key="${line%%=*}"
    value="${line#*=}"

    # Trim whitespace around key and value
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    key=$(echo "$key" | tr '[:upper:]' '[:lower:]')

    # Only care about mon..sun lines; ignore everything else
    case "$key" in
      mon|tue|wed|thu|fri|sat|sun) ;;
      *) continue ;;
    esac

    [ "$key" = "$daykey" ] || continue
    [ -z "$value" ] && return 1

    # Remove all whitespace inside the ranges
    value="${value//[[:space:]]/}"

    IFS=',' read -r -a ranges <<<"$value"
    for r in "${ranges[@]}"; do
      [ -z "$r" ] && continue

      local start="${r%-*}"
      local end="${r#*-}"

      [ -z "$start" ] && continue
      [ -z "$end" ] && continue

      local start_m end_m
      start_m=$(time_to_minutes "$start" 2>/dev/null || echo "")
      end_m=$(time_to_minutes "$end" 2>/dev/null || echo "")
      if [ -z "$start_m" ] || [ -z "$end_m" ]; then
        continue
      fi

      # Active if now is within [start, end)
      if (( now_hm >= start_m && now_hm < end_m )); then
        return 0
      fi
    done
  done < "$CONFIG"

  return 1
}

# -----------------
# Display control
# -----------------

set_display() {
  local desired="$1"  # "on" or "off"

  # Avoid redundant writes if nothing changed since last tick
  if [ "$LAST_DISPLAY_STATE" = "$desired" ]; then
    return 0
  fi

  # Force the desired state
  if [ "$desired" = "on" ]; then
    # Turning ON is always allowed
    [ -w "$BACKLIGHT" ] && echo 0  > "$BACKLIGHT" 2>/dev/null || true
    [ -w "$HDMI_STATUS" ] && echo on > "$HDMI_STATUS" 2>/dev/null || true
  else
    # Turning OFF only allowed if hdmi_control=true
    if $HDMI_CONTROL; then
      [ -w "$BACKLIGHT" ] && echo 1   > "$BACKLIGHT" 2>/dev/null || true
      [ -w "$HDMI_STATUS" ] && echo off > "$HDMI_STATUS" 2>/dev/null || true
    fi
  fi

  LAST_DISPLAY_STATE="$desired"
}

# -----------------
# Slideshow control
# -----------------

set_slides_mode() {
  local desired="$1"  # "normal" | "off" | "none"
  local current=""

  if [ -f "$MODE_FILE" ]; then
    current=$(cat "$MODE_FILE" 2>/dev/null || echo "")
  fi

  if [ "$current" = "$desired" ]; then
    return 0
  fi

  echo "$desired" > "$MODE_FILE"

  # Slideshow service watches this mode file and adjusts behavior.
  # Restarting it here ensures it reacts immediately to mode changes.
  systemctl restart announcements-slideshow.service 2>/dev/null || true
}

# -----------------
# Main loop
# -----------------

reload_config

while true; do
  # Allow changes to announcements.conf to be picked up without reboot
  reload_config

  if should_be_on; then
    # On schedule:
    #   - show normal slides
    #   - make sure display is logically "on"
    set_slides_mode "normal"
    set_display "on"
  else
    if $HDMI_CONTROL; then
      # Off schedule + HDMI control enabled:
      #   - stop running slideshow entirely (none)
      #   - actually turn HDMI/backlight OFF
      set_slides_mode "none"
      set_display "off"
    else
      # Off schedule + HDMI control disabled:
      #   - keep HDMI ON (TV stays happy / no input lost)
      #   - switch slideshow to "off" mode (blank/off-hours deck)
      set_slides_mode "off"
      set_display "on"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done