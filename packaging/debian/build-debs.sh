#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build Debian packages for the Surface Pro 7 camera stack from source.
#
#   sp7-camera-dkms_<ver>_all.deb     kernel modules as DKMS source
#                                     (rebuilt + signed for every kernel)
#   sp7-camera_<ver>_amd64.deb        patched libcamera + PipeWire libcamera SPA,
#                                     controller/relays, boot loader + timer,
#                                     modprobe/udev/WirePlumber/systemd config
#   sp7-camera-firmware_<ver>_all.deb only with --with-firmware (proprietary
#                                     Intel blob: build it locally, do not publish)
#
# Every upstream source is fetched at the commit pinned in install.sh and
# docs/source-bases.txt, and patched with patches/*. Nothing is installed.
#
# Usage: packaging/debian/build-debs.sh [--with-firmware] [--keep-work]
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
VERSION="$(cat "$HERE/VERSION")"
DEBREV=1
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/out}"
WITH_FW=0
KEEP=0
for a in "$@"; do
	case "$a" in
	--with-firmware) WITH_FW=1 ;;
	--keep-work) KEEP=1 ;;
	*) echo "Usage: $0 [--with-firmware] [--keep-work]" >&2; exit 2 ;;
	esac
done

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for t in git meson ninja cc pkg-config dpkg-deb dpkg-shlibdeps fakeroot curl sha256sum; do
	command -v "$t" >/dev/null || die "Missing build tool: $t (see README, 'Build dependencies')"
done

# Pinned commits: single source of truth is install.sh / docs/source-bases.txt.
eval "$(grep -E '^(LINUX_COMMIT|LINUX_REF|IPU4_COMMIT|LIBCAMERA_COMMIT|PIPEWIRE_COMMIT|V4L2LOOPBACK_COMMIT|V4L2LOOPBACK_REF|FIRMWARE_COMMIT|FIRMWARE_SHA256)=' "$ROOT/install.sh")"
repo_for_section() {
	awk -v section="$1:" '
		$0 == section { active = 1; next }
		active && ($1 == "repository:" || $1 == "upstream:") { print $2; exit }
		active && /^[[:alnum:]][^[:space:]]*:/ { exit }
	' "$ROOT/docs/source-bases.txt"
}
LINUX_REPO="$(repo_for_section Linux)"
IPU4_REPO="$(repo_for_section IPU4)"
LIBCAMERA_REPO="$(repo_for_section libcamera)"
PIPEWIRE_REPO="$(repo_for_section PipeWire)"
V4L2LOOPBACK_REPO="$(repo_for_section v4l2loopback)"

