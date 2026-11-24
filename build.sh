#!/bin/bash
#
# Builds SpineLabel (Apple silicon + Intel) for IsiX DICOM Viewer (GitHub build) or Horos,
# and optionally installs it.
#
#   ./build.sh                         IsiX build  -> build/SpineLabel.osirixplugin
#   ./build.sh install                 ... and install in ~/Library/Application Support/IsiX/Plugins
#   TARGET=horos ./build.sh [install]  Horos build -> build-horos/..., ~/Library/Application Support/Horos/Plugins
#
# Needs Xcode (clang, ibtool, codesign). The plugin SDK headers are in ./third_party.
#
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${TARGET:-isix}"
if [ "$TARGET" = "horos" ]; then
  HEADERS="${HOROS_HEADERS:-$(pwd)/third_party/Horos-headers}"
  MIN_OS=11.0                       # Horos 3.3.x (Intel) and 4.0.x run on macOS 11+
  BUILD=build-horos
  PLUGIN_DIR="$HOME/Library/Application Support/Horos/Plugins"
  HOST="Horos"
else
  HEADERS="${ISIX_HEADERS:-$(pwd)/third_party/IsiX-headers}"
  MIN_OS=15.0
  BUILD=build
  PLUGIN_DIR="$HOME/Library/Application Support/IsiX/Plugins"
  HOST="IsiX"
fi
ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(-arch "$a"); done
NAME=SpineLabel
BUNDLE="$BUILD/$NAME.osirixplugin"
LOG="$BUILD/build.log"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$HEADERS/PluginFilter.h" ] || die "$HOST plugin headers not found at: $HEADERS"
xcrun --find clang >/dev/null 2>&1 || die "Xcode command line tools not found. Run: sudo xcode-select -s /Applications/Xcode.app"
xcrun --find ibtool >/dev/null 2>&1 || die "ibtool not found: full Xcode is required. Run: sudo xcode-select -s /Applications/Xcode.app"

rm -rf "$BUILD"
mkdir -p "$BUILD/obj" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/English.lproj"
: > "$LOG"

SOURCES=(
  Sources/SpineLabelFilter.m
  Sources/SpineLabelController.m
)

COMMON_FLAGS=(
  "${ARCH_FLAGS[@]}" -mmacosx-version-min=$MIN_OS
  -O2 -g
  -fobjc-arc -fobjc-exceptions
  -fvisibility=default
  -I Sources -I "$HEADERS"
  -Wno-deprecated-declarations -Wno-deprecated-implementations
  -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unknown-pragmas
  -Wno-objc-method-access -Wno-nullability-completeness -Wno-format
  -Wno-error=int-conversion -Wno-error=implicit-function-declaration
  -Wno-error=incompatible-pointer-types -Wno-error=implicit-int
  -Wno-error=incompatible-function-pointer-types
  -Werror=unguarded-availability-new
)

echo "==> $HOST build, macOS $MIN_OS+: compiling ${#SOURCES[@]} files ($ARCHS)"
failed=0
OBJECTS=()
for src in "${SOURCES[@]}"; do
  obj="$BUILD/obj/$(basename "${src%.*}").o"
  OBJECTS+=("$obj")
  extra=()
  case "$src" in
    *.m) extra=(-x objective-c) ;;
    *.c) extra=(-x c) ;;
  esac
  if ! xcrun clang "${COMMON_FLAGS[@]}" "${extra[@]}" -c "$src" -o "$obj" >>"$LOG" 2>&1; then
    echo "   FAILED: $src"
    failed=1
  fi
done
if [ $failed -ne 0 ]; then
  echo; echo "Compilation failed. Errors:"; grep -E "error:" "$LOG" | head -40
  echo; echo "Full log: $(pwd)/$LOG"; exit 1
fi

echo "==> Linking"
xcrun clang -bundle "${ARCH_FLAGS[@]}" -mmacosx-version-min=$MIN_OS \
  "${OBJECTS[@]}" -framework Cocoa -fobjc-arc \
  -undefined dynamic_lookup \
  -o "$BUNDLE/Contents/MacOS/$NAME" >>"$LOG" 2>&1 || { tail -30 "$LOG"; die "link failed (log: $LOG)"; }

echo "==> Assembling bundle"
cp Sources/Info.plist "$BUNDLE/Contents/Info.plist"
mkdir -p "$BUNDLE/Contents/Resources"
cp Sources/SpineLabel-icon.png "$BUNDLE/Contents/Resources/"

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE" >>"$LOG" 2>&1 || die "codesign failed (log: $LOG)"

echo "==> Built: $(pwd)/$BUNDLE"
lipo -info "$BUNDLE/Contents/MacOS/$NAME" || true

if [ "${1:-}" = "install" ]; then
  mkdir -p "$PLUGIN_DIR"
  rm -rf "$PLUGIN_DIR/$NAME.osirixplugin"
  cp -R "$BUNDLE" "$PLUGIN_DIR/"
  echo "==> Installed to: $PLUGIN_DIR/$NAME.osirixplugin"
  echo "    Restart $HOST, then check Plugins > Plugins Manager."
fi
