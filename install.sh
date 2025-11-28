#!/bin/bash
#
# Install the announcements frame system on a Raspberry Pi.
#
# Purpose:
#   - Install required packages
#   - Lay out /srv/announcements directory tree
#   - Copy scripts + config into place
#   - Install and enable systemd units
#   - Configure Samba shares (via /etc/samba/conf.d/)
#   - Create a dedicated service user for file ownership + Samba access
#
# Usage:
#   sudo ./install.sh [--user NAME] [--password PASS] [--noninteractive]
#
# Flags:
#   --user NAME         Create/use this service user instead of the default "annc"
#   --password PASS     Password for the service user (system + Samba)
#   --noninteractive    Do not prompt; requires --password
#
# Notes:
#   - /srv/announcements is the runtime base directory.
#   - The service user owns all files and is the only Samba user allowed.
#   - Assumes Raspberry Pi OS Desktop (Debian-based).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (e.g. sudo ./install.sh)" >&2
  exit 1
fi

SERVICE_USER="annc"
SERVICE_USER_PASS=""
NONINTERACTIVE=0

# Parse flags: --user, --password, --noninteractive
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      SERVICE_USER="$2"
      shift 2
      ;;
    --password)
      SERVICE_USER_PASS="$2"
      shift 2
      ;;
    --noninteractive)
      NONINTERACTIVE=1
      shift 1
      ;;
    *)
      # Unknown flag; ignore or break if you prefer strictness
      shift 1
      ;;
  esac
done

# Basic validation for service user name
if [[ -z "$SERVICE_USER" ]]; then
  echo "ERROR: service user name cannot be empty." >&2
  exit 1
fi

if [[ "$SERVICE_USER" == "root" ]]; then
  echo "ERROR: service user cannot be 'root'." >&2
  exit 1
fi

