# Requirements

This design is built for version **2025.2** of the AMD tools. Older tool versions are not
supported; if you use one, check the
[release tags](https://github.com/fpgadeveloper/mipi-over-chip2chip/tags) for a version of
this repository that matches.

## Tools

* **Vivado 2025.2** — both block designs and both bitstreams.
* **Vitis 2025.2** — it provides `sdtgen` / `xsct`, which the Yocto flow uses to turn the
  XSA into a System Device Tree, and it builds the **bare-metal application** of the host
  (`./build.sh standalone --target zcu106`, see [Bare-metal demo](baremetal)).
* A **Linux PC or virtual machine** for the Yocto image of the host. The Vivado and the
  bare-metal builds run on Linux and on Windows (git bash or `build.bat`); the Yocto stage
  is Linux only, and the build runner refuses it up front on Windows with the hand-off
  command.

There is **no PetaLinux project** for this design: the Linux image of the host is the AMD
EDF Yocto flow only. The processor-less `auboard` target has no software at all.

## Hardware

This is a two-board system: both boards are needed.

* One AMD [ZCU106] Evaluation board — the **host**
* One Tria [AUBoard 15P] FPGA Development board — the **mezzanine**
* One Opsero [RPi Camera FMC] (OP068)
* Two [Raspberry Pi Camera Module 2], connected to ports `CAM0` and `CAM2` of the FMC
* One **SFP+ direct attach (DAC) cable** between the `SFP0` cage of the ZCU106 and the
  SFP+ cage of the AUBoard 15P
* A micro-USB cable to each board for JTAG and UART, and an Ethernet cable from the ZCU106
  to your network (the Linux image brings up GEM3 with a fixed MAC address and an SSH
  server, and asks for an address by DHCP)
* An SD card of 16 GB or more for the Linux image of the ZCU106 (the image is 8 GiB + 16 KiB)

Optional:

* A **DisplayPort monitor and cable** for the ZCU106's DisplayPort socket, to see the two
  camera streams side by side — see
  [Showing the cameras on a DisplayPort monitor](display). Everything else in this design
  works without one, and `c2c-display check` proves the picture reached the monitor from the
  command line.

```{warning}
**FMC voltage (VADJ).** The RPi Camera FMC is specified for a VADJ of **1.2 V**. On the
AUBoard 15P, the board definition file describes jumper `J46` as setting VCCO of banks 66
and 86 — the banks of the FMC connector — to 1.8 V (high, the board default) or 1.2 V (low).

Opsero runs this bench, and the `auboard` target of the
[rpi-camera-fmc](https://github.com/fpgadeveloper/rpi-camera-fmc) reference design, at the
board's 1.8 V setting without any observed issue. The design uses 1.2 V-compatible I/O
standards in either case, as the AMD MIPI CSI-2 RX subsystem requires.
```

## Supported cameras

The [RPi Camera FMC] accepts any camera with the standard
[15-pin Raspberry Pi camera interface](https://camerafmc.com/docs/rpi-camera-fmc/detailed-description/#camera-connectors),
but this design has software support for the [Raspberry Pi Camera Module 2] (IMX219) only.
The sensor is driven by the in-kernel `imx219` driver on the host, and by a register table
in `scripts/jtag/auboard_cam.tcl` when the AUBoard is exercised over JTAG alone.

```{tip}
We're working on developing software support for more cameras. If you'd like to help with
this effort, your pull requests are more than welcome.
```

[ZCU106]: https://www.xilinx.com/zcu106
[AUBoard 15P]: https://www.avnet.com/americas/products/avnet-boards/avnet-board-families/auboard-15p-fpga-development-kit/
[RPi Camera FMC]: https://docs.opsero.com/op068/datasheet/overview/
[Raspberry Pi Camera Module 2]: https://www.raspberrypi.com/products/camera-module-v2/
