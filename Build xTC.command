#!/bin/bash
# Double-click this file in Finder to build xTC.app
# Terminal will open automatically.

cd "$(dirname "$0")"

echo "=========================================="
echo "  xTC — Build & Launch"
echo "=========================================="
echo ""

# Run the build
if bash build-app.sh; then
  echo ""
  echo "✅ Build succeeded!"
  echo ""
  echo "Opening xTC.app..."
  open build/xTC.app
else
  echo ""
  echo "❌ Build failed. Check the errors above."
  echo ""
  read -p "Press Enter to close..."
fi
