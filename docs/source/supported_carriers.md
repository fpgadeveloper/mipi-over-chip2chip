# Supported boards

This design is a two-board system, and each role is supported on exactly one board. They
are not alternatives: both designs must be built, and both boards must be present.

| Role | Target design | Board | Device | Connector used |
|------|---------------|-------|--------|----------------|
{% for design in data.designs %}{% if design.publish %}| {{ design.role | capitalize }} | `{{ design.label }}` | [{{ design.board }}]({{ design.link }}) | {% for group in data.groups %}{% if group.label == design.group %}{{ group.name }}{% endif %}{% endfor %} | {{ design.connector }} |
{% endif %}{% endfor %}

* On the **host**, the connector column is the SFP+ cage that carries the chip-to-chip
  link: `SFP0` of the ZCU106, wired to GTH Quad 225, channel 2.
* On the **mezzanine**, it is the FMC connector that carries the [RPi Camera FMC]. The
  chip-to-chip link uses the board's own SFP+ cage, wired to GTH Quad 226, channel 3.

## Board specific notes

### ZCU106 (host)

The design uses the `SFP0` cage and the `USER_MGT_SI570_CLOCK1` reference clock, which the
board supplies at 156.25 MHz at power-up without any programming. No FMC connector is used
on this board — the ZCU106 needs no MIPI-capable pins at all, which is the whole point of
the architecture.

Set the boot mode DIP switch `SW6` to SD (`1 0 0 0`) to boot the Linux image from the SD
card.

### AUBoard 15P (mezzanine)

The design supports two cameras on this board: `CAM0` and `CAM2` as labelled on the
[RPi Camera FMC]. All four camera ports of the FMC land in bank 66 of the device, and each
MIPI CSI-2 RX subsystem instance carries its own D-PHY PLL in that bank, which is the first
hard limit on the camera count (see [Advanced](advanced)).

The 156.25 MHz GT reference clock comes from the board's programmable clock generator
(U57), which outputs that frequency at power-up without programming.

The board definition files of the AUBoard 15P are not in the AMD board store. They are
pulled in by the `submodules/avnet-bdf` git submodule; clone this repository with
`--recursive`, or let the build runner initialise the submodule for you.

```{note}
The AUBoard 15P has no boot mode switch: it always boots from its own quad SPI configuration
flash. Write the design into that flash and the board configures itself about 1.5 to 2
seconds after power-on, with no JTAG cable and no operator, and the Chip2Chip link trains
from there by itself — see
[Booting the AUBoard from its configuration flash](flash.md). Programming the device over
JTAG instead is the volatile alternative, and the one to use while iterating: the design is
lost at the next power cycle and the board comes back with whatever image is in its flash.
```

## Other boards

The host role only needs a free transceiver lane, a free-running reference clock for it,
and DDR: nothing about the ZCU106 design is specific to MIPI or to cameras. Porting it to
another host board is mostly a matter of the GT location, the reference clock and the SFP
pin constraints — see [Advanced](advanced).

The mezzanine role, in this proof of concept, is tied to the AUBoard 15P because that is
the board whose pinout the [RPi Camera FMC] matches and whose SFP+ cage carries the link.

If you need to know whether the [RPi Camera FMC] is compatible with a carrier that is not
listed here, please first check the [compatibility list]. If your carrier is not there,
[contact Opsero] with its pinout and we'll be happy to check compatibility and generate a
Vivado constraints file for you.

[contact Opsero]: https://opsero.com/contact-us
[compatibility list]: https://camerafmc.com/docs/rpi-camera-fmc/compatibility/
[RPi Camera FMC]: https://docs.opsero.com/op068/datasheet/overview/
