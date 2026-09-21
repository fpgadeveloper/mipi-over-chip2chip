# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# JTAG-boot a RAM-resident Linux on the ZCU106 (PetaLinux 2025.2 pre-built images).
# usage: xsdb jtag_boot_ramdisk.tcl <petalinux-prebuilt-images-dir> <jtag_ramdisk.scr> [cable-glob]
# See docs/source/deploy.md. The cable glob selects the JTAG cable of the ZCU106 when
# several boards share one hw_server (default: every cable, "*").
# Memory map: dtb 0x00100000, Image 0x00200000, U-Boot 0x08000000 (its link address),
# initrd 0x10000000 (NOT the stock 0x04000000: a 207 MB cpio there overlaps U-Boot),
# boot script 0x20000000 (U-Boot sources ${scriptaddr} when the boot mode is JTAG).
# Connects to the hw_server on the default port; every target selection is filtered by cable.
set img   [lindex $argv 0]
set scr   [lindex $argv 1]
set cable [expr {[llength $argv] > 2 ? [lindex $argv 2] : "*"}]
proc sel {name} {
    global cable
    targets -set -nocase -filter "name =~ \"$name\" && jtag_cable_name =~ \"$cable\""
}
proc maskw {addr mask val} {
    set cur [mrd -force -value $addr]
    mwr -force $addr [expr {($cur & ~$mask) | ($val & $mask)}]
}
proc step {msg} { puts ">>> [clock format [clock seconds] -format %H:%M:%S] $msg"; flush stdout }

connect
after 1500

step "alt boot mode = JTAG (BOOT_MODE_USER 0x0100), system reset"
sel "PSU"
mwr -force 0xFF5E0200 0x0100
rst -system
after 3000
sel "PSU"
puts "BOOT_MODE_USER = [mrd -force -value 0xFF5E0200]"

step "program the pre-built bitstream (matches the pre-built device tree)"
# With two FPGAs on the hw_server, fpga wants the top-level JTAG device of the
# ZynqMP ("PS TAP"), not its "PL" child; the cable filter keeps it off the AUBoard.
sel "PS TAP"
fpga -file $img/system.bit
after 500

step "PMU firmware"
sel "PSU"
maskw 0xFFCA0038 0x1C0 0x1C0
after 500
sel "MicroBlaze PMU*"
catch {stop}
after 500
dow $img/pmufw.elf
con
after 1000

step "FSBL (DDR, clocks, MIO)"
sel "APU*"
mwr -force 0xFFFF0000 0x14000000
maskw 0xFD1A0104 0x501 0x0
after 500
sel "*A53*#0"
dow $img/zynqmp_fsbl.elf
con
after 6000
stop
puts "A53#0 after FSBL: [rrd pc]"

step "device tree, kernel, boot script"
dow -data $img/system.dtb 0x00100000
dow -data $img/Image      0x00200000
dow -data $scr            0x20000000
step "root filesystem (cpio, ~207 MB over JTAG)"
dow -data $img/rootfs.cpio.gz.u-boot 0x10000000
step "U-Boot + TF-A, go"
dow $img/u-boot.elf
dow $img/bl31.elf
con
step "released; watch the UART"
disconnect
