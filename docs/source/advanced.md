# Advanced: project structure and customization

This page is for people who want to change the design rather than just build it. Read
[Description](description) first — it explains the architecture the changes below apply to —
and keep `docs/link_contract_deviations.md` at hand: it is the authoritative record of every
parameter the two block designs must agree on.

## Repository layout

| Path | Content |
|------|---------|
| `config/data.json` | The manifest: the single source of truth for the target designs. |
| `config/update.py` | Regenerates the README table, the target table of `Vivado/scripts/build.tcl` and the `.gitignore` from the manifest. |
| `Vivado/scripts/build.tcl` | Creates the Vivado project of a target and sources the right block design script. |
| `Vivado/scripts/xsa.tcl` | Implements the design, writes the reports and exports the hardware. |
| `Vivado/scripts/cfgmem.tcl` | Generates the configuration memory file (`.mcs`) of the mezzanine from its bitstream. |
| `Vivado/src/bd/bd_zynqmp.tcl` | Block design of the host (`zcu106`): the link, and the `display_pipeline` hierarchy. |
| `Vivado/src/bd/bd_fpga.tcl` | Block design of the processor-less mezzanine (`auboard`). |
| `Vivado/src/bd/mipi_locs.tcl` | MIPI D-PHY pin LOCs of the AUBoard 15P, per camera port. |
| `Vivado/src/constraints/<target>.xdc` | One constraints file per target. |
| `Vivado/src/hdl/` | `bit_sync.v`, `freq_counter.v`, `pipe_gpio.v`. |
| `Yocto/` | The AMD EDF Yocto flow, the BSP of the host (`c2c-tools`, `c2c-cameras`, `c2c-display`) and the run-time device-tree overlay of the remote pipelines (`Yocto/overlays/`). |
| `Vitis/` | The bare-metal demo of the host: `common/src/` (the `cam_test` application), `common/dts/remote_pipeline.dtsi` (the User DTS that describes the *remote* IP) and `py/` (the build wrapper, `user_dts.py`, `pre_build.py`). |
| `scripts/jtag/` | JTAG bring-up and test of both boards, with no software running; `auboard_flash.tcl` writes the mezzanine's configuration flash and `zcu106_baremetal.tcl` runs the bare-metal demo. |
| `scripts/` | Host-side helpers: `filedrop.py` (HTTP file drop to and from the board), `rgb2png.py` (raw RGB24 capture to PNG). |
| `docs/` | Sphinx documentation. `docs/link_contract_deviations.md` is the link contract. |
| `build.py`, `build.sh`, `build.bat` | The cross-platform build runner. |
| `submodules/avnet-bdf` | Board definition files of the AUBoard 15P. |

Build outputs land in `Vivado/<target>/` (project, `c2c_wrapper.xsa`, `reports/`, and the
`c2c_wrapper.mcs` of the mezzanine), `Vivado/logs/` (build logs),
`Yocto/<target>/images/linux/` (`BOOT.BIN`, `Image`, `rootfs.wic.xz`, …) and
`Vitis/<target>_workspace/` + `Vitis/boot/<target>/BOOT.BIN` (bare metal). All of them are
gitignored.

## `config/data.json` and `config/update.py`

The target designs are described in `config/data.json`. After a change to the manifest, run

```
python3 config/update.py
```

to regenerate the files that are derived from it: the target table of `README.md` (between
the `<!-- updater start -->` / `<!-- updater end -->` tags), the `target_dict` of
`Vivado/scripts/build.tcl` (between `# UPDATER START` / `# UPDATER END`) and the per-target
directories in `.gitignore`. **Do not edit those blocks by hand.** The Sphinx pages read
`config/data.json` directly through a Jinja2 pass, so their tables follow automatically.

Every design in the manifest carries a `role`: `host` for the board with the processor that
runs Linux, and `mezzanine` for the processor-less board that carries the cameras.
`update.py` warns if a role is missing or if the system does not have exactly one host.
`cams` is the list of RPi Camera FMC ports that get a pipeline, and it reaches the block
design script as the Tcl variable `cams`.

## Changing the line rate of the link

The link runs at **10.3125 Gb/s from a 156.25 MHz reference clock**. Both boards must be
changed together — a mismatch simply does not train — and five places hold the numbers:

