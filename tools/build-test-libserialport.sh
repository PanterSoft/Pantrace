#!/bin/sh
# Builds libserialport for `flutter test`, which does not bundle the plugin's
# native library. Output: build/test/libserialport.{dylib,so}; point
# LIBSERIALPORT_PATH at it (the Makefile `test` target does).
#
# One twist: the SLCAN tests talk to a pseudo-terminal, and ptys answer ENOTTY
# to the modem-line ioctls sp_open() insists on. The shim below treats that as
# "no modem lines" so the rest of the library runs unmodified.
set -e
cd "$(dirname "$0")/.."

PKG=$(grep -A1 '"name": "flutter_libserialport"' .dart_tool/package_config.json |
  sed -n 's|.*"rootUri": "file://\(.*\)",|\1|p')
[ -d "$PKG" ] || { echo "flutter_libserialport not found; run flutter pub get" >&2; exit 1; }
SRC="$PKG/third_party/libserialport"
OUT=build/test
mkdir -p "$OUT"

cat > "$OUT/ioctl_shim.c" <<'EOF'
#include <errno.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#undef ioctl
int ioctl(int, unsigned long, ...); /* the -D renamed the header prototype */
int sp_test_ioctl(int fd, unsigned long req, ...) {
  va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
  int r = ioctl(fd, req, arg);
  if (r < 0 && errno == ENOTTY &&
      (req == TIOCMGET || req == TIOCMBIS || req == TIOCMBIC)) {
    if (req == TIOCMGET) *(int *)arg = 0;
    return 0;
  }
  return r;
}
EOF

case "$(uname -s)" in
Darwin)
  cat > "$OUT/config.h" <<'EOF'
#define HAVE_DECL_BOTHER 0
#define HAVE_UNISTD_H 1
#define HAVE_TERMIOS_SPEED 1
#define SP_API __attribute__((visibility("default")))
#define SP_PRIV __attribute__((visibility("hidden")))
#define SP_PACKAGE_VERSION_MAJOR 0
#define SP_PACKAGE_VERSION_MINOR 1
#define SP_PACKAGE_VERSION_MICRO 1
#define SP_PACKAGE_VERSION_STRING "0.1.1"
#define SP_LIB_VERSION_CURRENT 1
#define SP_LIB_VERSION_REVISION 0
#define SP_LIB_VERSION_AGE 1
#define SP_LIB_VERSION_STRING "1:0:1"
EOF
  cc -dynamiclib -O2 -w -DLIBSERIALPORT_ATBUILD -Dioctl=sp_test_ioctl \
    -I"$OUT" -I"$SRC" "$SRC/serialport.c" "$SRC/macosx.c" "$SRC/timing.c" \
    "$OUT/ioctl_shim.c" -framework IOKit -framework CoreFoundation \
    -o "$OUT/libserialport.dylib"
  ;;
Linux)
  cc -shared -fPIC -O2 -w -DLIBSERIALPORT_ATBUILD -Dioctl=sp_test_ioctl \
    -I"$PKG/linux/libserialport" -I"$SRC" "$SRC/serialport.c" "$SRC/linux.c" \
    "$SRC/linux_termios.c" "$SRC/timing.c" "$OUT/ioctl_shim.c" \
    -o "$OUT/libserialport.so"
  ;;
*)
  echo "no test build of libserialport for $(uname -s)" >&2; exit 1 ;;
esac
ls "$OUT"/libserialport.*
