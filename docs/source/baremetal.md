# Bare-metal demo (ZCU106)

This design has a bare-metal application for the ZCU106 as well as the Linux images
described in [Yocto](yocto) and [Using the cameras from Linux](linux_cameras).
It drives both camera pipelines of the AUBoard from the A53, without an operating
system, and writes the frames into the DDR of the ZCU106.

Its real subject is not the cameras. It is this question:

> The camera IP is in the *other* FPGA. The ZCU106 hardware hand-off (XSA) has never
> heard of it. How does the software build system learn what drivers to pull in and
> what addresses to give them?

The answer is the **System Device Tree (SDT) flow** of the Vitis Unified IDE, and a
**User DTS** that describes the remote hardware.

```{contents}
:local:
:depth: 2
```

## How the SDT flow makes this possible

In Vitis Classic the build system read all hardware metadata out of the XSA. In the
Unified IDE it does not: the tools first generate a **System Device Tree** from the XSA,
and a tool called **Lopper** then reads that device tree to decide which drivers a BSP
needs and to fill in their configuration structures (`*_g.c`) and `xparameters.h`.

That extra step is the opening. A device tree is just text, and Vitis lets us add our
own: *Create Platform Component → Advanced Options → User DTS* in the IDE. Whatever we
put in that file is merged into the generated System Device Tree before Lopper runs. IP
that exists in no XSA at all can therefore be described to the build system exactly as
if it were local.

```
   Vivado (ZCU106)                 hand written
   Vivado/zcu106/c2c_wrapper.xsa   Vitis/common/dts/remote_pipeline.dtsi
        |                                    |
        +---------------> sdtgen <-----------+   (VITIS_SDT_INCLUDE_DTS)
                             |
                    System Device Tree
                             |
                          Lopper
                             |
          +------------------+------------------+
   standalone BSP:                        xparameters.h
   iic, gpio, intc, mipicsiss,            XPAR_CAM0_IIC_BASEADDR 0xa0110000
   v_demosaic, v_gamma_lut,               XPAR_CAM0_FRMBUF_BASEADDR 0xa0150000
   vprocss, v_frmbuf_wr, ...              ...
```

## The User DTS

`Vitis/common/dts/remote_pipeline.dtsi` is the interesting file of this flow. It adds
one node per remote IP under `&amba_pl`:

```
&amba_pl {
	c2c_intc: interrupt-controller@a0040000 { ... };

	cam0_gpio:     gpio@a0120000               { ... };
	cam0_iic:      i2c@a0110000                { ... };
	cam0_csi:      mipi_csi2_rx_subsystem@a0100000 { ... };
	cam0_demosaic: v_demosaic@a0130000         { ... };
	cam0_gamma:    v_gamma_lut@a0140000        { ... };
	cam0_vpss:     v_proc_ss@a0180000          { ... };
	cam0_frmbuf:   v_frmbuf_wr@a0150000        { ... };
	/* ... and the same again for CAM2 at 0xA020_0000 */
};
```

Three things decide whether this works.

**The compatible string** is what Lopper matches against the driver bindings in
`<Vitis>/data/embeddedsw/XilinxProcessorIPLib/drivers/`. `"xlnx,v-frmbuf-wr-3.0"` is
what pulls the `v_frmbuf_wr` driver into the BSP.

