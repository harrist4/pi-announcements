# Raspberry Pi Announcements Frame

A lightweight Raspberry Pi system that converts PowerPoint slides into images and displays them full-screen on a schedule. Designed for church foyers, hall displays, and always‑on announcement screens.

## Features
- Watches an upload folder for new PPTX files
- Converts PPTX → PDF → PNG via LibreOffice + ImageMagick
- Runs a fullscreen slideshow using pqiv
- Optional “off‑schedule” slides
- Automatic display power control via systemd timer
- Two Samba shares:
  - announcements_inbox (upload PPTX)
  - announcements_live (converted slides)
- Dedicated service user for isolation
- Install/uninstall scripts are idempotent

## Requirements
- Raspberry Pi OS Desktop (not Lite)
- Raspberry Pi 3 or 4
- Network access (for Samba shares)

## Directory Layout
Installed under:
/srv/announcements
    inbox/
    live/
    off_schedule/
    config/
    logs/
    tmp/

Service configuration:
/etc/announcements-frame/env

Samba configuration:
/etc/samba/conf.d/announcements.conf

## Installation
Run as root:
    sudo ./install.sh

Optional flags:
    --user NAME         Service user (default: annc)
    --password PASS     Password for system + Samba
    --noninteractive    No prompts (requires --password)

## Uninstall
    sudo ./uninstall.sh

## Uploading Slides
Drop .pptx files into the announcements_inbox share.
Converted slides appear in announcements_live.

## Services
- announcements-watcher.service
- announcements-slideshow.service
- announcements-display.service
- announcements-display.timer

