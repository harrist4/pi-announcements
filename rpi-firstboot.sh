#!/usr/bin/env bash
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

echo "==> Running install.sh non-interactively..."
./install.sh --noninteractive

echo "==> First-boot install complete."
