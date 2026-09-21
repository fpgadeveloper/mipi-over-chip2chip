# Link contract: values found and deviations

The two block designs of this repository must configure AXI Chip2Chip and Aurora 64B/66B
identically, or the link does not train. This file records, per board, every value that the
phase 1 link contract left open and every place where a design deviates from it. **Whatever
is listed here must be matched by the other board.**

## AUBoard 15P (`auboard`, `Vivado/src/bd/bd_fpga.tcl`) - the AXI Chip2Chip master

### Values the contract left open (Vivado 2025.2, axi_chip2chip 5.0, aurora_64b66b 13.0)

| Parameter | Value | Meaning | Other board |
|---|---|---|---|
| `C_INTERFACE_TYPE` | `2` | Aurora 64B/66B (0/1 = SelectIO SDR/DDR, 3 = Aurora 8B/10B) | `2` |
| `C_INTERFACE_MODE` | `1` | Compact 2:1. With a 64 bit AXI data bus this is the only setting that fits ONE Aurora lane (`C_AURORA_WIDTH` = 1); Compact 1:1 needs two lanes. Not named in the contract. | `1` |
| `C_INCLUDE_AXILITE` | `2` | The core gets the AXI4-Lite **master** port `m_axi_lite`. The GUI calls this value "Slave". | `1` (port `s_axi_lite`, GUI "Master") |
| `C_MASTER_FPGA` | `1` | Master: ports `s_axi`, `s_aclk`, `s_aresetn` | `0` |

### AXI ID width and WUSER width (needs attention on both boards)

`C_AXI_ID_WIDTH` and `C_AXI_WUSER_WIDTH` are **read-only on the master**: the core copies them
from whatever drives `s_axi` when the block design is validated. Behind a SmartConnect they
come out as **0 / 0**, and they would change again when phase 2 adds the frame buffer writers.
The model parameters of the core follow them, so they are part of the link configuration.

`bd_fpga.tcl` therefore pins them to the contract values **ID 6 / WUSER 4** with an
`axi_register_slice` (`c2c_regslice`, `ID_WIDTH 6`, `WUSER_WIDTH 4`) between the SmartConnect
and `s_axi`, and stops with an error if the validated core does not report 6 / 4.

The slave side sets the same numbers by hand: `C_M_AXI_ID_WIDTH 6`, `C_M_AXI_WUSER_WIDTH 4`.

On this side the SmartConnect is a *master* towards the register slice and has no WUSER at
all, so the only message is `WARNING: [BD 41-237] Bus Interface property WUSER_WIDTH does not
match between /c2c_regslice/S_AXI(4) and /smc_mm/M00_AXI(0)`: the four WUSER bits of the link
are tied to 0. There is no critical warning. The build log prints the derived values on lines
that start with `INFO: [link]`.

Error status bits: a master that has never seen its partner reads `0x004` (GT PLL locked,
nothing else). Once the link has been up and the partner goes away, the master asserts
`axi_c2c_link_error_out` and `axi_c2c_multi_bit_error_out` (status `0x034`), and a loopback
session (the master talking to itself) also leaves `axi_c2c_config_error_out` asserted. A
reset of the AUBoard design (reset push button or re-programming) clears them. Take bits 0..3
as the current state of the link, and bits 4..6 as "something happened since the last reset".

### Aurora 64B/66B

As in the contract: 1 lane, 10.3125 Gbps, 156.25 MHz reference clock, Duplex, Streaming, no
flow control, no CRC, shared logic in the core, single ended 100 MHz `init_clk`. Two
parameters cannot be set from a block design script and take the contract values by themselves:

* `C_INIT_CLK` is read-only in a block design, it follows the clock on `init_clk` (= 100.0).
* `DRP_FREQ` is disabled in this configuration and fixed at 100.0000.

GT: `C_START_QUAD Quad_X0Y2`, `C_START_LANE X0Y11`, `C_REFCLK_SOURCE MGTREFCLK1_of_Quad_X0Y2`
(a placeholder: the IP only offers its own quad; `auboard.xdc` puts the reference clock ports
on Y7/Y6 = MGTREFCLK1 of quad 224 and Vivado routes the clock north to quad 226).

