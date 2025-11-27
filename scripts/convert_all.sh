#!/usr/bin/env bash
#
# convert_all.sh
#
# Purpose:
#   - Take a snapshot of the inbox
#   - Convert PPTX → PDF → PNG slides
#   - Groom standalone images into 1920x1080 PNG slides
#   - Atomically update the live output directory
#   - Clean the inbox and signal readiness
#
# Triggered by:
#   - watch_inbox.sh (typically via systemd)
#
# Configuration:
#   - Reads /srv/announcements/config/announcements.conf (key = value, '#' comments)

set -euo pipefail

CONFIG="/srv/announcements/config/announcements.conf"

# ---- Defaults ----
BASE="/srv/announcements"
INBOX="$BASE/inbox"
OUT="$BASE/live"
LOGDIR="$BASE/logs"
TMP="$BASE/tmp"

OUTPUT_WIDTH=1920
OUTPUT_HEIGHT=1080
BACKGROUND_COLOR="black"
CENTER_IMAGES=true
KEEP_PDFS=true

PPT_EXTENSIONS="pptx"
IMAGE_EXTENSIONS="jpg jpeg png"
MAX_SLIDES=0   # 0 = unlimited

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
if val=$(get_conf_value "live_dir" 2>/dev/null); then
  [ -n "$val" ] && OUT="$val"
fi
if val=$(get_conf_value "log_dir" 2>/dev/null); then
  [ -n "$val" ] && LOGDIR="$val"
fi
if val=$(get_conf_value "temp_dir" 2>/dev/null); then
  [ -n "$val" ] && TMP="$val"
fi

if val=$(get_conf_value "output_width" 2>/dev/null); then
  [[ "$val" =~ ^[0-9]+$ ]] && OUTPUT_WIDTH="$val"
fi
if val=$(get_conf_value "output_height" 2>/dev/null); then
  [[ "$val" =~ ^[0-9]+$ ]] && OUTPUT_HEIGHT="$val"
fi
if val=$(get_conf_value "background_color" 2>/dev/null); then
  [ -n "$val" ] && BACKGROUND_COLOR="$val"
fi

if val=$(get_conf_value "center_images" 2>/dev/null); then
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  case "$val" in
    true|yes|1)  CENTER_IMAGES=true ;;
    false|no|0)  CENTER_IMAGES=false ;;
  esac
fi

if val=$(get_conf_value "keep_pdfs" 2>/dev/null); then
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  case "$val" in
    true|yes|1)  KEEP_PDFS=true ;;
    false|no|0)  KEEP_PDFS=false ;;
  esac
fi

if val=$(get_conf_value "ppt_extensions" 2>/dev/null); then
  [ -n "$val" ] && PPT_EXTENSIONS="$val"
fi
if val=$(get_conf_value "image_extensions" 2>/dev/null); then
  [ -n "$val" ] && IMAGE_EXTENSIONS="$val"
fi
if val=$(get_conf_value "max_slides" 2>/dev/null); then
  [[ "$val" =~ ^[0-9]+$ ]] && MAX_SLIDES="$val"
fi

mkdir -p "$INBOX" "$OUT" "$LOGDIR" "$TMP"

LOGFILE="$LOGDIR/convert_$(date +%Y%m%d-%H%M%S).log"

sanitize_name() {
  local s="$1"
  s=$(echo "$s" | tr '[:upper:]' '[:lower:]')
  s=$(echo "$s" | sed 's/[^a-z0-9]/_/g')
  s=$(echo "$s" | sed 's/_\+/_/g; s/^_//; s/_$//')
  printf '%s\n' "$s"
}

groom_image() {
  local src="$1"
  local dst="$2"

  if $CENTER_IMAGES; then
    convert "$src" \
      -resize "${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}>" \
      -background "$BACKGROUND_COLOR" \
      -gravity center \
      -extent "${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}" \
      "$dst"
  else
    convert "$src" \
      -resize "${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}>" \
      "$dst"
  fi
}