| File | What to change |
|---|---|
| `Vivado/src/bd/bd_zynqmp.tcl` | `set line_rate` and `set refclk_mhz` near the top |
| `Vivado/src/bd/bd_fpga.tcl` | `CONFIG.C_LINE_RATE` and `CONFIG.C_REFCLK_FREQUENCY` of the `aurora` cell |
| `Vivado/src/constraints/zcu106.xdc` | the `create_clock` period of `gt_refclk` |
| `Vivado/src/constraints/auboard.xdc` | the `create_clock` period of `sfp_refclk` |
| `scripts/jtag/auboard_axi.tcl` | `USER_CLK_NOMINAL_HZ` and `REFCLK_NOMINAL_HZ`, which the `status` command compares the measured user clock against |

Both boards must also be able to *produce* the new reference clock: on the ZCU106 it is the
programmable `USER_MGT_SI570_CLOCK1`, on the AUBoard the programmable clock generator U57.
Both output 156.25 MHz at power-up with no programming, which is why this design uses that
frequency; another rate means programming the clock generator before the link can train.

Two derived values change with the line rate:

* **The Aurora user clock is line rate / 64.** At 10.3125 Gb/s that is 161.1328125 MHz; it
  clocks the PHY side of the Chip2Chip core and is what the frequency counter on the AUBoard
  measures.
* **The `init_clk` must not exceed the user clock.** At the 5 Gb/s line rate, for example,
  the user clock is 5000 / 64 = **78.125 MHz**, so the 100 MHz `init_clk` of this design is
  too fast and has to be lowered: on the ZCU106 through
  `CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ` of the PS (`pl_clk0` is the init clock, the
  DRP clock and the AXI clock of the whole PL, so everything else moves with it), and on the
  AUBoard through `CLKOUT1_REQUESTED_OUT_FREQ` of `clk_wiz`. At that rate the Aurora core
  also moves from the QPLL to the CPLL of the GT quad.

After any such change, check what the IP actually produced: both block design scripts print
every link parameter on lines that start with `INFO: [link]` after `validate_bd_design`, and
they fail the build if `C_INTERFACE_MODE`, `C_AURORA_WIDTH` or the AXI ID/WUSER widths come
out wrong. `C_INIT_CLK` is read-only in a block design — it follows whatever clock is
connected to `init_clk`, so the log line is the only place it can be confirmed.

```{note}
`C_INTERFACE_MODE 1` (Compact 2:1) is the only mode that fits a 64-bit AXI data bus into one
Aurora lane; Compact 1:1 makes `C_AURORA_WIDTH` 2, i.e. a two-lane, 128-bit stream. If you
widen the link to two lanes you can use Compact 1:1, but then the GT LOCs, the SFP pin
constraints and the board wiring all change with it — the SFP+ cages of these two boards
carry one lane each.
```

## Matching rules for the link

Whatever you change, these must be identical on both boards or the link will not work:

* `C_INTERFACE_TYPE`, `C_INTERFACE_MODE`, `C_AXI_BUS_TYPE`, `C_AXI_DATA_WIDTH`,
  `C_AXI_ADDR_WIDTH`, `C_INTERRUPT_WIDTH`, `C_ECC_ENABLE`, `C_EN_AXI_LINK_HNDLR`, and the
  AXI4-Lite data/address widths.
* The **AXI ID width and WUSER width** (6 / 4 here). They are read-only on the master — the
  core copies them from whatever drives `s_axi` at validation time — which is why
  `bd_fpga.tcl` pins them with the `c2c_regslice` register slice and errors out if the
  validated core reports anything else. The slave sets the same numbers by hand on
  `C_M_AXI_ID_WIDTH` / `C_M_AXI_WUSER_WIDTH`.
* The Aurora line rate, reference clock frequency, lane count, dataflow (Duplex), interface
  mode (Streaming), flow control (None) and CRC (off).
* `C_INCLUDE_AXILITE` and `C_MASTER_FPGA` must be *opposite*: 2 / 1 on the AUBoard (master,
  AXI4-Lite master port) and 1 / 0 on the ZCU106 (slave, AXI4-Lite slave port).

