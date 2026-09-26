#!/bin/sh
# Wrap the Linux release bundle into Pantrace-linux-<arch>.rpm (Fedora,
# openSUSE, RHEL). Needs rpmbuild. Usage: package-rpm.sh <version> [x64|arm64]
set -e
V=$1; ARCH=${2:-x64}
case "$ARCH" in
  x64) RPM_ARCH=x86_64 ;;
  arm64) RPM_ARCH=aarch64 ;;
  *) echo "unknown arch $ARCH" >&2; exit 1 ;;
esac
BUNDLE=$(pwd)/build/linux/$ARCH/release/bundle
TOP=$(mktemp -d)
mkdir -p "$TOP/SPECS"
linux/desktop-entry.sh > "$TOP/pantrace.desktop"
cat > "$TOP/SPECS/pantrace.spec" <<SPEC
Name: pantrace
Version: $(echo "$V" | tr - _)
Release: 1
Summary: Cross-platform CAN tracer with DBC decoding
License: MIT
URL: https://github.com/PanterSoft/Pantrace
Requires: gtk3
# The bundle ships its own Flutter engine and plugin libraries.
AutoReqProv: no
%define __strip /bin/true
%define debug_package %{nil}

%description
Open-source CAN bus tracer with DBC decoding, logging and replay.

%install
mkdir -p %{buildroot}/opt/pantrace %{buildroot}%{_bindir} %{buildroot}%{_datadir}/applications
cp -r $BUNDLE/. %{buildroot}/opt/pantrace/
ln -s /opt/pantrace/pantrace %{buildroot}%{_bindir}/pantrace
install -Dm644 $(pwd)/linux/pantrace.png %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/pantrace.png
install -m644 $TOP/pantrace.desktop %{buildroot}%{_datadir}/applications/pantrace.desktop

%files
/opt/pantrace
%{_bindir}/pantrace
%{_datadir}/applications/pantrace.desktop
%{_datadir}/icons/hicolor/256x256/apps/pantrace.png
SPEC
rpmbuild -bb --define "_topdir $TOP" --target "$RPM_ARCH" "$TOP/SPECS/pantrace.spec"
cp "$TOP"/RPMS/*/pantrace-*.rpm "Pantrace-linux-$RPM_ARCH.rpm"
