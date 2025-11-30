#!/bin/bash
#
# Install the announcements frame system on a Raspberry Pi.
#
# Purpose:
#   - Install required packages
#   - Lay out /srv/announcements directory tree
#   - Copy scripts + config into place
#   - Install and enable systemd units
#   - Configure Samba shares (single minimal smb.conf)
#   - Use the current logged-in user for file ownership + Samba access
#
# Usage:
#   sudo ./install.sh [--smbpass PASS] [--noninteractive]
#
# Flags:
#   --smbpass PASS      Samba password for the current user
#   --noninteractive    Do not prompt; if --smbpass is omitted, a fixed default is used
#
# Notes:
#   - /srv/announcements is the runtime base directory.
#   - The current logged-in user owns all files and is the only Samba user allowed.
#   - Assumes Raspberry Pi OS Desktop (Debian-based).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (e.g. sudo ./install.sh)" >&2
  exit 1
fi

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
  echo "ERROR: Cannot determine non-root invoking user."
  echo "Run this script using:  sudo ./install.sh"
  exit 1
fi
SMB_PASS=""
NONINTERACTIVE=0

# Parse flags: --smbpass, --noninteractive
while [[ $# -gt 0 ]]; do
  case "$1" in
    --smbpass)
      SMB_PASS="$2"
      shift 2
      ;;
    --noninteractive)
      NONINTERACTIVE=1
      shift 1
      ;;
    *)
      shift 1
      ;;
  esac
done

# Ensure we are running on a system with a desktop environment
if ! command -v startx >/dev/null; then
  echo "This system does not appear to have a desktop environment installed."
  echo "Please use Raspberry Pi OS Desktop (not Lite)."
  exit 1
fi

FRAME_DIR="$(cd "$(dirname "$0")" && pwd)"

OWNER="$REAL_USER"
GROUP="$REAL_USER"
echo "==> Using real user: $REAL_USER"

BASE_DIR="/srv/announcements"

# --- SMB password logic ---
if [[ -z "$SMB_PASS" ]]; then
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    SMB_PASS="announcements"
  else
    read -s -p "Set Samba password for user '$REAL_USER': " SMB_PASS < /dev/tty
    echo
  fi
fi

echo "Using user: $OWNER"
echo "Base dir:   $BASE_DIR"

echo "==> Installing packages..."
apt-get update
apt-get install -y \
  libreoffice-impress \
  imagemagick \
  ghostscript \
  pqiv \
  samba

echo "==> Creating directory structure..."
mkdir -p "$BASE_DIR"/{inbox,live,off,config,logs,tmp}
chown -R "$OWNER:$GROUP" "$BASE_DIR"

echo "==> Creating initial 'installation complete' slide..."
INSTALL_SLIDE="$BASE_DIR/live/installation_complete.png"
if [ ! -f "$INSTALL_SLIDE" ]; then
  convert -size 1920x1080 xc:black \
    -gravity center \
    -fill white \
    -font DejaVu-Sans \
    -pointsize 96 \
    -annotate +0+0 "Announcements frame\ninstallation complete.\n\nAdd some slides to the inbox\nshare to get started." \
    "$INSTALL_SLIDE" || true
  chown "$OWNER:$GROUP" "$INSTALL_SLIDE"
fi

echo "==> Copying scripts..."
install -m 0755 "$FRAME_DIR/scripts/convert_all.sh"      "$BASE_DIR/convert_all.sh"
install -m 0755 "$FRAME_DIR/scripts/announcements-watcher.sh"      "$BASE_DIR/announcements-watcher.sh"
install -m 0755 "$FRAME_DIR/scripts/announcements-slideshow.sh"  "$BASE_DIR/announcements-slideshow.sh"
install -m 0755 "$FRAME_DIR/scripts/announcements-display.sh" "$BASE_DIR/announcements-display.sh"
install -m 0755 "$FRAME_DIR/scripts/announcements-status.sh"   "$BASE_DIR/announcements-status.sh"