`C_INIT_CLK` and `DRP_FREQ` are **not** part of the link protocol; they differ between the
two boards here (the ZCU106's `pl_clk0` cannot be made exactly 100 MHz from the PS reference
clock, and reads back as 99.990005) and nothing has to be matched.

## Adding or removing cameras

The number of pipelines comes from the `cams` list of the target in `config/data.json` —
`[0, 2]` today. `bd_fpga.tcl` builds one `mipi_<n>` hierarchy per entry, adds a slave port
to `smc_mm` and two master ports to `axi_periph` for each, and grows the interrupt
controller. `Vivado/src/bd/mipi_locs.tcl` already carries the D-PHY pin LOCs of all four
camera ports of the AUBoard 15P.

Three things cap the count on this board:

1. **The D-PHY PLLs of bank 66.** All four camera ports of the RPi Camera FMC land in bank
   66 of the xcau15p, and each MIPI CSI-2 RX subsystem is configured with shared logic in
   the core (`SupportLevel 1`), so each instance carries its own D-PHY PLL in that bank. The
   routed two-camera design uses 2 of the device's 6 PLLs and 1 of its 3 MMCMs; the bank's
   own PLLs are the binding limit, and they are the reason this board supports **two**
   cameras. (The `rpi-camera-fmc` reference design reaches the same conclusion for the
   AUBoard 15P.)
2. **Logic.** One pipeline is about 11.6k LUTs, 15.5k flip-flops, 30 block RAM tiles and
   41 DSPs. Two of them plus the link fill 42 % of the LUTs and 50 % of the block RAM of the
   xcau15p.
3. **The address map.** `addr_cam_base` in `bd_fpga.tcl` places CAM0 at `0xA010_0000` and
   CAM2 at `0xA020_0000`, 1 MB apart, inside the 16 MB window the ZCU106 assigns to the
   link. There is room for more, but every address that changes must also change in
   `Yocto/overlays/c2c-cams.dtso` (the constants are `#define`s at the top of that file) and
   in `scripts/jtag/auboard_cam.tcl`.

If you add a camera, also add its interrupts to the `intr_list` order in `bd_fpga.tcl` —
that order *is* the interrupt specifier in the device tree of the host — and to the overlay.

Adding the remaining two cameras of the FMC is not a matter of editing `cams` alone, because
of point 1: it needs a different D-PHY clocking arrangement, which this proof of concept
does not attempt.

## Changing the video pipelines

The parameters are Tcl variables at the top of `bd_fpga.tcl`, and they apply to every
pipeline:

