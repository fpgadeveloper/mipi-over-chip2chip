# Device-tree overlay of the remote camera pipelines

The two MIPI camera pipelines live on the AUBoard 15P and are reached through the AXI
Chip2Chip window `0xA000_0000 - 0xA0FF_FFFF`. Their drivers are built into the kernel and touch
the hardware in probe, and a register access while the link is down never completes. So their
nodes are not in the base device tree: `c2c-cams.dtso` adds them at run time, after a link check.

| File | What |
|---|---|
| `c2c-cams.dtso` | overlay source, both cameras. **Needs cpp** (all hardware values are `#define`s at the top). |
| `build-overlay.sh` | host build (cpp + `dtc -@`) and, with `--check`, an offline merge test against a copy of `system.dtb` |
| `init_c2c_cams.sh` | target script: media-ctl links + formats for both pipelines, prints capture commands |
| `out/` | build products (not sources) |

> This directory **is** tracked: `Yocto/.gitignore` has `!/overlays/` (and ignores only
> `/overlays/out/`). The build products in `out/` are not sources.

## These files ARE the image's source — do not copy them anywhere

`bsp/zcu106/meta-user/recipes-apps/c2c-cameras/` builds the image's copy of the overlay out of
**this** directory. It does not fork the files into the layer: it adds this directory to the
bitbake fetcher's search path with a path relative to the recipe,

```
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../../../overlays:"
```

and its `do_compile` runs `build-overlay.sh` (with `OUT_DIR` set into the bitbake work
directory, so nothing is written here). Consequences worth knowing:

* `c2c-cams.dtso`, `init_c2c_cams.sh` and `build-overlay.sh` have **one** copy each. Edit them
  here; a host build (`./build-overlay.sh --check`) and the image build compile the same source
  with the same flags and produce a **byte-identical** `.dtbo` (verified).
* Editing any of them makes bitbake rebuild `c2c-cameras` and the image — the file contents are
  part of the task hash.
* The path has no symlinks and stays inside the repository, so a fresh clone or a source export
  works unchanged.
* On the board: the blob is `/lib/firmware/c2c/c2c-cams.dtbo`, the init script is
  `/usr/bin/c2c-init-cams` (also as `init_c2c_cams.sh`), and `c2c-cameras.service` applies them
  at boot after a link check and a check that the AUBoard really runs the camera design. See
  `docs/source/linux_cameras.md`; the manual procedure below still works and is what the service
  automates.

## Build and check (host)

```
./build-overlay.sh --check        # -> out/c2c-cams.dtbo, out/c2c-cams.pp.dtso, out/c2c-cams-flat.dtbo
```

dtc / fdtoverlay / fdtget come from PATH or from the native sysroot of the Yocto workspace
(`DTC_DIR=` overrides). `--check` copies `Yocto/zcu106/images/linux/system.dtb`, applies the
overlay with `fdtoverlay` and then verifies **by node path** that every reference landed on the
node it was meant for: INTC -> GIC, every `reset-gpios` -> the GPIO of the *same* camera, every
interrupt -> the remote INTC, `dmas` -> the frame buffer of the same camera, clocks, supplies, and
all ten endpoint pairs pointing at each other. (A check that only looks for unresolved
placeholders passes an overlay whose CAM2 reset is wired to the CAM0 GPIO; this one fails it.)

Compiler output: **0 warnings with two documented `-W no-...` switches**; without them dtc prints
6 lines of exactly two kinds, both caused by compiling an overlay without its base tree (it cannot
see `#address-cells = <2>` / `#size-cells = <2>` of `&amba_pl`) or by the `reg = <0>` the
`xlnx,video` binding needs on a single port. The reasons are in the script. With that prerequisite
off, dtc's duplicate-unit-address check is not relied upon.

## Apply (target)

Normally nothing to do: `c2c-cameras.service` does all of this at boot. By hand — which is what
the service automates — it is:

```
systemctl stop c2c-cameras                       # only if it is active, so it does not race you
c2c-link-status                                  # link must be up
c2c-overlay apply cams /lib/firmware/c2c/c2c-cams.dtbo   # or a .dtbo you copied over
dmesg | tail -40
c2c-init-cams                                    # 1080p RGB24 on both cameras
```

* Do **not** hand the raw `c2c-cams.dtso` to `c2c-overlay`: it runs plain `dtc`, which stops at
  the first `#define` (tested: syntax error). Use the `.dtbo`, or `out/c2c-cams.pp.dtso`, which
  compiles with the helper's exact command to a byte-identical blob (tested).
* **Apply once per boot; do not remove it.** Removal unbinds a cascaded interrupt controller
  (`xilinx_intc_of_remove` gives up with a warning if an interrupt is still requested, and its
  memory is freed anyway), a V4L2 async graph and DMA channels, and every unbind touches remote
  registers - fatal if the link dropped meanwhile. To re-apply: reboot.
* Never access a video IP (demosaic, gamma, v_proc_ss, frmbuf) with devmem / c2c-peek while its
  reset bit in the camera GPIO is 0: the access never completes and blocks the whole register
  path until the AUBoard is re-programmed. The drivers release the resets themselves.
