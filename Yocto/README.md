# Yocto / EDF builds

This folder builds the Linux image of the **host** of the MIPI over Chip2Chip reference
design, the AMD ZCU106 (target `zcu106`), using the AMD Yocto / Embedded Development
Framework (EDF) flow — the announced successor to PetaLinux Tools. The other half of the
system, the processor-less AUBoard 15P (target `auboard`), has no software: it is not a Linux
target and nothing is built for it here.

The board support package (`bsp/zcu106/`) is complete. `./build.sh yocto --target zcu106`
produces a bootable image whose Linux brings up the board Ethernet port and SSH, provides the
tools that check the Chip2Chip link, and **starts the two remote camera pipelines on the AUBoard
15P by itself** — see `bsp/zcu106/meta-user/recipes-apps/c2c-cameras/` and
`docs/source/linux_cameras.md`. It can also show both camera streams on a DisplayPort monitor
attached to the ZCU106 (`recipes-apps/c2c-display/`, `docs/source/display.md`); that one is
**off by default**.

The host has a bare-metal application as well (`Vitis/`, `./build.sh standalone --target
zcu106`, `docs/source/baremetal.md`). It is independent of this flow and needs no Linux
build host.

## How it works: the parse-sdt flow

The build generates a **custom Yocto MACHINE directly from the Vivado XSA** —
there is no dependency on an AMD-provided machine config, and a change of the PS
configuration in Vivado flows through automatically:

```
XSA  --sdtgen-->  System Device Tree  --gen-machineconf parse-sdt-->  MACHINE + DTS
```

`scripts/configure-build.sh` runs `xsct`/`sdtgen` on the XSA to produce a
System Device Tree (which includes `pl.dtsi`, the PL hardware extracted from
the design), then runs `gen-machineconf parse-sdt` to emit
`conf/machine/c2c-zcu106.conf` plus the lopper-pruned per-domain device
trees (`cortexa53-linux.dts` on this ZynqMP board). Because no PL overlay is
requested, the Vivado boot artifact (the `.bit`) is embedded into `BOOT.BIN`
(the FSBL programs the PL at boot, before Linux comes up).

The XSA of the ZCU106 only describes the hardware of the ZCU106. The video
pipelines live in the other FPGA, behind the AXI Chip2Chip link, so they do not
appear in the generated device tree — and they must not be in the base device
tree either, because their drivers touch remote registers in probe and such an
access hangs the CPU while the link is down. They are a **run-time device-tree
overlay** instead (`overlays/c2c-cams.dtso`), applied after a link check by
`c2c-cameras.service`. `bsp/zcu106/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`
carries only the fixups of the ZCU106 itself.

## Prerequisites

Host packages on Ubuntu 22.04 / 24.04:

```
sudo apt-get install repo gawk wget git diffstat unzip texinfo gcc \
    build-essential chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    python3-subunit zstd liblz4-tool file locales libacl1 bmap-tools
```

Plus Vivado 2025.2 (used to produce the XSA this flow consumes) and Vitis
2025.2 — `sdtgen`/`xsct` (used to turn the XSA into a System Device Tree)
ship with Vitis, not Vivado, in 2025.2. The build runner locates and sources
the Vitis environment itself; sourcing it manually is only needed when
running the `scripts/` engine by hand:

```
source <xilinx-install>/2025.2/Vitis/settings64.sh
```

## Build

Yocto images are built with the cross-platform build runner at the repo root
(this stage requires a native Linux machine; on Windows the runner refuses
it up front and prints the hand-off command):

```
./build.sh yocto --target zcu106
```

