# Booting the AUBoard from its configuration flash

## Why

The AUBoard 15P has no processor. Nothing on the board loads a bitstream into the FPGA for
you, so there are exactly two ways to get this design running on it:

* **Program the FPGA over JTAG** with `scripts/jtag/auboard_prog.tcl`. This is immediate and
  it is what you want while you are developing, but it is **volatile**: the FPGA forgets the
  design at the next power cycle and the board comes back with whatever is in its
  configuration flash — on a new board, the demo image it shipped with.
* **Write the design into the configuration flash**, which is what this page is about. The
  board then loads the design by itself at every power-on, with no host, no JTAG cable and
  no operator. Measured on the bench: **`DONE` goes high about 1.5 to 2 seconds after the
  power comes on**, and the Chip2Chip link trains by itself from there.

The AUBoard has **no boot mode switch**. Its mode pins `M[2:0]` are hard-wired to `001`,
Master SPI, so the FPGA always tries to configure itself out of the flash at power-on. JTAG
is not disabled by that — a bitstream loaded over JTAG always overrides what came out of the
flash, until the next power cycle.

The configuration flash is **U17, an ISSI IS25WP512M**: 512 Mb = 64 MB, quad SPI, 1.8 V. In
Vivado it is the configuration memory part `is25wp512m-spi-x1_x2_x4`.

```{note}
The ZCU106 host needs none of this. Its FSBL programs the PL out of `BOOT.BIN` on the SD
card, so the host half of the link is already live before Linux starts.
```

## Back up what is in the flash first

Programming the flash destroys the image the board shipped with. If you may ever want that
image back, read it out before you overwrite it — it is not published anywhere you can
download it from, so this backup is the only copy you will have.

```
vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_flash.tcl \
  -tclargs -readback auboard_factory_flash.bin [-cable <pattern>]
```

This reads all 64 MB and takes about **3.5 minutes** (208 s measured). The result is the raw
content of the flash, byte for byte. Check that it is worth keeping before you go on:

* the file is exactly 67,108,864 bytes;
* it is not blank — a fresh AUBoard is roughly 11 % non-`0xFF`;
* it contains a configuration image: the bus-width detect word `0x000000BB 0x11220044` at
  offset `0x40` and the bitstream **sync word `0xAA995566` at offset `0x50`**.

To turn the `.bin` into a file you can program back, trim it to the part that is not blank
and run it through `write_cfgmem`:

```
write_cfgmem -force -format MCS -size 64 -interface SPIx4 -checksum \
  -loaddata "up 0x0 auboard_factory_flash_trimmed.bin" auboard_factory_flash.mcs
```

Keep a `sha256sum` of both files next to them.

## Generate the .mcs

The flash is not written with the bitstream directly; it is written with a **configuration
memory file** that wraps the bitstream in the format the flash and the configuration logic
expect. The `cfgmem` build stage creates it, building the bitstream first if it is not there:

```
./build.sh cfgmem --target auboard
```

The stage runs `Vivado/scripts/cfgmem.tcl`, which holds the flash part, size and interface of
each board that has one. You can also call it directly, once the bitstream exists:

```
vivado -mode batch -nolog -nojournal -notrace \
  -source Vivado/scripts/cfgmem.tcl -tclargs auboard
```

It writes two files next to the exported hardware, in the gitignored build directory
`Vivado/auboard/`:

| file | what it is |
|---|---|
| `c2c_wrapper.mcs` | the configuration memory file, about 12 MB of Intel-hex text |
| `c2c_wrapper.prm` | the memory map `write_cfgmem` writes alongside it |

The log ends with the map of the image, which is worth a glance:

```
File Format        MCS
Interface          SPIX4
Size               64M
Start Address      0x00000000
End Address        0x03FFFFFF
Checksum           0xBD299292

Addr1         Addr2         File(s)
0x00000000    0x004393C3    .../impl_1/c2c_wrapper.bit
```

The design occupies `0x00000000`–`0x004393C3`, that is 4,428,740 bytes, so it uses about
**4.4 MB of the 64 MB flash**. Everything above that is untouched by a program run, because
the programmer only erases the sectors the file covers.

`cfgmem.tcl` knows which targets have a configuration flash. Asking it for `zcu106` is an
error, not a silent no-op: that board boots from its SD card and its bitstream lives inside
`BOOT.BIN`.

## Program the flash with the script

`scripts/jtag/auboard_flash.tcl` connects to a **`hw_server` that is already running** and
opens only the JTAG target whose name matches the cable pattern, so other boards on the same
`hw_server` are untouched — the same convention as the other scripts in `scripts/jtag/`.

