# Revision History

## 2025.2

First release. A proof of concept of the "universal MIPI CSI-2 FMC" architecture: the camera
pipelines live on a processor-less mezzanine FPGA and are bridged to the main board over
AXI Chip2Chip and Aurora 64B/66B, so the main board needs no MIPI-capable pins.

**The chip-to-chip link**

* AXI Chip2Chip over one Aurora 64B/66B lane at 10.3125 Gb/s from a 156.25 MHz reference
  clock, on an SFP+ direct attach cable between the `SFP0` cage of the ZCU106 and the SFP+
  cage of the AUBoard 15P.
* `zcu106` (`bd_zynqmp.tcl`): Zynq UltraScale+ PS, the Chip2Chip **slave** and the Aurora
  core on `SFP0` (GTH `X0Y10`, reference clock routed in from Quad 226).
  `M_AXI_HPM0_FPD` drives the AXI4-Lite slave port of the core: a 16 MB remote window at
  `0xA000_0000`. The AXI4 master port of the core writes the PS DDR low through
  `S_AXI_HP0_FPD`, behind an AXI MMU that passes only that 2 GB window. Link status GPIO at
  `0xA100_0000`; Chip2Chip interrupts on `pl_ps_irq0`.
* `auboard` (`bd_fpga.tcl`, no processor): the Chip2Chip **master** and the Aurora core on
  the SFP+ cage (GTH `X0Y11`, reference clock routed in from Quad 224). Its AXI4-Lite master
  port and a JTAG-to-AXI master reach the local peripherals from `0xA000_0000`; the
  JTAG-to-AXI master also reaches the ZCU106 DDR through the AXI4 slave port.
* `docs/link_contract_deviations.md` records every parameter the two block designs must
  agree on, and every place where one of them deviates. Both block design scripts check the
  validated result and fail the build on a mismatch.

**The camera pipelines (on the mezzanine)**

* One MIPI CSI-2 capture pipeline per camera, for `CAM0` and `CAM2` of the RPi Camera FMC:
  MIPI CSI-2 RX subsystem (2 lanes, RAW10) → subset converter → demosaic → gamma LUT →
  video processing subsystem (scaler) → frame buffer write, plus an AXI IIC and a GPIO
  (camera enable and the IP resets) per camera. CAM0 at `0xA010_0000`, CAM2 at
  `0xA020_0000`, inside the remote AXI4-Lite window.
* One AXI INTC at `0xA004_0000` cascades all ten pipeline interrupts into Chip2Chip
  interrupt 0 and thence GIC SPI 89 on the host.
* The frame buffer writers master the Chip2Chip AXI4 port and write straight into the
  ZCU106 DDR. Their AXI4 master is 64 bits wide to match the link, with 64-beat bursts.

**The host Linux image (AMD EDF Yocto flow)**

* `meta-user` layer for the `zcu106` target: console and `bootargs` fixups (`cma=1024M` for
  the capture buffers), `xlnx,fclk` nodes that keep `pl_clk0` and `pl_clk1` running, GEM3 PHY
  and MAC fixups, a kernel configuration fragment (Xilinx V4L2 video pipeline, IMX219,
  device-tree overlays through configfs), and a bench-ready root filesystem.
* `c2c-tools`: `c2c-link-status`, `c2c-peek` / `c2c-poke` (guarded against an access into a
  window whose link is down), `c2c-latency` and `c2c-overlay`.
* The remote peripherals are deliberately **not** in the base device tree. They are applied
  at run time by `Yocto/overlays/c2c-cams.dtso` after a link check, under a `simple-pm-bus`
  node whose `dma-ranges` keeps the capture buffers in the low 2 GB that the remote 32-bit
  masters can reach. `build-overlay.sh` compiles it and verifies every reference against the
  image's `system.dtb`; `init_c2c_cams.sh` sets up both media pipelines.

**The cameras come up by themselves (`c2c-cameras`)**

* `c2c-cameras.service` is **enabled by default** and brings both remote pipelines up at
  boot with no operator: wait for the Chip2Chip link, probe the remote design read-only,
  quiesce the remote frame buffer writers, apply the overlay once, wait for the media
  devices and run `c2c-init-cams`. Without the second board the ZCU106 boots and runs
  normally and the unit reports why the cameras are missing; the retry is
  `systemctl restart c2c-cameras`.
* `c2c-cameras health` is a read-only, one-line check that a capture wrapper can call
  before it opens a device. **Exit status 5** is the one condition a running system cannot
  recover from: the mezzanine was reset behind the drivers' back, so the remote video IP are
  back in reset and the next capture would hang the CPU. It is detected from the
  per-pipeline reset GPIOs *and* a generation marker in the AUBoard's scratch BRAM, because
  the GPIO signal does not survive a stream teardown. `c2c-cameras status` ends with the
  same verdict.
