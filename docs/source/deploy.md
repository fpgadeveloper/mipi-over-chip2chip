# Deploying and updating the Linux image

This page describes how the Yocto image of the host board (target `zcu106`) gets onto the SD
card, including when nobody can reach the card, and how to update a board that is already
running. Build the image first (see [Yocto](yocto)); the files are in
`Yocto/zcu106/images/linux/`.

## What is where on the SD card

The image uses the four-partition layout of the AMD EDF. The running system mounts the first
three partitions itself:

| Partition | Filesystem | Mounted at | Contents |
|-----------|-----------|------------|----------|
| `mmcblk0p1` `esp` (512 MB) | FAT32 | `/boot/efi` | `BOOT.BIN`: FSBL, PMU firmware, **bitstream**, TF-A, **Linux device tree**, U-Boot |
| `mmcblk0p2` `boot` (512 MB) | ext4 | `/boot` | `Image` (kernel), `boot.scr` |
| `mmcblk0p3` `root` (6 GB) | ext4 | `/` | root filesystem, kernel modules in `/lib/modules` |
| `mmcblk0p4` `storage` (1 GB) | FAT32 | not mounted | free for the user |

Two consequences:

* **The device tree and the bitstream are inside `BOOT.BIN`.** U-Boot hands its own device
  tree to the kernel; the `system.dtb` next to the kernel on `/boot` is not used. A change of
  `system-user.dtsi` or of the Vivado design is deployed by replacing one file,
  `/boot/efi/BOOT.BIN`.
* The kernel command line is `/chosen/bootargs` of that device tree, to which `boot.scr` appends
  `root=/dev/mmcblk0p3 ro rootwait`.

The image is 8 GiB + 16 KiB, so the card must be 16 GB or larger.

## First deployment with a card reader

Write `rootfs.wic.xz` to the card and copy `BOOT.BIN` onto the first partition, as described
in `Yocto/README.md` ("Flashing to SD card"). Set the boot mode switches (SW6) to SD.

## First deployment without access to the card

When the card is already in a board that can only be reached over JTAG, UART and Ethernet,
the card is written by a Linux that runs entirely from RAM. The scripts are in
`Yocto/bsp/zcu106/deploy/`. The procedure needs:

* the pre-built images of the AMD PetaLinux 2025.2 BSP for the ZCU106 (the directory
  `pre-built/linux/images/` of the extracted BSP): they boot to a complete Linux with
  networking and an SSH server from a RAM disk;
* `xsdb` (Vivado or Vitis) and `mkimage` (for example the one of the PetaLinux tools,
  `<petalinux>/sysroots/x86_64-petalinux-linux/usr/bin/mkimage`);
* the board on the same network as the build machine, with a DHCP server.

The boot mode switches can stay on SD: the script selects the JTAG boot mode through the
`BOOT_MODE_USER` register, which a power cycle clears again.

```{warning}
**Power-cycle the board before you start, and never run this procedure on a board that is
still running Linux.** `jtag_boot_ramdisk.tcl` does `rst -system`, which resets the SoC but
**does not remove power from the SD card**. A card that the previous Linux had switched to
UHS-I **1.8 V** signalling stays in 1.8 V until its power is cycled — the SD voltage switch
is one-way — while the re-initialising host drives 3.3 V. The result is a card that answers,
enumerates, reports `ro=0`, accepts writes that report success, and does not store them.

That is exactly what cost a day here: a deploy started from a running Yocto Linux produced
60 kernel `WRITE` I/O errors, two failed read-back verifies and small writes that did not
stick, and the card was written off as dead. From a cold start the same card passed
14 of 14 write/read-back tests spread over its whole 30 GB with zero I/O errors, and then
took a full 8 GiB image with a clean verify. Nothing was wrong with it.

A cold card initialises at 3.30 V, `sd high-speed`, 50 MHz — check with
`cat /sys/kernel/debug/mmc0/ios` once the RAM-disk Linux is up.
```

1. **Power-cycle the board.** Switch the ZCU106 off with its power switch (SW1), wait at
   least ten seconds so the card is fully discharged, then switch it on again. A reset
   button, a JTAG system reset or a `reboot` is **not** enough: none of them removes power
   from the card.

   `deploy_sd.sh` also pre-flights the card (step 4) and refuses to start the long write if
   a small one does not stick, but that check cannot undo a bad bus state — only a power
   cycle can.

