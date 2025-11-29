# Raspberry Pi Announcements Frame

A lightweight Raspberry Pi system that converts PowerPoint slides into images and displays them full-screen on a schedule. Designed for church foyers, hallway displays, and any always-on announcement screen.

## Features
- Watches an upload folder for new PPTX files  
- Converts PPTX → PDF → PNG via LibreOffice + ImageMagick  
- Runs a fullscreen slideshow using **pqiv**  
- Optional off-schedule slide deck  
- Automatic display power control via systemd timer  
- Two Samba shares:
  - **announcements_inbox** (upload PPTX/images)
  - **announcements_live** (converted slides)
- Dedicated service user for isolation  
- Install/uninstall scripts are idempotent  
- Prepopulated “installation complete” slide to confirm the system is working

## Important Notes
- The system is preconfigured to show slides **all day, every day**.  
  To change this behavior, edit the scheduler settings in:  
  `/srv/announcements/config/announcements.conf`
- The Raspberry Pi desktop must auto-login as the **service user** created during installation.  
  A **reboot is required after install** for the slideshow to function.  
  A reboot is also required after uninstall to restore the original GUI user.

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

Service environment:
```
/etc/announcements-frame/env
```

Samba configuration:
```
/etc/samba/conf.d/announcements.conf
```
## Installation (one-liner)
On a fresh Raspberry Pi OS **Desktop**, open a terminal and run:
```bash
curl -sSL https://raw.githubusercontent.com/harrist4/pi-announcements/main/rpi-install.sh | sudo bash
```
You will be prompted to choose a password for the service user (**annc**).  
When the installer finishes, **reboot** the Pi.

After reboot, connect from another machine to one or both Samba shares:

- `announcements_inbox` – drop PPTX/PDF/images here  
- `announcements_live` – converted PNG slides

The slideshow starts automatically.

## Installation
Run as root:
```
sudo ./install.sh
```

Optional flags:
```
--user NAME         Create/use a specific service user (default: annc)
--password PASS     Password for system + Samba user
--noninteractive    No prompts (requires --password)
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

## Services Installed
- `announcements-watcher.service`  
- `announcements-slideshow.service`  
- `announcements-display.service`  
- `announcements-status.service`

## Detailed Description
### Updating Announcements
The `announcements-watcher.service` service launches `watch_inbox.sh`, which runs an infinite loop.

Within that loop:
* `watch_inbox.sh` checks for fresh files in the inbox, calculating a checksum of the filenames, ignoring any text files.
* When a different checksum is calculated, the time is noted.
* If no relevant files are present the loop continues.
* If the "last change" time exceeds the QUIET_SECONDS setting then it's time to process the files
  * Remove the `_READY.txt` file
  * Create the `_PROCESSING.txt` file with timestamp
  * Run `convert_all.sh`
  * Restart the `announcements-slideshow.service` service to pick up the changed slides
  * Create the `_READY.txt` file with results


### Scheduling the Display
The `announcements-display.service` service launches `schedule_display.sh`, which runs an infinite loop.
This script views the schedule in the config file and determines if the slide show shoudld be visible.
A special file is created in 

### Running the Slide Show
The `announcements-slideshow.service` service launches `start_slideshow.sh`, which launches `pqiv` to show slides.
If `pqiv` exits then this service will relaunch, starting a fresh `pqiv` instance.

### Monitoring Status
The `announcements-status.service` service launchs `status_watcher.sh`, which runs in an infinite loop with a 30 second sleep.

This service checks for subdirectories under `/svc/announcements/tmp` and if there is a scratch directory present its contents are written to a `_STATUS_\<timestamp\>.txt` file in in the same directory as the `_READY.txt` and `_PROCESSING.txt` files appear.

The timestamp is there so Samba cachine doesn't complicate status checks.
The idea is to allow someone to see how far along the Pi is in the process.
