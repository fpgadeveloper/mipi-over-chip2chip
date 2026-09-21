# Description

This reference design connects MIPI CSI-2 cameras that are attached to a **processor-less
FPGA board** to a **Zynq UltraScale+ host** running Linux. The two boards are joined by
[AXI Chip2Chip] over an [Aurora 64B/66B] serial link on a single SFP+ direct attach cable.
The host sees the remote video pipelines as ordinary memory-mapped peripherals, and the
captured frames are written straight into the DDR memory of the host.

## Why a second FPGA on the mezzanine

The AMD MIPI CSI-2 RX subsystem (and the equivalent IP of other vendors) needs its D-PHY
lanes on particular FPGA pins: pins that belong to the right byte group and offer the
DBC/QBC functions of the UltraScale/UltraScale+ I/O. The VITA 57.1 FMC standard fixes the
connector, the electrical levels, the clocks and the transceiver locations, but it does not
constrain pins at that level. A conventional MIPI CSI-2 FMC can therefore be pin-matched to
one or two carrier boards, but never to all of them.

Putting a small FPGA on the mezzanine card breaks that limitation. The MIPI pin assignment
becomes a property of the *mezzanine's own* FPGA and is fixed once; the interface towards
the carrier becomes a generic serial link — here Aurora over the FMC transceiver pairs —
which almost any carrier can provide.

There is a second benefit. A 1080p capture pipeline is not free: in this design one
pipeline costs about **11.6k LUTs, 15.5k flip-flops, 30 block RAM tiles and 41 DSP slices**
(see [Resource usage and timing](resource-usage)). Moving it to the mezzanine leaves those
resources on the main device for higher level work.

This repository is the **proof of concept** of that architecture, built from off-the-shelf
hardware: an AMD ZCU106 plays the main board, and a Tria AUBoard 15P carrying the Opsero
[RPi Camera FMC] plays the mezzanine card. The link is an SFP+ DAC cable instead of the FMC
transceiver pairs.

## A two-board system

Unlike most Opsero reference designs, the target designs of this repository are not
alternatives to choose from. They are the two halves of one system and both must be built:

| Role      | Target design | Board | What it does |
|-----------|---------------|-------|--------------|
{% for design in data.designs %}{% if design.publish %}| {{ design.role | capitalize }} | `{{ design.label }}` | [{{ design.board }}]({{ design.link }}) | {% if design.role == "host" %}Runs Linux, controls the remote video pipelines and receives the frames in its DDR memory.{% else %}Has no processor. Carries the [RPi Camera FMC] with the cameras and holds the MIPI CSI-2 video pipelines.{% endif %} |
{% endif %}{% endfor %}

```
          AUBoard 15P  (xcau15p, no processor)                 ZCU106  (xczu7ev, Linux)
 +---------------------------------------------+     +---------------------------------------+
 |  RPi Camera FMC (OP068) on the FMC slot     |     |                                       |
 |                                             |     |                                       |
 |  CAM0 =MIPI=> [ pipeline 0 ] =AXI4=+        |     |         +--------+      +--------+    |
 |  CAM2 =MIPI=> [ pipeline 2 ] =AXI4=+        |     |         |  APU   |======|  DDR4  |    |
 |                     ^              |        |     |         +--------+      +--------+    |
 |          AXI4-Lite  |              v  AXI4  |     |             |                ^        |
 |         (registers) |        +-----------+  |     |       regs  v                | DMA    |
 |                     +--------|  AXI      |  |     |        +------------------------+     |
 |                              | Chip2Chip |  |     |        |    AXI Chip2Chip       |     |
 |                              |  MASTER   |  |     |        |    SLAVE               |     |
 |                              +-----+-----+  |     |        +-----------+------------+     |
 |                                    |        |     |                    |                  |
 |                              +-----+-----+  |     |              +-----+-----+            |
 |                              |  Aurora   |  |     |              |  Aurora   |            |
 |                              |  64B/66B  |  |     |              |  64B/66B  |            |
 |                              +-----+-----+  |     |              +-----+-----+            |
 +------------------------------------|--------+     +--------------------|------------------+
                                  SFP+ cage                            SFP0 cage
                                      |                                   |
                                      +====== SFP+ DAC cable ==============+
                                        1 lane, Aurora 64B/66B, 10.3125 Gb/s
```

## The chip-to-chip link

### Roles

