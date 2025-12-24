#!/bin/bash
set -euo pipefail

BASE="/srv/announcements"
LOG_DIR="$BASE/logs/pi-temp"
LOG="$LOG_DIR/temps.csv"

mkdir -p "$LOG_DIR"

# Write CSV header once
if [ ! -s "$LOG" ]; then
  printf "timestamp,c,f\n" > "$LOG"
fi

ts=$(date -Is)
raw=$(</sys/class/thermal/thermal_zone0/temp)
c=$(awk -v t="$raw" 'BEGIN{printf "%.1f", t/1000}')
f=$(awk -v c="$c" 'BEGIN{printf "%.1f", (c*9/5)+32}')
printf "%s,%s,%s\n" "$ts" "$c" "$f" >> "$LOG"
