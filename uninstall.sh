#!/bin/bash
#
# uninstall.sh
#
# Purpose:
#   Cleanly remove the announcements frame system installed by install.sh.
#
# Removes:
#   - systemd units + timer
#   - /srv/announcements (all contents)
#   - Samba share definitions (from /etc/samba/conf.d/announcements.conf)
#   - The dedicated service user (system + Samba), as configured in /etc/announcements-frame/env
#
# Usage:
#   sudo ./uninstall.sh [--force]
#
# Flags:
#   --force    Skip confirmation prompt and uninstall immediately

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./uninstall.sh" >&2
  exit 1
fi

BASE="/srv/announcements"
SERVICE_USER="annc"
# Default to 'annc'; this will be overridden if /etc/announcements-frame/env exists.
FORCE=0

# Parse flags: currently only --force
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift 1
      ;;
    *)
      # Unknown flag; ignore for now
      shift 1
      ;;
  esac
done

if [[ "$FORCE" -ne 1 ]]; then
  echo "This will:"
  echo "  - stop and remove announcements systemd services"
  echo "  - delete $BASE and all its contents"
  echo "  - remove Samba config: /etc/samba/conf.d/announcements.conf"
  echo "  - remove the service user (system + Samba) defined in /etc/announcements-frame/env"
  echo
  read -r -p "Type 'yes' to continue: " REPLY
  if [[ "$REPLY" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Load configured user
if [[ -f /etc/announcements-frame/env ]]; then
  source /etc/announcements-frame/env
else
  SERVICE_USER="annc"
fi

# --- Desktop auto-login restore/cleanup --------------------------------------

LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
OLD_AUTOCONF="/etc/lightdm/lightdm.conf.d/99-autologin.conf"

# Remove old conf.d autologin file if we ever created one
rm -f "$OLD_AUTOCONF" 2>/dev/null || true

if [[ -f "$LIGHTDM_CONF" ]]; then
  if [[ -n "${ORIGINAL_GUI_USER:-}" ]]; then
    echo "==> Restoring desktop autologin to '$ORIGINAL_GUI_USER'..."
    if grep -q '^autologin-user=' "$LIGHTDM_CONF"; then
      # Replace existing autologin-user line
      sed -i "s/^autologin-user=.*/autologin-user=$ORIGINAL_GUI_USER/" "$LIGHTDM_CONF"
    else
      # Insert under [Seat:*] if present, otherwise append at end
      if grep -q '^\[Seat:\*\]' "$LIGHTDM_CONF"; then
        awk '
          /^\[Seat:\*\]/ {
            print
            print "autologin-user='"$ORIGINAL_GUI_USER"'"
            next
          }
          { print }
        ' "$LIGHTDM_CONF" > "${LIGHTDM_CONF}.tmp" && mv "${LIGHTDM_CONF}.tmp" "$LIGHTDM_CONF"
      else
        printf "\n[Seat:*]\nautologin-user=%s\n" "$ORIGINAL_GUI_USER" >> "$LIGHTDM_CONF"
      fi
    fi
  else
    echo "==> No ORIGINAL_GUI_USER recorded; removing autologin for '$SERVICE_USER' (if present)..."
    sed -i "\|^autologin-user=$SERVICE_USER$|d" "$LIGHTDM_CONF"
  fi
fi

echo "==> Stopping services..."
systemctl stop announcements-watcher.service 2>/dev/null || true
systemctl stop announcements-slideshow.service 2>/dev/null || true
systemctl stop announcements-display.service 2>/dev/null || true
systemctl stop announcements-display.timer 2>/dev/null || true

echo "==> Disabling services..."
systemctl disable announcements-watcher.service 2>/dev/null || true
systemctl disable announcements-slideshow.service 2>/dev/null || true
systemctl disable announcements-display.service 2>/dev/null || true
systemctl disable announcements-display.timer 2>/dev/null || true

echo "==> Removing systemd unit files..."
rm -f /etc/systemd/system/announcements-watcher.service
rm -f /etc/systemd/system/announcements-slideshow.service
rm -f /etc/systemd/system/announcements-display.service
rm -f /etc/systemd/system/announcements-display.timer

systemctl daemon-reload

echo "==> Removing /srv/announcements..."
rm -rf "$BASE"

# --- Samba cleanup ------------------------------------------------------------

SMB_ANN_FILE="/etc/samba/conf.d/announcements.conf"
SMB_MAIN_CONF="/etc/samba/smb.conf"

if [[ -f "$SMB_ANN_FILE" ]]; then
  echo "==> Removing Samba announcements config..."
  rm -f "$SMB_ANN_FILE"

  # Remove the include line we added during install
  sed -i "\|include = $SMB_ANN_FILE|d" "$SMB_MAIN_CONF"

  systemctl restart smbd nmbd 2>/dev/null || systemctl restart smbd || true
fi

# --- User cleanup -------------------------------------------------------------

echo "==> Removing Samba user '$SERVICE_USER'..."
smbpasswd -x "$SERVICE_USER" 2>/dev/null || true

echo "==> Terminating running processes for '$SERVICE_USER'..."
pkill -u "$SERVICE_USER" 2>/dev/null || true

echo "==> Removing system user '$SERVICE_USER'..."
deluser --remove-home "$SERVICE_USER" 2>/dev/null || true

echo "==> Removing service config directory..."
rm -rf /etc/announcements-frame 2>/dev/null || true

echo
echo "Uninstall complete."
echo
echo "After reboot, the Pi will auto-login as '$ORIGINAL_GUI_USER' as was the original setup."
echo
echo "Reinstall with: sudo ./install.sh"