The Aurora user clock is 161.1328125 MHz (line rate / 64).

### Additions on the AUBoard (nothing the host has to match, but it can use them)

| Address | What |
|---|---|
| `0xA000_0000` | `axi_gpio_sys` ch1: only bit 1..0 drive LEDs (LED2, LED1). LED4 = Aurora `channel_up` and LED3 = AXI Chip2Chip link status are driven by hardware. |
| `0xA000_0008` | `axi_gpio_sys` ch2, status: bits 0..9 as in the contract (bit 6 `axi_c2c_config_error_out` exists on the master), plus **bit 10 = SFP+ LOS** and **bit 11 = SFP+ TX fault** (board pins). |
| `0xA001_0000` | The scratch BRAM is 8K; `0xA001_2000-0xA001_FFFF` of its 64K slot is not mapped (DECERR). |
| `0xA002_0008` | `axi_gpio_freq` ch2: number of frequency measurements (+1 per second while the user clock runs). The frequency itself (ch1, `0xA002_0000`) reads 0 when the clock is not running. |
| `0xA003_0000` | **`axi_gpio_dbg`** (new): ch1 bit 2..0 = Aurora `loopback` (0 = normal, 2 = near-end PMA loopback). Bring-up aid. A non-zero write from the host takes the link down until the AUBoard is reset or re-programmed. |

Interrupts: `axi_c2c_m2s_intr_in[3:0]` were all tied to 0 in phase 1; phase 2 uses bit 0 (below).

### Phase 2: the video pipelines (what the device tree of the host needs)

Two capture pipelines, `mipi_0` (CAM0 of the RPi Camera FMC) and `mipi_2` (CAM2), each the pipe
of the rpi-camera-fmc reference design for this board without its display half:

```
mipi_csi2_rx_subsystem -> axis_subset_converter (RAW10 -> 8 bit) -> v_demosaic -> v_gamma_lut
  -> v_proc_ss (scaler only) -> v_frmbuf_wr -> smc_mm -> c2c_regslice -> axi_c2c/s_axi -> DDR of the host
```

All values below are read back from the validated block design (the build log prints them on
lines that start with `INFO: [cam]` and `INFO: [map]`). The link parameters of phase 1 are
unchanged (`INFO: [link]`: mode 1, ID 6, WUSER 4, one lane).

#### Address map (identical from the host through `m_axi_lite` and from `jtag_axi`)

| Address | Size | IP | Clock of the AXI4-Lite port |
|---|---|---|---|
| `0xA004_0000` | 64K | `axi_intc` (4.1) | 100 MHz |
| `0xA010_0000` / `0xA020_0000` | 64K | CAM0 / CAM2 `mipi_csi2_rx_subsystem` (6.0). The IP decodes 4K (the CSI-2 RX controller); there is no D-PHY register block (`DPY_EN_REG_IF false`). | 100 MHz |
| `0xA011_0000` / `0xA021_0000` | 64K | CAM0 / CAM2 `axi_iic` (2.1) | 100 MHz |
| `0xA012_0000` / `0xA022_0000` | 64K | CAM0 / CAM2 `axi_gpio` (2.0) | 100 MHz |
| `0xA013_0000` / `0xA023_0000` | 64K | CAM0 / CAM2 `v_demosaic` (1.1) | video clock |
| `0xA014_0000` / `0xA024_0000` | 64K | CAM0 / CAM2 `v_gamma_lut` (1.1) | video clock |
| `0xA015_0000` / `0xA025_0000` | 64K | CAM0 / CAM2 `v_frmbuf_wr` (3.0) | video clock |
| `0xA018_0000` / `0xA028_0000` | 256K | CAM0 / CAM2 `v_proc_ss` (2.3): `+0x0_0000` h scaler, `+0x1_0000` its reset GPIO (2 bit, bit 1 = reset of both scalers, active low, reset value 0), `+0x2_0000` v scaler | video clock |