```
vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_flash.tcl \
  -tclargs Vivado/auboard/c2c_wrapper.mcs -verify [-cable <pattern>]
```

| Argument | Meaning |
|---|---|
| `<mcs file>` | erase the sectors the image needs, then program them |
| `-erase-only` | erase the **whole** flash and program nothing. The board then comes up unconfigured (`DONE` low) until something is written back into it |
| `-readback <file>` | read the whole flash into `<file>` and program nothing; `.bin` or `.mcs` by extension |
| `-verify` | read the flash back after programming and compare it with the `.mcs` |
| `-boot` | make the FPGA reconfigure from the flash when the script is done, instead of leaving the indirect programming bitstream in it |
| `-url <host:port>` | the `hw_server` to connect to (default `127.0.0.1:3121`) |
| `-cable <pattern>` | a substring of the JTAG cable name (default `1234-oj1A`, the on-board USB-JTAG) |
| `-part <cfgmem>` | configuration memory part (default `is25wp512m-spi-x1_x2_x4`) |

Every phase prints a `TIME:` line. Measured on a bench AUBoard 15P with the on-board
USB-JTAG, for the 4.4 MB image of this design:

| phase | time |
|---|---|
| load the indirect programming bitstream | 2.2 s |
| erase | 10.2 s |
| program | 75.3 s |
| verify (`-verify`) | 14.0 s |
| **total, including Vivado startup** | **about 2 minutes** |

A full 64 MB readback, for comparison, is 208 s.

```{warning}
Programming the flash **replaces the running design**. Indirect programming works by loading
a small programming bitstream into the FPGA, which then drives the flash — so the Chip2Chip
link drops the moment programming starts, and the host loses the remote window. Do not have
software on the ZCU106 touching the AUBoard while the flash is being written.

When the script is finished the FPGA still holds that programming bitstream, **not** your
design. Power-cycle the board (or pass `-boot`) to load the design out of the flash.
```

## Program the flash with the Vivado Hardware Manager GUI

If you would rather click than run a script:

1. **Open Hardware Manager** in Vivado, then **Open target ▸ Auto Connect**. The AUBoard
   appears as a target with the device `xcau15p_0`.
2. Right-click the device `xcau15p_0` and choose **Add Configuration Memory Device…**.
3. In the search box type **`is25wp512m`** and select **`is25wp512m-spi-x1_x2_x4`**
   (manufacturer ISSI, density 512 Mb, width x1_x2_x4). Click **OK**.
4. Vivado offers to program it right away — click **OK**, or right-click the configuration
   memory device later and choose **Program Configuration Memory Device…**.
5. In the dialog:
   * **Configuration file**: browse to `Vivado/auboard/c2c_wrapper.mcs`.
   * **PRM file**: `Vivado/auboard/c2c_wrapper.prm` (optional).
   * **State of non-config mem I/O pins**: **Pull none**.
   * Tick **Erase**, **Program** and **Verify**. Leave **Blank check** off — it costs a full
     read of the device and tells you nothing you need.
   * Address Range: **Configuration File Only**.
6. Click **OK**. Vivado loads the indirect programming bitstream itself and runs the three
   operations, with a progress dialog. Expect about 100 seconds.
7. **Power-cycle the board.**

To read the flash out from the GUI instead, right-click the configuration memory device and
choose **Readback Configuration Memory Device…**.

## Verify that it worked

Power-cycle the board — do not touch JTAG — wait a few seconds, then ask the design itself:

```
vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_axi.tcl -tclargs status [-cable <pattern>]
```

A board that configured itself out of the flash answers like this:

```
CONFIG_STATUS = 0x109079FC, DONE pin = 1
status (0xA0000008) = 0x00F
  bit  0 channel_up           1
  bit  1 lane_up              1
  bit  2 gt_pll_lock          1
  bit  3 c2c_link_status      1
  ...
  bit  9 mmcm_not_locked      0
link: UP (Aurora channel up and AXI Chip2Chip link up)
user_clk frequency (0xA0020000) = 161128088 Hz  (measurement number 11, one per second)
  expected 161132812.5 Hz at 10.3125 Gbps: deviation -29.3 ppm
```

What to look at:

* **`DONE pin = 1`** — the FPGA is configured. Nothing else in the output is meaningful if
  this is 0.
* The design answers on the JTAG-to-AXI master at all, which is only possible if *our*
  design is the one running.
* **`user_clk` ≈ 161.128 MHz** and **`mmcm_not_locked = 0`** — the GT reference clock and the
  MMCM are up.
