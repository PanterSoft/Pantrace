#!/bin/sh
# Wrap the Linux release bundle into Pantrace-linux-<arch>.deb.
# Usage: package-deb.sh <version> [x64|arm64]
set -e
V=$1; ARCH=${2:-x64}
case "$ARCH" in
  x64) DEB_ARCH=amd64 ;;
  arm64) DEB_ARCH=arm64 ;;
  *) echo "unknown arch $ARCH" >&2; exit 1 ;;
esac
BUNDLE=build/linux/$ARCH/release/bundle
P=$(mktemp -d)
mkdir -p "$P/DEBIAN" "$P/opt/pantrace" "$P/usr/bin" "$P/usr/share/applications"
install -Dm644 linux/pantrace.png "$P/usr/share/icons/hicolor/256x256/apps/pantrace.png"
cp -r "$BUNDLE/." "$P/opt/pantrace/"
ln -s /opt/pantrace/pantrace "$P/usr/bin/pantrace"
cat > "$P/DEBIAN/control" <<CTL
Package: pantrace
Version: $V
Architecture: $DEB_ARCH
Maintainer: PanterSoft <https://github.com/PanterSoft/Pantrace>
Depends: libgtk-3-0
Description: Cross-platform CAN tracer with DBC decoding.
CTL
linux/desktop-entry.sh > "$P/usr/share/applications/pantrace.desktop"
dpkg-deb --build --root-owner-group "$P" "Pantrace-linux-$DEB_ARCH.deb"
