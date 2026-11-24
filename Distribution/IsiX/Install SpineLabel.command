#!/bin/bash
# Installs SpineLabel for IsiX for the current user.
cd "$(dirname "$0")"
PLUGIN="SpineLabel.osirixplugin"
DEST="$HOME/Library/Application Support/IsiX/Plugins"
echo "SpineLabel for IsiX — installer"; echo
if [ ! -d "$PLUGIN" ]; then
  echo "ERROR: $PLUGIN is not next to this installer. Unzip the whole package first."
  read -n 1 -s -r -p "Press any key to close."; exit 1
fi
if [ ! -d "/Applications/IsiX DICOM Viewer.app" ]; then echo "WARNING: IsiX DICOM Viewer is not in /Applications."; fi
if pgrep -xq "IsiX DICOM Viewer"; then
  echo "Please quit IsiX DICOM Viewer first, then run this installer again."
  read -n 1 -s -r -p "Press any key to close."; exit 1
fi
mkdir -p "$DEST"
rm -rf "$DEST/$PLUGIN"
cp -R "$PLUGIN" "$DEST/"
# The plugin is not notarised: remove the download quarantine so that macOS lets IsiX DICOM Viewer load it.
xattr -dr com.apple.quarantine "$DEST/$PLUGIN" 2>/dev/null
echo; echo "Installed: $DEST/$PLUGIN"
echo "Open IsiX DICOM Viewer; the plugin is in Plugins > ROI Tools > Spine Labeling. Plugins > Plugins Manager shows whether it loaded."
echo; read -n 1 -s -r -p "Press any key to close."