* `99-c2c-cameras.rules` gives the **stable names** `/dev/video-cam0` / `/dev/video-cam2`,
  the matching media devices and one subdev link per pipeline stage. The `videoN` numbering
  and the sensors' I2C bus numbers are *not* stable across boots.
* Settings in `/etc/default/c2c-cameras`. The manual overlay procedure still works unchanged.

**DisplayPort output of the two cameras (host)**

* The `zcu106` block design gains a `display_pipeline` hierarchy — video mixer, timing
  controller, AXI4-Stream to Video Out and a dynamically reconfigurable pixel clock wizard —
  that reads the camera frames back out of PS DDR through `S_AXI_HP3_FPD` and drives the PS
  DisplayPort **live video** input. Registers at `0xA200_0000`, interrupts on
  `pl_ps_irq0[5:4]`, datapath on `pl_clk1` at 250 MHz. Nothing of the link design moved.
* Every stage is RGB, so `v4l2src ! kmssink` needs no colour conversion on the CPU.
* `c2c-display` drives it: `both` (960x540 side by side), `cam0`, `cam2`, `pattern`,
  `check` (read-only diagnostics) and `off` / `stop`. The display is **off by default** —
  the unit is shipped disabled and refuses unless `C2C_DISPLAY_ENABLE=1` in
  `/etc/default/c2c-display` — and it borrows the pipelines rather than owning them.

**Bare-metal demo (host)**

* A standalone A53 application (`cam_test`, `./build.sh standalone --target zcu106`) drives
  both remote camera pipelines with no operating system and writes the frames into the
  ZCU106's DDR. It is built with the Vitis **System Device Tree** flow and a **User DTS**
  (`Vitis/common/dts/remote_pipeline.dtsi`) that describes IP living in the *other* FPGA, so
  the standalone BSP pulls in drivers and generates their configuration tables for hardware
  that is in no XSA.
* The application **polls** rather than using interrupts, and stops its frame buffer writers
  on a frame boundary so a JTAG dump is reproducible.
  `scripts/jtag/zcu106_baremetal.tcl` runs it over JTAG and dumps a frame from DDR.

**Bring-up and test tooling**

* `scripts/jtag/`: program the AUBoard (`auboard_prog.tcl`) or write its configuration flash
  (`auboard_flash.tcl`), drive its JTAG-to-AXI master (link status, measured Aurora user
  clock, memory test), exercise both camera pipelines (registers, IMX219 chip ID over I2C,
  CSI-2 packet and error check, interrupt path), bring the ZCU106 up over JTAG with no
  software at all (`zcu106_init.tcl` / `zcu106_mem.tcl`), and run the bare-metal demo and
  dump its frames (`zcu106_baremetal.tcl`).
* `scripts/filedrop.py` and `scripts/rgb2png.py`: pull captures to the build host and turn a
  raw RGB24 file into a PNG.

**Booting the AUBoard from its configuration flash**

* `Vivado/scripts/cfgmem.tcl` creates the configuration memory file (`.mcs`) of the
  `auboard` target from its bitstream, and `scripts/jtag/auboard_flash.tcl` programs,
  verifies, reads back or erases the board's quad SPI flash (ISSI IS25WP512M, 512 Mb) over
  JTAG. The AUBoard then loads the design by itself about 1.5 to 2 seconds after power-on,
  with no JTAG cable and no operator, and the Chip2Chip link trains from there without
  intervention.

**Documentation**

* Full Sphinx documentation: architecture, requirements, supported boards, build
  instructions, the Yocto flow, deployment, booting the AUBoard from its configuration
  flash, using the cameras from Linux, the DisplayPort output, the bare-metal demo,
  advanced customization and troubleshooting.

**Known limitations of this release**

* No auto-exposure, no automatic white balance and no colour space conversion: the single
  capture format is `RGB3`, and exposure, gain and gamma are set by hand.
* The IMX219's full 3280x2464 mode exceeds the 1920x1232 maximum of the video IP.
* Two cameras on the AUBoard 15P, not the four the RPi Camera FMC offers.
* Capture buffers must come from the capture driver (MMAP): the remote frame buffer writers
  are 32-bit masters limited to the low 2 GB of the host DDR.
* The device-tree overlay is applied once per boot and cannot be removed.
* A mezzanine that is reset while the host keeps running is **detected and refused**
  (`c2c-cameras health`, exit 5), but there is no recovery short of rebooting the host: the
  remote resets are released only in the drivers' `probe`.
* The camera-to-`/dev/videoN` assignment and the sensors' I2C bus numbers are not stable
  across boots. Use the stable names or the media graph.
* The display path is 1080p60 only, and the mixer layers cannot downscale, so the capture
  size must equal the window size (`c2c-display` reconfigures the remote scaler to match).
* The bare-metal application polls: `XSetupInterruptSystem()` cannot cascade an AXI INTC
  behind the GIC on a Cortex-A53.
* No PetaLinux project — the host's Linux image is the AMD EDF Yocto flow only.