# fetch URL COMMIT DEST [REF] [sparse paths...]
fetch() {
	local url="$1" commit="$2" dest="$3" ref="${4:-}"; shift 4 || shift $#
	if [[ -d "$dest/.git" ]] && [[ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" == "$commit" ]]; then
		git -C "$dest" reset -q --hard && git -C "$dest" clean -qfdx
		return
	fi
	rm -rf "$dest"; git init -q "$dest"
	git -C "$dest" remote add origin "$url"
	if [[ $# -gt 0 ]]; then
		git -C "$dest" sparse-checkout set --no-cone "$@"
		git -C "$dest" fetch -q --depth=1 --filter=blob:none origin "${ref:-$commit}" \
			|| git -C "$dest" fetch -q --depth=1 origin "${ref:-$commit}"
	else
		git -C "$dest" fetch -q --depth=1 origin "${ref:-$commit}"
	fi
	git -C "$dest" checkout -q --detach FETCH_HEAD
	[[ "$(git -C "$dest" rev-parse HEAD)" == "$commit" ]] || die "Wrong commit in $dest"
}
apply() { git -C "$1" apply --whitespace=nowarn "$2" || die "Patch failed: $2"; }

mkdir -p "$WORK" "$OUT"
SRC="$WORK/src"; mkdir -p "$SRC"

# =========================================================== DKMS package ====
log "Kernel sources (linux $LINUX_REF, sparse)"
fetch "$LINUX_REPO" "$LINUX_COMMIT" "$SRC/linux" "$LINUX_REF" \
	/drivers/media/i2c/ov8865.c /drivers/media/i2c/dw9719.c \
	/drivers/media/pci/intel/ipu-bridge.c /drivers/media/v4l2-core/v4l2-async.c
for p in "$ROOT"/patches/kernel/*.patch; do apply "$SRC/linux" "$p"; done

log "IPU4P sources"
fetch "$IPU4_REPO" "$IPU4_COMMIT" "$SRC/ipu4" ""
for p in "$ROOT"/patches/ipu4/*.patch; do apply "$SRC/ipu4" "$p"; done

log "v4l2loopback sources"
fetch "$V4L2LOOPBACK_REPO" "$V4L2LOOPBACK_COMMIT" "$SRC/v4l2loopback" "$V4L2LOOPBACK_REF"

D="$WORK/stage/sp7-camera-dkms"
DS="$D/usr/src/sp7-camera-$VERSION"
rm -rf "$D"; mkdir -p "$D/DEBIAN" "$DS/kmod" "$DS/ipu4/linux-6.19.8/drivers/media/pci" "$DS/v4l2loopback"
cp "$SRC/linux/drivers/media/i2c/ov8865.c" "$SRC/linux/drivers/media/i2c/dw9719.c" \
   "$SRC/linux/drivers/media/pci/intel/ipu-bridge.c" "$DS/kmod/"
printf 'obj-m += ov8865.o\nobj-m += dw9719.o\nobj-m += ipu-bridge.o\n' > "$DS/kmod/Makefile"
cp -a "$SRC/ipu4/linux-6.19.8/include" "$DS/ipu4/linux-6.19.8/"
cp -a "$SRC/ipu4/linux-6.19.8/drivers/media/pci/intel" "$DS/ipu4/linux-6.19.8/drivers/media/pci/"
(cd "$SRC/v4l2loopback" && git archive HEAD) | tar -x -C "$DS/v4l2loopback"
rm -f "$DS/v4l2loopback/dkms.conf"   # only the top-level dkms.conf is used
install -m 0644 "$HERE/dkms/dkms-build.sh" "$DS/dkms-build.sh"
sed "s/@VERSION@/$VERSION/" "$HERE/dkms/dkms.conf" > "$DS/dkms.conf"
cat > "$DS/SOURCES" <<EOF
kmod/: linux $LINUX_REF ($LINUX_COMMIT) + patches/kernel/*
ipu4/: $IPU4_REPO $IPU4_COMMIT + patches/ipu4/*
v4l2loopback/: $V4L2LOOPBACK_REPO $V4L2LOOPBACK_REF ($V4L2LOOPBACK_COMMIT), unmodified
EOF

cat > "$D/DEBIAN/control" <<EOF
Package: sp7-camera-dkms
Version: $VERSION-$DEBREV
Architecture: all
Maintainer: sp7-camera fork <noreply@localhost>
Depends: dkms (>= 3), build-essential, linux-headers-surface | linux-headers-amd64
Recommends: sp7-camera
Section: kernel
Priority: optional
Homepage: https://github.com/Elefantenjongleur/surface-pro-7-camera
Installed-Size: $(du -sk "$D/usr" | cut -f1)
Description: Surface Pro 7 camera kernel modules (DKMS)
 Patched OV8865 sensor, DW9719 VCM and IPU bridge drivers, the patched
 IPU4P stack (intel-ipu4p*, incl. front-camera firmware recycle) and
 v4l2loopback 0.15.4. DKMS rebuilds and signs them for every installed kernel.
EOF
sed "s/@VERSION@/$VERSION/g" "$HERE/maint/sp7-camera-dkms.postinst" > "$D/DEBIAN/postinst"
sed "s/@VERSION@/$VERSION/g" "$HERE/maint/sp7-camera-dkms.prerm" > "$D/DEBIAN/prerm"
chmod 0755 "$D/DEBIAN/postinst" "$D/DEBIAN/prerm"
fakeroot dpkg-deb --root-owner-group -Zxz -b "$D" "$OUT/sp7-camera-dkms_${VERSION}-${DEBREV}_all.deb"

# ====================================================== userspace package ====
U="$WORK/stage/sp7-camera"
rm -rf "$U"; mkdir -p "$U/DEBIAN"

log "libcamera"
fetch "$LIBCAMERA_REPO" "$LIBCAMERA_COMMIT" "$SRC/libcamera" ""
for p in "$ROOT"/patches/libcamera/*.patch; do apply "$SRC/libcamera" "$p"; done
rm -rf "$WORK/libcamera-build"
meson setup "$WORK/libcamera-build" "$SRC/libcamera" \
	--prefix=/usr/local --libdir=lib64 --buildtype=debugoptimized \
	-Dcam=enabled -Dqcam=disabled -Ddocumentation=disabled -Dtest=false \
	-Dpipelines=simple
ninja -C "$WORK/libcamera-build" -j"$(nproc)"
LC_STAGE="$WORK/libcamera-stage"; rm -rf "$LC_STAGE"
DESTDIR="$LC_STAGE" meson install -C "$WORK/libcamera-build" --quiet
install -D -m 0644 "$SRC/libcamera/src/ipa/simple/data/ov8865.yaml" \
	"$LC_STAGE/usr/local/share/libcamera/ipa/simple/ov8865.yaml"

log "PipeWire libcamera SPA"
fetch "$PIPEWIRE_REPO" "$PIPEWIRE_COMMIT" "$SRC/pipewire" ""
for p in "$ROOT"/patches/pipewire/*.patch; do apply "$SRC/pipewire" "$p"; done
PCDIR="$WORK/pkgconfig"; rm -rf "$PCDIR"; mkdir -p "$PCDIR"
for pc in libcamera.pc libcamera-base.pc; do
	sed "s|^prefix=/usr/local\$|prefix=$LC_STAGE/usr/local|" \
		"$LC_STAGE/usr/local/lib64/pkgconfig/$pc" > "$PCDIR/$pc"
done
rm -rf "$WORK/pipewire-build"
PKG_CONFIG_PATH="$PCDIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
meson setup "$WORK/pipewire-build" "$SRC/pipewire" \
	--prefix="$WORK/pipewire-prefix" --libdir=lib64 --buildtype=debugoptimized \
	-Dlibcamera=enabled -Ddbus=disabled -Dsystemd=disabled -Dselinux=disabled \
	-Dgstreamer=disabled -Dgstreamer-device-provider=disabled -Dalsa=disabled \
	-Dbluez5=disabled -Djack=disabled -Dv4l2=disabled -Dudev=disabled \
	-Dsdl2=disabled -Dtests=disabled -Dexamples=disabled -Dman=disabled \
	-Ddocs=disabled -Dsession-managers=[]
ninja -C "$WORK/pipewire-build" -j"$(nproc)" spa/plugins/libcamera/libspa-libcamera.so

log "Helpers"
mkdir -p "$WORK/helpers"
cc -O2 -Wall -Wextra -o "$WORK/helpers/sp7-camera-relay" "$ROOT/src/sp7-camera-relay.c"
cc -O2 -Wall -Wextra -o "$WORK/helpers/sp7-camera-client-usage" "$ROOT/src/sp7-camera-client-usage.c"

log "Staging sp7-camera"
L=/usr/local
put() { install -D -m "$1" "$2" "$U$3"; }   # put MODE SRC DEST
mkdir -p "$U$L/lib64" "$U$L/libexec" "$U$L/share" "$U$L/bin"
cp -a "$LC_STAGE$L"/lib64/libcamera*.so* "$LC_STAGE$L/lib64/libcamera" "$U$L/lib64/"
cp -a "$LC_STAGE$L/libexec/libcamera" "$U$L/libexec/"
cp -a "$LC_STAGE$L/share/libcamera" "$U$L/share/"
cp -a "$LC_STAGE$L/bin/cam" "$LC_STAGE$L/bin/libcamerify" "$U$L/bin/"
put 0755 "$WORK/pipewire-build/spa/plugins/libcamera/libspa-libcamera.so" \
	"$L/lib64/spa-0.2/libcamera/libspa-libcamera.so"
put 0755 "$WORK/helpers/sp7-camera-relay"        "$L/libexec/sp7-camera-relay"
put 0755 "$WORK/helpers/sp7-camera-client-usage" "$L/libexec/sp7-camera-client-usage"
put 0755 "$ROOT/src/sp7-camera-controller"       "$L/libexec/sp7-camera-controller"
put 0755 "$ROOT/src/sp7-audio-fix"               "$L/libexec/sp7-audio-fix"
put 0755 "$ROOT/scripts/sp7-wait-dw9719"         "$L/libexec/sp7-wait-dw9719"
put 0755 "$ROOT/scripts/sp7-camera-boot"         "$L/sbin/sp7-camera-boot"
put 0755 "$HERE/sp7-camera-fetch-firmware"       "$L/sbin/sp7-camera-fetch-firmware"
for p in standard hq fast front-standard front-hq; do
	put 0644 "$ROOT/config/profiles/$p.env" "$L/share/sp7-camera/$p.env"
done
put 0644 "$ROOT/config/modprobe.d/ipu4p.conf"            /etc/modprobe.d/ipu4p.conf
put 0644 "$ROOT/config/modprobe.d/sp7-v4l2loopback.conf" /etc/modprobe.d/sp7-v4l2loopback.conf
put 0644 "$ROOT/config/modules-load.d/sp7-v4l2loopback.conf" /etc/modules-load.d/sp7-v4l2loopback.conf
put 0644 "$ROOT/config/udev/60-persistent-v4l.rules"     /etc/udev/rules.d/60-persistent-v4l.rules
mkdir -p "$U/etc/ld.so.conf.d"; echo /usr/local/lib64 > "$U/etc/ld.so.conf.d/sp7-camera.conf"
put 0644 "$ROOT/systemd/system/sp7-camera-boot.service" /usr/lib/systemd/system/sp7-camera-boot.service
put 0644 "$ROOT/systemd/system/sp7-camera-boot.timer"   /usr/lib/systemd/system/sp7-camera-boot.timer
for f in sp7-camera-controller.service sp7-camera-relay@.service sp7-audio-fix.service; do
	put 0644 "$ROOT/systemd/user/$f" "/usr/lib/systemd/user/$f"
done
SPA_SYS="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)/spa-0.2"
for s in pipewire wireplumber; do
	for f in "$ROOT/systemd/user/$s.service.d"/*.conf; do
		mkdir -p "$U/usr/lib/systemd/user/$s.service.d"
		sed "s|/usr/lib64/spa-0.2|$SPA_SYS|" "$f" > "$U/usr/lib/systemd/user/$s.service.d/$(basename "$f")"
	done
done
for f in "$ROOT"/config/wireplumber/wireplumber.conf.d/*.conf; do
	put 0644 "$f" "/usr/share/wireplumber/wireplumber.conf.d/$(basename "$f")"
done
put 0644 "$ROOT/config/wireplumber/scripts/sp7-hide-raw-nodes.lua" \
	/usr/share/wireplumber/scripts/sp7-hide-raw-nodes.lua
mkdir -p "$U/usr/share/doc/sp7-camera"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$U/usr/share/doc/sp7-camera/"
cp -a "$ROOT/patches" "$ROOT/docs/source-bases.txt" "$U/usr/share/doc/sp7-camera/"
(cd "$U" && find etc -type f | sed 's|^|/|' | sort) > "$U/DEBIAN/conffiles"

log "Computing shared-library dependencies"
SHL="$WORK/shlibdeps"; rm -rf "$SHL"; mkdir -p "$SHL/debian"
printf 'Source: sp7-camera\n\nPackage: sp7-camera\nArchitecture: amd64\n' > "$SHL/debian/control"
mapfile -t ELFS < <(find "$U/usr/local" -type f \( -name '*.so*' -o -perm -u+x \) \
	-exec sh -c 'head -c4 "$1" | grep -q ELF && echo "$1"' _ {} \;)
SHLIBS="$(cd "$SHL" && dpkg-shlibdeps -O --ignore-missing-info \
	-l"$U/usr/local/lib64" -xsp7-camera "${ELFS[@]}" 2>/dev/null \
	| sed -n 's/^shlibs:Depends=//p')"
[[ -n "$SHLIBS" ]] || die "dpkg-shlibdeps produced no dependencies"

cat > "$U/DEBIAN/control" <<EOF
Package: sp7-camera
Version: $VERSION-$DEBREV
Architecture: amd64
Maintainer: sp7-camera fork <noreply@localhost>
Depends: sp7-camera-dkms (= $VERSION-$DEBREV), pipewire (>= 1.4), wireplumber (>= 0.5),
 gstreamer1.0-tools, gstreamer1.0-pipewire, gstreamer1.0-plugins-base,
 alsa-utils, v4l-utils, kmod, curl, $SHLIBS
Recommends: sp7-camera-firmware
Section: video
Priority: optional
Homepage: https://github.com/Elefantenjongleur/surface-pro-7-camera
Installed-Size: $(du -sk "$U" | cut -f1)
Description: Surface Pro 7 cameras (rear OV8865 + front OV5693) userspace stack
 Patched libcamera 0.7.2 and PipeWire libcamera SPA, the on-demand controller
 and relays that feed v4l2loopback /dev/video80-84, the delayed IPU4P boot
 loader with a per-device IOMMU identity domain (no iommu=pt needed) and the
 WirePlumber rules that hide the raw libcamera nodes. Installs to /usr/local
 because libcamera's IPA paths are compiled in. The proprietary IPU4P firmware
 is fetched with sp7-camera-fetch-firmware.
EOF
for s in postinst prerm postrm; do
	install -m 0755 "$HERE/maint/sp7-camera.$s" "$U/DEBIAN/$s"
done
fakeroot dpkg-deb --root-owner-group -Zxz -b "$U" "$OUT/sp7-camera_${VERSION}-${DEBREV}_amd64.deb"

# ======================================================= firmware package ====
if [[ "$WITH_FW" -eq 1 ]]; then
	log "Firmware (local use only - do not publish)"
	F="$WORK/stage/sp7-camera-firmware"; rm -rf "$F"; mkdir -p "$F/DEBIAN"
	FW="$WORK/ipu4-20191030.bin"
	if [[ -f /usr/lib/firmware/ipu4p_cpd.bin ]] &&
	   echo "$FIRMWARE_SHA256  /usr/lib/firmware/ipu4p_cpd.bin" | sha256sum -c - >/dev/null 2>&1; then
		cp /usr/lib/firmware/ipu4p_cpd.bin "$FW"
	else
		curl -fL --retry 3 -o "$FW" \
			"https://media.githubusercontent.com/media/ruslanbay/ipu4-drivers/$FIRMWARE_COMMIT/firmware/ipu4-20191030.bin"
	fi
	echo "$FIRMWARE_SHA256  $FW" | sha256sum -c -
	install -D -m 0644 "$FW" "$F/usr/lib/firmware/ipu4p_cpd.bin"
	cat > "$F/DEBIAN/control" <<EOF
Package: sp7-camera-firmware
Version: 20191030-$DEBREV
Architecture: all
Maintainer: sp7-camera fork <noreply@localhost>
Section: non-free-firmware/kernel
Priority: optional
Installed-Size: $(du -sk "$F/usr" | cut -f1)
Description: Intel IPU4P firmware for the Surface Pro 7 cameras (local build)
 ipu4-20191030.bin from ruslanbay/ipu4-drivers@$FIRMWARE_COMMIT,
 installed as /usr/lib/firmware/ipu4p_cpd.bin. Proprietary; not redistributable.
EOF
	fakeroot dpkg-deb --root-owner-group -Zxz -b "$F" "$OUT/sp7-camera-firmware_20191030-${DEBREV}_all.deb"
fi

(cd "$OUT" && sha256sum sp7-camera-dkms_${VERSION}-${DEBREV}_all.deb sp7-camera_${VERSION}-${DEBREV}_amd64.deb > SHA256SUMS)
[[ "$KEEP" -eq 1 ]] || rm -rf "$WORK/stage" "$WORK/libcamera-build" "$WORK/pipewire-build" "$WORK/libcamera-stage"
log "Done"; ls -l "$OUT"
