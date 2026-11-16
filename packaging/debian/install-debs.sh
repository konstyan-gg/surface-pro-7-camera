#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Install the sp7-camera .deb packages on Debian 13 + linux-surface.
#
#   ./install-debs.sh [DIR]   DIR holds the .deb files (default: ./out, else .)
#
# Moves per-user copies left by install.sh out of the way (they would load
# the WirePlumber component twice), installs the debs with apt (pulls in
# dependencies), and fetches the IPU4P firmware if no firmware deb is given.
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-}"
if [[ -z "$DIR" ]]; then
	if compgen -G "$HERE/out/sp7-camera_*.deb" >/dev/null; then DIR="$HERE/out"; else DIR="$PWD"; fi
fi
DIR="$(cd -- "$DIR" && pwd)"

shopt -s nullglob
DEBS=("$DIR"/sp7-camera-dkms_*_all.deb "$DIR"/sp7-camera_*_amd64.deb "$DIR"/sp7-camera-firmware_*_all.deb)
[[ ${#DEBS[@]} -ge 2 ]] || { echo "No sp7-camera .deb files in $DIR" >&2; exit 1; }

if [[ -f "$DIR/SHA256SUMS" ]]; then
	(cd "$DIR" && sha256sum --ignore-missing -c SHA256SUMS)
fi

[[ -e /lib/modules/$(uname -r)/build/Makefile ]] || {
	echo "Kernel headers for $(uname -r) are missing:" >&2
	echo "    sudo apt install linux-headers-surface" >&2
	exit 1
}

BK="$HOME/.local/state/sp7-camera/pre-deb-$(date +%Y%m%d-%H%M%S)"
for f in \
	"$HOME"/.config/systemd/user/sp7-camera-controller.service \
	"$HOME"/.config/systemd/user/sp7-camera-relay@.service \
	"$HOME"/.config/systemd/user/sp7-audio-fix.service \
	"$HOME"/.config/systemd/user/default.target.wants/sp7-*.service \
	"$HOME"/.config/systemd/user/pipewire.service.d/*sp7*.conf \
	"$HOME"/.config/systemd/user/wireplumber.service.d/*sp7*.conf \
	"$HOME"/.config/wireplumber/wireplumber.conf.d/*sp7*.conf \
	"$HOME"/.local/share/wireplumber/scripts/sp7-hide-raw-nodes.lua
do
	[[ -e "$f" || -L "$f" ]] || continue
	mkdir -p "$BK"; mv -v "$f" "$BK/"
done
for f in /etc/systemd/system/sp7-camera-boot.service /etc/systemd/system/sp7-camera-boot.timer; do
	[[ -e "$f" ]] || continue
	sudo systemctl disable "$(basename "$f")" 2>/dev/null || true
	sudo mkdir -p /var/lib/sp7-camera/pre-deb
	sudo mv -v "$f" /var/lib/sp7-camera/pre-deb/
done

sudo apt-get update
sudo apt-get install -y "${DEBS[@]}"
sudo /usr/local/sbin/sp7-camera-fetch-firmware

dkms status sp7-camera || true
systemctl --user daemon-reload || true
echo
echo "Installed. Reboot; the cameras appear during boot as /dev/video80-84."