{
  echo "============================================"
  echo "Announcements conversion run: $(date)"
  echo "BASE:      $BASE"
  echo "INBOX:     $INBOX"
  echo "OUT:       $OUT"
  echo "LOGDIR:    $LOGDIR"
  echo "TMP:       $TMP"
  echo "Resolution: ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}, background=$BACKGROUND_COLOR, center_images=$CENTER_IMAGES"
  echo "PPT_EXT:   $PPT_EXTENSIONS"
  echo "IMG_EXT:   $IMAGE_EXTENSIONS"
  echo "MAX_SLIDES: $MAX_SLIDES"
  echo

  SNAP="$TMP/inbox_snapshot"
  rm -rf "$SNAP"
  mkdir -p "$SNAP"

  echo "Creating snapshot of inbox..."
  # Copy everything except our marker files
  find "$INBOX" -mindepth 1 -maxdepth 1 ! -name "_READY.txt" ! -name "_PROCESSING.txt" -print0 \
    | xargs -0 -r cp -t "$SNAP"
  echo "Snapshot created."
  echo

  # Gather files from snapshot
  mapfile -t ALL_FILES < <(find "$SNAP" -type f -maxdepth 1 | sort || true)

  if [ "${#ALL_FILES[@]}" -eq 0 ]; then
    echo "No files in snapshot. Nothing to do."
    echo "Writing _READY.txt..."
    echo "Drop folder is now empty." > "$INBOX/_READY.txt"
    echo
    exit 0
  fi

  # Classify files by extension
  declare -a PPTX_FILES=()
  declare -a IMAGE_FILES=()

  IFS=' ,' read -r -a ppt_exts <<<"$PPT_EXTENSIONS"
  IFS=' ,' read -r -a img_exts <<<"$IMAGE_EXTENSIONS"

  is_in_list() {
    local needle="$1"; shift
    local e
    for e in "$@"; do
      [ "$needle" = "$e" ] && return 0
    done
    return 1
  }

  for f in "${ALL_FILES[@]}"; do
    base="$(basename "$f")"
    ext="${base##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    if is_in_list "$ext" "${ppt_exts[@]}"; then
      PPTX_FILES+=("$f")
    elif is_in_list "$ext" "${img_exts[@]}"; then
      IMAGE_FILES+=("$f")
    else
      echo "Skipping unsupported file type: $base"
    fi
  done

  STAGING="$(mktemp -d "$TMP/staging.XXXXXX")"
  echo "Using staging dir: $STAGING"
  echo

  # --- PPTX -> PDF ---
  if [ "${#PPTX_FILES[@]}" -gt 0 ]; then
    echo "Converting PPTX -> PDF..."
    for f in "${PPTX_FILES[@]}"; do
      src_base="$(basename "$f")"
      src_noext="${src_base%.*}"
      safe_base="$(sanitize_name "$src_noext")"

      orig_safe="$safe_base"
      suffix=1
      while [ -e "$STAGING/${safe_base}.pdf" ] || [ -e "$STAGING/${safe_base}.pptx" ]; do
        printf -v safe_base "%s_%02d" "$orig_safe" "$suffix"
        suffix=$((suffix+1))
      done

      echo "  -> $src_base (as ${safe_base}.pdf)"
      cp "$f" "$STAGING/${safe_base}.pptx"
      soffice --headless --convert-to pdf "$STAGING/${safe_base}.pptx" --outdir "$STAGING"
      rm -f "$STAGING/${safe_base}.pptx"
    done
    echo "PPTX -> PDF done."
    echo
  else
    echo "No PPTX files found in snapshot."
    echo
  fi

  # --- PDFs -> slide PNGs ---
  declare -i slide_count=0

  shopt -s nullglob
  pdfs=("$STAGING"/*.pdf)
  shopt -u nullglob

  if [ "${#pdfs[@]}" -gt 0 ]; then
    echo "Converting PDFs -> slide PNGs..."
    for pdf in "${pdfs[@]}"; do
      pdf_base="$(basename "$pdf")"
      pdf_noext="${pdf_base%.*}"
      safe_pdf="$(sanitize_name "$pdf_noext")"

      tmp_pattern="$STAGING/${safe_pdf}_page_%02d.png"
      convert -density 150 "$pdf" "$tmp_pattern"

      mapfile -t pages < <(find "$STAGING" -maxdepth 1 -type f -name "${safe_pdf}_page_*.png" | sort || true)
      idx=1
      for p in "${pages[@]}"; do
        if (( MAX_SLIDES > 0 && slide_count >= MAX_SLIDES )); then
          echo "MAX_SLIDES ($MAX_SLIDES) reached, skipping remaining pages."
          rm -f "$p"
          continue
        fi
        printf -v slide_name "%s-slide-%02d.png" "$safe_pdf" "$idx"
        groom_image "$p" "$STAGING/$slide_name"
        rm -f "$p"
        idx=$((idx+1))
        slide_count=$((slide_count+1))
      done

      if $KEEP_PDFS; then
        mv "$pdf" "$LOGDIR/" 2>/dev/null || true
      else
        rm -f "$pdf"
      fi
    done
    echo "PDF -> slide PNGs done."
    echo
  else
    echo "No PDFs in staging (from PPTX)."
    echo
  fi

  # --- Standalone images -> PNG slides ---
  if [ "${#IMAGE_FILES[@]}" -gt 0 ]; then
    echo "Processing standalone images..."
    for f in "${IMAGE_FILES[@]}"; do
      if (( MAX_SLIDES > 0 && slide_count >= MAX_SLIDES )); then
        echo "MAX_SLIDES ($MAX_SLIDES) reached, skipping remaining images."
        break
      fi

      src_base="$(basename "$f")"
      src_noext="${src_base%.*}"
      safe_base="$(sanitize_name "$src_noext")"

      orig_safe="$safe_base"
      suffix=1
      while [ -e "$STAGING/${safe_base}.png" ]; do
        printf -v safe_base "%s_%02d" "$orig_safe" "$suffix"
        suffix=$((suffix+1))
      done

      echo "  -> $src_base (as ${safe_base}.png)"
      groom_image "$f" "$STAGING/${safe_base}.png"
      slide_count=$((slide_count+1))
    done
    echo "Standalone images processed."
    echo
  else
    echo "No standalone images found in snapshot."
    echo
  fi

  echo "Total slides prepared: $slide_count"
  echo

  echo "Staging build complete. Updating live output in-place..."
  mkdir -p "$OUT"

  rm -f "$OUT"/*.png 2>/dev/null || true

  shopt -s nullglob
  for img in "$STAGING"/*.png; do
    [ -e "$img" ] || continue
    mv "$img" "$OUT"/
  done
  shopt -u nullglob

  rm -f "$STAGING"/* 2>/dev/null || true
  rmdir "$STAGING" 2>/dev/null || true

  echo "Live output updated."
  echo

  echo "Cleaning inbox originals..."
  find "$INBOX" -mindepth 1 -maxdepth 1 \
    ! -name "*.txt" -print0 \
    | xargs -0 -r rm -f
  echo "Inbox cleaned."

  # Restore README.txt from template if available
  if [ -f "$BASE/config/inbox_readme.txt" ]; then
    cp "$BASE/config/inbox_readme.txt" "$INBOX/README.txt"
  fi

  echo "Writing _READY.txt..."
  echo "Drop folder is now empty." > "$INBOX/_READY.txt"
  echo "_READY.txt written."
  echo

  echo "Restarting slideshow service to pick up new deck..."
  systemctl restart announcements-slideshow.service || echo "Warning: failed to restart slideshow service."
  echo "Slideshow restart requested."
  echo

  rm -rf "$SNAP" 2>/dev/null || true

  echo "Conversion run complete."
  echo

} | tee -a "$LOGFILE"

