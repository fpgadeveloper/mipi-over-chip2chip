# Troubleshooting

If you need help with this design, please [contact Opsero](https://opsero.com/contact-us) or
[report an issue](https://github.com/fpgadeveloper/mipi-over-chip2chip/issues) on Github.

This page covers the hardware, the link and the Linux side. The bare-metal application has
its own troubleshooting section in [Bare-metal demo](baremetal), and the DisplayPort output
has one in [Showing the cameras on a DisplayPort monitor](display) — the entries below are
the ones worth checking first in either case.

## Build failures

1. **Are you using the correct version of the tools?** This repository requires Vivado and
   Vitis **2025.2**; `Vivado/scripts/build.tcl` refuses any other version. See
   [Requirements](requirements).
2. **Did you clone with `--recursive`?** The AUBoard 15P target needs the board definition
   files in `submodules/avnet-bdf`; they are not in the AMD board store. The build runner
   initialises a missing submodule by itself, but a half-initialised one will not work.
3. **Did the block design script stop with an error?** Both scripts check the link
   parameters after `validate_bd_design` and stop the build when the tools derived something
   other than the link contract — most often `C_INTERFACE_MODE` or the AXI ID / WUSER widths.
   The message names the parameter and the expected value; see
   [Advanced](advanced) and `docs/link_contract_deviations.md`.
4. **Critical warnings.** An evaluation-license warning (`[12-1790]`) is a known false
   positive. Two others, `DRC AVAL-350` and an "FVCO out of range" on a MIPI D-PHY PLL,
   appear if the 300 MHz board clock is redefined with a 3.333 ns period — see the comment
   in `Vivado/src/constraints/auboard.xdc` before changing it.

### The Yocto build fails on the build host

The Yocto stage needs a native Linux machine with the host packages listed in
`Yocto/README.md`, and it is sensitive to the state of the build host itself. Host-side
build problems and their workarounds are documented on the [Yocto](yocto) page. The Vivado
stages are unaffected and can be built on Windows.

One of them used to need a manual step and no longer does: on a host whose `tar` carries the
security fix for CVE-2025-45582, fakeroot tasks fail with `tar: ...: Cannot mkdir: Bad
address`. The build flow now detects that and supplies a usable `tar` by itself, printing
`[hostfix]` lines when it does. If you see that error anyway, read
[the `tar` / pseudo host issue](host-tar-pseudo) — it lists the fallbacks.

## The board does not boot at all, and the UART stays (almost) silent

This one is **not** a property of this design, and it is worth recognising before you go
looking for a fault in the image, the bitstream or the SD card.

An intermittent boot failure is reported for some ZCU106 boards: the boot sequence dies at or
before PL configuration. The symptoms are

* **nothing, or almost nothing, on the UART** — either no output at all, or the FSBL and PMU
  banners and then silence, within about 10 seconds of power-on;
* on the board: the FPGA `DONE` LED off, `INIT_B` red and `PS_ERR_STAT` red;
* over JTAG: the PL unconfigured (`DONE` low), and the PS error status registers non-zero —
  `PMU_GLOBAL ERROR_STATUS_1` / `_2` at `0xFFD8_0530` / `0xFFD8_0540` and `CSU_BR_ERROR` at
  `0xFFD8_0528`;
* as a knock-on effect, the Chip2Chip link never comes up, because the ZCU106's PL was never
  configured — although the AUBoard is perfectly healthy.

**The remedy is simply to power-cycle again.** It normally boots on one of the next two or
three attempts. Do not re-flash, re-deploy or replace the card on the strength of it.

```{important}
Judge it by **where** the boot stops. A failure at or before PL configuration — no FSBL
output, or banners and then silence — is this board-level symptom, and the answer is another
power cycle (give it about five before concluding anything). A failure **later** than that —
U-Boot messages, a kernel that boots and then panics, a service that fails, a link that trains
and then misbehaves — is a real fault and should be investigated normally.
```

An automated bring-up loop should treat it the same way: if no boot banner appears within
about ten seconds of power-on, power-cycle and retry, and count it as a board boot failure
rather than as a failure of the design under test.

## The link does not come up

Read the status first, from whichever side you can reach. It is safe in any link state on
both boards, because the bits come from an AXI GPIO in the *local* fabric:

```
# on the ZCU106, from Linux
sudo c2c-link-status

# on the ZCU106, over JTAG with no software
xsdb scripts/jtag/zcu106_mem.tcl status

# on the AUBoard, over JTAG
vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_axi.tcl -tclargs status
```

`LED4`/`LED3` on the AUBoard and `GPIO_LED_0`/`GPIO_LED_1` on the ZCU106 show `channel_up`
and the Chip2Chip link status without any tool at all.

| Bit | Name | If it is 0 |
|---|---|---|
| 2 | `gt_pll_lock` | The GT has no usable reference clock. Check the 156.25 MHz reference clock: on the AUBoard, `auboard_axi.tcl status` prints the measured Aurora user clock and the reference clock it implies (a reading of 0 Hz means the user clock is not running at all). |
| 1 | `lane_up` | The transceiver never reached symbol lock. Check the DAC cable and that it is in the **`SFP0`** cage of the ZCU106; check `sfp_los` (bit 10 on the AUBoard). |
| 0 | `channel_up` | Aurora did not finish channel bonding, usually because the far end is not transmitting: is the AUBoard programmed? Is the ZCU106 PL configured (its FSBL does that out of `BOOT.BIN`)? |
| 3 | `axi_c2c_link_status` | Aurora is up but the two Chip2Chip cores did not agree. This is almost always a **parameter mismatch** between the two block designs — re-read `docs/link_contract_deviations.md` and compare the `INFO: [link]` lines of both build logs. |
| 9 | `mmcm_not_locked` (1 = bad) | The Aurora core's own MMCM is not locked; follow `gt_pll_lock` first. |

Other things worth checking:

* **`sfp_los` (bit 10) or `sfp_tx_fault` (bit 11) set on the AUBoard.** Loss of signal or a
  transmitter fault reported by the module. A passive DAC cable normally reports neither.
* **Loopback left switched on.** `axi_gpio_dbg` on the AUBoard (`0xA003_0000`) and channel 2
  of `axi_gpio_link` on the ZCU106 (`0xA100_0008`) set the Aurora/GT loopback. A non-zero
  value takes the link down. Reset them to 0 and pulse the link reset
  (`zcu106_mem.tcl linkreset`, or re-program the AUBoard).
* **Near-end PMA loopback (mode 2) as a diagnostic.** If a board comes up in its own
  loopback but not against the other board, the transceiver and the Chip2Chip core on that
  side are fine and the problem is in the cable or on the far side.
* **The link needs a moment after a ZCU106 reboot.** A reboot reprograms the PL, so the link
  drops and trains again by itself once Linux is back: `c2c-link-status -w 30` waits for it.

### Error bits that stay set after the other board resets

Bits 4..6 (`axi_c2c_link_error_out`, `axi_c2c_multi_bit_error_out`,
`axi_c2c_config_error_out`) are **sticky on the master**, i.e. on the AUBoard. Read bits 0..3
as the current state of the link and bits 4..6 as "something happened since this design was
last reset".

* A master that has never seen its partner reads `0x004` — GT PLL locked, nothing else.
* Once the link *has* been up and the partner goes away (for example while the ZCU106
  reboots and reprograms its PL), the master latches `0x034`.
* A loopback session — the master talking to itself — also leaves `axi_c2c_config_error_out`
  set.

They clear when the AUBoard design is reset: press the board's reset push button or
re-program the device. A healthy link reads `0x00F` on both boards.

On the ZCU106, bit 4 is **always 0**: a Chip2Chip slave with an Aurora PHY has no
`axi_c2c_link_error_out` output at all. That is not a fault.

## A register access hangs and everything stops responding

There is no timeout anywhere in the register path of this design. Two situations make an
access hang forever, and they look identical from outside:

1. **An access into the remote window while the link is down.** On the ZCU106 this hangs the
   CPU (from Linux) or the debug access port of the PS (from JTAG). On the AUBoard, an
   access into `0x0000_0000`–`0x7FFF_FFFF` while the link is down hangs the JTAG-to-AXI
   master.
2. **An access to a video IP that is held in reset.** `v_demosaic`, `v_gamma_lut`,
   `v_frmbuf_wr`, the whole `v_proc_ss` window while its GPIO bit is 0, and the two scalers
   inside `v_proc_ss` until bit 1 of its internal reset GPIO is set. This is the power-up
   state of every pipeline. Such an access blocks **every** register access of the design —
   for the host and for `jtag_axi` alike.

The tools of this design refuse both by default: `c2c-peek` / `c2c-poke` and
`zcu106_mem.tcl` check the link status before entering the window, `auboard_axi.tcl` checks
it before entering the host DDR window, and every command of `auboard_cam.tcl` releases the
reset of an IP before touching it. `-f` / `-force` overrides the check, at your own risk.

**Recovery:**

* Re-program the AUBoard (`scripts/jtag/auboard_prog.tcl`). That clears a stuck AXI path on
  the mezzanine side.
* On the ZCU106, a hung Linux needs a reboot; a hung debug access port shows up as
  `DAP (AXI AP transaction error, ...)` instead of the `PSU` target in `xsdb`. A system
  reset may not bring it back — **power-cycle the board** if it does not.
* Never `devmem` or `c2c-peek` a video IP before the device-tree overlay has been applied.
  The Linux drivers release the resets themselves in their probe.

## The AUBoard loses power while the ZCU106 is running

All of the following was measured on hardware, with both cameras streaming 1080p at the
moment the AUBoard's power was cut.

**What happens immediately — the ZCU106 is fine:**

* **Linux does not hang.** SSH stays up, the load stays low, and `dmesg` records **nothing
  at all** — no V4L2 error, no DMA timeout, no warning.
* **The streams just stop.** The capture processes end silently, without an error message.
* **The link retrains by itself** once the AUBoard has reloaded from its configuration flash
  (about 2 s): `c2c-link-status` is back to `0x0000000F`.
* **The remote pipelines are back in their power-up state**: `0xA012_0000` and `0xA022_0000`
  read `0x00000001`, i.e. **all four video resets are asserted again**. The Linux drivers
  release those resets only in their `probe`, and the overlay cannot be removed, so nothing
  in the running system ever releases them again.

**The cameras are gone until the ZCU106 is rebooted. The service detects this and refuses:**

```
$ sudo c2c-cameras health
the mezzanine was reset behind the drivers' back - reboot the host (or power-cycle both boards)
the device-tree overlay is applied, so the video drivers have probed and released their
resets - but the pipeline GPIO 0xA0120000 reads 0x00000001, i.e. the video IPs are back in reset
...
$ echo $?
5
```

Exit status **5** is this condition and nothing else. `sudo c2c-cameras status` ends with the
same verdict, `systemctl restart c2c-cameras` fails with it (`ExecMainStatus=5`, unit
`failed`), and `c2c-display` refuses to start and passes the 5 on. See the *health check*
section of [Using the cameras from Linux](linux_cameras) for how it is detected.

**Trying to bring the cameras back without a reboot still will not work — the check is there
to stop you finding that out the hard way:**

* `systemctl start c2c-cameras` **does nothing**. The unit is still `active` from boot, and
  systemd re-runs a `oneshot` unit on `start` only when it is *not* active. It returns in
  under 0.1 s (measured: 0.084 s) and writes nothing to the journal. **Use
  `systemctl restart`**, which really re-runs it — and which now fails with a clear message
  instead of a false success.
* Before the health check existed, `c2c-cameras start` **ran to completion and printed
  `remote cameras are ready` — a false success.** Every step passed: the link was up, the
  design probe passed (the GPIO still has bit 0 set), the quiesce step correctly saw the
  writers in reset and skipped them, the overlay was already applied, the device nodes were
  still there, and `c2c-init-cams` only sets formats, which the V4L2 drivers cache in
  software. Afterwards `0xA012_0000` was **still `0x00000001`**: nothing came out of reset.
* **The first capture after that hangs the CPU**, because the frame buffer writer is in
  reset. A `timeout` around the command does not help — the access is an uninterruptible read
  that never completes. SSH and the UART both stop responding.
* **Do not hand-release the resets either.** Writing the running value `0x5D` back to
  `0xA012_0000` / `0xA022_0000` was tried: the next read of a frame buffer writer still never
  completed and wedged the board.

```{warning}
**A GPIO reading `0x5D` after this event does not mean the pipelines recovered.** The
`gpio-xilinx` driver keeps the output word in software, and the video drivers touch their
reset lines when a stream is released. Measured: right after the AUBoard power cycle both
pipeline GPIOs read `0x01`; stopping the running display — an ordinary stream teardown —
made the drivers write their cached `0x5D` back into a register the mezzanine had reset,
with nobody poking anything. The register then looks healthy while the IPs are still dead.
That is why the health check also keeps a generation marker in the AUBoard's scratch BRAM,
which a reload of that board's fabric clears and no driver can restore.
```

**What to do**

> After the AUBoard has been power-cycled, **reboot the ZCU106 before touching any camera**.

A plain `reboot` is enough and is safe, provided nothing has touched a video IP since the
AUBoard came back: the service's shutdown path reads the pipeline GPIO first, sees `0x01`,
and skips the remote registers. On the next boot the overlay is applied again, the drivers
re-probe and re-release the resets, and the cameras come up normally — measured:
`remote cameras are ready` 10.6 s after kernel start, and a capture straight afterwards
succeeded.

**Recovery once it has already hung**

Power-cycle **both** boards. Power-cycling only the ZCU106 is *not* enough: the transaction
that never completed also leaves the AUBoard's AXI path stuck (see the section above), so the
next ZCU106 boot stalls at `Starting Remote MIPI cameras over AXI Chip2Chip...` and never
reaches a login prompt. The console shows

```
rcu: INFO: rcu_sched detected stalls on CPUs/tasks:
rcu: 	1-...0: (0 ticks this GP) ...
Sending NMI from CPU 0 to CPUs 1:
```

Never try a soft reboot to get out of this — the board is already past the point where
software runs.

## The AUBoard is back to its old design after a power cycle

Expected, if you programmed it over JTAG. `scripts/jtag/auboard_prog.tcl` programs the
device over JTAG only — nothing is written to the configuration flash. The AUBoard boots
from its quad SPI flash (Master SPI x4, no boot mode switch), so after a power cycle it
comes back with whatever image is stored there, and the link will not train against the
current ZCU106 design unless that image happens to be this one.

Two ways out:

* re-program it over JTAG after every power cycle, or
* **write the design into the configuration flash**, and the board loads it by itself about
  1.5 to 2 seconds after the power comes on — see
  [Booting the AUBoard from its configuration flash](flash.md).

If the design *is* in the flash and the board still comes up with something else, check
whether anything programmed the device over JTAG since the last power cycle: a JTAG load
always overrides the flash image until the board is power-cycled.

The same applies to the JTAG bring-up of the ZCU106: `zcu106_init.tcl` writes nothing to the
SD card or to the QSPI flash, and it selects the JTAG boot mode through a register that a
power cycle clears.

## Linux: the video devices do not appear

* `sudo c2c-link-status` must say `link: UP` **before** the overlay is applied. If it does
  not, stop and fix the link — the drivers touch remote registers in their probe.
* Apply the overlay **once per boot** and **never remove it**; to start over, reboot.
* Do not hand the raw `c2c-cams.dtso` to `c2c-overlay`: it contains `#define`s and plain
  `dtc` stops at the first one. Use `out/c2c-cams.dtbo`, or the preprocessed
  `out/c2c-cams.pp.dtso`.
* The `dmesg` output right after the overlay contains about thirty
  `Fixed dependency cycle(s)` lines, a few `port@0 initialization failed` /
  `DMA initialization failed` lines while `xilinx-frmbuf` is still deferred on its reset
  GPIO, `Entity type for entity ... was not initialized!` and
  `OF: overlay: WARNING: memory leak will occur if overlay removed`. All of these are
  harmless — the V4L2 graph is cyclic by construction, the capture node retries, and the
  overlay is never removed.

The full procedure and the expected output are in
[Using the cameras from Linux](linux_cameras).

## Linux: the picture is the wrong shape, or a small image spread over a large frame

Almost always a stale **`bytesperline`**. `xvip_dma` clamps a requested `bytesperline` only
*upwards* to `width * 3`, and `v4l2-ctl --set-fmt-video=width=...` reads the current format
first and writes the untouched fields back — so the stride of a previous, wider format
survives a change to a smaller one, and the frame buffer writer keeps advancing by the old
stride. Measured: after 1920x1080, a plain
`--set-fmt-video=width=640,height=480,pixelformat=RGB3` left `bytesperline` at 5760 and
every frame came out with 160 lines of picture spread over 480 lines, in a buffer three
times too large.

Always set the stride explicitly:

```
v4l2-ctl -d /dev/video-cam0 \
  --set-fmt-video=width=640,height=480,pixelformat=RGB3,bytesperline=1920,sizeimage=921600
```

`init_c2c_cams.sh` does this for you.

## Linux: the picture is dark, or has a green cast

Both are expected from this pipeline and both are fixed with controls, not with a rebuild.
The pipeline has a demosaic, a gamma LUT and a scaler; it has **no auto-exposure and no
automatic white balance**, and `v_proc_ss` is built without colour space conversion.

* **Dark and contrasty:** the gamma LUT powers up at 1.0, i.e. linear light. Set roughly
  0.45 — the sRGB display encode — on all three channels. The controls take the exponent
  times ten, so `4` or `5`.
* **Green cast:** there is no white balance, and green has twice as many Bayer samples as
  red and blue. Compensate with a slightly *larger* exponent on green.

```
v4l2-ctl -d /dev/video-cam0 --set-ctrl=red_gamma_correction_1_0_1_10=5,green_gamma_correction_1_0_1_1=6,blue_gamma_correction_1_0_1_10=5
v4l2-ctl -d /dev/video-cam0 --set-ctrl=exposure=1759,analogue_gain=232,digital_gain=256
```

To check the colour order and the Bayer phase independently of the scene, switch the
sensor's own colour bars on (`--set-ctrl=test_pattern=1`): row 540 of the captured frame
must read white, yellow, cyan, green, magenta, red, blue, black, with byte 0 = R.

```{note}
`horizontal_flip` / `vertical_flip` change the Bayer order. Set them *before* running
`init_c2c_cams.sh`, or the demosaic will be configured for the wrong phase and the colours
will be wrong.
```

See [Using the cameras from Linux](linux_cameras) for the full control table.

## Linux: capture starts but no frames arrive

* **Use MMAP buffers only** (`--stream-mmap`, `io-mode=mmap`). The remote frame buffer
  writers are 32-bit masters that reach only `0x0000_0000`–`0x7FFF_FFFF` of the host DDR; a
  USERPTR or DMABUF buffer from the DDR above 4 GB cannot be written by them.
* `Stream Line Buffer Full!` in `dmesg` (CSI-2 RX `ISR` bit 18) means the frame buffer
  writers could not keep up and back pressure reached the receiver. It was never reached at
  two cameras of 1080p at 47.6 fps; if you see it, look at `frmbuf_burst_len` in
  `bd_fpga.tcl` (see [Advanced](advanced)) and at the link status for errors.
* Check the interrupts: `/proc/interrupts` should show one `v_frmbuf_wr` interrupt per
  CSI-2 "frame received" interrupt on each camera.

## Linux: the DisplayPort monitor stays dark

Full diagnostics are in [Showing the cameras on a DisplayPort monitor](display); `c2c-display
check` collects all of them at once. The usual causes, in the order worth checking:

* **`modetest -M xlnx -D a2000000.v_mix` lists no connectors.** The video mixer did not attach
  to the DisplayPort bridge. Check `/proc/cmdline` for `xlnx_mixer.connect_drm_bridge=1` — the
  mixer is built into the kernel, so that is the only way to set it. Then look in `dmesg` for
  `zynqmp-dpsub ...: DP output port not connected` (the `dp-connector` node is missing from the
  device tree) or `'xlnx,video-format' property missing` (the `&display_pipeline_v_mix_0`
  override did not apply — check that the generator still emits that label).
* **Connector is `connected` but the screen is black.** Almost always the mode: the PL pixel
  clock is built for 1080p60, and if `modetest` picks the monitor's preferred mode instead
  (144 Hz, 4K) the DisplayPort drives no valid pixels. Always pin the rate (`...-60@...`), which
  is what `c2c-display` does. Confirm with
  `cat /sys/kernel/debug/clk/*clk_out1*/clk_rate` — it should read `148500000`.
* **`status=connected` but the EDID is empty.** The hot-plug pin is asserted but the AUX
  channel is not answering: suspect the `psgtr` reference-clock node
  (`Invalid reference clock number 3` in `dmesg`) rather than anything in the PL.
* **Picture is there but in the wrong place, or centred instead of in its window.** `kmssink`
  needs `can-scale=true`, and `render-rectangle` needs the spaced `"< x, y, w, h >"` form; with
  either wrong the rectangle is silently ignored.
* **Picture is there but the colours are wrong.** The component order of the native video bus
  and the DisplayPort live video input do not agree by default, and the design crosses two of
  the three components in the `vid_concat` of the `display_pipeline` hierarchy of
  `bd_zynqmp.tcl` to fix it. Measured on this hardware, the crossover needed is **green and
  blue**, not the red/blue swap one might expect — red is the component that is already
  right. So test with **four bars (red, green, blue, white) in one frame**, never with a
  single flat colour: a solid-red test passes whether the mapping is right or not, and a
  webcam's auto white balance destroys a full-screen flat colour anyway. If you do have to
  change it, change `vid_concat` and rebuild the XSA — not the remote AUBoard pipeline, and
  not with a `videoconvert`, which would cost CPU on every frame. See
  [Showing the cameras on a DisplayPort monitor](display).
* **`c2c-display` says it is rescaling the pipelines.** That is normal: the video mixer can
  only upscale, so a 960x540 window needs the frames to leave the AUBoard at 960x540, and
  `c2c-display` re-runs `c2c-init-cams` for the size it needs and re-applies the picture
  controls. `systemctl restart c2c-cameras` puts them back to the service's own size. Pass
  `-k` to forbid the change — `c2c-display` then refuses when the capture size and the window
  size differ, and tells you what to run (`init_c2c_cams.sh 1920 1080 960 540`).
