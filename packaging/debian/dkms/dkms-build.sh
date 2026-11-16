#!/bin/sh
# Build every SP7 camera module for one kernel. Called by dkms as:
#   sh ./dkms-build.sh <kernelver> <kernel_source_dir>   (build)
#   sh ./dkms-build.sh clean
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IPU4_SRC="$HERE/ipu4/linux-6.19.8/drivers/media/pci/intel"

if [ "${1:-}" = clean ]; then
	for d in "$HERE/kmod" "$IPU4_SRC" "$HERE/v4l2loopback"; do
		find "$d" \( -name '*.o' -o -name '*.ko' -o -name '*.mod' -o -name '*.mod.c' \
			-o -name '.*.cmd' -o -name 'modules.order' -o -name 'Module.symvers' \
			-o -name '*.mod.o' \) -delete 2>/dev/null || true
	done
	exit 0
fi

KVER=${1:?kernel version}
KDIR=${2:-/lib/modules/$KVER/build}
JOBS=${parallel_jobs:-$(nproc)}

# 1. OV8865 sensor, DW9719 VCM, IPU bridge (patched copies from linux v6.19.8)
make -C "$KDIR" M="$HERE/kmod" -j"$JOBS" modules

# 2. IPU4P stack (same flags as scripts/build-modules.sh upstream; -j1 as there)
make -C "$KDIR" M="$IPU4_SRC" EXTERNAL_BUILD=1 srcpath="$IPU4_SRC" \
	CONFIG_VIDEO_INTEL_IPU=m CONFIG_VIDEO_INTEL_IPU4P=y \
	CONFIG_VIDEO_INTEL_IPU6= CONFIG_VIDEO_IPU3_CIO2= CONFIG_INTEL_VSC= \
	CONFIG_VIDEO_INTEL_IPU_FW_LIB=y -j1 modules

# 3. v4l2loopback 0.15.4, upstream unmodified
make -C "$HERE/v4l2loopback" KERNELRELEASE="$KVER" KERNEL_DIR="$KDIR" \
	-j"$JOBS" v4l2loopback.ko