The frame buffer writers see `0x0000_0000-0x7FFF_FFFF` (the link) and nothing else; any other
address gets a DECERR from `smc_mm`. The phase 1 peripherals have not moved. One change there:
the scratch BRAM controller is now an AXI4-Lite slave (it was AXI4), so that the register
interconnect is a pure AXI4-Lite `axi_interconnect` (`axi_periph`) instead of a SmartConnect;
the host only ever made single beat accesses, so nothing changes for it.

**A video IP that is held in reset does not answer on AXI4-Lite, and the access never
completes.** This applies to `v_demosaic`, `v_gamma_lut`, `v_frmbuf_wr` (reset = GPIO bit of the
pipeline, below), to the whole `v_proc_ss` window while its GPIO bit is 0, and to the two
scalers inside `v_proc_ss` until bit 1 of its internal reset GPIO is set. There is no timeout
anywhere in the register path, so such an access blocks ALL register accesses of the host
(and of `jtag_axi`) until the AUBoard is re-programmed. The Linux drivers of these IP take
`reset-gpios` and release the reset in their probe; the device tree must give every one of them
its GPIO line.

#### GPIO of a pipeline (`axi_gpio`, 32 bit, all outputs, one channel, reset value `0x0000_0001`)

| Bit | Function |
|---|---|
| 0 | camera IO0 = enable (power) of the Raspberry Pi camera, active high. Reset value 1 = camera on. |
| 1 | camera IO1 (not used by the Raspberry Pi camera v2) |
| 2 | reset of `v_demosaic`, active low |
| 3 | reset of `v_proc_ss` (`aresetn_ctrl`), active low |
| 4 | reset of `v_gamma_lut`, active low |
| 5 | not connected (the reset of the frame buffer read IP in the reference design) |
| 6 | reset of `v_frmbuf_wr`, active low |

The reset bits go through a synchroniser into the video clock domain (`src/hdl/pipe_gpio.v`,
3 video clock cycles). The pins of the FMC that are common to all cameras are constants:
`clk_sel` = `01b`, level translators of the camera IO pins enabled and driving towards the
cameras (`rsvd_gpio` = `0x030`, the reset value of the AXI GPIO of the reference design).

#### Interrupts

One `axi_intc` (4.1): 10 inputs, **all level, active high** (`C_KIND_OF_INTR 0xFFFFFC00`,
`C_KIND_OF_LVL 0xFFFFFFFF`), no fast interrupts, output `irq` a level, active high
(`C_IRQ_IS_LEVEL 1`, `C_IRQ_ACTIVE 1`) -> `axi_c2c_m2s_intr_in[0]` -> ZCU106 `pl_ps_irq0[0]`
= GIC SPI 89, level high. Bits 3..1 of the link interrupts stay 0.

| INTC input | Source | | INTC input | Source |
|---|---|---|---|---|
| 0 | CAM0 `mipi_csi2_rx_subsystem` | | 5 | CAM2 `axi_iic` |
| 1 | CAM0 `v_frmbuf_wr` | | 6 | CAM0 `v_demosaic` |
| 2 | CAM0 `axi_iic` | | 7 | CAM0 `v_gamma_lut` |
| 3 | CAM2 `mipi_csi2_rx_subsystem` | | 8 | CAM2 `v_demosaic` |
| 4 | CAM2 `v_frmbuf_wr` | | 9 | CAM2 `v_gamma_lut` |

`v_proc_ss` has no interrupt. Every input except the two `axi_iic` has a synchroniser in the
interrupt controller (`C_ASYNC_INTR 0xFFFFFFDB`).

#### Clocks

All from one MMCM (`clk_wiz`, 300 MHz board oscillator, VCO 1200 MHz), so they are synchronous
to each other:

| Clock | Frequency | Pins |
|---|---|---|
| `clk_100M` | 100 MHz | every AXI4-Lite port in the 100 MHz column above; `mipi_csi2_rx_subsystem/lite_aclk`; `axi_iic/s_axi_aclk`; `axi_gpio/s_axi_aclk`; `axi_intc/s_axi_aclk`; the AXI4 side of the Chip2Chip core |
| `clk_200M` | 200 MHz | `mipi_csi2_rx_subsystem/dphy_clk_200M` |
| `clk_video` | 300 MHz (the video clock of the reference design) | `mipi_csi2_rx_subsystem/video_aclk`; `v_demosaic/ap_clk`; `v_gamma_lut/ap_clk`; `v_proc_ss/aclk_axis` and `aclk_ctrl`; `v_frmbuf_wr/ap_clk` (AXI4-Stream, AXI4-Lite and the AXI4 master of these IP) |