# Allow typical Unix usernames: start with letter/underscore, then letters/numbers/_/-
if [[ ! "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "ERROR: invalid service user name: '$SERVICE_USER'." >&2
  echo "Allowed: start with a letter or underscore, then letters, digits, '_' or '-'." >&2
  exit 1
fi

echo "==> Service user will be: $SERVICE_USER"

# Ensure we are running on a system with a desktop environment
if ! command -v startx >/dev/null; then
  echo "This system does not appear to have a desktop environment installed."
  echo "Please use Raspberry Pi OS Desktop (not Lite)."
  exit 1
fi

FRAME_DIR="$(cd "$(dirname "$0")" && pwd)"

# This system always uses the dedicated service user (default: annc),
# optionally overridden via --user. OWNER/GROUP match SERVICE_USER.
OWNER="$SERVICE_USER"
GROUP="$SERVICE_USER"

BASE_DIR="/srv/announcements"

echo "==> Creating service user '$SERVICE_USER' (if missing)..."
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$SERVICE_USER"
fi

echo

if [[ -z "$SERVICE_USER_PASS" ]]; then
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    echo "ERROR: --noninteractive requires --password <PASS>" >&2
    exit 1
  fi
  read -s -p "Set password for user '$SERVICE_USER' (used for both system + Samba): " SERVICE_USER_PASS
  echo
fi

if [[ -z "$SERVICE_USER_PASS" ]]; then
  echo "ERROR: empty passwords are not allowed." >&2
  exit 1
fi

echo "$SERVICE_USER:$SERVICE_USER_PASS" | chpasswd

echo "==> Configuring desktop auto-login for '$SERVICE_USER'..."

LIGHTDM_CONF="/etc/lightdm/lightdm.conf"

if [[ -f "$LIGHTDM_CONF" ]]; then
  if grep -q '^autologin-user=' "$LIGHTDM_CONF"; then
    # Replace existing autologin-user line
    sed -i "s/^autologin-user=.*/autologin-user=$SERVICE_USER/" "$LIGHTDM_CONF"
  else
    # Insert under [Seat:*] if present, otherwise append at end
    if grep -q '^\[Seat:\*\]' "$LIGHTDM_CONF"; then
      awk '
        /^\[Seat:\*\]/ {
          print
          print "autologin-user='"$SERVICE_USER"'"
          next
        }
        { print }
      ' "$LIGHTDM_CONF" > "${LIGHTDM_CONF}.tmp" && mv "${LIGHTDM_CONF}.tmp" "$LIGHTDM_CONF"
    else
      printf '\n[Seat:*]\nautologin-user=%s\n' "$SERVICE_USER" >> "$LIGHTDM_CONF"
    fi
  fi
else
  echo "NOTE: $LIGHTDM_CONF not found; please configure desktop auto-login for '$SERVICE_USER' manually."
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
  inotify-tools \
  samba

echo "==> Creating directory structure..."
mkdir -p "$BASE_DIR"/{inbox,live,off_schedule,config,logs,tmp}
chown -R "$OWNER:$GROUP" "$BASE_DIR"

echo "==> Creating initial 'installation complete' slide..."
INSTALL_SLIDE="$BASE_DIR/live/installation_complete.png"
if [ ! -f "$INSTALL_SLIDE" ]; then
  convert -size 1920x1080 \
    -background black \
    -fill white \
    -gravity center \
    -pointsize 44 \
    caption:"Announcements frame installation complete.\n\nAdd some slides to the inbox share to get started." \
    "$INSTALL_SLIDE" || true
  chown "$OWNER:$GROUP" "$INSTALL_SLIDE"
fi

echo "==> Copying scripts..."
install -m 0755 "$FRAME_DIR/scripts/convert_all.sh"      "$BASE_DIR/convert_all.sh"
install -m 0755 "$FRAME_DIR/scripts/watch_inbox.sh"      "$BASE_DIR/watch_inbox.sh"
install -m 0755 "$FRAME_DIR/scripts/start_slideshow.sh"  "$BASE_DIR/start_slideshow.sh"
install -m 0755 "$FRAME_DIR/scripts/schedule_display.sh" "$BASE_DIR/schedule_display.sh"
install -m 0755 "$FRAME_DIR/scripts/status_watcher.sh"   "$BASE_DIR/status_watcher.sh"

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
if [ ! -f "$BASE_DIR/off_schedule/black.png" ]; then
  convert -size 1920x1080 xc:black "$BASE_DIR/off_schedule/black.png" || true
fi
chown -R "$OWNER:$GROUP" "$BASE_DIR/off_schedule"

echo "==> Writing service configuration..."
mkdir -p /etc/announcements-frame
# Record service user and the original GUI user so uninstall can restore autologin
echo "SERVICE_USER=$SERVICE_USER" > /etc/announcements-frame/env
echo "ORIGINAL_GUI_USER=${SUDO_USER:-}" >> /etc/announcements-frame/env

echo "==> Configuring sudoers for slideshow restart..."
SUDOERS_SNIPPET="/etc/sudoers.d/announcements-frame"
SYSTEMCTL_BIN="$(command -v systemctl || echo /usr/bin/systemctl)"

cat > "$SUDOERS_SNIPPET" <<EOF
$SERVICE_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN restart announcements-slideshow.service
EOF
chmod 440 "$SUDOERS_SNIPPET"

echo "==> Installing systemd units..."
export SERVICE_USER

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
echo -e "$SERVICE_USER_PASS\n$SERVICE_USER_PASS" | smbpasswd -a -s "$SERVICE_USER"

echo "==> Configuring Samba shares..."

SMB_D_DIR="/etc/samba/conf.d"
SMB_ANN_FILE="$SMB_D_DIR/announcements.conf"
SMB_MAIN_CONF="/etc/samba/smb.conf"

mkdir -p "$SMB_D_DIR"

cat > "$SMB_ANN_FILE" <<EOF
[announcements_inbox]
  path = $BASE_DIR/inbox
  browseable = yes
  read only = no
  valid users = $SERVICE_USER
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
  valid users = $SERVICE_USER
  create mask = 0664
  directory mask = 0775
  veto files = /._*/.DS_Store/.Trash*/.Spotlight-V100/.fseventsd/
  delete veto files = yes
  strict sync = yes
  sync always = yes
EOF

# Ensure main smb.conf includes our file (no wildcards; Samba doesn't expand them here)
if [[ -f "$SMB_MAIN_CONF" ]]; then
  # Add a clean include line if missing
  if ! grep -q '^include = /etc/samba/conf.d/announcements.conf$' "$SMB_MAIN_CONF"; then
    printf 'include = /etc/samba/conf.d/announcements.conf\n' >> "$SMB_MAIN_CONF"
  fi
fi

systemctl restart smbd nmbd 2>/dev/null || systemctl restart smbd || true

echo
echo "Install complete."
echo "- Drop .pptx files into $BASE_DIR/inbox (Samba: announcements_inbox)"
echo "- Converted slides appear in $BASE_DIR/live (Samba: announcements_live)"
echo "- Slideshow + scheduler systemd units installed"
echo "- Service user: $SERVICE_USER"
echo
echo "NOTE: A reboot is required."
echo "After reboot, the Pi will auto-login as '$SERVICE_USER' for the slideshow to function."