**The properties** are what fills the driver's config structure. Each driver ships a
YAML binding with a `required:` list, and every name on that list has to be in the node
or the generated structure gets a zero where a real value belongs. The values in this
file are the ones the AUBoard block design was actually built with — the build log of
the `auboard` target prints them on the `INFO: [cam]` and `INFO: [map]` lines, and
[the link contract](https://github.com/fpgadeveloper/mipi-over-chip2chip) records them.
The property *names* and node shapes were taken from a System Device Tree that `sdtgen`
generated for a design that has the same IP locally, which is the method the article
this design accompanies recommends.

**The address map** is the part that is easy to miss. Lopper only generates
configuration for nodes the processor cluster can reach, and reachability comes from the
`address-map` property of the `cpus_a53` node. A device tree property cannot be appended
to, so the whole map has to be deleted and written out again with the new entries added:

```
&cpus_a53 {
	/delete-property/ address-map;
	address-map = <0x0 0xf0000000 &amba 0x0 0xf0000000 0x0 0x10000000>,
		      ...                                     /* 112 existing entries */
		      <0x0 0xa0040000 &c2c_intc 0x0 0xa0040000 0x0 0x10000>,
		      <0x0 0xa0110000 &cam0_iic 0x0 0xa0110000 0x0 0x10000>,
		      ...                                     /* 23 remote entries */
};
```

Those 112 existing entries belong to the ZCU106 XSA and change whenever that design
changes. Copying them into a version-controlled file by hand would rot, so this repo
does not: `Vitis/py/user_dts.py` runs `sdtgen` once on the current XSA, reads the map
back out of the generated `system-top.dts`, appends the remote entries from one table at
the top of that script, and writes the composed file into the build directory
(`Vitis/<target>_workspace/dts/`). The hand-written part stays in
`Vitis/common/dts/remote_pipeline.dtsi` and never has to change when the ZCU106 design
is rebuilt.

```{note}
The User DTS is `#include`d at the end of the generated `system-top.dts`, so it goes
through the C preprocessor. A `*/` inside a comment — in a file path, say — ends the
comment early and `dtc` then fails with a syntax error somewhere further down.
```

### How the file reaches the platform build

In the Python API the *User DTS* field of the IDE is the `advanced_options` argument of
`client.create_platform_component()`; it becomes the environment hook
`VITIS_SDT_INCLUDE_DTS` that the tool's `platformutil.tcl` turns into
`sdtgen set_dt_param -include_dts`.

The shared Opsero build script — `Vitis/py/build-vitis.py`, the same file every reference
design uses — passes it when `args.json` asks for it. Two optional keys drive that, and
both are inert in a repo that does not set them:

```json
"user_dtsi":           "common/dts/remote_pipeline.dtsi",
"user_dtsi_generator": "py/user_dts.py",
```

`user_dtsi` alone is enough for a design whose User DTS is a checked-in file. Ours is not:
the address-map block has to be regenerated from the current XSA, so `user_dtsi_generator`
names a repo-local module that *writes* the file. The shared script imports it and calls

```python
compose(vitis_dir=<Vitis/>, xsa_path=<the XSA>, out_dir=<workspace>/dts, cfg=<args.json>)
```

after the workspace is opened and **before** the platform is created — the only moment a
User DTS can still be passed, and the earliest moment anything may be written under the
workspace, since Vitis refuses a workspace directory holding files it did not create. The
path that comes back becomes

```python
advanced_options = client.create_advanced_options_dict(user_dtsi=<path>)
```

on `create_platform_component()`.

This is deliberately *not* the script's older `pre_platform_build_script` hook: that one
runs after `create_platform_component()` — it is handed the finished platform object — so
it is too late to influence the platform's own device tree.

One more repo-local script, `Vitis/py/pre_build.py`, runs through the shared script's
existing `pre_build_script` hook. `pipe.c` uses `pow()` for the gamma curve and the
application component's generated link line has no `-lm`, so the script adds `m` to
`USER_LINK_LIBRARIES` in the component's `UserConfig.cmake` before the build.

So the `Vitis/py/` directory holds four scripts and the usual `args.json`:
`build-vitis.py` and `make-boot.py` (both byte-identical to the shared, canonical copies)
and `user_dts.py` and `pre_build.py` (repo-local, referenced from `args.json`).

## What ends up in the BSP

This is the claim worth checking, and it is easy to check. After a build,
`Vitis/zcu106_workspace/zcu106_platform/psu_cortexa53_0/standalone_psu_cortexa53_0/bsp/`
contains drivers for IP that is in no XSA:

```
libsrc/  ... gpio  iic  intc  mipicsiss  csi  v_demosaic  v_frmbuf_wr
             v_gamma_lut  v_hscaler  v_vscaler  vprocss  video_common ...
```

`include/xparameters.h` gives them the addresses from the User DTS:

```c
#define XPAR_XV_DEMOSAIC_NUM_INSTANCES 2
#define XPAR_CAM0_DEMOSAIC_BASEADDR 0xa0130000
#define XPAR_CAM2_DEMOSAIC_BASEADDR 0xa0230000

#define XPAR_XIIC_NUM_INSTANCES 2
#define XPAR_CAM0_IIC_BASEADDR 0xa0110000
#define XPAR_CAM0_IIC_INTERRUPTS 0x2002
#define XPAR_CAM0_IIC_INTERRUPT_PARENT 0xa0040001
```

and the generated config tables carry them into the drivers
(`libsrc/v_frmbuf_wr/src/xv_frmbufwr_g.c`):

```c
XV_frmbufwr_Config XV_frmbufwr_ConfigTable[] = {
	{
		"xlnx,v-frmbuf-wr-3.0", /* compatible */
		0xa0150000,             /* reg */
		0x1,                    /* xlnx,samples-per-clock */
		0x780,                  /* xlnx,max-cols  = 1920 */
		0x4d0,                  /* xlnx,max-rows  = 1232 */
		0x8,                    /* xlnx,max-data-width */
		0x40,                   /* xlnx,aximm-data-width = 64 */
		0x20,                   /* xlnx,aximm-addr-width = 32 */
		...
		0x1,                    /* xlnx,has-rgb8 */
		...
		0x2001,                 /* interrupts */
		0xa0040001              /* interrupt-parent */
	},
	...
```

`0xa0150000` is the frame buffer writer of CAM0 on the AUBoard, reached over the
Chip2Chip link. The application never writes that number down: it uses
`XPAR_CAM0_FRMBUF_BASEADDR`, so a User DTS that failed to reach the platform build is a
compile error, not a silent wrong-address bug.

```{warning}
**One driver's generated table is wrong in Vitis 2025.2, and it is not the User DTS's
fault.** `mipicsiss_v1_14/data/mipicsiss.yaml` lists 26 entries under `required:`, but
`XCsiSs_Config` has only 24 slots in a design with no separate MIPI RX PHY IP — its last
three fields sit behind `#if (XPAR_XMIPI_RX_PHY_NUM_INSTANCES > 0)`. The generated
`xcsiss_g.c` therefore overflows the struct (GCC says *excess elements in struct
initializer*) and `EnableVCx`, `IntrId` and `IntrParent` come out wrong. Any design with
a local `mipi_csi2_rx_subsystem` 6.0 and no `mipi_rx_phy` hits this. It does not affect
this demo: the subsystem needs no register write to receive, and the application never
uses the `XCsiSs` driver — exactly as in the RPi Camera FMC reference design. Every other
generated table (demosaic, gamma, VPSS, frame buffer writer, IIC, GPIO, INTC) matches its
struct exactly and builds without a warning.
```

## Interrupts

The remote IP interrupt through an `axi_intc` in the AUBoard, whose output crosses the
link on `axi_c2c_m2s_intr_in[0]` and arrives at the ZCU106 as `pl_ps_irq0[0]` = **GIC SPI
89**. The User DTS describes that cascade, and Lopper encodes it correctly:

| generated symbol | value | meaning |
|---|---|---|
| `XPAR_C2C_INTC_INTERRUPTS` | `0x4059` | SPI 89 (`0x59`), sense 4 = level high (`4 << 12`) |
| `XPAR_C2C_INTC_INTERRUPT_PARENT` | `0xf9010000` | the GIC distributor |
| `XPAR_CAM0_IIC_INTERRUPTS` | `0x2002` | INTC input 2, sense 2 = level high |
| `XPAR_CAM0_IIC_INTERRUPT_PARENT` | `0xa0040001` | the remote INTC — bit 0 set marks "AXI INTC, not GIC" |

So the *description* is complete and right. The *runtime* is not.

`XSetupInterruptSystem()` (`xinterrupt_wrap.c`) branches on bit 0 of `IntrParent`. For an
AXI INTC parent it calls `XRegisterInterruptHandler(NULL, IntcParent)`, which installs
`XIntc_InterruptHandler` as the CPU's `XIL_EXCEPTION_ID_INT` vector. On a MicroBlaze,
where the INTC *is* the root controller, that is correct. On a Cortex-A53 it is not: the
IRQ vector must go through `XScuGic_InterruptHandler`, which acknowledges the GIC, and
nothing in that path ever enables SPI 89 in the GIC distributor. Installing the INTC
handler also replaces whatever the GIC-parented devices (the UART, for instance) had
registered. The wrapper has one static `XIntc` and one static `XScuGic` and no notion of
one hanging below the other.

**This application therefore polls**, which is honest and, for a demo that captures a
fixed number of frames, entirely sufficient:

* `i2c.c` is a small polled AXI IIC driver at register level, using the sequences that
  `scripts/jtag/auboard_cam.tcl` has already proven on this hardware (including the
  quirk that the core raises its transmit-error flag at the end of every master read).
* `frmbuf.c` polls the `DONE` bit of the frame buffer writer's interrupt status register,
  counts the frame and rotates the buffer address there. The IER bit is set so the status
  latches; GIE stays off, so the IP never drives its interrupt line.

Polling costs this demo nothing measurable: it captures at the sensor's full 47.6 fps on
both cameras with no dropped frames (see [What it prints](what-it-prints)). The poll loop
goes round in tens of microseconds against a 21 ms frame period.

Interrupts would **not** fix the frame-address race described under [Why the demo stops the
writers before you dump](freeze-why), because the IP
re-latches its address within a clock of `DONE` — far sooner than any interrupt handler can
run. That is a property of auto-restart, not of polling.

If you do want interrupts anyway, the cascade has to be wired by hand rather than through
`XSetupInterruptSystem()`: initialise `XScuGic`, `XScuGic_Connect(SPI 89,
XIntc_InterruptHandler, &Intc)`, `XScuGic_Enable()`, then `XIntc_Initialize` /
`XIntc_Start(XIN_REAL_MODE)` on `XPAR_C2C_INTC_BASEADDR` and `XIntc_Connect` /
`XIntc_Enable` per device. That is a worthwhile follow-up; it is not what this demo does.

## The application

`Vitis/common/src/`, ported from the RPi Camera FMC reference design with the display
half (frame buffer read, video mixer, TPG, HDMI TX, VPHY) dropped.

| file | what it does |
|---|---|
| `main.c` | link check, camera probe, bring-up, capture loop, report, idle |
| `link.c/.h` | the Chip2Chip link status register and the refusal to go on without it |
| `pipe.c/.h` | one camera pipeline: GPIO, reset release, demosaic, gamma, scaler, writer |
| `frmbuf.c/.h` | frame buffer writer, polled, three rotating slots, the freeze, cache maintenance |
| `timer.h` | milliseconds from `CNTPCT_EL0` / `CNTFRQ_EL0` |
| `i2c.c/.h` | polled AXI IIC (see above) |
| `imx219.c/.h` | sensor detection and the 1920x1080 register table |
| `remote.h` | the `XPAR_*` macros of the remote IP, and where the frames go in DDR |
| `config.h` | video mode, gamma, how many frames to capture |

Three things in it are specific to a two-board system and worth calling out.

**The link check comes first.** There is no timeout anywhere in the Chip2Chip register
path. An AXI4-Lite access into the `0xA000_0000` window while the link is down never
completes and the A53 hangs with no way out but a power cycle. `main()` reads the link
status register — which is on the ZCU106 side and always safe — and refuses to touch
anything remote until channel-up, lane-up, PLL-locked and link-status are all set. The
capture loop keeps watching it, so a link that drops mid-run is reported instead of
hanging the CPU.

**Resets are released before an IP is touched.** A video IP whose reset bit in the
pipeline's `axi_gpio` is 0 does not answer on AXI4-Lite either, with the same
consequence. `pipe_init()` releases each reset, waits for the synchroniser in the video
clock domain, and only then calls the driver's initialisation.

**The frame buffers are in DDR low, and the caches are managed by hand.** The frame
buffer writers are 32-bit AXI masters and the AXI MMU of the ZCU106 design only passes
`0x0000_0000`–`0x7FFF_FFFF`; anything above that gets a DECERR. The buffers are at
`0x2000_0000` (CAM0) and `0x2200_0000` (CAM2), three 1920x1080 RGB8 slots each. That path
comes in through `S_AXI_HP0_FPD`, which does not go through the cache-coherent
interconnect, so the application flushes the region before the writer starts and
invalidates a frame before anything reads it.

The gamma LUT powers up linear, which gives a dark, contrasty picture, and this pipeline
has no automatic white balance, so raw RGB comes out green. `pipe_load_gamma()` fixes both
with one mechanism — a **per-channel gamma exponent**, `out = 255*(in/255)^g`, with red and
blue lifted harder than green so that the difference stands in for the missing white
balance. The exponents in `config.h` (0.50 / 0.60 / 0.50) are the triple measured on the
Linux side of this same hardware; see [Using the cameras from Linux](linux_cameras).

(freeze-why)=
### Why the demo *stops* the writers before you dump

This is the part that is easy to get wrong, and the demo got it wrong first.

The frame buffer writer runs with auto-restart, so it **re-latches its buffer address
register within a clock of `DONE`** — thousands of cycles before a CPU that polls (or even
one that takes an interrupt) can write a new address. An address written after `DONE`
therefore takes effect one frame *later* than the naive reading suggests, which makes "the
slot that has just finished" in general the slot the hardware is filling right now. On top
of that, a 6 MB block read over JTAG takes about 23 seconds, during which a running writer
goes round its three slots some 350 times. Rotating buffers do not make a frame readable.

`FrmbufFreeze()` does not try to guess when the IP samples the register. It stops rotating,
so the IP re-latches the **same** slot frame after frame; waits for three completions, after
which that slot holds a whole frame whatever the sampling instant; and then flushes the core
immediately after a `DONE`, inside the vertical blanking gap — 1113 total lines for 1080
active at 47.6 fps is about 600 µs, far more than the two register accesses need. `main()`
then stops both sensors. **Nothing writes the frame buffers afterwards**, which is what
makes a dump reproducible: two JTAG dumps of the same address a minute apart come back
byte-identical.

Because the frozen slot depends on how many frames were captured, the application also
publishes the geometry and the frozen address of each camera in a small block in DDR at
`0x1FFF_0000` (see `remote.h`), and `zcu106_baremetal.tcl` reads it — so `run+dump` needs
nobody to read the UART.

## Building

The bare-metal flow needs Vivado and Vitis; it does **not** need PetaLinux, and it runs
on Windows as well as on Linux.

```
./build.sh standalone --target zcu106
```

(`build.bat standalone --target zcu106` from a plain Windows shell.) That builds the XSA
first if it is not there, then the Vitis platform, the BSP, the application and the boot
image. With the XSA already built, a run from a deleted `Vitis/zcu106_workspace/` takes
**2 m 17 s – 2 m 20 s** (measured, three clean rebuilds on a Linux host) — roughly a minute
of that is the extra `sdtgen` pass that reads the A53 address map back out of the XSA.
(`./build.sh all --target zcu106` does this plus the Yocto build, which is hours; use
`standalone` when the bare-metal demo is what you want.)

```{note}
The Vitis workspace takes a **copy** of `Vitis/common/src/`, so an edit there is only
picked up by a fresh workspace: delete `Vitis/zcu106_workspace/` (and `Vitis/boot/`, whose
presence makes the runner skip the stage as up to date) before rebuilding.
```

What appears:

| artifact | path |
|---|---|
| Vitis workspace | `Vitis/zcu106_workspace/` |
| composed User DTS | `Vitis/zcu106_workspace/dts/remote_pipeline.dtsi` |
| platform + standalone BSP | `Vitis/zcu106_workspace/zcu106_platform/` |
| application ELF | `Vitis/zcu106_workspace/cam_test/build/cam_test.elf` (about 1.3 MB) |
| FSBL | `Vitis/zcu106_workspace/zcu106_platform/export/zcu106_platform/sw/boot/fsbl.elf` |
| `BOOT.BIN` | `Vitis/boot/zcu106/BOOT.BIN` (about 19 MB — it holds the bitstream) |
| boot image zip | `bootimages/mipi-over-chip2chip_zcu106_standalone-*.zip` (`./build.sh package`) |

```{note}
A bare-metal platform exports only `fsbl.elf` under `sw/boot/`; there is no PMU
firmware build. Vitis does export a prebuilt one next to it at `sw/qemu/pmufw.elf` —
a genuine MicroBlaze ELF that runs on the real PMU — and the JTAG script picks that up
automatically. `BOOT.BIN` contains the FSBL, the bitstream and the application, and no
PMU firmware partition.
```

`BOOT.BIN` holds the FSBL, the ZCU106 bitstream and the application; copy it to a FAT32
SD card and set the ZCU106 to SD boot to run the demo without a debugger. **The AUBoard
must be running the `auboard` design and the SFP+ cable must be connected first** — it
does that by itself if the design is in its configuration flash
([Booting the AUBoard from its configuration flash](flash)), otherwise program it over
JTAG ([Build instructions](build_instructions)).

## Running it over JTAG

`scripts/jtag/zcu106_baremetal.tcl` does the whole thing on the two-cable bench: it
selects only targets of the ZCU106's cable, resets, programs the PL, runs the PMU
firmware and the **real FSBL** (not a Tcl `psu_init` — after a Tcl-only initialisation,
block reads of the PS DDR on this board have ended in an AP transaction timeout, and the
frame dump is a 6 MB block read), releases the PS-PL isolation and `pl_resetn0`, then
downloads the application and starts it.

```{warning}
**The FSBL does not release the PL on this path, and that step is not optional.** The FSBL
removes the PS-PL isolation and deasserts `pl_resetn0` in `XFsbl_PlWaitForDone()` — only on
the branch where the FSBL itself loads a bitstream out of a boot image. Here the PL is
programmed over JTAG and the FSBL boots in JTAG mode with no boot image, so that code never
runs: `psu_init()` on its own leaves the PL powered down behind the isolation with
`pl_resetn0` asserted, and **no PL slave answers at all** — not the remote window, not even
the ZCU106's own `axi_gpio_link` at `0xA100_0000`. Nothing in that path times out, so the
application's very first register read hangs the A53 and only a power cycle recovers it.

The script therefore calls `psu_ps_pl_isolation_removal` and `psu_ps_pl_reset_config` from
the XSA's own `psu_init.tcl` after the FSBL, exactly as `scripts/jtag/zcu106_init.tcl` does.
Isolation removal is a power-up request to the PMU, so it needs the PMU firmware the script
already runs: do not combine it with `-nopmufw`. It then reads `0xA100_0000` from xsdb and
prints it, so a PL that is still asleep is reported by the script instead of silently
hanging the CPU.
```

```
# the AUBoard: nothing to do if it boots the camera design from its flash,
# otherwise program it once:
vivado -mode batch -nolog -nojournal -notrace -source scripts/jtag/auboard_prog.tcl \
  -tclargs Vivado/auboard/auboard.runs/impl_1/c2c_wrapper.bit

# then the ZCU106: boot, wait for the capture, dump both frozen frames
xsdb scripts/jtag/zcu106_baremetal.tcl run+dump

# only dump, from a board that is already running the demo: the addresses come
# from the block the application publishes in DDR, so they need not be given
xsdb scripts/jtag/zcu106_baremetal.tcl dump

# turn a dump into a picture
python3 scripts/rgb2png.py frames/cam0.bin 1920 1080 --stats
```

The script assumes a persistent `hw_server` on `tcp:127.0.0.1:3121` and picks its targets
with `jtag_cable_name =~ "*FT232H 11093*"`, so the AUBoard on the same server is left
alone. Use `-cable` for a different board. `-addr0` / `-addr2` are only a fallback for a
board whose application has not reached its report yet.

Measured on the bench: **25 s** for `run` (reset, PL, PMU firmware, FSBL, isolation
removal, application), and **70 s** for `run+dump` — that 25 s, the 25 s `-wait`, and about
23 s for the two 6 MB block reads.

```{warning}
**Do not re-program the ZCU106 PL while the AUBoard is streaming.** The AUBoard's frame
buffer writers are AXI masters *into* the ZCU106; re-programming the ZCU106 PL underneath
them leaves them with writes that never complete, and they then never finish another frame
— the next run probes both cameras happily and captures **0 frames**. Only a power cycle
of the AUBoard clears it: switch its power off and on again (it reloads the design from its
configuration flash in about two seconds; if you load it over JTAG instead, program it
again).

The application avoids this by stopping its writers and both sensors before it idles, so
consecutive `run` cycles are safe.
Note that the sticky `axi_c2c_link_error` /
`axi_c2c_multi_bit_error` bits on the AUBoard side (status `0x03F`) latch on *every* ZCU106
PL re-program, because the link drops and retrains — they are **not** by themselves a sign
of this problem. Bits 0..3 are the live state.
```

(what-it-prints)=
## What it prints

115200 8N1 on the USB-UART of the ZCU106 (`/dev/ttyUSB0`, the first of the four ports).
This is a **recorded run** on the bench ZCU106 + AUBoard 15P, not an illustration:

```
################################################################
#   MIPI over Chip2Chip - bare-metal camera demo  v1.0         #
#   ZCU106 (host) + Tria AUBoard 15P + RPi Camera FMC (OP068)  #
################################################################

The camera IP of this design is in the FPGA of the AUBoard, not
in the ZCU106. The drivers below came from the User DTS of the
platform (Vitis/common/dts/remote_pipeline.dtsi).

  remote window : 0xA0000000 (AXI Chip2Chip)
  remote INTC   : 0xA0040000
  CAM0 base     : 0xA0100000   CAM2 base     : 0xA0200000
  link status   : 0xA1000000 (on the ZCU106)

Chip2Chip link status: 0x00F  [ channel_up lane_up pll_locked c2c_link ]
Link is up.

Probing the cameras:
  CAM0:
      IMX219 found (model id 0x0219)
  CAM2:
      IMX219 found (model id 0x0219)

Configuring the video pipelines:
  CAM0: ok
  CAM2: ok

Starting the cameras:
  CAM0: streaming
  CAM2: streaming

Capturing 60 frames per camera ...

Freezing the frames in DDR:
  CAM0: writer stopped on a whole frame at 0x20000000
  CAM2: writer stopped on a whole frame at 0x22000000
  the sensors are stopped: nothing writes the DDR any more

Results after 1303 ms:
  cam  frames    fps   max gap  geometry    stride   frame size   frozen frame
  0    63        48.0   22 ms   1920x1080   5760     6220800      0x20000000
  2    60        47.5   22 ms   1920x1080   5760     6220800      0x22000000

'max gap' is the longest interval between two consecutive
frames: one frame period means no frame was dropped.

The frames are RGB8: 3 bytes per pixel, R first, no padding
between pixels; a line is 'stride' bytes. Dump one with
  mrd -bin -file cam0.bin 0x20000000 1555200
and convert it with scripts/rgb2png.py.

Chip2Chip link status: 0x00F  [ channel_up lane_up pll_locked c2c_link ]

Idle - the frames are frozen in DDR. Dump them over JTAG now.

  alive: CAM0 63 frames frozen at 0x20000000  CAM2 60 frames frozen at 0x22000000  link 0x00F  [ channel_up lane_up pll_locked c2c_link ]
  alive: CAM0 63 frames frozen at 0x20000000  CAM2 60 frames frozen at 0x22000000  link 0x00F  [ channel_up lane_up pll_locked c2c_link ]
```

What the numbers mean, and what they were measured against:

* **48.0 and 47.5 frames per second, both cameras at once.** The IMX219 register table of
  this demo programs a frame length of 1113 lines, i.e. 47.6 fps, so both pipelines run at
  the sensor's maximum — 1920x1080 RGB8 twice over, about **592 MB/s through the Chip2Chip
  link**. The Linux side of the same hardware measures 47.57 fps per camera
  ([Using the cameras from Linux](linux_cameras)); bare metal reaches the same rate.
* **No dropped frames.** `max gap` is the longest interval the application saw between two
  consecutive `DONE`s. 22 ms at a 1 ms timer granularity is one frame period (21.0 ms), so
  no frame was missed on either camera over the whole capture.
* The two cameras are timed **separately, each from its own first frame**. They do not start
  together: programming an IMX219 is about sixty register writes on a 100 kHz I2C bus, so
  the second camera starts a good third of a second after the first, and one common start
  time would understate it.
* `frames` differs slightly between the cameras because the capture loop stops when *both*
  have reached `CAPTURE_FRAMES`; whichever got there first keeps counting meanwhile.
* The link reads `0x00F` before the capture, after it, and in every idle line.

## Troubleshooting

**"the AXI Chip2Chip link to the AUBoard is DOWN"** — the application stops before it
touches anything remote, which is the desired behaviour. Program the AUBoard, check the
SFP+ cable is in SFP0 of the ZCU106, and confirm the PL of the ZCU106 was programmed and
`pl_resetn0` released. `xsdb scripts/jtag/zcu106_mem.tcl status` decodes the status
register without any software running.

**"no IMX219 at I2C 0x10"** — the RPi Camera FMC is not fitted, the camera is not
connected, or the ribbon cable is in the wrong way round. `vivado -mode batch -source
scripts/jtag/auboard_cam.tcl -tclargs i2cscan 0` scans the bus from the AUBoard side.

**The application hangs with no output at all** — the UART is on the PS, so this is a
boot problem rather than a link problem: check that the FSBL ran (the JTAG script stops
on `XFsbl_Exit`) and that the boot-mode register was set to JTAG.

**The CPU hangs partway through the bring-up** — an access to a remote IP that is in
reset, or to the window after the link dropped. Power-cycle the ZCU106; a system reset
does not reliably clear the debug access port after a bus access that never completed.

**Nothing at all is printed after the address banner** — the first thing after it is a read
of the link status GPIO at `0xA1000000`, so the PL is not answering: the PS-PL isolation is
still in place or `pl_resetn0` is still asserted. See the warning under *Running it over
JTAG*. Power-cycle the ZCU106 and use a script that releases them.

**Both cameras are found but the capture reports 0 frames** — the AUBoard's frame buffer
writers are stuck, almost always because the ZCU106 PL was re-programmed while they were
streaming into it. Resetting the remote video IP does not clear it: power-cycle the AUBoard
(switch its power off and on again; it reloads the design from its configuration flash, or
program it again over JTAG if that is how you load it) and run again. The sticky
error bits in the AUBoard's status register are *not* a reliable symptom — they latch on
every re-program.

**The dumped picture is torn** — it should not be: the application stops its writers on a
frame boundary and switches both sensors off before it idles, and two dumps of the same
address come back byte-identical. If you do see a tear, check that the UART actually
reported `writer stopped on a whole frame` rather than the timeout warning.

**Colours look wrong** — if red and blue are swapped, pass `--bgr` to `rgb2png.py`. If the
picture is dark, flat or tinted, the per-channel gamma exponents in
`Vitis/common/src/config.h` (`GAMMA_RED` / `GREEN` / `BLUE`) are the knobs: smaller lifts
the channel more. There is no automatic white balance in this pipeline, so the difference
between the three exponents *is* the white balance — lifting red and blue equally against a
higher green exponent is what cancels the green bias of the Bayer pattern. Multiplying a
channel on top of the curve instead (rather than changing its exponent) clips the highlights
and tints the picture.

## The pictures

Both cameras, captured by this application and pulled out of the ZCU106's DDR over JTAG
(`xsdb scripts/jtag/zcu106_baremetal.tcl run+dump`, then `scripts/rgb2png.py`):

They are sharp, correctly demosaiced — no maze or zipper artefacts, so the RGGB Bayer phase
is right — and the same tone as the Linux captures of the same hardware.

The byte order was *measured* rather than assumed: with the three gamma tables deliberately
loaded with different gains, the channel that came out lowest was memory byte 1 and the
highest was byte 2, matching the gains given to LUT 1 and LUT 2. Gamma LUT 0/1/2 therefore
drive memory bytes 0/1/2, and the layout is R first — which is what
`XVIDC_CSF_MEM_RGB8` and the Linux driver's `V4L2_PIX_FMT_RGB24` promise.
