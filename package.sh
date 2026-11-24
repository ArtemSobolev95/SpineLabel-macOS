#!/bin/bash
#
# Builds the universal plugin (Apple silicon + Intel) and packs it:
#   TARGET=isix  ./package.sh  ->  dist/SpineLabel-IsiX-<version>.zip
#   TARGET=horos ./package.sh  ->  dist/SpineLabel-Horos-<version>.zip
#
set -euo pipefail
cd "$(dirname "$0")"
TARGET="${TARGET:-isix}"
if [ "$TARGET" = "horos" ]; then BUILD=build-horos; HOSTNAME=Horos; else BUILD=build; HOSTNAME=IsiX; fi
TARGET="$TARGET" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $BUILD/SpineLabel.osirixplugin/Contents/Info.plist)
NAME="SpineLabel-$HOSTNAME-$VERSION"
STAGE="dist/$NAME"
rm -rf "$STAGE" "dist/$NAME.zip"
mkdir -p "$STAGE"
cp -R $BUILD/SpineLabel.osirixplugin "$STAGE/"
cp "Distribution/$HOSTNAME/Install SpineLabel.command" "$STAGE/"
chmod +x "$STAGE/Install SpineLabel.command"
sed "s/@VERSION@/$VERSION/g" "Distribution/$HOSTNAME/README.txt" > "$STAGE/README.txt"
cp LICENSE "$STAGE/"
codesign --verify --deep "$STAGE/SpineLabel.osirixplugin"
echo "==> Architectures: $(lipo -archs "$STAGE/SpineLabel.osirixplugin/Contents/MacOS/SpineLabel")"
(cd dist && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$NAME.zip")
echo "==> Package: $(pwd)/dist/$NAME.zip"