* `link: UP` once the ZCU106 half is running too.

The **measurement number** is a free-running counter that increments once a second from the
moment the design starts, so it also tells you how long the design has been alive. That is
how the configuration time below was measured: read the counter, subtract it from the time
since the power came on.

Three cold boots measured on the bench, each one a full power cycle with no JTAG involved:

| boot | USB-JTAG back | status read | counter | FPGA configured |
|---|---|---|---|---|
| 1 | +2.46 s | +13.80 s | 11 | **+1.8 s** |
| 2 | +2.36 s | +13.49 s | 11 | **+1.5 s** |
| 3 | +2.56 s | +13.93 s | 11 | **+1.9 s** |

All times are from the moment the power came on; the counter has one-second granularity, so
read the last column as "under two seconds". Shifting 4,428,740 bytes at `CONFIGRATE` 31.9
MHz over four data lines only takes about 0.28 s, so most of that time is the board's own
power-on reset ramp, not the configuration itself.

In all three boots the design came up clean and the camera checks passed unchanged:
`auboard_cam.tcl regs` reported `REGS PASSED`, and `camid 0` and `camid 2` both found the
IMX219 (model ID `0x02 0x19`) at I2C address `0x10`.

### The link after a cold boot

A cold boot of the AUBoard under a **running** ZCU106 needs no intervention: the Aurora
channel and the Chip2Chip link train again by themselves within the few seconds it takes the
board to come up, and **both sides read a clean `0x00F`** afterwards, with no sticky error
bits. The host can read and write the AUBoard's registers again immediately
(`zcu106_mem.tcl remote`).

The other order is noisier, and this is expected. If the **ZCU106**'s PL is programmed (or
the ZCU106 reboots) while the AUBoard is already running, the link drops and trains again,
and the AUBoard latches sticky error bits while it does — `0x01F` (`c2c_link_error`) or
`0x03F` (`c2c_link_error` and `c2c_multi_bit_error`) were both seen. The link is up and
usable in that state; the bits are a record of the retraining, and they clear when the
AUBoard is reset or re-programmed. See [Troubleshooting](troubleshooting.md).

## Going back

**Restore a backup.** Program the `.mcs` you made from the readback, exactly like any other
image:

```
vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_flash.tcl -tclargs auboard_factory_flash.mcs -verify
```

Then power-cycle. To confirm the restore, read the flash back again and `cmp` it against
your backup `.bin`.

**Erase it.** `-erase-only` erases the whole device and writes nothing:

```
vivado -mode batch -nolog -nojournal -notrace \
  -source scripts/jtag/auboard_flash.tcl -tclargs -erase-only
```

After that the board comes up unconfigured — `DONE` stays low and no design runs — until you
program the flash again. JTAG still works, so this is recoverable, but there is no undo:
take the backup first.

**Just go back to JTAG for a session.** You do not have to erase anything. A bitstream
loaded with `auboard_prog.tcl` overrides the flash image until the next power cycle, so you
can keep a known-good image in the flash and still iterate over JTAG.

## Caveats

* **The bitstream must carry the right configuration properties.** The `.mcs` is generated
  for a quad SPI interface, and the FPGA has to read the flash the same way. These four
  lines in `Vivado/src/constraints/auboard.xdc` are what make that true, and a bitstream
  built without them will program into the flash happily and then never reach `DONE`:

  ```
  set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
  set_property BITSTREAM.CONFIG.CONFIGRATE 31.9 [current_design]
  set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
  set_property CONFIG_MODE SPIx4 [current_design]
  ```

  If you change them, change the `-interface` in `Vivado/scripts/cfgmem.tcl` to match.
* **JTAG always overrides the flash.** A device programmed over JTAG stays that way until
  the next power cycle, whatever is in the flash. If you are wondering why your new flash
  image does not seem to be running, check whether something programmed the device over JTAG
  after the last power cycle.
* **Programming drops the link**, and leaves the indirect programming bitstream in the FPGA
  until you power-cycle. See the warning above.
* **A power cycle, not a reset.** The reset pushbutton (`SYS_RST_N`) resets the design's
  logic; it does not make the FPGA reconfigure. The `PROGRAM_B` pushbutton does.
* **One flash, one image.** This design uses 4.4 MB of the 64 MB and does not use multiboot
  or a golden image, so there is no fallback if a programming run is interrupted — just
  program it again.
* **`-verify` is worth the 14 seconds.** It reads the flash back and compares it with the
  `.mcs`, which is the only check that the image really landed.