#### Configuration of the IP of a pipeline (both pipelines are identical)

| IP | Configuration |
|---|---|
| `mipi_csi2_rx_subsystem` 6.0 | 2 lanes (`CMN_NUM_LANES 2`, `C_DPHY_LANES 2`), pixel format RAW10 (data type `0x2B`), video format bridge included (`CMN_INC_VFB true`), 1 pixel per clock, `video_out` TDATA 16 bit (the pixel in bits 9..0), TDEST 10 bit, TUSER 1 bit; all virtual channels (`CMN_VC All`); CSI-2 v2.0 features on (`C_EN_CSI_V2_0 true`); active lane selection off (`C_CSI_EN_ACTIVELANES false`); no user data type filter; line buffer depth 2048; D-PHY line rate 420 Mb/s (`C_HS_LINE_RATE`/`DPY_LINE_RATE 420`), `C_HS_SETTLE_NS 158`, no D-PHY register interface (`DPY_EN_REG_IF false`), shared logic in the core (one PLL of bank 66 per instance); IP parameter `AXIS_TDATA_WIDTH 32` |
| `axis_subset_converter` | 2 bytes -> 1 byte, `tdata[9:2]`: the 8 most significant bits of RAW10. No registers. |
| `v_demosaic` 1.1 | 8 bit, 1 sample per clock, max 1920 x 1232, `ALGORITHM 1`, zipper removal on, no URAM. IMX219 Bayer phase = RGGB (`0`). |
| `v_gamma_lut` 1.1 | 8 bit, 1 sample per clock, max 1920 x 1232 |
| `v_proc_ss` 2.3 | scaler only (`C_TOPOLOGY 0`), polyphase (`C_SCALER_ALGORITHM 2`), 6 taps horizontal and vertical, 64 phases, 8 bit, 1 sample per clock, max 1920 x 1232, no colour space conversion (`C_ENABLE_CSC false`), colour support RGB / YUV 4:4:4 only (`C_COLORSPACE_SUPPORT 2`), no DMA |
| `v_frmbuf_wr` 3.0 | video format **RGB8 only** (`HAS_RGB8 1`, everything else 0: memory format `XVIDC_CSF_MEM_RGB8`, 3 bytes per pixel; the Linux frame buffer driver calls it `"bgr888"` in `xlnx,vid-formats` = `V4L2_PIX_FMT_RGB24` / `DRM_FORMAT_BGR888`), 8 bit, 1 sample per clock, max 1920 x 1232, not interlaced; AXI4 master: **address width 32**, **data width 64**, burst length 64 beats (512 bytes), 4 outstanding writes |
| `axi_iic` 2.1 | 100 kHz, 7 bit addressing, 100 MHz `s_axi_aclk`. The IMX219 answers at `0x10`. One bus per camera, no multiplexer. |

YUYV8 was not added to `v_frmbuf_wr`: the scaler-only `v_proc_ss` without colour space
conversion delivers RGB, so the format could never be used.

The data width of the AXI4 master of `v_frmbuf_wr` is 64 and not the 128 of the reference design:
the link is 64 bit wide, so `smc_mm` needs no width converter. The stride that software
programs must be a multiple of 8 bytes (`xlnx,dma-align = <8>`, the minimum of the Linux driver).
The burst length is 64 beats and not the 16 of the reference design: every burst costs a round
trip over the link, and 16 beats of 64 bit would be half the bytes per burst of the reference
design (16 beats of 128 bit). This value is an estimate, it has not been tuned against a
measured throughput (`frmbuf_burst_len` in `bd_fpga.tcl`).