The AXI Chip2Chip core is instantiated once on each board, in opposite roles. The naming is
worth reading twice, because the two AXI channels of the link run in opposite directions:

| | AUBoard 15P (`auboard`) | ZCU106 (`zcu106`) |
|---|---|---|
| `C_MASTER_FPGA` | `1` — **master** | `0` — **slave** |
| AXI4 memory-mapped | `s_axi` (slave port): the local masters push writes *into* the link | `m_axi` (master port): the traffic comes *out* of the link |
| AXI4-Lite | `m_axi_lite` (**master** port, `C_INCLUDE_AXILITE 2`) | `s_axi_lite` (**slave** port, `C_INCLUDE_AXILITE 1`) |
| What that means | the frame buffer writers write to the host's DDR; the local peripherals are driven by the register accesses arriving from the host | the PS is the register master of the remote peripherals; the remote writes land in the PS DDR |

```{note}
The Vivado GUI labels `C_INCLUDE_AXILITE` from the point of view of *where the AXI4-Lite
master lives*, so it calls the AUBoard's value ("2", the AXI4-Lite master port) "Slave" and
the ZCU106's value ("1", the AXI4-Lite slave port) "Master". The block design scripts set
the numbers directly.
```

### Aurora and the GT

One lane, 10.3125 Gb/s, Duplex, Streaming interface, no flow control, no CRC, shared logic
in the core, a single-ended 100 MHz `init_clk`, and a 156.25 MHz GT reference clock. The
Aurora user clock is therefore 161.1328125 MHz (line rate / 64); `auboard_axi.tcl status`
measures it on the AUBoard against the 300 MHz board oscillator.

The GT placement is the one interesting part, and it is the same trick on both boards:

| | AUBoard 15P | ZCU106 |
|---|---|---|
| SFP cage on | GTH Quad 226, channel 3 (`GTHE4_CHANNEL_X0Y11`) | GTH Quad 225, channel 2 (`GTHE4_CHANNEL_X0Y10`), the `SFP0` cage |
| Free-running 156.25 MHz reference clock enters | MGTREFCLK1 of **Quad 224** (pins Y7/Y6), two quads *south* | MGTREFCLK1 of **Quad 226** (pins U10/U9), one quad *north* |
| Source | the board's programmable clock generator U57, which outputs 156.25 MHz at power-up without programming | `USER_MGT_SI570_CLOCK1` (Si570 U56 through the Si53340 buffer U51), 156.25 MHz at power-up |

On neither board does a free-running reference clock enter the quad that carries the SFP
lane. The Aurora IP only offers the two reference clock inputs of its *own* quad, so both
block designs select `MGTREFCLK1_of_Quad_X0Y2` as a placeholder and the constraints file
places the reference clock *port* on the real pins. That moves the core's `IBUFDS_GTE4` to
the real quad's `GTHE4_COMMON`, and Vivado routes the clock over the dedicated
north/south reference clock lines (an UltraScale+ GTH reference clock can be shared up to
two quads away) and swaps it onto the transceiver's north/south reference clock inputs by
itself.

```{warning}
Do not LOC the clock buffer or the `GTHE4_COMMON`, and do not change the reference clock
selection of the Aurora core. The constraint on the port is what makes this work.
```

### Link parameters both boards must match

`docs/link_contract_deviations.md` in the repository is the authoritative record. In short:
`C_INTERFACE_TYPE 2` (Aurora 64B/66B), `C_INTERFACE_MODE 1` (Compact 2:1 — the only mode
that fits a 64-bit AXI data bus into *one* Aurora lane), `C_AXI_BUS_TYPE 0`,
`C_AXI_DATA_WIDTH 64`, `C_AXI_ADDR_WIDTH 32`, AXI ID width 6, AXI WUSER width 4,
`C_INTERRUPT_WIDTH 4`, `C_ECC_ENABLE true`, `C_EN_AXI_LINK_HNDLR false`, `C_COMMON_CLK 0`,
AXI4-Lite 32/32.

Two of those need care, and both block design scripts stop the build if the validated core
does not report the expected value:

* **`C_INTERFACE_MODE`** ends up 0 or 1 depending on the *order* in which the IP's
  parameters are set. `bd_zynqmp.tcl` therefore sets it on its own and last.