| Variable | Value | Effect |
|---|---|---|
| `max_cols` / `max_rows` | 1920 / 1232 | Maximum resolution of the HLS video IP. Drives their resource usage, and caps the usable sensor modes (this is why the IMX219's 3280x2464 mode cannot be used). |
| `pipe_samples_pc` | 1 | Samples per clock. Raising it widens the streams and changes the subset converter's remap. |
| `video_clk_mhz` | 300.000 | The video clock. At one sample per clock it must exceed the sensor's pixel rate during a line — the two-lane IMX219 delivers up to 182.4 Mpixel/s. |
| `frmbuf_mm_width` | 64 | Data width of the AXI4 master of the frame buffer writers. 64 matches the link and keeps a width converter out of `smc_mm`. |
| `frmbuf_burst_len` | 64 | Burst length in beats (512 bytes). Every burst costs a round trip over the link, so short bursts limit throughput. This value is an estimate: it was never the limit in the measurements, so it has not been tuned. |

The IP configuration itself lives in `create_mipi_pipe` in the same file. Note two
consequences of the current choices that are easy to trip over:

* `v_proc_ss` is built as a **scaler only, without colour space conversion**
  (`C_ENABLE_CSC false`), and `v_frmbuf_wr` has **RGB8 only**. The single capture format is
  therefore `RGB3`. Adding YUYV8 to the frame buffer writer would be useless without also
  enabling colour space conversion in the video processing subsystem.
* The video clock is a **300 MHz** clock in a device whose D-PHY PLLs already run at the top
  of their range. If you change the 300 MHz board clock definition in `auboard.xdc`, read
  the comment there first: the period is deliberately rounded *up* to 3.334 ns.

After any change to the pipelines, the `INFO: [cam]` and `INFO: [map]` lines of the build
log are the values the device-tree overlay must be updated with, and
`Yocto/overlays/build-overlay.sh --check` verifies the overlay against the image's
`system.dtb` before you take it to the board.

## Porting the host role to another board

Nothing in the **link half** of the host design is specific to MIPI or to cameras: it is a
PS, an AXI Chip2Chip slave, an Aurora core and an address filter. It needs a free
transceiver lane, a free-running reference clock for that lane, and DDR. To move it to
another Zynq UltraScale+ board, change only:

1. **`gt_dict` in `bd_zynqmp.tcl`** — add an entry for the new `board_name` with the GT
   `quad`, `lane` and `refclk` of the SFP cage you will use. Keep the "placeholder refclk"
   idiom: select the same-numbered reference clock input of the GT's *own* quad, and let the
   constraints place the port on the real pins.
2. **A new `Vivado/src/constraints/<target>.xdc`** — the reference clock pins and its
   `create_clock`, the four serial pins of the SFP cage, the SFP TX-disable pin and its
   polarity, and the LEDs.
3. **`config/data.json`** — a new design entry with `role: host`, the board part
   (`url`/`boardname`), the `connector` name and `group`. Then run `config/update.py`.

The PS configuration (a 32-bit `M_AXI_HPM0_FPD` for the register path, a 64-bit
`S_AXI_HP0_FPD` for the inbound DMA, `pl_clk0` at 100 MHz, `pl_ps_irq0`) is board-independent
and comes from the board preset plus the overrides in `bd_zynqmp.tcl`.

Two things that do **not** change: the address map (the Chip2Chip core passes addresses
through 1:1, so the AUBoard's map is the same wherever the host is), and the link parameters
(the contract above).

The **display half** is the part that is board-dependent, because it drives the *PS*
DisplayPort live video input: `create_display_pipeline` in `bd_zynqmp.tcl`, `pl_clk1`
at 250 MHz, `S_AXI_HP3_FPD`, `pl_ps_irq0[5:4]`, the EMIO GPIO that resets the mixer, and
the `psgtr` / `dp-connector` nodes in the BSP's `system-user.dtsi`. It is entirely
optional — nothing in the link or the cameras depends on it — so a port that does not want
a monitor can drop `create_display_pipeline` and its address assignments and leave
everything else alone. See [Description](description) for what it consists of and
[Showing the cameras on a DisplayPort monitor](display) for the reasoning behind the
formats.

```{warning}
The GT reference clock routing is the part that usually bites. On both boards of this design
the free-running clock enters a *different* quad from the one that carries the SFP lane, and
UltraScale+ only allows a reference clock to be shared up to two quads away. Check that
before you pick the cage.
```

## Moving the remote address map

The window is assigned in two places and they must agree:

* `bd_zynqmp.tcl` assigns `axi_c2c/s_axi_lite/Reg` at `0xA000_0000` with a range of 16 MB
  in the PS address space.
* `bd_fpga.tcl` assigns every local peripheral explicitly, from `addr_gpio_sys`,
  `addr_bram`, `addr_gpio_freq`, `addr_gpio_dbg`, `addr_intc` and `addr_cam_base` /
  `addr_cam_offs`, into *both* the `axi_c2c/MAXI-Lite` and the `jtag_axi/Data` address
  spaces — so the host and the JTAG master see an identical map.

If you move anything, update `Yocto/overlays/c2c-cams.dtso`, `scripts/jtag/auboard_axi.tcl`,
`scripts/jtag/auboard_cam.tcl`, `scripts/jtag/zcu106_mem.tcl` and the tables in
`docs/link_contract_deviations.md` to match, and re-run
`Yocto/overlays/build-overlay.sh --check`.

The DMA direction is separate: the frame buffer writers and `jtag_axi` reach
`0x0000_0000`–`0x7FFF_FFFF` (the host's DDR low, mapped 1:1) and nothing else. That 2 GB
limit follows from the 32-bit address width of the link and of the frame buffer writers, and
is enforced on both sides — by `smc_mm` on the AUBoard and by the AXI MMU on the ZCU106.
