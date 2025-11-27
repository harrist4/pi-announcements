#!/usr/bin/env bash
#
# schedule_display.sh
#
# Purpose:
#   - Periodically check announcements.conf schedule.
#   - Turn display ON/OFF (HDMI/backlight) and select slide deck.
#
# Config (announcements.conf):
#   - schedule_poll_interval
#   - mon..sun time ranges
#   - hdmi_control        (true/false)
#   - off_schedule_slides (true/false)

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"

BACKLIGHT="/sys/class/backlight/10-0045/bl_power"
HDMI_STATUS="/sys/class/drm/card0-HDMI-A-1/status"
DISPLAY_STATE_FILE="/tmp/announcements_display_state"
MODE_FILE="/tmp/announcements_slides_mode"  # "normal" | "off" | "none"

CHECK_INTERVAL=60
HDMI_CONTROL=true
OFF_SLIDES=false

reload_config() {
  # reset to defaults first
  CHECK_INTERVAL=60
  HDMI_CONTROL=true
  OFF_SLIDES=false

  # schedule_poll_interval
  if val=$(get_conf_value "schedule_poll_interval" 2>/dev/null); then
    [[ "$val" =~ ^[0-9]+$ ]] && CHECK_INTERVAL="$val"
  fi

  # hdmi_control
  if val=$(get_conf_value "hdmi_control" 2>/dev/null); then
    val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
    case "$val" in
      true|yes|1)  HDMI_CONTROL=true ;;
      false|no|0)  HDMI_CONTROL=false ;;
    esac
  fi

  # off_schedule_slides
  if val=$(get_conf_value "off_schedule_slides" 2>/dev/null); then
    val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
    case "$val" in
      true|yes|1)  OFF_SLIDES=true ;;
      false|no|0)  OFF_SLIDES=false ;;
    esac
  fi
}

# schedule_poll_interval
if val=$(get_conf_value "schedule_poll_interval" 2>/dev/null); then
  [[ "$val" =~ ^[0-9]+$ ]] && CHECK_INTERVAL="$val"
fi

# hdmi_control
if val=$(get_conf_value "hdmi_control" 2>/dev/null); then
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  case "$val" in
    true|yes|1)  HDMI_CONTROL=true ;;
    false|no|0)  HDMI_CONTROL=false ;;
  esac
fi

# off_schedule_slides
if val=$(get_conf_value "off_schedule_slides" 2>/dev/null); then
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  case "$val" in
    true|yes|1)  OFF_SLIDES=true ;;
    false|no|0)  OFF_SLIDES=false ;;
  esac
fi

day_key_for_today() {
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
  local t="$1"
  local h="${t%%:*}"
  local m="${t##*:}"
  printf '%d\n' "$((10#$h * 60 + 10#$m))"
}

should_be_on() {
  local daykey
  daykey=$(day_key_for_today)

  [ -f "$CONFIG" ] || return 1

  local now_hm
  now_hm=$(time_to_minutes "$(date +%H:%M)")

  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue

    local key value
    key="${line%%=*}"
    value="${line#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    key=$(echo "$key" | tr '[:upper:]' '[:lower:]')

    case "$key" in
      mon|tue|wed|thu|fri|sat|sun) ;;
      *) continue ;;
    esac

    [ "$key" = "$daykey" ] || continue
    [ -z "$value" ] && return 1

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
      [ -z "$start_m" ] || [ -z "$end_m" ] && continue

      if (( now_hm >= start_m && now_hm < end_m )); then
        return 0
      fi
    done
  done < "$CONFIG"

  return 1
}

set_display() {
  local desired="$1"  # "on" or "off"
  local current=""

  if [ -f "$DISPLAY_STATE_FILE" ]; then
    current=$(cat "$DISPLAY_STATE_FILE" 2>/dev/null || echo "")
  fi

  # Avoid redundant writes
  if [ "$current" = "$desired" ]; then
    return 0
  fi

  if $HDMI_CONTROL; then
    if [ "$desired" = "on" ]; then
      [ -w "$BACKLIGHT" ] && echo 0 > "$BACKLIGHT" 2>/dev/null || true
      [ -w "$HDMI_STATUS" ] && echo on  > "$HDMI_STATUS" 2>/dev/null || true
    else
      [ -w "$BACKLIGHT" ] && echo 1 > "$BACKLIGHT" 2>/dev/null || true
      [ -w "$HDMI_STATUS" ] && echo off > "$HDMI_STATUS" 2>/dev/null || true
    fi
  fi

  echo "$desired" > "$DISPLAY_STATE_FILE"
}

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

  # Only matters if off-schedule slides are enabled
  if $OFF_SLIDES; then
    systemctl restart announcements-slideshow.service 2>/dev/null || true
  fi
}

reload_config

while true; do
  reload_config

  if should_be_on; then
    set_slides_mode "normal"
    set_display "on"
  else
    if $OFF_SLIDES; then
      set_slides_mode "off"
    else
      set_slides_mode "none"
    fi
    set_display "off"
  fi

  sleep "$CHECK_INTERVAL"
done

