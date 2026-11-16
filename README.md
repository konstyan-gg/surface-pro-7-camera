# Surface Pro 7 Camera for Linux (Debian fork)

Repository: <https://github.com/konstyan-gg/surface-pro-7-camera>

Experimental camera support for the rear OV8865 and front OV5693 RGB
cameras of the Microsoft Surface Pro 7.

This is a fork of
[Elefantenjongleur/surface-pro-7-camera](https://github.com/Elefantenjongleur/surface-pro-7-camera).
It adds Debian 13 support, Secure Boot support through DKMS, `.deb`
packages, and fixes for problems found while getting the front camera,
PipeWire and V4L2 applications to work on Debian. The upstream Fedora
`install.sh` path still works.

## What this fork changes

| Area | Change |
| --- | --- |
| Packaging | `sp7-camera-dkms` (kernel modules, rebuilt for every kernel) and `sp7-camera` (userspace) `.deb` packages; `packaging/debian/` |
| Secure Boot | Modules are signed with the DKMS MOK key instead of refusing to install |
| IOMMU | `sp7-camera-boot` puts only the IPU's IOMMU group (`0000:00:05.0`) into identity mode before loading IPU4P. Without it the IPU's raw-physical DMA is blocked by VT-d and CSE firmware authentication fails. **No `iommu=pt` kernel parameter and no GRUB change are needed.** |
| Boot timing | `sp7-camera-boot.service` loads the IPU4P stack right after udev coldplug (about 11 s into boot); the old 30 s timer is gone, since the CSE auth failures it worked around were caused by the IOMMU |
| udev | `60-persistent-v4l.rules` skips `v4l_id` on the ~50 raw IPU ISYS nodes (they could hang in D state) |
| Front camera, kernel | `patches/ipu4/0002-sp7-front-fw-recycle.patch`: firmware-context recycle before every front (source 7) start; fixes `can't open stream (-1)` after the first PipeWire use |
| Front camera, libcamera | `patches/libcamera/0002-sp7-front-camera.patch`: front sensor enabled, VFLIP limited to OV8865, OV5693 forced to the reliable 2592x1944 mode (the binned 1296x972 mode gave CSI "Frame sync error"), CPU-debayer prescale to 1292x972 |
| Front camera, PipeWire | `patches/pipewire/0002-sp7-front-camera-profiles.patch`: `front-standard` / `front-hq` libcamera profiles |
| PipeWire | The pipewire daemon gets the same `SPA_PLUGIN_DIR` drop-ins as WirePlumber (it hosts the libcamera nodes) |
| WirePlumber | `sp7-hide-raw-nodes.lua` hides the raw `sp7.*` libcamera nodes from applications. Apps that switched to them raced the controller for the IPU and could wedge the front sensor until reboot |
| Relay profiles | Integer frame rates in `config/profiles/*.env` (30/1, 14/1, 60/1). The fractional rates made PipeWire's clock run backwards and froze `(V4L2)` streams after 1–2 frames |
| v4l2loopback | `max_buffers=8` |

## Status

Tested working on this fork:

- Microsoft Surface Pro 7 (without Plus)
- Debian 13 "trixie", linux-surface kernel 6.19.8-surface-3, Secure Boot on
- rear OV8865 (Standard, HQ, Fast) and front OV5693 (Standard, HQ)
- PipeWire 1.4 / WirePlumber 0.5, GNOME Snapshot, V4L2 apps via /dev/video80-84

Upstream tested Fedora Workstation 43 with kernel 6.19.8-3.surface.fc43.

This is experimental hardware support, not a generic Surface camera
driver.

## Camera profiles

| Profile | Output | Rate | V4L2 device |
| --- | --- | ---: | --- |
| Rear Standard | 1628x1224 | 30 fps | /dev/video80 |
| Rear HQ | 3260x2448 | 14 fps | /dev/video81 |
| Rear Fast | 1404x792 | 60 fps | /dev/video82 |
| Front Standard | 1292x972 | ~30 fps | /dev/video83 |
| Front HQ | 2588x1944 | 25 fps | /dev/video84 |

In PipeWire, applications see the five cameras as "… (V4L2)" nodes. The
rear and front cameras share the IPU, so only one physical stream runs at
a time.

## Architecture

    OV8865 rear / OV5693 front
      -> Intel IPU4P (kernel, DKMS)
      -> libcamera SimplePipeline + CPU SoftISP (patched, /usr/local)
      -> PipeWire libcamera SPA (patched)
      -> SP7 on-demand controller (gst-launch-1.0 pipelines)
      -> idle relay -> v4l2loopback /dev/video80 ... /dev/video84
      -> application (directly, or through PipeWire's V4L2 monitor)

The controller starts a real camera stream only when a client actually
opens one of the virtual cameras.

## Installation from binary packages (Debian 13)

Prebuilt packages are attached to the [GitHub releases](https://github.com/konstyan-gg/surface-pro-7-camera/releases) of this fork:

| File | Contents |
| --- | --- |
| `sp7-camera-dkms_<ver>_all.deb` | Kernel module **sources**; DKMS builds and signs them for each installed kernel |
| `sp7-camera_<ver>_amd64.deb` | Patched libcamera 0.7.2, PipeWire libcamera SPA, controller/relays, boot loader, modprobe/udev/WirePlumber/systemd config |
| `install-debs.sh`, `SHA256SUMS` | Installer and checksums |

The proprietary Intel IPU4P firmware is **not** in the packages. The
installer downloads it from its pinned upstream commit and checks its
SHA-256 (`sp7-camera-fetch-firmware`).

### 1. Prerequisites

1. Debian 13 (amd64) on a Surface Pro 7.
2. The [linux-surface](https://github.com/linux-surface/linux-surface/wiki/Installation-and-Setup#debian--ubuntu)
   kernel, **booted**, with its headers:

       sudo apt install linux-image-surface linux-headers-surface

   The module sources are from the 6.19 kernel series. On much newer
   kernels the DKMS build can fail (see [Troubleshooting](#troubleshooting)).

### 2. Install

    mkdir sp7 && cd sp7
    for f in sp7-camera-dkms_0.2.2-1_all.deb sp7-camera_0.2.2-1_amd64.deb install-debs.sh SHA256SUMS; do
        curl -fLO https://github.com/konstyan-gg/surface-pro-7-camera/releases/download/v0.2.2/$f
    done
    sha256sum -c SHA256SUMS
    bash install-debs.sh .

`install-debs.sh` moves the per-user files from an earlier `install.sh`
run to `~/.local/state/sp7-camera/`, installs both packages with
`apt` (which pulls in dkms, the build toolchain, PipeWire/GStreamer
tools and libraries), and installs the firmware.

Doing it by hand instead:

    sudo apt install ./sp7-camera-dkms_*_all.deb ./sp7-camera_*_amd64.deb
    sudo /usr/local/sbin/sp7-camera-fetch-firmware

### 3. Secure Boot

DKMS signs the modules with `/var/lib/dkms/mok.key` (created on first
use). If Secure Boot is on and that key is not yet enrolled, the
installation prints a warning. Then:

    sudo mokutil --import /var/lib/dkms/mok.pub    # choose a one-time password
    sudo reboot                                    # MokManager: Enroll MOK -> enter password

Tip for reinstalling the same machine: MOK enrollments are stored in the
UEFI firmware and survive an OS reinstall. Back up
`/var/lib/dkms/mok.key` and `mok.pub`, and put them back before installing
the packages to skip re-enrollment.

### 4. Reboot

    sudo reboot

`sp7-camera-boot.service` loads the IPU4P stack during boot. Check:

    systemctl status sp7-camera-boot.service
    ls /dev/video8[0-4]
    systemctl --user status sp7-camera-controller.service

No GRUB or kernel command-line change is needed.

### Updates and removal

Kernel updates: DKMS rebuilds and signs the modules automatically.

    sudo apt remove sp7-camera sp7-camera-dkms        # remove
    sudo rm /usr/lib/firmware/ipu4p_cpd.bin           # optional

## Building from source

### Option A: build the .deb packages (recommended on Debian)

Build dependencies (Debian 13):

    sudo apt install git curl build-essential dpkg-dev fakeroot pkgconf \
        meson ninja-build python3-yaml python3-ply python3-jinja2 openssl \
        libyaml-dev libevent-dev libudev-dev libssl-dev libdw-dev \
        libunwind-dev libjpeg-dev libtiff-dev libsdl2-dev libdrm-dev \
        libegl-dev libgles-dev libglib2.0-dev libdbus-1-dev

Build:

    packaging/debian/build-debs.sh                   # -> packaging/debian/out/
    packaging/debian/build-debs.sh --with-firmware   # also sp7-camera-firmware deb (local use only)

The script fetches every upstream source at the commit pinned in
`install.sh` / `docs/source-bases.txt` (Linux v6.19.8 kernel files via
sparse checkout, sp7-ipu4-camera, v4l2loopback v0.15.4, libcamera
v0.7.2, PipeWire 1.4.11), applies `patches/*/*.patch` in order, builds
libcamera and the PipeWire libcamera SPA, and assembles the packages.
Package dependencies come from `dpkg-shlibdeps`, so a build on another
Debian-based release gets correct library dependencies. The kernel
modules are compiled later by DKMS on the target machine.

Then install with `packaging/debian/install-debs.sh` (it uses
`packaging/debian/out/` by default).

Do not publish the `sp7-camera-firmware` package: the firmware is not
redistributable.

To release: bump `packaging/debian/VERSION`, run `build-debs.sh`, and
attach `out/sp7-camera-dkms_*.deb`, `out/sp7-camera_*.deb`,
`out/SHA256SUMS` and `packaging/debian/install-debs.sh` to a GitHub
release.

### Option B: upstream installer (builds and installs directly)

For the tested Fedora configuration:

    ./check-system.sh
    ./install.sh

On other distributions, including Debian, install the build dependencies
first, then:

    ./check-system.sh --allow-untested-distro
    ./install.sh --allow-untested-distro

This builds the modules for the running kernel only and installs them to
`/lib/modules/$(uname -r)/updates/extra` (signed with
`/var/lib/dkms/mok.key` when Secure Boot is on). Rerun it after every
kernel update. Per-user configuration goes to `~/.config`.

`./install.sh --build-only --allow-untested-distro` builds everything
without installing anything.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No /dev/video80-84 | `journalctl -b -u sp7-camera-boot`; `dkms status sp7-camera`; `sudo dmesg \| grep -i -e ipu -e cse` |
| `Key was rejected by service` | MOK key not enrolled (see Secure Boot) |
| `CSE boot_load failed` / DMAR faults on 00:05.0 | IOMMU identity switch failed; see the boot log. Fallback: add `iommu=pt` to `GRUB_CMDLINE_LINUX_DEFAULT` and run `sudo update-grub` |
| DKMS build fails on a new kernel | `/var/lib/dkms/sp7-camera/<ver>/build/make.log`; boot the 6.19 surface kernel or port the patches |
| `(V4L2)` camera shows a frozen picture | Make sure `/usr/local/share/sp7-camera/*.env` have integer `FPS_NUM`/`FPS_DEN` |
| Camera stuck after an error | Reboot. **Never `rmmod` / reload the IPU modules live**; that wedges the IPU |

## Source bases

The exact upstream commits are recorded in:

    docs/source-bases.txt

The release currently uses:

- Linux stable 6.19.8 source base
- the SP7 IPU4P driver source base recorded in docs/source-bases.txt
- libcamera source base recorded in docs/source-bases.txt
- PipeWire 1.4.11 (only the libcamera SPA plugin is built and used)
- v4l2loopback v0.15.4 without local source modifications

v4l2loopback already contains the CLIENT_USAGE private event used by
the on-demand controller. No v4l2loopback source patch is required.

## Known limitations

### Front IR camera

The validated front-camera support covers the OV5693 RGB camera. The
separate front IR camera is outside the scope of this project.

### One physical stream

The rear OV8865 and front OV5693 share the IPU camera resources. The
five V4L2 cameras are therefore virtual profiles, not five
simultaneously usable physical streams.

The on-demand controller arbitrates globally between all five V4L2
profiles. The most recent client-usage transition selects the active
physical camera profile.

### Snapshot and Signal at the same time

The V4L2 controller does not control native PipeWire/libcamera clients.
Nevertheless, simultaneous GNOME Snapshot and Signal operation was
successfully tested in the final validation.

This does not imply that independent rear and front physical sensor
streams can run concurrently.

### Autofocus

Continuous contrast-detection autofocus is implemented and works, but
it is still relatively slow.

### Automatic exposure

Automatic exposure works, but adaptation can also be slow.

### Fast profile

The Fast profile is intended primarily for good lighting. Low-light
colour reproduction is currently worse than Standard and HQ.

### Signal preview

Signal may mirror the local preview because the v4l2loopback devices
appear as generic webcams. The camera pipeline itself does not apply a
horizontal flip.

## Internal microphone

The Surface Pro 7 uses a Realtek ALC274 audio codec. On the tested Fedora 43
system, the internal microphone was initialized with `Internal Mic Boost` at
`+30 dB`, causing severe clipping and distorted voice recordings even though
applications reported an input level of 100%.

The installer includes `sp7-audio-fix.service`, which sets the ALC274
`Internal Mic Boost` control to `0 dB` and the hardware playback `Master`
control to `100%` / `0 dB` / unmuted through the stable ALSA card ID `PCH`.
The normal `Capture`, `Digital`, `Speaker` and `PCM` controls are left
untouched.

Testing showed that WirePlumber/ACP can raise `Internal Mic Boost` back to
`+30 dB` when the ALSA device is initialized and the PipeWire source volume
is restored to 100%. The installer therefore also installs a WirePlumber
rule for the Surface Pro 7 audio device with
`api.alsa.soft-mixer = true`.

This keeps PipeWire volume and mute handling in software instead of mapping
them back onto the ALC274 hardware mixer. The known-good hardware values can
therefore remain at `Internal Mic Boost = 0 dB`, `Master = 0 dB`,
`Capture = +30 dB` and `Digital = 0 dB` while PipeWire can independently
control the normal software playback and microphone volumes.

Because WirePlumber/ACP initializes the ALSA device asynchronously,
starting `sp7-audio-fix.service` after `wireplumber.service` alone is not
sufficient. The helper therefore waits until the internal PipeWire capture
source `alsa_input.pci-0000_00_1f.3.analog-stereo` is available, allows a
short settling period, and only then sets `Internal Mic Boost` to `0 dB`.
This avoids the boot-time race in which ACP could otherwise restore the
hardware boost after the fix had already run.

The helper is deliberately non-fatal if the expected ALSA card or mixer
control is not present.

The tagged camera reference
`sp7-camera-five-profile-final-2026-09-29` predates this audio fix and remains
unchanged.

### GNOME Snapshot video recording

Camera preview, still photos and camera switching work correctly in GNOME
Snapshot. Video recording is visibly strongly compressed, particularly with
the high-resolution camera profiles.

Current GNOME Snapshot/Aperture code uses a default video encoder bitrate of
2048 kbit/s. This is low for the resolutions provided by this project and
provides a plausible explanation for the visible compression. Applications
using the V4L2 devices directly are not limited to Snapshot's recording
bitrate.

## Release policy

Version 0.1.x deliberately preserves the code that was tested on the
known-good machine, including some diagnostic logging.

Cleanup and refactoring should be separate changes and should be
re-tested before becoming part of a later release.

## Repository layout

    config/             Runtime configuration (modprobe, udev, WirePlumber, relay profiles)
    docs/               Source bases and technical documentation
    packaging/debian/   .deb build script, DKMS files, maintainer scripts, installer
    patches/            Kernel, IPU4, libcamera and PipeWire source deltas (applied in order)
    scripts/            System helper scripts
    src/                SP7 controller and relay sources
    systemd/            System and user services, PipeWire/WirePlumber drop-ins

## Safety

The camera kernel modules are tied to a specific kernel ABI.

Do not install modules built for another kernel.

The known-good installer configuration is:

    Fedora Workstation 43
    6.19.8-3.surface.fc43.x86_64

With the Debian packages, DKMS builds the modules for each installed
kernel and signs them with the DKMS MOK key.

The default install.sh path refuses untested distribution/kernel combinations.
With --allow-untested-distro, experienced users can deliberately test
other combinations. The Surface Pro 7 hardware check, x86_64
requirement, IPU4P check and matching kernel build tree remain enforced.
Under Secure Boot the modules are signed with /var/lib/dkms/mok.key.

External modules are built for the running kernel and their vermagic is
checked before installation.

## Credits

Upstream project: [Elefantenjongleur/surface-pro-7-camera](https://github.com/Elefantenjongleur/surface-pro-7-camera).
IPU4P driver base: [georgemihaila/sp7-ipu4-camera](https://github.com/georgemihaila/sp7-ipu4-camera).
Firmware: [ruslanbay/ipu4-drivers](https://github.com/ruslanbay/ipu4-drivers).
See LICENSE for the multi-license terms of this repository.