The runner builds the Vivado XSA first if one isn't already present, then
sequences the four scripts in `scripts/` — the engine of the flow
(init-workspace, configure-build, build-image, package-output; a fifth,
`hostfix.sh`, is sourced by the two that run bitbake and works around host
tools that break bitbake's fakeroot — see `docs/source/yocto.md`).

The first build for a target:

1. Builds the Vivado project and exports the XSA if one isn't already
   present.
2. Initializes a manifest workspace under `Yocto/<TARGET>/` with
   `repo init -u https://github.com/Xilinx/yocto-manifests.git -b rel-v2025.2 -m default-edf.xml`
   and `repo sync` (≈5 GB of git history).
3. Sources `edf-init-build-env` to set up the bitbake environment.
4. Generates the System Device Tree from the XSA and runs
   `gen-machineconf parse-sdt` to create `MACHINE = "c2c-<target>"`
   (gen-machineconf builds its own native helpers — `kconfig-frontends-native`,
   `lopper`, etc. — via bitbake on first run).
5. Layers `bsp/<board>/conf/local.conf.append` and `bsp/<board>/meta-user/`
   (kernel config, `system-user.dtsi`, image bbappend) over the EDF default config.
6. Runs `bitbake edf-linux-disk-image`.
7. Gathers `BOOT.BIN` (with the PL bitstream embedded), `Image`, `system.dtb`,
   `boot.scr`, `u-boot.elf`, `rootfs.tar.gz`, `rootfs.wic.xz`, and
   `rootfs.wic.bmap` into `Yocto/<TARGET>/images/linux/`.

Subsequent builds skip `repo sync`. To force a re-config (e.g. after editing
`bsp/<board>/conf/local.conf.append`), remove `Yocto/<TARGET>/configdone.txt`.

`./build.sh status --target all` reports what has been built. Only the `zcu106` target has
a Yocto flow; the runner skips the Yocto stage of the `auboard` target.

## Board support package (`bsp/zcu106/`)

It follows the layout of the other Opsero reference designs: `bsp/zcu106/conf/local.conf.append`
for the board overrides, and the Yocto layer `bsp/zcu106/meta-user/`.

```
bsp/zcu106/
  conf/local.conf.append                board overrides appended to the generated local.conf
  deploy/                               first deployment over JTAG + Ethernet (see
                                        docs/source/deploy.md): prepare_serve.sh,
                                        jtag_boot_ramdisk.tcl, jtag_ramdisk.cmd, deploy_sd.sh
  meta-user/
    conf/layer.conf
    recipes-bsp/device-tree/            system-user.dtsi: console on ttyPS0, the DP83867 PHY of
                                        GEM3 with a fixed MAC, /chosen/bootargs (cma=1024M and
                                        xlnx_mixer.connect_drm_bridge=1), the xlnx,fclk nodes
                                        that keep pl_clk0 and pl_clk1 enabled, and the display
                                        path's OF graph (mixer -> dpsub -> dp-connector, psgtr)
    recipes-kernel/linux/               bsp.cfg: V4L2 / media controller, the AMD video pipeline
                                        drivers, IMX219, run-time overlays (OF_OVERLAY,
                                        OF_CONFIGFS), the Xilinx INTC as a platform driver;
                                        plus the three DRM patches the v_mix -> zynqmp-dpsub
                                        bridge pipeline needs
    recipes-apps/c2c-tools/             c2c-link-status, c2c-peek, c2c-poke, c2c-overlay,
                                        c2c-latency + the shared c2c-functions.sh
    recipes-apps/c2c-cameras/           compiles ../../../../../overlays/c2c-cams.dtso and ships
                                        it with c2c-cameras.service, which brings the remote
                                        cameras up at boot (see below), plus the udev rules that
                                        give the stable /dev/video-cam0 / /dev/video-cam2 names
    recipes-apps/c2c-display/           c2c-display + its unit and /etc/default file: the two
                                        camera streams on the ZCU106's DisplayPort output.
                                        Shipped DISABLED (see docs/source/display.md)
    recipes-core/images/                the package list of the image
```

### `c2c-cameras`: one source of truth for the overlay

The overlay source `overlays/c2c-cams.dtso`, its build script `overlays/build-overlay.sh` and
the pipeline init script `overlays/init_c2c_cams.sh` exist **once** in this repository. The
recipe does not copy them into the layer; it points the bitbake fetcher at `Yocto/overlays/`
with a path relative to the recipe:

```
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../../../overlays:"
```

so the image is built from the very files a developer edits and tests by hand. The path is
inside the repository and uses no symlinks (it survives a fresh clone and a source export), and
bitbake hashes the contents of every fetched file, so editing the `.dtso` rebuilds the recipe
and the image. `do_compile` runs `build-overlay.sh` itself with `OUT_DIR` in the work directory,
which single-sources the compiler flags as well — a host build and the image build produce a
byte-identical `.dtbo`.

What the service does on the board is documented in `docs/source/linux_cameras.md`; it is
configured through `/etc/default/c2c-cameras`.

## Flashing to SD card

The build produces a full wic disk image (`rootfs.wic.xz`). Flash it to the SD
card's raw device; per-partition file copies do **not** work because the boot
script boots from the device it finds itself on.

The ZCU106 is a Zynq UltraScale+ target, which uses the 4-partition EDF layout —
`esp` (vfat), `boot` (ext4), `root` (ext4), `storage` (vfat). The EDF wks
leaves the `esp` partition empty, and `BOOT.BIN` is installed onto the ext4
`boot` partition (which the BootROM cannot read). The BootROM reads `BOOT.BIN`
from the first FAT partition (`esp`) — so after flashing you must drop
`BOOT.BIN` onto `esp` by hand (step 4 below). The kernel command line mounts
the rootfs from `/dev/mmcblk0p3`.

### 1. Identify the SD card device — carefully

This is the step that will eat one of your hard drives if you get it wrong.
`dd`-style writes to a block device cannot be undone.

With the SD card **un**plugged, list the block devices and note what's there:

```
lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT
```

Now insert the SD card and re-run the same command. The new entry (typically
`/dev/sdX`, with `RM=1` for removable, and a size that matches your card) is
your target. Confirm with:

```
udevadm info --query=property --name=/dev/sdX | grep -E "ID_BUS|ID_MODEL"
```

`ID_BUS=usb` and a model like `SDXC/MMC` or your card-reader's name is what you
want to see. **Do not proceed until you are certain `/dev/sdX` is your SD card
and not an internal disk.** Throughout the rest of this section, replace `sdX`
with the actual device letter, and `<TARGET>` with your board.

### 2. Unmount any auto-mounted partitions

```
for p in /dev/sdX?*; do sudo umount "$p" 2>/dev/null; done
```

### 3. Flash the wic image to the raw device

Preferred: `bmaptool` only writes the blocks that are actually used, so it
finishes in a minute or two on a fast card:

```
sudo bmaptool copy \
    --bmap Yocto/<TARGET>/images/linux/rootfs.wic.bmap \
          Yocto/<TARGET>/images/linux/rootfs.wic.xz \
          /dev/sdX
```

Fallback (slower, writes every block):

```
xzcat Yocto/<TARGET>/images/linux/rootfs.wic.xz \
    | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

### 4. Install BOOT.BIN on the esp partition

```
sudo partprobe /dev/sdX
```

Most desktops will now expose `/media/<you>/esp` (and `boot`, `root`,
`storage`). Copy `BOOT.BIN` onto `esp`:

```
cp Yocto/<TARGET>/images/linux/BOOT.BIN /media/<you>/esp/BOOT.BIN
sync
```

If your desktop didn't auto-mount, mount `esp` (the first partition) manually:

```
sudo mkdir -p /mnt/sd_esp
sudo mount /dev/sdX1 /mnt/sd_esp
sudo cp Yocto/<TARGET>/images/linux/BOOT.BIN /mnt/sd_esp/BOOT.BIN
sync
sudo umount /mnt/sd_esp && sudo rmdir /mnt/sd_esp
```

### 5. Eject and boot

Eject the card cleanly (`sudo eject /dev/sdX`) so pending writes flush. Insert
it into the ZCU106, set the boot mode switches to SD and attach a UART terminal
at 115200 8N1. The AUBoard 15P must be configured with its bitstream and the SFP+
cable must be connected before Linux accesses the remote video pipelines.

## Offline / faster builds

Place the absolute path to a directory containing an extracted AMD sstate-cache
mirror in `Yocto/offline.txt` — `configure-build.sh` auto-detects which
architecture subdirs exist under it and wires one `SSTATE_MIRRORS` entry per
arch (plus `SOURCE_MIRROR_URL` if a `downloads/` dir is present).

Expected layout under that path:

```
<sstate root>/
  aarch64/           (ZynqMP Linux)
  microblaze/        (the PMU firmware multiconfig)
  downloads/         (optional — the source-mirror tarballs)
```

Both `aarch64` and `microblaze` are needed: the generated MACHINE builds the
PMU firmware as a MicroBlaze multiconfig. The sstate-cache and downloads
archives are available behind login at the AMD Embedded Design Tools download
page under "sstate-cache & Downloads - 2025.2".

A warm sstate-cache typically gives a high hit rate; because each target uses a
distinct generated MACHINE name, the machine-specific recipes still rebuild
(architecture-level recipes hit the cache), so a first build is moderate rather
than from-scratch.

## Layout

```
Yocto/
  README.md                 this file
  .gitignore                excludes per-target workspaces + local state
  offline.txt               (optional, gitignored) path to an extracted sstate mirror
  scripts/
    init-workspace.sh       repo init + sync
    configure-build.sh      sdtgen + gen-machineconf parse-sdt + apply BSP + sstate
    build-image.sh          bitbake the image recipe
    package-output.sh       gather deploy artifacts into images/linux/
    hostfix.sh              host-tool workarounds, sourced by the two scripts that
                            run bitbake; a no-op on a host that needs none
  overlays/                 the run-time device-tree overlay of the remote camera
                            pipelines: c2c-cams.dtso (the ONE copy), build-overlay.sh,
                            init_c2c_cams.sh. The c2c-cameras recipe builds these.
  bsp/
    zcu106/                 the BSP of the host board (see above)
      conf/
        local.conf.append   board overrides
      deploy/               first deployment over JTAG + Ethernet
      meta-user/            Yocto layer: kernel cfg + DRM patches, system-user.dtsi,
                            c2c-tools, c2c-cameras, c2c-display, image bbappend
  <TARGET>/                 (gitignored) per-target workspace made by the build.
                            hostfix/bin/ appears here when scripts/hostfix.sh has
                            to give bitbake a working host tool -- it is created
                            automatically (docs/source/yocto.md).
  tools/                    (gitignored) helper checkouts
  logs/                     (gitignored) build logs
```

## Architectural notes

* **The MACHINE is generated from the XSA** by `gen-machineconf parse-sdt`
  (the flow AMD recommends; `parse-xsa` is deprecated). This is the only
  build flow — there is no pinned AMD-validated MACHINE and no per-target
  flow selection. The custom machine is named `c2c-<target>`.

* **The bitstream lives in BOOT.BIN**, not loaded at runtime via FPGA manager.
  Because no PL overlay is requested, `fpga-overlay` is left out of
  `MACHINE_FEATURES`, so `xilinx-bootbin`'s `BIF_BITSTREAM_ATTR` defaults to
  `bitstream` and the bitstream `sdtgen` extracted from the XSA is embedded
  automatically. FSBL programs the PL of the ZCU106 during boot, so its end of
  the chip-to-chip link is live before Linux starts.

* **`system-user.dtsi` must be scoped to the Linux device tree** (via a guard on
  `CONFIG_DTFILE` in the device-tree bbappend of the BSP). The FSBL and PMU domain device-trees don't define the SoC
  peripheral labels (`uart0`/`uart1`, `sdhci1`, `&zynqmp_dpsub`, …) the
  overrides reference, so including it there makes `dtc` fail with
  "Label or path … not found".