* Capture with MMAP buffers only (`--stream-mmap`, `io-mode=mmap`).

## Design decisions (details and kernel file:line in the comments of the .dtso)

* **Interrupts: one remote `axi_intc` cascaded into GIC SPI 89, by overlay.** This kernel is built
  with `CONFIG_IRQCHIP_XILINX_INTC_MODULE_SUPPORT_EXPERIMENTAL=y`, which turns the INTC driver
  into a platform driver; an overlay-added node is probed. No hardware change. (The alternative,
  4 shared direct lines, does not work: only xilinx_frmbuf requests its interrupt with
  `IRQF_SHARED`; csi2rxss and i2c-xiic do not, so 5 exclusive lines would be needed.)
* **DMA below 2 GB: a `simple-pm-bus` node with `dma-ranges`.** No driver limits the DMA mask
  (`xlnx,dma-addr-width` only selects 32/64-bit register writes; the `xlnx,video` device that
  allocates the buffers sets a 64-bit mask), and the board has DDR at `0x8_0000_0000`.
  `dma-ranges` sets `bus_dma_limit` for every device under the bus. It must be `simple-pm-bus`:
  the children of an overlay-added `simple-bus` are never populated.
  `out/c2c-cams-flat.dtbo` is the fallback without that bus (and without the limit; it then
  relies on the default CMA area being in DDR low, which `cma=1024M` gives on this board).
* **Formats:** SRGGB10 from the sensor to the demosaic sink pad (the 10->8 bit converter needs no
  node), `RBG888_1X24` after it, capture format RGB24 (`RGB3`) only: the scaler has no colour
  conversion and the frame buffer writer has RGB8 only.
* Camera enable (GPIO bit 0) has no Linux consumer; `xlnx,dout-default = <1>` keeps it on.

## What is verified, and what is not

**Verified on hardware (2026-09-20, ZCU106 + AUBoard 15P, both cameras).** The overlay applied on
the first attempt with no change to this file: the remote `axi_intc` probed from the overlay
(`irq-xilinx: ... num_irq=10, edge=0x0`), `simple-pm-bus` populated its children, both `imx219`
bound at `0x10`, every video driver probed, `/dev/media0..1`, `/dev/video0..1` and ten
`/dev/v4l-subdev*` appeared, and both pipelines captured real 1080p pictures over the link at the
sensor's maximum rate with no dropped frames. So the "kernel behaviour was only read, not run"
caveat below, and the "sensor address 0x10 is NOT confirmed" open value, are both settled.
Details, commands and the measured frame-rate table: `docs/source/linux_cameras.md`.

One fix *was* needed, in `init_c2c_cams.sh`, not in the overlay: the capture format must carry an
explicit `bytesperline` / `sizeimage`, because `xvip_dma` clamps a requested `bytesperline` only
upwards and `v4l2-ctl --set-fmt-video` writes back the stride of the previous format. Without it
a switch from 1920x1080 to 640x480 left a 5760-byte stride and produced frames with 160 lines of
picture spread over 480 lines. See the comment at the `--set-fmt-video` call.

Verified on the host:
* the overlay compiles, merges into a copy of our `system.dtb`, and every reference resolves to
  the intended node (both variants); the checker was shown to fail on a deliberately wrong file;
* the constants equal the read-back of the **validated block design** of hardware build 1
  (`INFO: [map]` / `INFO: [cam]` lines of the project build log): all addresses and sizes, 10 INTC
  inputs in this order, RAW10 / 2 lanes / VFB, 6+6 taps, RGB8 only, 32-bit address, clocks
  100 / 200 / 300 MHz; and the hardware engineer's JTAG register test (`REGS PASSED`) found the
  CAM2 blocks, the v_proc_ss sub-blocks at +0x1_0000 / +0x2_0000 and the reset bits where the
  drivers expect them;
* `init_c2c_cams.sh`: `sh -n` and full runs against stub `media-ctl` / `v4l2-ctl` (both output
  layouts, flipped sensor, refused mode, scaling, exit codes). Not linted.

Still NOT exercised:
* the `-DC2C_FLAT` fallback variant (`out/c2c-cams-flat.dtbo`) has not been applied on the target;
  only the default variant with the `simple-pm-bus` / `dma-ranges` node has;
* nothing forces a buffer above `0x8000_0000`, so the `dma-ranges` limit itself was never seen to
  bite - it was simply never violated (`cma=1024M` keeps the CMA area in DDR low).

## Open values

* `CLK_VIDEO_HZ` = 300 MHz matches build 1, but the video clock was still being tuned. It is
  cosmetic for Linux: the drivers only enable this clock, none reads its rate.
* ~~Sensor address `0x10` is NOT confirmed on this hardware.~~ **Settled:** both sensors bind at
  `0x10` (`/sys/bus/i2c/devices/{2,3}-0010/driver -> imx219`) and stream. The earlier NACK over
  JTAG was not an address problem.
