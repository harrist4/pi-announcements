# Raspberry Pi Announcements Frame

A lightweight Raspberry Pi system that converts PowerPoint slides into images and displays them full-screen on a schedule. Designed for church foyers, hallway displays, and any always-on announcement screen.

## Features
- Watches an upload folder for new PowerPoint, PDF, or image files
- Converts PPTX → PDF → PNG via LibreOffice + ImageMagick
- Runs a fullscreen slideshow using **pqiv** with basic controls
- Programmable schedule
- Off schedule, choose between blank slide or HDMI off
- Two Samba shares:
  - **announcements_inbox** (upload PPTX/images)
  - **announcements_live** (current live slides)
- Install/uninstall scripts are idempotent

## Important Notes
- The system is preconfigured to show slides **all day, every day**.
  To change this behavior, edit the scheduler settings in:
  `/srv/announcements/config/announcements.conf`
- The slideshow runs as the **regular desktop user** who ran the installer (for example, `pi` or another login).
  A **reboot is recommended after install** so the slideshow and Samba services start cleanly.

## Requirements
- Raspberry Pi OS **Desktop** (not Lite)
- Raspberry Pi 3 or 4
- Network access for Samba file shares

## Directory Layout
```
/srv/announcements
    inbox/
    live/
    off/
    config/
    logs/
    tmp/
```

Samba configuration:
```
/etc/samba/smb.conf    (installer writes a minimal config; original saved as /etc/samba/smb.conf.orig)
```

## Installation (one-liner)
On a fresh Raspberry Pi OS **Desktop**, open a terminal and run:
```bash
curl -sSL https://raw.githubusercontent.com/harrist4/pi-announcements/main/rpi-install.sh | sudo bash
```
You will be prompted to choose a **Samba password** for your desktop user.  
When the installer finishes, this script will automatically **reboot**.

After install, connect from another machine to one or both Samba shares:

- `announcements_inbox` – drop PPTX/PDF/images here  
- `announcements_live` – live PNG slides

The slideshow starts automatically once the services are running.

## Installation
Run as root:
```
sudo ./install.sh
```

Optional flags:
```
--smbpass PASS      Samba password for the current user
--noninteractive    Do not prompt; if --smbpass is omitted, a fixed default is used
```

## Uninstallation
```
sudo ./uninstall.sh
```

If you installed with the one-liner:
```
sudo /srv/announcements-src/uninstall.sh
```

## Uploading Slides
Place `.pptx` files or supported images into the **announcements_inbox** share.  
Converted slides appear automatically in **announcements_live**.
Processing may take several minutes, especially for PowerPoint.

The Pi will make a best effort at rendering PowerPoint slides, but fonts will be replaced.
It is always better to manually export PowerPoint to PDF and then upload the PDF version.

## Services Installed
- `announcements-watcher.service`  
- `announcements-slideshow.service`  
- `announcements-display.service`  
- `announcements-status.service`

## Detailed Description
### Updating Announcements
The `announcements-watcher.service` service launches `announcements-watcher.sh`, which runs an infinite loop.

Within that loop:
* `announcements-watcher.sh` checks for fresh files in the inbox, calculating a checksum of the filenames, ignoring any text files.
* When a different checksum is calculated, the time is noted.
* If no relevant files are present the loop continues.
* If the "last change" time exceeds the QUIET_SECONDS setting then it's time to process the files
  * Remove the `_READY.txt` file
  * Create the `_PROCESSING.txt` file with timestamp
  * Run `convert_all.sh`
  * Restart the `announcements-slideshow.service` service to pick up the changed slides
  * Create the `_READY.txt` file with results

### Scheduling the Display
The `announcements-display.service` service launches `announcements-display.sh`, which runs an infinite loop.
This script views the schedule in the config file and determines if the slide show should be visible.
Two state files are used:

`/tmp/announcements_display_state` is of questionable value, intended to prevent HDMI on/off spamming, but there should be a better way.

`/tmp/announcements_slides_mode` file is used to communicate the current mode to the slide show service. 

### Running the Slide Show
The `announcements-slideshow.service` service launches `announcements-slideshow.sh`, which launches `pqiv` to show slides.
This service refers to the `/tmp/announcements_slides_mode` to determine whether to show the normal slides or black slide.

If `pqiv` exits then this service will relaunch, starting a fresh `pqiv` instance.

### Monitoring Status
The `announcements-status.service` service launches `announcements-status.sh`, which runs in an infinite loop with a 30‑second sleep.

This service checks for subdirectories under `/srv/announcements/tmp` and if there is a scratch directory present its contents are written to a `_STATUS_<timestamp>.txt` file in the inbox (next to `_READY.txt` and `_PROCESSING.txt`).

The timestamp avoids Samba caching confusion and allows someone to check progress.
