# Nautilus MS Office Thumbnailer

Generate file previews (thumbnails) in GNOME Files (Nautilus) for Microsoft Office and OpenDocument formats — `.docx`, `.xlsx`, `.pptx`, `.odt`, `.ods`, `.odp`, and more.

Uses LibreOffice headless to render the first page, then ImageMagick to resize.

## Quick Install

```bash
git clone https://github.com/psychaos999/nautilus-msoffice-thumbnailer.git
cd nautilus-msoffice-thumbnailer
sudo ./msoffice-thumbnailer-install.sh
```

Then restart Nautilus:

```bash
nautilus -q && nautilus &
```

## Supported Formats

| Category | Extensions |
|---|---|
| MS Word | `.doc` `.docx` `.docm` |
| MS Excel | `.xls` `.xlsx` `.xlsm` |
| MS PowerPoint | `.ppt` `.pptx` `.pptm` |
| OpenDocument Text | `.odt` `.ott` |
| OpenDocument Spreadsheet | `.ods` `.ots` |
| OpenDocument Presentation | `.odp` `.otp` |
| OpenDocument Graphics | `.odg` `.otg` |
| Sun XML | `.sxw` `.sxc` `.sxi` `.sxd` |

## How It Works

```
Office file  →  LibreOffice (headless)  →  page 1 PNG  →  ImageMagick  →  thumbnail
```

The script is designed to work inside GNOME's modern **bwrap sandbox** (Nautilus 43+):

- Temp files go in the output directory (guaranteed writable by the sandbox)
- LibreOffice gets a private user profile via `-env:UserInstallation`
- 30-second timeout prevents hung processes
- `--norestore` avoids session recovery dialogs
- Handles `TryExec` probing (Nautilus' pre-flight check) gracefully

## What The Installer Does

1. Checks for dependencies (LibreOffice, ImageMagick)
2. Installs the thumbnailer script to `/usr/local/bin/`
3. Registers a `.thumbnailer` entry in `/usr/share/thumbnailers/`
4. Disables the built-in `gsf-office.thumbnailer` (which only extracts embedded thumbnails and conflicts)
5. Clears the Nautilus failure cache so thumbnails regenerate immediately

## Requirements

- **GNOME Files (Nautilus)** — 43 or later
- **LibreOffice** — `libreoffice-fresh` or `libreoffice-still`
- **ImageMagick** — v6 (`convert`) or v7 (`magick`)
- **Linux** — tested on Arch (CachyOS), should work on Ubuntu/Debian/Fedora

## Manual Uninstall

```bash
sudo rm /usr/local/bin/msoffice-thumbnailer
sudo rm /usr/share/thumbnailers/00-msoffice.thumbnailer
sudo mv /usr/share/thumbnailers/gsf-office.thumbnailer.disabled \
        /usr/share/thumbnailers/gsf-office.thumbnailer
```

## Why Not The Built-in Thumbnailer?

GNOME ships with `gsf-office-thumbnailer` (from `libgsf`) which only **extracts pre-embedded thumbnails** from Office files. Most files — especially those created by LibreOffice, Google Docs exports, or programmatic generation — don't have embedded thumbnails and show nothing.

This thumbnailer **actually renders the first page** using LibreOffice, so every file gets a real preview.

## License

MIT
