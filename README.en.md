# sd_backupper

*[Deutsche Version](README.md)*

Shell scripts to back up an SD card (via USB card reader) as a compressed
image directly onto a USB-attached HDD — and to restore such an image onto
a target device.

> ⚠️ Both scripts write to block devices using `dd`. Selecting the wrong
> source/target can cause data loss. Double-check the device list before
> every confirmation.

## Features

- Works **exclusively with USB devices** (detected via `TRAN=usb`) —
  internal devices are never listed.
- Source (SD card) and target (HDD) are chosen interactively from a list.
- Any partitions of the source that happen to be auto-mounted are cleanly
  unmounted before imaging.
- The image is created **directly on the HDD** (no staging on the SD card,
  since it's usually too small).
- The HDD mountpoint is created automatically if needed.
- Subfolder on the HDD: choose an existing one or enter a new name.
- Suggested filename: `backup_YYYY-MM-DD.img` (freely editable).
- Checks whether there's enough free space on the HDD.
- Compressed afterwards with [PiShrink](https://github.com/Drewsif/PiShrink)
  (`-s`, so images of distributions other than Raspberry Pi OS work too).
- `pishrink.sh` is automatically downloaded into the script folder on first
  run if it isn't already present.
- At the end: lists all files in the chosen backup folder and asks whether
  to unmount the HDD (e.g. to manually delete old backups first).

## Requirements

- `bash`, `lsblk`, `dd`, `blockdev`, `findmnt`, `df`, `curl`, `gzip`, `parted`
- Root privileges (`sudo`)
- Internet connection on first run (for the PiShrink download)

## Installation

```bash
git clone <REPO-URL> ~/scripts/sd_backupper
cd ~/scripts/sd_backupper
chmod +x sd_backup.sh sd_restore.sh
```

`pishrink.sh` is automatically downloaded into the same folder by
`sd_backup.sh` on first run, if not already present.

```
~/scripts/sd_backupper/
├── sd_backup.sh
├── sd_restore.sh
├── pishrink.sh      # downloaded automatically
└── README.md
```

## Target HDD structure

Backup folders must sit **directly at the top level** of the HDD
partition — neither script recognizes any deeper subfolders (neither
when listing them nor when searching for images):

```
/ (root of the HDD partition)
├── Arbeits-Pi/
│   ├── backup_2026-09-24.img
│   └── backup_2026-09-25.img
├── radio_kueche/
│   └── backup_2026-09-25.img
└── ...
```

Image files (`.img`/`.img.gz`) must likewise sit directly inside their
folder, not in further subfolders.

## Usage

```bash
cd ~/scripts/sd_backupper
sudo ./sd_backup.sh
```

The script then walks you through:

1. Selecting the source (SD card)
2. Selecting the target HDD (and partition, if applicable)
3. Selecting/creating the target folder
4. Confirming the filename
5. Imaging (`dd`) + compression (`pishrink.sh -s`)
6. Listing existing backups + asking whether to unmount the HDD

## Restore (sd_restore.sh)

Writes a previously created image from the HDD back onto a target device.

```bash
cd ~/scripts/sd_backupper
sudo ./sd_restore.sh
```

Flow:

1. Select the HDD with the backups (same as backup, auto-mounts if needed)
2. Select the subfolder and the desired image (`.img`/`.img.gz`)
3. Select the target device (e.g. a new SD card)
4. Check whether the image fits on the target
5. **Safety confirmation** (`[y/N]`), since all data on the target will be
   irrecoverably overwritten
6. Writing the image (`dd`, streamed through `zcat` first for `.img.gz`)
   and asking whether to unmount the HDD at the end

## Notes

- Before starting, make sure source and target are correctly identified —
  the device list shows size and model for verification.
- `dd` creates a new image file. It only overwrites an existing file if one
  with the same name already exists (e.g. a second backup on the same day
  with an unchanged filename suggestion). Make sure there's enough free
  space (checked automatically).

## License

[MIT](LICENSE)

---

Created with [Claude](https://claude.ai) (Anthropic).