2. **Prepare the files and serve them over HTTP** (build machine, 1.5 minutes). The image is
   served gzip-compressed together with the size and the md5 of the uncompressed image:

   ```
   cd Yocto/bsp/zcu106/deploy
   ./prepare_serve.sh ../../../zcu106/images/linux /tmp/c2c-serve
   python3 -m http.server 8000 --bind <host-ip> --directory /tmp/c2c-serve
   ```

3. **Boot the RAM-resident Linux over JTAG** (24 minutes with a 15 MHz JTAG clock; nearly
   all of it is the download of the 207 MB root filesystem):

   ```
   mkimage -A arm64 -T script -C none -d jtag_ramdisk.cmd /tmp/jtag_ramdisk.scr
   xsdb jtag_boot_ramdisk.tcl <bsp>/pre-built/linux/images /tmp/jtag_ramdisk.scr "<cable>"
   ```

   `<cable>` is a glob on the JTAG cable name, needed when several boards share one
   `hw_server`. It is matched against the **whole** name, so use wildcards on both sides:
   `xsdb` command `jtag targets` prints e.g. `Xilinx HW-FTDI-TEST FT232H 11093`, and the
   argument to pass is `"*FT232H 11093*"` (default `*` = every cable). The script resets
   the PS into JTAG boot mode, programs the **pre-built bitstream** (it has to match the
   pre-built device tree: the drivers of that device tree access its PL), runs the PMU firmware
   and the FSBL, downloads the device tree, the kernel, the root filesystem and a two-line boot
   script, and starts U-Boot, which boots Linux without any interaction. Watch the UART
   (115200 8N1) until the `login:` prompt; the user is `petalinux`, and a password has to be set
   at the first login.

   Four details that differ from a stock PetaLinux JTAG boot and that the scripts take care
   of: the root filesystem is loaded at `0x10000000`, because at the usual `0x04000000` a
   207 MB image overlaps the load address of U-Boot (`0x08000000`); `fpga` is given the
   top-level JTAG device ("PS TAP") rather than the "PL" target, which `xsdb` refuses when two
   FPGAs are connected; all register writes are forced (`mwr -force`); and `jtag_ramdisk.cmd`
   sets the kernel command line itself, to add **`modprobe.blacklist=mali`**.

   ```{note}
   Without that blacklist the boot can die at about 16 seconds with
   `SError Interrupt on CPU3, code 0x00000000bf000002` and
   `Kernel panic - not syncing: Asynchronous SError Interrupt`, in `mali_probe` ->
   `mali_pp_reset_wait`. udev loads the out-of-tree Mali GPU module of the pre-built root
   filesystem, and its first register read takes an external abort because this JTAG sequence
   resets a *running* system and the GPU does not end up powered the way a normal boot powers
   it. It is intermittent — the same command succeeded on an earlier run. Nothing in this
   procedure needs a GPU, so the module is simply kept out of the way.
   ```

