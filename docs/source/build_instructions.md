# Build instructions

## Source code

The source code for the reference design is managed on this Github repository:

* [https://github.com/fpgadeveloper/mipi-over-chip2chip](https://github.com/fpgadeveloper/mipi-over-chip2chip)

As this repository has a submodule, clone it with the `--recursive` option:
```
git clone --recursive https://github.com/fpgadeveloper/mipi-over-chip2chip.git
cd mipi-over-chip2chip
```

The `--recursive` flag pulls in `submodules/avnet-bdf`, the Avnet/Tria board definition
files that the AUBoard 15P target needs (they are not in the AMD board store). If the
submodule is missing, the build runner initialises it before it builds.

## License requirements

Both target designs build with the Vivado **Standard** Edition, the free edition that needs
no license, and neither uses a separately licensed IP core.

(target-designs)=

## Target designs

This design is a two-board system: the target designs below are the two halves of one
system and **both must be built**.

| Target board        | Target design     | Role | Connector | Cameras | Baremetal<br> App | Yocto<br> Build | Vivado<br> Edition | IP<br>License |
|---------------------|-------------------|------|-----------|---------|-----|-----|-----|-----|
{% for design in data.designs %}{% if design.publish %}| [{{ design.board }}]({{ design.link }}) | `{{ design.label }}` | {{ design.role }} | {{ design.connector }} | {{ design.cams | length }} | {% if design.baremetal %} ✅ {% else %} ❌ {% endif %} | {% if design.yocto %} ✅ {% else %} ❌ {% endif %} | {{ "Enterprise" if design.license else "Standard 🆓" }} | {{ "Required" if design.ip_license else "-" }} |
{% endif %}{% endfor %}

The `auboard` target has no processor, so it has no software build: its products are the
bitstream and the configuration memory file the board boots from. The `zcu106` target has
a Yocto (AMD EDF) Linux image and a bare-metal Vitis application; there is no PetaLinux
project for this design.

## Cross-platform build runner

All builds are driven by the `build.py` runner at the root of the repository, on **both
Windows and Linux**. Each command builds whatever it depends on automatically, skips
anything that is already built, and locates the AMD tools itself, so there is no need to
source the settings scripts beforehand.

On Linux and on Windows (git bash), commands are run with the `build.sh` shim, which finds
a suitable Python 3 automatically (including the interpreter bundled with the AMD tools).
Windows users who prefer not to use git bash can run the same commands from Command Prompt
or PowerShell using `build.bat` instead — the commands and arguments are otherwise
identical, for example `build.bat xsa --target zcu106`.

## Build the bitstreams

```
./build.sh xsa --target zcu106
./build.sh xsa --target auboard
```

Each command creates the Vivado project of the target, runs synthesis and implementation,
and exports the hardware to `Vivado/<target>/c2c_wrapper.xsa`.

* The bitstream of the processor-less `auboard` target is
  `Vivado/auboard/auboard.runs/impl_1/c2c_wrapper.bit` (it is also inside the XSA).
* Timing and utilization reports are written to `Vivado/<target>/reports/`
  (`timing_summary.rpt`, `utilization.rpt`, `utilization_hier.rpt`).
* The timing result is printed in the build log (`Vivado/logs/<target>_xsa.log`) on a line
  that starts with `TIMING:`. A target that misses timing also produces a
  `CRITICAL WARNING: [Opsero-Timing]` and fails the build.

Both block design scripts check the link parameters after `validate_bd_design` and stop the
build if the tools derived something other than the link contract; they print what they
found on lines that start with `INFO: [link]`, `INFO: [cam]` and `INFO: [map]`. Those lines
are the source of the address map and IP configuration that the Linux device tree overlay
depends on, so they are worth keeping after a change.

```{note}
`./build.sh xsa --target auboard` builds two MIPI capture pipelines and takes considerably
longer than the host build — the AUBoard design fills about 42 % of the xcau15p.
```

## Build the Linux image of the host

This stage requires a native Linux machine.

```
./build.sh yocto --target zcu106
```

See the [Yocto](yocto) page for the flow and its prerequisites, and
[Deploying and updating the Linux image](deploy) for how to get the result onto the board's
SD card — including the case where the card cannot be reached.

## Build the bare-metal application of the host

This stage needs Vivado and Vitis only. It runs on Windows as well as on Linux, and it does
**not** need PetaLinux or a Yocto build.

```
./build.sh standalone --target zcu106
```

It builds the XSA first if it is not there, then the Vitis platform (from the XSA plus a
*User DTS* that describes the camera IP living in the other FPGA), the standalone BSP, the
`cam_test` application and `Vitis/boot/zcu106/BOOT.BIN`. See
[Bare-metal demo](baremetal) for the flow, for running it over JTAG and for dumping a
captured frame out of DDR.

## Build the configuration memory file of the mezzanine

The `.mcs` that the AUBoard's configuration flash is written with is a build product like
any other:

```
./build.sh cfgmem --target auboard
```

It builds the bitstream first if it is not there, then wraps it into
`Vivado/auboard/c2c_wrapper.mcs` (plus the `.prm` memory map next to it). `./build.sh all
--target auboard` runs this stage too, and re-running it is a no-op while the `.mcs` is
newer than the bitstream. Only a target that boots from a configuration flash has the stage
— `zcu106` does not, because its bitstream travels inside `BOOT.BIN`.

Under the hood it runs `Vivado/scripts/cfgmem.tcl`, which owns the flash part, size and
interface of each such board; you can still call it directly:

```
vivado -mode batch -nolog -nojournal -notrace \
  -source Vivado/scripts/cfgmem.tcl -tclargs auboard
```

See [Booting the AUBoard from its configuration flash](flash.md).

## Gather the boot images

```
./build.sh package --target all
```

Collects what each target has built into `bootimages/`:

| Target | Zip | Contents |
|---|---|---|
| `zcu106` | `mipi-over-chip2chip_zcu106_standalone-2025-2.zip` | the bare-metal `BOOT.BIN` |
| `zcu106` | `mipi-over-chip2chip_zcu106_yocto-2025-2.zip` | `rootfs.wic.xz`, its `.bmap`, `BOOT.BIN` |
| `auboard` | `mipi-over-chip2chip_auboard_bitstream-2025-2.zip` | `c2c_wrapper.bit`, and the `.mcs`/`.prm` when the `cfgmem` stage has run |

The `auboard` zip is what a processor-less target produces: it has no software and no boot
image, so the design itself is the deliverable. `./build.sh all --target <target>` ends with
this stage.

## Other commands

```
./build.sh list                       # the targets of this repo and their attributes
./build.sh status --target all        # what has been built
./build.sh all --target all           # build everything that each target supports
./build.sh clean --target <target>    # delete the generated outputs of a target
./build.sh --help                     # every command
```

## Programming the boards

### Program the AUBoard 15P over JTAG

`scripts/jtag/auboard_prog.tcl` connects to a **`hw_server` that is already running** and
opens only the JTAG target whose name matches the cable pattern, so other boards on the
same `hw_server` are untouched.

```
vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_prog.tcl \
  -tclargs Vivado/auboard/auboard.runs/impl_1/c2c_wrapper.bit \
           [-url <host:port>] [-cable <pattern>]
```

| Option | Default | Meaning |
|---|---|---|
| `-url` | `127.0.0.1:3121` | the `hw_server` to connect to |
| `-cable` | `1234-oj1A` | a substring of the JTAG cable name (the on-board USB-JTAG of the AUBoard 15P) |

The script reports `CONFIG_STATUS`, the state of the `DONE` pin and the JTAG-to-AXI masters
it found, and exits non-zero if the device did not configure. Nothing is written to the
configuration flash: the design is lost at the next power cycle, and the board comes back
with whatever image is in its flash.

That is what you want while you are developing. To make the design permanent, write it into
the AUBoard's configuration flash instead — the board then loads it by itself about 1.5 to
2 seconds after power-on, with no JTAG cable and no operator. Generate the configuration
memory file and program it:

```
vivado -mode batch -nolog -nojournal -notrace \
  -source Vivado/scripts/cfgmem.tcl -tclargs auboard

vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_flash.tcl \
  -tclargs Vivado/auboard/c2c_wrapper.mcs -verify [-cable <pattern>]
```

A JTAG load always overrides the flash image until the next power cycle, so the two are not
exclusive: keep a known-good image in the flash and still iterate over JTAG. The full
procedure, including how to back up the image the board shipped with, how to do the same
from the Vivado Hardware Manager GUI, and how to undo it, is in
[Booting the AUBoard from its configuration flash](flash.md).

### Exercise the link from the AUBoard

`scripts/jtag/auboard_axi.tcl` drives the design's JTAG-to-AXI master — no processor and no
host needed. Same `-url` / `-cable` options.

```
vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_axi.tcl -tclargs <command> [args] [options]
```

| Command | What it does |
|---|---|
| `status` | decode the link status bits, print the measured Aurora user clock and the GT reference clock it implies |
| `rd <addr> [<count>]` | read 32-bit words |
| `wr <addr> <data> [<data> ...]` | write 32-bit words to consecutive addresses |
| `leds <value>` | write the LED GPIO (bits 1..0 drive LED2..LED1) and read it back |
| `loopback <0..7>` | Aurora loopback: 0 = normal, 1 = near-end PCS, 2 = near-end PMA |
| `test` | LED GPIO read-back test plus a single-beat and burst pattern test of the 8K scratch BRAM |

`-force` allows an `rd`/`wr` in `0x0000_0000`–`0x7FFF_FFFF` (the host's DDR through the
link) while the link is down. Such a transaction never completes: expect an error, and
re-program the device if the master stays stuck.

### Exercise the camera pipelines from the AUBoard

`scripts/jtag/auboard_cam.tcl`, same invocation and options, plus `-samples <n>` (default 5,
one per second) for the streaming commands.

| Command | What it does |
|---|---|
| `regs` | read an identifying/status register of every IP of both pipelines and of the interrupt controller (releases the video IP resets first, restores the GPIOs afterwards) |
| `camid <0\|2>` | enable the camera and read the chip ID of the IMX219 over I2C |
| `stream <0\|2>` | program the IMX219 for 1920x1080, 2 lanes, RAW10, start it, and sample the status registers of the MIPI CSI-2 RX subsystem |
| `csi <0\|2>` | the samples of `stream` only, for a sensor that is already streaming |
| `stop <0\|2>` | stop streaming and put the pipeline back into its power-up state |
| `irq <0\|2>` | check the path of the interrupts into the interrupt controller |
| `i2cscan <0\|2>` | scan the camera's I2C bus with the camera enable pin high and low |
| `i2crd <0\|2> <reg> [<count>]` / `i2cwr <0\|2> <reg> <value>` | read / write IMX219 registers |

```{warning}
`stream` does **not** configure the scaler, so the video stops in front of it after a few
lines and the CSI-2 line buffer fills. Each sample restarts the demosaic and gamma LUT IP,
which lets up to two frames through. Continuous flow through the whole pipeline is not
tested by this script — that is what the Linux side does.

A video IP whose reset bit is 0 does not answer on AXI4-Lite, and an access to it never
completes and blocks the register path for everybody, including the host; only
re-programming the device recovers it. Every command of this script releases the reset
before it touches an IP.
```

### Bring the ZCU106 up over JTAG, without any software

`scripts/jtag/zcu106_init.tcl` runs under `xsdb`. It resets the system, programs the PL and
then runs the `psu_init.tcl` of the hardware hand-off, so that the DDR, `pl_clk0` and the
PS-PL AXI interfaces are live. Nothing is written to the SD card or to the QSPI flash, and
the boot mode switches can stay wherever they are — the script selects the JTAG boot mode
through the `BOOT_MODE_USER` register, which a power cycle clears again.

```
xsdb scripts/jtag/zcu106_init.tcl <bit file> <psu_init.tcl> [-url <url>] [-cable <pattern>] [-noreset]
xsdb scripts/jtag/zcu106_init.tcl -xsa Vivado/zcu106/c2c_wrapper.xsa [options]
```

The `-xsa` form extracts the bitstream and `psu_init.tcl` from the XSA itself. The default
`-url` is `tcp:127.0.0.1:3121`.

`scripts/jtag/zcu106_mem.tcl` then reads and writes the memory map:

```
xsdb scripts/jtag/zcu106_mem.tcl [-url <url>] [-cable <pattern>] [-force] <command> [arguments]
```

| Command | What it does |
|---|---|
| `status` | read the local link status register and decode its bits |
| `mrd <addr> [words]` / `mwr <addr> <value> ...` | read / write 32-bit words |
| `ddrtest [addr] [words]` | write and read back a pattern in the PS DDR (default `0x10000000`, 256 words) |
| `loopback <0..7>` | set the Aurora/GT loopback mode, then reset the link |
| `linkreset` | pulse the link reset request (`pma_init`) |
| `remote` | read the first registers of the remote board through the link |

The script refuses an access to the remote window (`0xA000_0000`–`0xA0FF_FFFF`) unless the
status shows `channel_up` and `link_status`, because such an access never completes and
hangs the debug access port of the PS. `-force` overrides the refusal.

### Run the bare-metal demo over JTAG

`scripts/jtag/zcu106_baremetal.tcl` boots the standalone `cam_test` application on the
ZCU106 without touching the SD card — reset, program the PL, PMU firmware, the real FSBL,
release the PS-PL isolation and `pl_resetn0`, then download and start the application — and
pulls the captured frames out of the PS DDR afterwards. It is described, with its options
and the warning about the isolation, in [Bare-metal demo](baremetal).

## Running the system

1. Fit the RPi Camera FMC on the AUBoard 15P with cameras on `CAM0` and `CAM2`, connect the
   SFP+ DAC cable between the `SFP0` cage of the ZCU106 and the SFP+ cage of the AUBoard,
   and power both boards.
2. Load the design into the AUBoard (above). With the design in its configuration flash
   there is nothing to do here: the board configures itself about 1.5 to 2 seconds after
   power-on. Check the link with `auboard_axi.tcl status`. `LED4` is the Aurora
   `channel_up` and `LED3` is the AXI Chip2Chip link status, so the link state is also
   visible on the board.
3. Boot the ZCU106 from its SD card. Its FSBL programs the PL out of `BOOT.BIN`, so the host
   end of the link is live before Linux starts. From Linux, `sudo c2c-link-status` must
   report `link: UP` (`0x0000000F`).
4. Capture. `c2c-cameras.service` has already applied the device-tree overlay of the remote
   pipelines and configured both of them — `sudo c2c-cameras status` says so. See
   [Using the cameras from Linux](linux_cameras), and
   [Showing the cameras on a DisplayPort monitor](display) to put them on a screen.

```{note}
A reboot of the ZCU106 reprograms its PL, so the link drops and trains again by itself once
Linux is back (`c2c-link-status -w 30`). The AUBoard is not reset by this: its registers and
memories keep their contents, and its sticky error bits stay set until it is reset or
re-programmed.
```