**Measured 2026-09-20 (Linux on the ZCU106, both pipelines):** the link carries **both** cameras
at 1920 x 1080 RGB8 and the sensor's maximum 47.57 frames/s at the same time, i.e.
**591.8 MB/s**, with no frame loss: over a 42 s run (2000 frames per camera) `/proc/interrupts`
counted exactly one `v_frmbuf_wr` interrupt per CSI-2 "frame received" interrupt on each camera,
the CSI-2 RX `CSR` bit 1 / `ISR` bit 18 (stream line buffer full) never set, and the link status
stayed `0x00F` on both boards - no link error, no multi-bit error, no Aurora hard or soft error.
The back pressure case ("stream line buffer full", ISR bit 18, `dev_alert` "Stream Line Buffer
Full!" in dmesg) was therefore never reached, and the `frmbuf_burst_len` of 64 beats needs no
tuning for this load. The reference application scales to 720 x 480 before it writes; this design
does not have to. Full table in `docs/source/linux_cameras.md`.

#### The sensor side, as far as the register map is concerned

Each camera has its own I2C bus. With the camera enabled (GPIO bit 0 = 1) the IMX219 answers at
the 7 bit address `0x10` (model ID registers `0x0000`/`0x0001` = `0x02 0x19`); with bit 0 = 0 it
does not. The sensor mode of the reference application (1920 x 1080, 2 lanes, RAW10) arrives
as data type `0x2B` with a word count of 2400 bytes per line. The MIPI CSI-2 RX subsystem is
enabled after reset and needs no register write to receive.

`scripts/jtag/auboard_cam.tcl` exercises all of this from the JTAG to AXI master, without the
host (`regs`, `camid`, `stream`, `irq`, `stop`).

## ZCU106 (`zcu106`, `Vivado/src/bd/bd_zynqmp.tcl`) - the AXI Chip2Chip slave

### Values the contract left open (Vivado 2025.2, axi_chip2chip 5.0, aurora_64b66b 13.0)

Found independently on this side and identical to the AUBoard table above:

| Parameter | Value | Meaning | Other board |
|---|---|---|---|
| `C_INTERFACE_TYPE` | `2` | Aurora 64B/66B | `2` |
| `C_INTERFACE_MODE` | `1` | Compact 2:1 (`C_AURORA_WIDTH` = 1, a 64-bit stream = one lane). The IP leaves this at 0 **or** 1 depending on the order in which its parameters are set (one `set_property -dict` from the defaults gives 1, the GUI order gives 0 = Compact 1:1 = `C_AURORA_WIDTH` 2 = a 128-bit stream that does not fit one lane), so `bd_zynqmp.tcl` sets it explicitly, last, and stops with an error if the validated core does not report mode 1 / width 1. | `1` |
| `C_INCLUDE_AXILITE` | `1` | The core gets the AXI4-Lite **slave** port `s_axi_lite` (+ `s_axi_lite_aclk`). The GUI calls this value "Master". | `2` |
| `C_MASTER_FPGA` | `0` | Slave: ports `m_axi`, `m_aclk`, `m_aresetn` | `1` |
| `C_M_AXI_ID_WIDTH` / `C_M_AXI_WUSER_WIDTH` | `6` / `4` | User parameters on the slave; must equal the (derived) `C_AXI_ID_WIDTH` / `C_AXI_WUSER_WIDTH` of the master | `6` / `4` |

The remaining C2C parameters are the contract values: `C_AXI_BUS_TYPE 0`, `C_AXI_DATA_WIDTH 64`,
`C_AXI_ADDR_WIDTH 32`, `C_INTERRUPT_WIDTH 4`, `C_ECC_ENABLE true`, `C_EN_AXI_LINK_HNDLR false`,
`C_COMMON_CLK 0`, AXI4-Lite 32/32. The build log prints them on lines that start with `INFO: [link]`.

### Deviations from the contract

* **Status bit 4 (`axi_c2c_link_error_out`) is always 0 on the ZCU106.** A C2C *slave* with an
  Aurora PHY has no `axi_c2c_link_error_out` pin (its pins are `axi_c2c_link_status_out`,
  `axi_c2c_multi_bit_error_out` and `axi_c2c_config_error_out`). The other nine bits are as in
  the contract.
* **Aurora `C_INIT_CLK` = 99.990005, not 100.** It is read-only in a block design and follows
  the clock on `init_clk`, which is the PS `pl_clk0`: the PS PLL cannot make exactly 100 MHz
  from the 33.333 MHz PS reference clock. `DRP_FREQ` is a disabled parameter, fixed at 100.0000 (the DRP
  clock is the same `pl_clk0`). Neither value is part of the link protocol; nothing to match.
* **No SmartConnect between the C2C `m_axi` port and the PS.** A SmartConnect rejects the 4-bit
  WUSER of the link contract (critical warning "WUSER_WIDTH (4) of S00_AXI must be integer number
  of bits per byte of WDATA (64)", also through a register slice). As there is one master and
  one slave, the path is `axi_c2c/m_axi` -> `axi_mmu` -> `S_AXI_HP0_FPD`: the AXI MMU passes the
  assigned window `0x0000_0000-0x7FFF_FFFF` (PS DDR low, 1:1) and answers every other address with
  DECERR. **Seen from the AUBoard: an AXI4 access above `0x7FFF_FFFF` gets DECERR from the ZCU106.**
  (The AUBoard side may see the same SmartConnect message on the master port that faces its
  `c2c_regslice`.)

GT: `C_START_QUAD Quad_X0Y2`, `C_START_LANE X0Y10` (SFP0 = quad 225 channel 2),
`C_REFCLK_SOURCE MGTREFCLK1_of_Quad_X0Y2` (a placeholder, as on the AUBoard: `zcu106.xdc` puts
the reference clock port on U10/U9 = MGTREFCLK1 of quad 226 and Vivado routes the clock south
to quad 225).

### Additions on the ZCU106 (nothing the AUBoard has to match)

| Address (ZCU106 PS) | What |
|---|---|
| `0xA100_0000` | `axi_gpio_link` ch1 (in): link status bits 0..9 as in the contract (bit 4 always 0, see above). |
| `0xA100_0008` | `axi_gpio_link` ch2 (out, reset value 0), bring-up aid: bit 2..0 = Aurora `loopback` of the ZCU106 GT (0 = normal, 2 = near-end PMA loopback), bit 3 = link reset request (ORed into `aurora_pma_init_in` of the C2C; pulse it after a loopback change). |
| `0xA200_0000` / `0xA201_0000` / `0xA202_0000` | 64K each: `v_mix` / `v_tc` / `clk_wiz` of the local DisplayPort display path (`display_pipeline` in `bd_zynqmp.tcl`). |

Interrupts: `axi_c2c_m2s_intr_out[3:0]` -> `pl_ps_irq0[3:0]` (GIC SPI 89..92). `axi_c2c_s2m_intr_in[3:0]`
are tied to 0 (no interrupts are sent to the AUBoard). The display path takes `pl_ps_irq0[4]`
(v_mix, GIC SPI 93) and `pl_ps_irq0[5]` (v_tc, GIC SPI 94).

### The display path is outside the contract

The ZCU106 design also carries a video mixer that reads the captured frames back out of PS
DDR and drives the PS DisplayPort live video input. **None of it is part of the link
contract and the AUBoard has nothing to match:** it is local to the ZCU106, it sits above
the 16 MB remote window (`0xA200_0000`+, so nothing in the window moved), it takes its own
PS clock (`pl_clk1`, 250 MHz) and its own PS slave port (`S_AXI_HP3_FPD`, separate from the
`S_AXI_HP0_FPD` the link writes into), and it uses the two `pl_ps_irq0` lines above the
four the link owns. The one thing it inherits from the mezzanine is the pixel format: the
mixer's memory layers are format 20 (`RGB8`), byte for byte what the remote `v_frmbuf_wr`
writes, so a change to `v_frmbuf_wr`'s format would have to change the mixer layers too.
See `docs/source/display.md`.

LEDs: GPIO_LED_0 = Aurora `channel_up`, GPIO_LED_1 = AXI Chip2Chip link status, GPIO_LED_2 = GT PLL lock.
