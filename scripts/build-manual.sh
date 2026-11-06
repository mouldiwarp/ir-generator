#!/bin/sh
# Renders docs/manual.html to docs/IR-Generator-Manual.pdf with headless Chrome.
# Refresh the screenshots first with:  "build/IR Generator.app/Contents/MacOS/IRGenerator" --snapshot docs/screenshots
set -e
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --allow-file-access-from-files \
  --print-to-pdf="$PWD/docs/IR-Generator-Manual.pdf" "file://$PWD/docs/manual.html" 2>/dev/null
echo "Built: docs/IR-Generator-Manual.pdf"
