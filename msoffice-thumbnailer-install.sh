#!/usr/bin/env bash
# ============================================================================
#  msoffice-thumbnailer-install.sh
#  One-shot installer for Nautilus MS Office / ODF thumbnail previews.
#
#  What it does:
#    1. Checks for required dependencies (libreoffice, imagemagick)
#    2. Writes the thumbnailer script to /usr/local/bin/
#    3. Registers a .thumbnailer entry in /usr/share/thumbnailers/
#    4. Disables the conflicting gsf-office thumbnailer (embedded-thumbnail-only)
#    5. Clears Nautilus thumbnail failure cache so it retries immediately
#
#  After running, restart Nautilus:  nautilus -q && nautilus &
#
#  Supported formats:
#    .doc  .docx  .xls  .xlsx  .ppt  .pptx
#    .odt  .ods   .odp  .odg   (OpenDocument)
#    .sxw  .sxc   .sxi  .sxd   (Sun XML)
# ============================================================================

set -euo pipefail

# ----  user-facing helpers  -----------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

say()   { echo -e "  $*"; }
ok()    { echo -e "  ${GREEN}✔${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()   { echo -e "  ${RED}✘${NC} $*"; exit 1; }

# ----  check we're on a system that makes sense  --------------------------
command -v nautilus >/dev/null 2>&1 || die "Nautilus is not installed — nothing to thumbnail for."

# ----  dependency checks  -------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MS Office / ODF Nautilus Thumbnailer Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
say "Checking dependencies..."

for dep in libreoffice magick convert; do
  if command -v "$dep" >/dev/null 2>&1; then
    ok "$dep found"
    break 2>/dev/null || true  # only need one of magick/convert
  fi
done

# ImageMagick — we need either magick (v7) or convert (v6)
if command -v magick >/dev/null 2>&1; then
  IM_CMD="magick"
elif command -v convert >/dev/null 2>&1; then
  IM_CMD="convert"
else
  die "ImageMagick is not installed.  Install with:  sudo pacman -S imagemagick"
fi

if ! command -v libreoffice >/dev/null 2>&1; then
  die "LibreOffice is not installed.  Install with:  sudo pacman -S libreoffice-fresh"
fi

ok "All dependencies satisfied (LO + ImageMagick $IM_CMD)"

# ----  paths  -------------------------------------------------------------
SCRIPT_DEST="/usr/local/bin/msoffice-thumbnailer"
ENTRY_DEST="/usr/share/thumbnailers/00-msoffice.thumbnailer"
GSF_ENTRY="/usr/share/thumbnailers/gsf-office.thumbnailer"

# ----  write the thumbnailer script  --------------------------------------
say "Writing thumbnailer script → $SCRIPT_DEST"

# We use a temp file + pkexec/sudo copy so the heredoc works regardless
# of whether the caller is root already.
TMP_SCRIPT=$(mktemp /tmp/msoffice-thumbnailer.XXXXXX)
chmod 644 "$TMP_SCRIPT"

cat > "$TMP_SCRIPT" << 'ENDOFSCRIPT'
#!/usr/bin/env bash
# ============================================================================
#  msoffice-thumbnailer
#  Generates a thumbnail PNG for MS Office & OpenDocument files.
#
#  Called by Nautilus via the .thumbnailer entry.  Runs inside a bwrap
#  sandbox on modern GNOME, so everything is self-contained:
#    • temp files go in the output directory (guaranteed writable)
#    • LibreOffice gets its own user profile in the temp dir
#    • 30-second timeout prevents hung processes
#
#  Usage:  msoffice-thumbnailer <input> <output> [size]
# ============================================================================
set -euo pipefail

# Nautilus calls TryExec without arguments to verify the binary exists.
# Exit cleanly so the check passes.
if [ $# -lt 2 ]; then
  exit 0
fi

INPUT="$1"
OUTPUT="$2"
SIZE="${3:-256}"

# ----  create temp workspace (bwrap-safe — inside output directory)  ------
WORKDIR="$(dirname "$OUTPUT")"
TMPDIR="$(mktemp -d "$WORKDIR/msoffice-thumb-XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

cp "$INPUT" "$TMPDIR/input.$(basename "$INPUT")"
INFILE="$TMPDIR/input.$(basename "$INPUT")"

# ----  render first page to PNG with LibreOffice  -------------------------
export SAL_USE_VCLPLUGIN=svp   # headless virtual canvas (no X11/Wayland)

# --norestore          don't try to recover crashed sessions
# -env:UserInstallation  give LO a writable profile inside our temp dir
#                        (the sandbox $HOME is often read-only or missing)
timeout 30s libreoffice \
  -env:UserInstallation="file://${TMPDIR}/lo-profile" \
  --headless \
  --norestore \
  --convert-to png \
  --outdir "$TMPDIR" \
  "$INFILE" >/dev/null 2>&1 || {
    echo "LibreOffice failed or timed out on: $INPUT"
    exit 1
  }

# LibreOffice names the output <basename-without-extension>.png
BASENAME="$(basename "$INFILE")"
BASENAME="${BASENAME%.*}"
PNG_FILE="$TMPDIR/${BASENAME}.png"

# Fallback: LO sometimes appends a number or uses a different name
if [ ! -f "$PNG_FILE" ]; then
  PNG_FILE="$(find "$TMPDIR" -maxdepth 1 -name '*.png' 2>/dev/null | head -1)"
fi

if [ -z "${PNG_FILE:-}" ] || [ ! -f "$PNG_FILE" ]; then
  echo "LibreOffice produced no PNG for: $INPUT"
  exit 1
fi

# ----  resize to final thumbnail  -----------------------------------------
# ImageMagick v7 uses 'magick', v6 uses 'convert'.  We try both.
if command -v magick >/dev/null 2>&1; then
  magick "$PNG_FILE" -thumbnail "${SIZE}x${SIZE}" -background white \
         -gravity center -extent "${SIZE}x${SIZE}" \
         png:"$OUTPUT"
else
  convert "$PNG_FILE" -thumbnail "${SIZE}x${SIZE}" -background white \
         -gravity center -extent "${SIZE}x${SIZE}" \
         png:"$OUTPUT"
fi

exit 0
ENDOFSCRIPT

# ----  install script (needs root for /usr/local/bin)  --------------------
if [ "$(id -u)" -eq 0 ]; then
  # Already running as root
  cp "$TMP_SCRIPT" "$SCRIPT_DEST"
  chmod 755 "$SCRIPT_DEST"
else
  if command -v pkexec >/dev/null 2>&1; then
    pkexec cp "$TMP_SCRIPT" "$SCRIPT_DEST" || die "Failed to copy script (pkexec)"
    pkexec chmod 755 "$SCRIPT_DEST"
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp "$TMP_SCRIPT" "$SCRIPT_DEST" || die "Failed to copy script (sudo)"
    sudo chmod 755 "$SCRIPT_DEST"
  else
    die "Need root to install to $SCRIPT_DEST.  Run with sudo or install pkexec."
  fi
fi

rm -f "$TMP_SCRIPT"
ok "Script installed → $SCRIPT_DEST"

# ----  write & install the .thumbnailer entry  ----------------------------
say "Registering thumbnailer entry..."

TMP_ENTRY=$(mktemp /tmp/msoffice.thumbnailer.XXXXXX)

cat > "$TMP_ENTRY" << 'ENDOFENTRY'
[Thumbnailer Entry]
TryExec=/usr/local/bin/msoffice-thumbnailer
Exec=/usr/local/bin/msoffice-thumbnailer %i %o %s
MimeType=application/msword;application/vnd.ms-word;application/vnd.ms-excel;application/vnd.ms-powerpoint;application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.openxmlformats-officedocument.wordprocessingml.template;application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;application/vnd.openxmlformats-officedocument.spreadsheetml.template;application/vnd.openxmlformats-officedocument.presentationml.presentation;application/vnd.openxmlformats-officedocument.presentationml.template;application/vnd.openxmlformats-officedocument.presentationml.slideshow;application/vnd.oasis.opendocument.text;application/vnd.oasis.opendocument.text-template;application/vnd.oasis.opendocument.spreadsheet;application/vnd.oasis.opendocument.spreadsheet-template;application/vnd.oasis.opendocument.presentation;application/vnd.oasis.opendocument.presentation-template;application/vnd.oasis.opendocument.graphics;application/vnd.oasis.opendocument.graphics-template;application/vnd.sun.xml.writer;application/vnd.sun.xml.calc;application/vnd.sun.xml.impress;application/vnd.sun.xml.draw;
ENDOFENTRY

# mktemp creates files as 0600.  If we copy that straight into
# /usr/share/thumbnailers/ the entry ends up root-only, and Nautilus
# (running as the logged-in user) cannot read it — it silently skips the
# thumbnailer with "Failed to load thumbnailer ... Permission denied".
# Make the source readable and force 0644 on the installed entry.
chmod 644 "$TMP_ENTRY"

if [ "$(id -u)" -eq 0 ]; then
  cp "$TMP_ENTRY" "$ENTRY_DEST"
  chmod 644 "$ENTRY_DEST"
else
  if command -v pkexec >/dev/null 2>&1; then
    pkexec cp "$TMP_ENTRY" "$ENTRY_DEST"
    pkexec chmod 644 "$ENTRY_DEST"
  else
    sudo cp "$TMP_ENTRY" "$ENTRY_DEST"
    sudo chmod 644 "$ENTRY_DEST"
  fi
fi

rm -f "$TMP_ENTRY"
ok "Thumbnailer entry → $ENTRY_DEST (mode 644)"

# ----  disable the old gsf-office thumbnailer  ----------------------------
# gsf-office-thumbnailer only extracts *embedded* thumbnails from Office
# files and produces blank/error thumbnails for most real-world files.
# It also runs before ours alphabetically ("g" < "m") and its failure
# gets cached, preventing ours from ever being tried.  Disable it.
if [ -f "$GSF_ENTRY" ]; then
  say "Disabling gsf-office thumbnailer (embedded-thumbnail-only, causes conflicts)..."

  if [ "$(id -u)" -eq 0 ]; then
    mv "$GSF_ENTRY" "${GSF_ENTRY}.disabled"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec mv "$GSF_ENTRY" "${GSF_ENTRY}.disabled"
  else
    sudo mv "$GSF_ENTRY" "${GSF_ENTRY}.disabled"
  fi

  ok "gsf-office disabled → ${GSF_ENTRY}.disabled"
else
  say "gsf-office.thumbnailer not present — nothing to disable."
fi

# ----  clear thumbnail failure cache  -------------------------------------
# Nautilus caches generation failures and refuses to retry until the
# cache is cleared.  We nuke it so thumbnails regenerate immediately.
CACHE_DIR="$HOME/.cache/thumbnails/fail/gnome-thumbnail-factory"

if [ -d "$CACHE_DIR" ]; then
  say "Clearing thumbnail failure cache..."
  rm -rf "${CACHE_DIR:?}"/*
  ok "Failure cache cleared"
fi

# ----  verify  -------------------------------------------------------------
echo ""
say "Running quick self-test..."
if /usr/local/bin/msoffice-thumbnailer; then
  ok "TryExec check passed (exit 0)"
else
  warn "TryExec check failed — please report this"
fi

# Nautilus runs as the logged-in user and must be able to *read* the
# .thumbnailer entry, otherwise it is skipped entirely.
ENTRY_PERMS="$(stat -c '%a' "$ENTRY_DEST" 2>/dev/null || echo '000')"
case "$ENTRY_PERMS" in
  *[4567]) ok "Entry is world-readable (mode $ENTRY_PERMS)" ;;
  *)       warn "Entry mode is $ENTRY_PERMS — Nautilus cannot read it and thumbnails will NOT appear." ;;
esac

# ----  done  ---------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ${GREEN}Installation complete!${NC}"
echo ""
echo "  To activate:"
echo "    nautilus -q && nautilus &"
echo ""
echo "  Supported formats:"
echo "    .doc .docx  .xls .xlsx  .ppt .pptx"
echo "    .odt .ods   .odp .odg   .sxw .sxc .sxi .sxd"
echo ""
echo "  Files touched:"
echo "    $SCRIPT_DEST"
echo "    $ENTRY_DEST"
echo "    ${GSF_ENTRY}.disabled  (was $GSF_ENTRY)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