echo "==> Copying config..."
install -m 0644 "$FRAME_DIR/config/announcements.conf" "$BASE_DIR/config/announcements.conf"
chown -R "$OWNER:$GROUP" "$BASE_DIR/config"

echo "==> Installing inbox README template..."
install -m 0644 "$FRAME_DIR/config/inbox_readme.txt" "$BASE_DIR/config/inbox_readme.txt"
cp "$BASE_DIR/config/inbox_readme.txt" "$BASE_DIR/inbox/README.txt"
chown "$OWNER:$GROUP" "$BASE_DIR/inbox/README.txt"

echo "==> Seeding _READY.txt..."
echo "Drop folder is ready for new content." > "$BASE_DIR/inbox/_READY.txt"
chown "$OWNER:$GROUP" "$BASE_DIR/inbox/_READY.txt"

echo "==> Seeding off-schedule black slide..."
if [ ! -f "$BASE_DIR/off/black.png" ]; then
  convert -size 1920x1080 xc:black "$BASE_DIR/off/black.png" || true
fi
chown -R "$OWNER:$GROUP" "$BASE_DIR/off"

echo "==> Installing systemd units..."
export REAL_USER

envsubst < "$FRAME_DIR/systemd/announcements-watcher.service.template" \
  > /etc/systemd/system/announcements-watcher.service

envsubst < "$FRAME_DIR/systemd/announcements-slideshow.service.template" \
  > /etc/systemd/system/announcements-slideshow.service

install -m 0644 "$FRAME_DIR/systemd/announcements-display.service" /etc/systemd/system/
install -m 0644 "$FRAME_DIR/systemd/announcements-status.service"  /etc/systemd/system/

echo "==> Reloading systemd..."
systemctl daemon-reload

echo "==> Enabling services..."
systemctl enable announcements-watcher.service
systemctl enable announcements-slideshow.service
systemctl enable announcements-display.service
systemctl enable announcements-status.service

echo "==> Starting services..."
systemctl start announcements-watcher.service
systemctl start announcements-slideshow.service
systemctl start announcements-display.service
systemctl start announcements-status.service

echo "==> Setting Samba password..."
echo -e "$SMB_PASS\n$SMB_PASS" | smbpasswd -a -s "$REAL_USER"

echo "==> Installing minimal Samba config..."

SMB_MAIN_CONF="/etc/samba/smb.conf"
SMB_BACKUP="/etc/samba/smb.conf.orig"

# Backup original smb.conf once (idempotent)
if [[ -f "$SMB_MAIN_CONF" && ! -f "$SMB_BACKUP" ]]; then
  cp "$SMB_MAIN_CONF" "$SMB_BACKUP"
fi

# Write a complete minimal smb.conf containing both shares
cat > "$SMB_MAIN_CONF" <<EOF
[global]
   workgroup = WORKGROUP
   server string = %h server
   security = user
   map to guest = Bad User
   unix extensions = no

   # Disable implicit shares
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

   usershare allow guests = no

[announcements_inbox]
  path = $BASE_DIR/inbox
  browseable = yes
  read only = no
  valid users = $REAL_USER
  create mask = 0664
  directory mask = 0775
  veto files = /._*/.DS_Store/.Trash*/.Spotlight-V100/.fseventsd/
  delete veto files = yes
  strict sync = yes
  sync always = yes

[announcements_live]
  path = $BASE_DIR/live
  browseable = yes
  read only = no
  valid users = $REAL_USER
  create mask = 0664
  directory mask = 0775
  veto files = /._*/.DS_Store/.Trash*/.Spotlight-V100/.fseventsd/
  delete veto files = yes
  strict sync = yes
  sync always = yes
EOF

echo "==> Restarting Samba..."
systemctl restart smbd nmbd 2>/dev/null || systemctl restart smbd || true

echo
echo "Install complete."
echo "- Drop .pptx files into $BASE_DIR/inbox (Samba: announcements_inbox)"
echo "- Converted slides appear in $BASE_DIR/live (Samba: announcements_live)"
echo "- Slideshow + scheduler systemd units installed"
echo "- Running under user: $REAL_USER"
echo
echo "NOTE: A reboot is recommended."
