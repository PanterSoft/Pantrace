#!/bin/sh
# The freedesktop launcher entry every Linux package installs.
cat <<DESK
[Desktop Entry]
Type=Application
Name=Pantrace
Comment=CAN bus tracer with DBC decoding
Exec=/opt/pantrace/pantrace
Icon=pantrace
Categories=Development;Electronics;
DESK
