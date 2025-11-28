#!/bin/bash
#
# make-zip.sh
#
# Purpose:
#   Create a clean ZIP archive of the current Git repository directory,
#   excluding the .git folder. The ZIP is created in the parent directory
#   with the name <repo>.zip, OR a custom filename if provided.
#
# Usage:
#   ./make-zip.sh
#     → produces ../<repo>.zip
#
#   ./make-zip.sh myfile.zip
#     → produces ../myfile.zip
#
# Notes:
#   - Must be run from inside the repository folder.
#   - Does NOT modify or touch the repo contents.
#

set -euo pipefail

# Name of the directory this script is called from
REPO_DIR="$(basename "$PWD")"

# Output filename (default: <repo>.zip)
OUTPUT_NAME="${1:-$REPO_DIR.zip}"

echo "==> Creating ZIP archive of '$REPO_DIR' ..."
echo "    Output: ../$OUTPUT_NAME"
echo "    Excluding: $REPO_DIR/.git/"
echo "    Excluding: $REPO_DIR/$(basename "$0")"

# Run zip from the parent directory to avoid path noise (repo/... etc.)
(
  cd .. || exit 1
  zip -r "$OUTPUT_NAME" "$REPO_DIR" \
    -x "$REPO_DIR/.git/*" \
    -x "$REPO_DIR/$(basename "$0")"
)

echo "==> ZIP complete."