* **`C_AXI_ID_WIDTH` / `C_AXI_WUSER_WIDTH` are read-only on the master**: the core copies
  them from whatever drives `s_axi` at validation time. `bd_fpga.tcl` pins them to 6 / 4
  with an `axi_register_slice` (`c2c_regslice`) in front of `s_axi`; the ZCU106 sets the
  same numbers by hand on `C_M_AXI_ID_WIDTH` / `C_M_AXI_WUSER_WIDTH`.

The build log prints every one of these on lines that start with `INFO: [link]`.

### Link status

Both boards expose the same ten status bits through an AXI GPIO of their *own* fabric, so
reading them is safe whatever the link is doing:

| Bit | Name | Bit | Name |
|---|---|---|---|
| 0 | `channel_up` | 5 | `axi_c2c_multi_bit_error_out` |
| 1 | `lane_up` | 6 | `axi_c2c_config_error_out` |
| 2 | `gt_pll_lock` | 7 | `hard_err` |
| 3 | `axi_c2c_link_status` | 8 | `soft_err` |
| 4 | `axi_c2c_link_error_out` | 9 | `mmcm_not_locked` |

The AUBoard adds two more from the SFP+ cage: bit 10 = LOS, bit 11 = TX fault. **The link
is up when bits 0 and 3 are both set** (`0x00F` with the PLL locked and the lane up).

Two asymmetries are worth knowing:

* **Bit 4 is always 0 on the ZCU106.** A Chip2Chip *slave* with an Aurora PHY has no
  `axi_c2c_link_error_out` pin at all.
* **Bits 4..6 are sticky on the master.** Take bits 0..3 as the current state and bits 4..6
  as "something happened since the last reset of this design". A master that has never seen
  its partner reads `0x004`; once the link has been up and the partner goes away, the master
  latches `0x034`. Re-programming the AUBoard or pressing its reset button clears them.

Each board also drives LEDs from the same signals (ZCU106: `GPIO_LED_0/1/2` =
`channel_up` / link status / GT PLL lock; AUBoard: `LED4` = `channel_up`, `LED3` = link
status), so the link state is visible with nothing running.

## The host design (`zcu106`)

`Vivado/src/bd/bd_zynqmp.tcl`. A Zynq UltraScale+ PS with the board preset, plus:

```
  PS M_AXI_HPM0_FPD --> axi_smc_ctrl --+--> axi_c2c/s_axi_lite    0xA000_0000  16M
                                       +--> axi_gpio_link/S_AXI   0xA100_0000  64K
                                       +--> display_pipeline      0xA200_0000  3x64K

  axi_c2c/m_axi --> axi_mmu_ddr --> PS S_AXI_HP0_FPD              0x0000_0000   2G

  axi_c2c <--AXI4-Stream--> aurora_64b66b <--> SFP0 cage

  display_pipeline/M00_AXI --> PS S_AXI_HP3_FPD                   (mixer layer reads)
  display_pipeline         --> PS dp_live_video_in_*              (DisplayPort live video)
```

* **The whole link runs on `pl_clk0` at 100 MHz** — the AXI4-Lite port of the Chip2Chip
  core, its AXI4 side, the Aurora `init_clk`, the GT DRP clock and the GPIO; so do the
  AXI4-Lite registers of the display block. (This is why the Yocto BSP adds an `xlnx,fclk`
  node: the generated Linux device tree would otherwise let the GPIO driver gate `pl_clk0`
  when it goes idle.)
* **`M_AXI_HPM0_FPD` is 32 bits wide** and reaches the 16 MB remote window at `0xA000_0000`
  and the local status GPIO at `0xA100_0000`.
* **`S_AXI_HP0_FPD` is 64 bits wide**, matching the AXI data width of the link.
* **`axi_gpio_link` channel 2** is a small debug output register (reset value 0): bits 2..0
  set the Aurora/GT loopback of the ZCU106 (0 = normal, 2 = near-end PMA), and bit 3 is a
  link reset request that is ORed into `aurora_pma_init_in`.
