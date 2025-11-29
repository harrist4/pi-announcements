#!/usr/bin/env bash
#
# rpi-install.sh
#
# Purpose:
#   One-shot installer for a fresh Raspberry Pi OS Desktop system.
#   - Installs git
#   - Clones or updates the pi-announcements repo into /srv/announcements-src
#   - Runs ./install.sh from that repo
#   - Reboots the Pi when finished
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/harrist4/pi-announcements/main/rpi-install.sh | sudo bash
#
# Notes:
#   - Must be run as root (via sudo).
#   - Safe to re-run; it will pull latest from Git and re-run install.sh.
set -euo pipefail

REPO_URL="https://github.com/harrist4/pi-announcements.git"
SRC_DIR="/srv/announcements-src"

echo "==> Updating apt and installing git..."
apt-get update
apt-get install -y git

if [[ ! -d "$SRC_DIR" ]]; then
  echo "==> Cloning announcements repo..."
  git clone "$REPO_URL" "$SRC_DIR"
else
  echo "==> Repo already present, pulling latest..."
  cd "$SRC_DIR"
  git pull --ff-only
fi

cd "$SRC_DIR"

echo "==> Running install.sh..."
./install.sh

echo "==> Install complete...rebooting"

systemctl reboot