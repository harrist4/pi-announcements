#!/bin/bash
#
# uninstall.sh
#
# Purpose:
#   Cleanly remove the announcements frame system installed by install.sh.
#
# Removes:
#   - systemd units
#   - /srv/announcements (all contents)
#   - /etc/announcements-frame (env + config)
#   - Restores /etc/samba/smb.conf from backup if available
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
  echo "  - remove /etc/announcements-frame"
  echo "  - restore /etc/samba/smb.conf from backup, if available"
  echo
  read -r -p "Type 'yes' to continue: " REPLY
  if [[ "$REPLY" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "==> Stopping services..."
systemctl stop announcements-watcher.service 2>/dev/null || true
systemctl stop announcements-slideshow.service 2>/dev/null || true
systemctl stop announcements-display.service 2>/dev/null || true
systemctl stop announcements-status.service 2>/dev/null || true

echo "==> Disabling services..."
systemctl disable announcements-watcher.service 2>/dev/null || true
systemctl disable announcements-slideshow.service 2>/dev/null || true
systemctl disable announcements-display.service 2>/dev/null || true
systemctl disable announcements-status.service 2>/dev/null || true

echo "==> Removing systemd unit files..."
rm -f /etc/systemd/system/announcements-watcher.service
rm -f /etc/systemd/system/announcements-slideshow.service
rm -f /etc/systemd/system/announcements-display.service
rm -f /etc/systemd/system/announcements-status.service

systemctl daemon-reload

echo "==> Removing $BASE..."
rm -rf "$BASE"

# --- Samba cleanup ------------------------------------------------------------

SMB_MAIN_CONF="/etc/samba/smb.conf"
SMB_BACKUP="/etc/samba/smb.conf.orig"

if [[ -f "$SMB_BACKUP" ]]; then
  echo "==> Restoring original Samba config from $SMB_BACKUP..."
  mv -f "$SMB_BACKUP" "$SMB_MAIN_CONF"
  systemctl restart smbd nmbd 2>/dev/null || systemctl restart smbd || true
else
  echo "==> No Samba backup found; leaving $SMB_MAIN_CONF as-is."
fi

echo
echo "Uninstall complete."
echo "You can reinstall later with: sudo ./install.sh"