* **No SmartConnect sits between `axi_c2c/m_axi` and the PS.** A SmartConnect rejects the
  4-bit WUSER of the link ("WUSER_WIDTH (4) of S00_AXI must be integer number of bits per
  byte of WDATA (64)"), even through a register slice. There is exactly one master and one
  slave on that path, so no arbitration is needed — only an address filter (below).

### The DMA path and its address limit

The remote frame buffer writers are **32-bit AXI masters**: `AXIMM_ADDR_WIDTH` is 32, and
`C_AXI_ADDR_WIDTH` of the link is 32. They can therefore only reach the low 4 GB of the
host's address space, and the design narrows that further:

* On the AUBoard, `smc_mm` gives each frame buffer writer exactly one segment — the link,
  `0x0000_0000`–`0x7FFF_FFFF`. Any other address gets a DECERR from `smc_mm`.
* On the ZCU106, an **AXI MMU** (`axi_mmu_ddr`) sits between `axi_c2c/m_axi` and
  `S_AXI_HP0_FPD`. It passes the assigned window (PS DDR low, 2 GB, mapped 1:1) and answers
  everything else with DECERR, so the remote FPGA can never reach the PS peripherals, the
  OCM or the PL address ranges. Seen from the AUBoard, an AXI4 access above `0x7FFF_FFFF`
  gets a DECERR from the ZCU106.

The ZCU106 has DDR above 4 GB as well, and Linux would happily hand out a buffer there. The
device-tree overlay therefore puts the remote peripherals under a `simple-pm-bus` node whose
`dma-ranges` sets `bus_dma_limit` for every device below it, and the kernel command line
carries `cma=1024M` so that the CMA area itself is in DDR low. **Capture with MMAP buffers
only** — a USERPTR or DMABUF buffer from above 4 GB cannot be written by the remote masters.

(display-path)=
### The display path

The camera frames land in PS DDR as packed RGB24, and a second block of the host design
reads them back out and drives the PS DisplayPort **live video** input, so both cameras can
be shown on a monitor plugged into the ZCU106. It all lives in the `display_pipeline`
hierarchy of `bd_zynqmp.tcl`:

```
  PS DDR --> v_mix (layer 1 = CAM0, layer 2 = CAM2) --AXI4-Stream RGB-->
      v_axi4s_vid_out --native 24-bit--> PS dp_live_video_in_*   --> monitor

  v_tc      1080p60 timing (2200 x 1125 total, 1920 x 1080 active)
  clk_wiz   pixel clock, 148.5 MHz for 1080p60, dynamically reconfigurable
```

* **Registers** — `v_mix` at `0xA200_0000`, `v_tc` at `0xA201_0000`, `clk_wiz` at
  `0xA202_0000`, 64 K each. The block starts at `0xA200_0000` so that the 16 MB remote
  window and the link status GPIO never have to move.
* **Interrupts** — `v_mix` frame-done on `pl_ps_irq0[4]` (GIC SPI 93) and `v_tc` on
  `pl_ps_irq0[5]` (GIC SPI 94). The four Chip2Chip interrupts keep `pl_ps_irq0[3:0]`.
* **Clocks** — the mixer datapath and its AXI master ports run on **`pl_clk1` at 250 MHz**,
  taken from the PS so that no PL clocking resource is spent and `pl_clk0` is untouched.
  `pl_clk1` is pinned on with a second `xlnx,fclk` node, because the mixer is an HLS core:
  its AXI4-Lite port is in that domain, and a register read with the clock stopped never
  completes.
* **Data path** — the two mixer layer read ports share one master into **`S_AXI_HP3_FPD`**,
  a different PS slave port from the `S_AXI_HP0_FPD` the mezzanine writes the frames into.
  It is restricted to DDR low, exactly as the remote FPGA's path is.
* **Reset** — the mixer is reset from **PS EMIO GPIO bit 0** (Linux GPIO 78), not from a
  `proc_sys_reset`. That is not a style choice: `xlnx_mixer` does `devm_gpiod_get(dev,
  "reset", …)` in probe and refuses to start without a `reset-gpios` property, and that
  property is generated from this block-design connection.
* **Nothing converts colour space.** The remote frame buffer writers deliver RGB8, the
  mixer's memory layers are format 20 (`RGB8`), its master layer is RGB and the DisplayPort
  live input takes `MEDIA_BUS_FMT_RGB888_1X24` — so `v4l2src ! kmssink` moves frames with no
  CPU conversion. The one place the component order does *not* line up is the native bus
  into the DisplayPort, where green and blue have to cross.

The link design is untouched by all of this: `pl_clk0` is still 100 MHz, the remote window
is still at `0xA000_0000`, the link status GPIO at `0xA100_0000` and the Chip2Chip
interrupts still own `pl_ps_irq0[3:0]`. The whole path, the run-time tooling
(`c2c-display`) and the measured results are in
[Showing the cameras on a DisplayPort monitor](display).

## The mezzanine design (`auboard`)

`Vivado/src/bd/bd_fpga.tcl`. No processor, neither hard nor soft.

### Clocks

One MMCM (`clk_wiz`) from the board's 300 MHz differential oscillator (VCO 1200 MHz) makes
all three fabric clocks, so they are synchronous to each other:

| Clock | Frequency | Drives |
|---|---|---|
| `clk_100M` | 100 MHz | every AXI4-Lite port outside the video clock domain, the Aurora `init_clk`, the GT DRP clock, the AXI4 side of the Chip2Chip core, `jtag_axi` |
| `clk_200M` | 200 MHz | `dphy_clk_200M` of both MIPI CSI-2 RX subsystems |
| `clk_video` | 300 MHz | the AXI4-Stream, the HLS video IP with their AXI4-Lite ports, and the AXI4 masters of the frame buffer writers |
| `user_clk_out` | 161.1328125 MHz | the PHY side of the Chip2Chip core (from the Aurora core) |

The video clock has to be faster than the sensor's pixel rate during a line, because the
pipelines run at one sample per clock: the two-lane IMX219 delivers up to 182.4 Mpixel/s.

```{note}
`auboard.xdc` redefines the 300 MHz board clock with a period of **3.334 ns** instead of the
3.333 ns that the clock wizard IP creates. A 1 ps period resolution makes 3.333 ns mean
300.03 MHz — 100 ppm fast — and the MIPI D-PHY PLLs run at the very top of their range
(200 MHz x 15 / 2 = 1500 MHz, fixed by the IP), so the tools computed 1500.15 MHz and raised
two critical warnings (DRC AVAL-350, FVCO out of range) for a PLL that really runs at
1500.000 MHz. Rounding the period up instead costs 0.02 % and is given back through 3 ps of
setup uncertainty.
```

### One capture pipeline per camera

Each camera gets a `mipi_<n>` hierarchy — the capture half of the
[rpi-camera-fmc](https://github.com/fpgadeveloper/rpi-camera-fmc) reference design for this
board, without its display half:

```
  MIPI CSI-2 RX subsystem  (2 lanes, RAW10, video format bridge, 1 pixel/clock)
        |  AXI4-Stream, 16-bit TDATA (pixel in bits 9..0)
        v
  axis_subset_converter    (RAW10 -> the 8 most significant bits, tdata[9:2])
        v
  v_demosaic               (8-bit, RGGB, zipper removal, max 1920x1232)
        v
  v_gamma_lut              (8-bit, max 1920x1232)
        v
  v_proc_ss                (scaler only, polyphase, 6 taps H and V, 64 phases, no CSC)
        v
  v_frmbuf_wr              (RGB8 only, 64-bit AXI4 master, 32-bit addresses,
        |                   64-beat bursts, 4 outstanding writes)
        v
  smc_mm --> c2c_regslice --> axi_c2c/s_axi --> the link --> ZCU106 DDR
```

plus, per camera, an `axi_iic` for the sensor (100 kHz, 7-bit addressing; the IMX219 answers
at `0x10`) and an `axi_gpio` for the camera enable pin and the resets of the video IP.

Two design decisions differ from the reference design and both follow from the link:

* **The AXI4 master of the frame buffer writer is 64 bits wide, not 128.** The link is
  64 bits wide, so `smc_mm` needs no width converter. The stride that software programs must
  therefore be a multiple of 8 bytes.
* **Its burst length is 64 beats (512 bytes), not 16.** Every burst costs a round trip over
  the link, because the write response comes from the host. 16 beats of 64 bits would carry
  half the bytes per burst of the reference design's 16 beats of 128 bits. The value is an
  estimate (`frmbuf_burst_len` in `bd_fpga.tcl`); nothing in the measurements below ever
  reached the limit of the link, so it has not been tuned against a measured throughput.

The pins of the FMC that are common to all cameras are driven as constants — `clk_sel` =
`01b`, and `rsvd_gpio` = `0x030`, which enables the level translators of the camera IO pins
and points them from the FPGA towards the cameras.

### The GPIO of a pipeline

`axi_gpio_0` of each `mipi_<n>`: 32 bits, all outputs, one channel, reset value `0x0000_0001`.

| Bit | Function |
|---|---|
| 0 | camera IO0 = enable (power) of the Raspberry Pi camera, active high. **Reset value 1 = camera on.** |
| 1 | camera IO1 (unused by the Raspberry Pi camera v2) |
| 2 | reset of `v_demosaic`, active low |
| 3 | reset of `v_proc_ss` (`aresetn_ctrl`), active low |
| 4 | reset of `v_gamma_lut`, active low |
| 5 | not connected (the frame buffer *read* IP of the reference design) |
| 6 | reset of `v_frmbuf_wr`, active low |

The reset bits cross into the video clock domain through a synchroniser
(`Vivado/src/hdl/pipe_gpio.v`, 3 video clock cycles).

(hang-hazard)=
```{danger}
**A video IP that is held in reset does not answer on AXI4-Lite, and the access never
completes.** This applies to `v_demosaic`, `v_gamma_lut`, `v_frmbuf_wr`, to the whole
`v_proc_ss` window while its GPIO bit is 0, and to the two scalers inside `v_proc_ss` until
bit 1 of its internal reset GPIO is set. There is no timeout anywhere in the register path,
so such an access blocks **every** register access of the host (and of `jtag_axi`) until the
AUBoard is re-programmed. The power-up state of the GPIO holds all of them in reset.

The Linux drivers take `reset-gpios` and release the reset in their probe, which is why the
device tree must give every one of them its GPIO line — and why you must never `devmem` or
`c2c-peek` one of these IP before the overlay has been applied.
```

### Interconnects

```
  jtag_axi ----------------> smc_mm ----M00----> c2c_regslice -> axi_c2c/s_axi (to the host)
  mipi_<n>/M_AXI_MM -------->  |
  (frame buffer writers)       +-------M01----+
                                             v
  axi_c2c/m_axi_lite ----------------------> axi_periph ---> the local peripherals
                                             (AXI4-Lite)      +-> mipi_<n>/S_AXI_CTRL  (100 MHz)
                                                              +-> mipi_<n>/S_AXI_VIDEO (video clk)
```

`axi_periph` and the two interconnects inside each pipeline are AXI **Interconnect** IP, not
SmartConnects, and every port on them is AXI4-Lite: an AXI4-Lite crossbar is a fraction of
the size of an AXI4 one. One non-AXI4-Lite port would silently turn the crossbar into an
AXI4 crossbar with a protocol converter per port, so the block design script checks the
validated result and fails the build otherwise. It is also why the scratch BRAM controller
is configured as an AXI4-Lite slave.

The register path of the host (`m_axi_lite`) only ever sees `axi_periph`, so it cannot loop
back into the link.

### Bring-up peripherals

A `jtag_axi` master and three small peripherals let either side prove the link with no
software at all: an AXI GPIO with the LEDs and the status bits, an 8K scratch BRAM, and a
frequency counter on the Aurora user clock. `scripts/jtag/auboard_axi.tcl` drives them.

## Address map

Identical from the host (through `m_axi_lite`) and from `jtag_axi` — the Chip2Chip core
passes addresses through 1:1. On the ZCU106 the whole table sits inside the 16 MB window at
`0xA000_0000`.

| Address | Size | IP | AXI4-Lite clock |
|---|---|---|---|
| `0xA000_0000` | 64K | `axi_gpio_sys`: `+0x0` ch1 out = LEDs (bits 1..0), `+0x8` ch2 in = link status (12 bits) | 100 MHz |
| `0xA001_0000` | 8K | scratch BRAM (`0xA001_2000`–`0xA001_FFFF` of the 64K slot is unmapped: DECERR) | 100 MHz |
| `0xA002_0000` | 64K | `axi_gpio_freq`: `+0x0` ch1 in = Aurora user clock in Hz, `+0x8` ch2 in = measurement count (+1 per second) | 100 MHz |
| `0xA003_0000` | 64K | `axi_gpio_dbg` ch1 out: bits 2..0 = Aurora loopback. A non-zero write from the host takes the link down until the AUBoard is reset. | 100 MHz |
| `0xA004_0000` | 64K | `axi_intc` (4.1) | 100 MHz |
| `0xA010_0000` / `0xA020_0000` | 64K | CAM0 / CAM2 `mipi_csi2_rx_subsystem` (6.0) — the IP decodes 4K; there is no D-PHY register block | 100 MHz |
| `0xA011_0000` / `0xA021_0000` | 64K | CAM0 / CAM2 `axi_iic` (2.1) | 100 MHz |
| `0xA012_0000` / `0xA022_0000` | 64K | CAM0 / CAM2 `axi_gpio` (2.0) | 100 MHz |
| `0xA013_0000` / `0xA023_0000` | 64K | CAM0 / CAM2 `v_demosaic` (1.1) | video |
| `0xA014_0000` / `0xA024_0000` | 64K | CAM0 / CAM2 `v_gamma_lut` (1.1) | video |
| `0xA015_0000` / `0xA025_0000` | 64K | CAM0 / CAM2 `v_frmbuf_wr` (3.0) | video |
| `0xA018_0000` / `0xA028_0000` | 256K | CAM0 / CAM2 `v_proc_ss` (2.3): `+0x0_0000` H scaler, `+0x1_0000` its reset GPIO (bit 1 = reset of both scalers, active low, reset value 0), `+0x2_0000` V scaler | video |

Outside the window, on the ZCU106 itself:

| Address | Size | What |
|---|---|---|
| `0xA100_0000` | 64K | `axi_gpio_link`: `+0x0` ch1 in = link status (10 bits), `+0x8` ch2 out = loopback (bits 2..0) and link reset request (bit 3) |
| `0xA200_0000` | 64K | `v_mix` video mixer of the [display path](#display-path) — AXI4-Lite in the `pl_clk1` domain |
| `0xA201_0000` | 64K | `v_tc` timing controller of the display path |
| `0xA202_0000` | 64K | `clk_wiz` pixel clock wizard of the display path |

And in the other direction:

| Address | Size | What |
|---|---|---|
| `0x0000_0000` | 2G | the PS DDR low of the ZCU106, as seen by `jtag_axi` and by the frame buffer writers of the AUBoard |

## Interrupts

The remote interrupts are cascaded, because the link carries only four interrupt lines and
the Linux drivers of these IP do not all request a shared line:

```
  10 sources  -->  axi_intc (4.1)  -->  axi_c2c_m2s_intr_in[0]  ==link==>
      axi_c2c_m2s_intr_out[0]  -->  pl_ps_irq0[0]  -->  GIC SPI 89, level high
```

All ten inputs of the interrupt controller are **level, active high**, there are no fast
interrupts, and its `irq` output is a level, active high — the Chip2Chip core forwards the
*level* of its interrupt inputs. Every input except the two `axi_iic` has a synchroniser in
the controller. Bits 3..1 of the link interrupts are tied to 0, and no interrupts are sent
from the host to the AUBoard.

| Input | Source | | Input | Source |
|---|---|---|---|---|
| 0 | CAM0 `mipi_csi2_rx_subsystem` | | 5 | CAM2 `axi_iic` |
| 1 | CAM0 `v_frmbuf_wr` | | 6 | CAM0 `v_demosaic` |
| 2 | CAM0 `axi_iic` | | 7 | CAM0 `v_gamma_lut` |
| 3 | CAM2 `mipi_csi2_rx_subsystem` | | 8 | CAM2 `v_demosaic` |
| 4 | CAM2 `v_frmbuf_wr` | | 9 | CAM2 `v_gamma_lut` |

`pl_ps_irq0[3:1]` of the ZCU106 are wired to the remaining three link interrupts (GIC SPI
90..92) but are unused. The `v_demosaic` and `v_gamma_lut` interrupts are wired in hardware
but no Linux driver uses them, so the overlay does not describe them and they stay masked.

The two interrupts of the local [display path](#display-path) sit above them, and are
entirely separate from the link: `pl_ps_irq0[4]` = `v_mix` frame-done (GIC SPI 93) and
`pl_ps_irq0[5]` = `v_tc` (GIC SPI 94).

## Why the remote nodes are a run-time overlay

The Linux drivers of the remote peripherals are built into the kernel and touch their
registers in `probe`. **A register access through the link while the link is down never
completes and hangs the CPU** — there is no timeout in the AXI Chip2Chip in this
configuration, and the same is true for an IP that is held in reset
([above](#hang-hazard)).

The nodes of the remote peripherals are therefore *not* in the base device tree. They are
added at run time, after a link check, by the device-tree overlay
`Yocto/overlays/c2c-cams.dtso`:

```
sudo c2c-link-status                                  # must report: link: UP
sudo c2c-overlay apply cams /path/to/c2c-cams.dtbo
```

Two consequences: apply the overlay **once per boot**, and **never remove it** (removal
unbinds a cascaded interrupt controller, a V4L2 async graph and DMA channels, and every
unbind touches remote registers). To start over, reboot. The full procedure is in
[Using the cameras from Linux](linux_cameras).

## Performance

All figures measured on the bench hardware (ZCU106 + AUBoard 15P, AMD EDF Yocto,
linux-xlnx 6.12.40, two Raspberry Pi Camera Module v2).

### Frame data through the link

| Case | Output size | fps | Bytes/s over the link |
|---|---|---|---|
| CAM0 alone | 1920x1080 | 30.01 | 186.6 MB/s |
| CAM0 alone, `vblank=32` | 1920x1080 | 47.57 | 295.9 MB/s |
| CAM0 + CAM2 together | 1920x1080 | 30.01 each | 373.2 MB/s |
| **CAM0 + CAM2 together, `vblank=32`** | **1920x1080** | **47.57 each** | **591.8 MB/s** |
| CAM0 + CAM2 together, `vblank=32` | 1280x720 (scaler) | 47.57 each | 262.9 MB/s |
| CAM0 + CAM2 together | 640x480 from 1640x1232 (scaler) | 30.01 each | 55.3 MB/s |

Every figure is the *sensor's* own maximum for that vertical blanking: **the link was never
the limit.** In a 42-second soak of both cameras at 1080p and 47.57 fps (2000 frames each),
`/proc/interrupts` counted exactly one frame-buffer-writer interrupt per CSI-2 "frame
received" interrupt on each camera — no frame dropped — the CSI-2 RX "stream line buffer
full" bit was never set, and both boards reported link status `0x00F` throughout: no link
error, no multi-bit error, no Aurora hard or soft error. 592 MB/s is roughly 60 % of the raw
10.3125 Gb/s lane, and the register path stayed responsive at the same time. The detailed
table and the commands are in [Using the cameras from Linux](linux_cameras).

### Register access latency

`c2c-latency` on the host times single-word reads of a remote register against the same loop
on a local one: **about 2.8 µs per 32-bit read through the link**, i.e. about 1.3 µs more
than a read of a local PL register. That is the cost of a round trip over the link, and it
is the reason the frame buffer writers use long bursts.

(resource-usage)=
### Resource usage and timing

Vivado 2025.2, routed designs. The `zcu106` column is the **full host design, display path
included**; the mezzanine is unchanged by it.

| | `auboard` (xcau15p-ffvb676-2-e) | `zcu106` (xczu7ev-ffvc1156-2-e) |
|---|---|---|
| CLB LUTs | 32 729 (42.1 %) | 11 141 (4.8 %) |
| CLB registers | 47 209 (30.4 %) | 18 867 (4.1 %) |
| Block RAM tiles | 71.5 (49.7 %) | 9 (2.9 %) |
| DSPs | 82 (14.2 %) | 2 (0.1 %) |
| MMCM / PLL | 1 of 3 / 2 of 6 | 1 of 8 / 0 of 16 (the pixel clock wizard; the PS supplies `pl_clk0` and `pl_clk1`) |
| Worst negative slack | 0.199 ns (MET) | 0.990 ns (MET) |

The display path is what the ZCU106 column mostly consists of: measured on the last build
*before* it was added, the host design was 2 976 LUTs, 5 840 registers and 6 block RAM
tiles (WNS 1.182 ns) — the Chip2Chip core, the Aurora core, the AXI MMU and a GPIO.

Per camera pipeline on the AUBoard (hierarchical report): 11 629 LUTs, 15 458 flip-flops,
23 RAMB36 + 15 RAMB18 (30.5 block RAM tiles), 41 DSPs. The two pipelines are within a few LUTs of each other. The
largest single block outside them is `smc_mm` (5 258 LUTs), then the Chip2Chip core
(1 700 LUTs) and the Aurora core (450 LUTs).

The reports are written to `Vivado/<target>/reports/` by every `xsa` build, and the timing
result also appears in `Vivado/logs/<target>_xsa.log` on a line that starts with `TIMING:`.
The figures above are read off `utilization.rpt` / `timing_summary.rpt` of the routed
designs — the `auboard` build of the two-camera design, and the `zcu106` build that carries
the display path. Re-run `./build.sh xsa --target <target>` and read your own reports after
any change.

[RPi Camera FMC]: https://docs.opsero.com/op068/datasheet/overview/
[AXI Chip2Chip]: https://www.xilinx.com/products/intellectual-property/axi-chip2chip.html
[Aurora 64B/66B]: https://www.xilinx.com/products/intellectual-property/aurora64b66b.html
