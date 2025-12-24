## 2025-12-24
- Added background CPU temperature monitoring using a systemd timer
- Log CPU temperature every 5 minutes to CSV with automatic log rotation
- Display current, 24-hour max, and 7-day max CPU temperature in `announcements status`
- Correctly auto-orient phone images during conversion using EXIF metadata
- Clarified service vs timer responsibilities in documentation and helper scripts
- Added symlinks to inbox and live directories

## 2025-12-02
- Added "config" to announcements helper command
- Cleaned up announcements helper command
- Updated watcher service to detect changes in live directory
- Updated slideshow service template to eliminate "Error retrieving accessibility bus address"

## 2025-12-01
- Added announcements helper command
- Added motd hint
- Added hero image and docs
- Cleaned up install/uninstall