4. **Write and verify the card** (15 minutes: 9 to write 8 GiB, 6 to read it back). On the
   board, as root:

   ```
   wget -O /tmp/deploy_sd.sh http://<host-ip>:8000/deploy_sd.sh
   sudo sh /tmp/deploy_sd.sh http://<host-ip>:8000 /dev/mmcblk0
   ```

   The script stops the automounter, unmounts the card, **pre-flights it**, streams the image
   onto the raw device, reads the whole image back and compares the md5, makes the kernel
   re-read the partition table, copies `BOOT.BIN` onto the first partition and compares its
   sha256. It ends with `DEPLOY OK`, or stops at the first error.

   The pre-flight writes 4 MiB of random data at two offsets, syncs, drops the page cache,
   reads it back and checks that no new block-layer I/O error appeared. It costs a few
   seconds and it fails in place of a 15-minute write and verify:

   ```
   pre-flight OK: 4 MiB written and read back at 30440MiB and 1MiB, no I/O errors
   ```

   ```{important}
   **The order of those two offsets matters, and the script tests the *end* of the card
   first.** A card in the "not power-cycled" state (see the warning above) *erases* without
   programming, and the low offset — 1 MiB — is inside partition 1, where the `BOOT.BIN` of
   a card that is still bootable lives. Testing there first would destroy a working image on
   a card that then refuses the new one, which is exactly what happened here once. The 8 MiB
   at the end of the card is past the image and harmless, so it goes first; the loop stops at
   the first failure, and the low offset is only touched once the card has proved that it can
   program. `PREFLIGHT_ONLY=1` never touches the low offset at all — it tests only the space
   past the image, so checking a suspect card cannot damage a deployed one.
   ```

   `PREFLIGHT_ONLY=1` runs only that check (useful to test a suspect card), and
   `SKIP_WRITE=1` repeats the final verification only, without touching the card.

   ```{note}
   The RAM-disk Linux runs **BusyBox** tools. Its `dd` supports only
   `if= of= bs= count= skip= seek=` — there is **no `conv=` at all**, so neither
   `conv=fsync` nor `conv=notrunc`; passing one makes `dd` exit 1 with a usage error and
   write nothing. Its `head` has no `-c`. `deploy_sd.sh` avoids all of these. If you write
   your own helper, do not redirect `dd`'s stderr away — a silent non-zero `dd` looks
   exactly like a card that refuses writes, and it will send you after the wrong fault.
   ```

5. **Power-cycle the board.** It boots from the card in about 35 seconds. The first login is
   on the UART as `amd-edf` with an empty password, which has to be changed; SSH works after
   that. The board asks for an address with DHCP; its MAC address is fixed in the device tree.

## Updating a running board over SSH

Only the first row of this table has been exercised on hardware so far (a new `BOOT.BIN`
copied onto the first partition of the card, then a reboot: the board was back at the login
prompt 26 seconds later with the link up). The kernel and package rows are derived from the layout of
the image (`/lib` is a symlink to `usr/lib`, `rpm` and `dnf` are installed, the root
filesystem is mounted read-write) and have **not been run yet**: check the result before
relying on them.

| What changed | What to do |
|--------------|-----------|
| Device tree (`system-user.dtsi`), bitstream, FSBL, U-Boot | Replace `BOOT.BIN`: `scp BOOT.BIN amd-edf@<board>:/tmp/ && ssh amd-edf@<board> 'sudo cp /tmp/BOOT.BIN /boot/efi/BOOT.BIN && sync && sudo reboot'` |
| Device tree overlay of the remote peripherals, scripts, single files | Copy the file; nothing to reboot. Overlays are applied at run time with `c2c-overlay`. |
| Kernel (`bsp.cfg`, patches) | Copy `Image` to `/boot/Image-<version>` (`/boot/Image` is a symlink to it) **and** replace `/usr/lib/modules/<version>` with the one of the new `rootfs.tar.gz`: `sudo tar -xzf rootfs.tar.gz -C / ./usr/lib/modules` (the image is usr-merged: the archive has no `./lib/modules` member). Kernel and modules must come from the same build. Then reboot. |
| A few packages | The build leaves RPMs in `Yocto/zcu106/build/tmp/deploy/rpm/`. Copy the ones needed and install them with `sudo rpm -Uvh` (or `dnf install ./<file>.rpm`). Handy while developing, but the result is no longer bit-identical to the image the build produced — do not accept a release on it. |
| The whole root filesystem | Write the card again (either first-deployment procedure). A running system cannot overwrite the partition it runs from. |

After a rebuild, `./build.sh yocto --target zcu106` only re-runs the Yocto stage when one of
the four products in `Yocto/zcu106/images/linux/` is missing: delete `BOOT.BIN` there to make
the runner pick up a BSP change.

```{note}
A rootfs-only change (a new or changed package, such as `c2c-cameras`) tempts one to install
the handful of RPMs over SSH instead of writing the card again — a minute against three
quarters of an hour. It is the right thing while iterating, and the wrong thing for a release
test: the RPM route leaves the previous rootfs plus a package on top, which is not what the
build produced. Acceptance tests are run on a card written from `rootfs.wic.xz`.
```

A reboot of the ZCU106 reprograms its PL, so the Chip2Chip link drops and trains again by
itself once Linux is back (`c2c-link-status -w 30`). The AUBoard 15P is not reset by this: its
registers and memories keep their contents.
