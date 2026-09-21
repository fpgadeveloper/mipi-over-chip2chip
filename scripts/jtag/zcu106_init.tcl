# Opsero Electronic Design Inc. Copyright 2026
#
# Bring the ZCU106 host design up over JTAG WITHOUT any software: system reset, program the
# PL, then run the PS initialisation of the hardware hand-off (psu_init.tcl) so that the DDR,
# pl_clk0 and the PS-PL AXI interfaces are live. After this, the memory map of the design
# can be read and written over JTAG (see zcu106_mem.tcl). Nothing is written to the SD card
# or to the QSPI flash: everything is lost at the next power cycle or reset.
#
# Usage (from any directory):
#
#   xsdb zcu106_init.tcl <bit file> <psu_init.tcl> [options]
#   xsdb zcu106_init.tcl -xsa <xsa file> [options]      (takes both files from the XSA)
#
# Options:
#   -url <url>          hw_server to connect to            (default tcp:127.0.0.1:3121)
#   -cable <pattern>    part of the name of the JTAG cable (default "FT232H 11093", the
#                       on-board USB-JTAG of the bench ZCU106; use "*" when the ZCU106 is
#                       the only board on the hw_server)
#   -noreset            do not reset the system first (only program the PL and run psu_init)
#
# The script connects to a hw_server that is ALREADY RUNNING and only selects targets of
# the JTAG cable that matches the pattern, so other boards on the same hw_server are
# untouched.
#
# The boot mode switches of the board can stay in any position: the script selects the JTAG
# boot mode through the BOOT_MODE_USER register before the reset, so the boot ROM does not
# try to boot from the SD card or the QSPI flash while the PS is initialised from here.
#
#*****************************************************************************************

set url     tcp:127.0.0.1:3121
set cable   "FT232H 11093"
set bitfile ""
set psuinit ""
set xsafile ""
set doreset 1

set positional {}
for {set i 0} {$i < [llength $argv]} {incr i} {
  set arg [lindex $argv $i]
  switch -- $arg {
    -url     { incr i; set url     [lindex $argv $i] }
    -cable   { incr i; set cable   [lindex $argv $i] }
    -xsa     { incr i; set xsafile [lindex $argv $i] }
    -noreset { set doreset 0 }
    default  { lappend positional $arg }
  }
}

proc usage {} {
  puts "Usage: xsdb zcu106_init.tcl <bit file> <psu_init.tcl> \[-url url\] \[-cable pattern\] \[-noreset\]"
  puts "       xsdb zcu106_init.tcl -xsa <xsa file>           \[-url url\] \[-cable pattern\] \[-noreset\]"
}

if { $xsafile ne "" } {
  # The XSA is a zip archive that contains the bitstream and psu_init.tcl
  if { ![file exists $xsafile] } { puts "ERROR: XSA file not found: $xsafile"; exit 1 }
  set xsafile [file normalize $xsafile]
  set exdir [file join [file dirname $xsafile] jtag_init]
  file mkdir $exdir
  if { [catch {exec unzip -o -q $xsafile psu_init.tcl *.bit -d $exdir} msg] } {
    puts "ERROR: could not extract psu_init.tcl and the bitstream from $xsafile: $msg"
    exit 1
  }
  set bitfile [lindex [glob -nocomplain -directory $exdir *.bit] 0]
  set psuinit [file join $exdir psu_init.tcl]
} else {
  set bitfile [lindex $positional 0]
  set psuinit [lindex $positional 1]
}

if { $bitfile eq "" || $psuinit eq "" } { puts "ERROR: bit file and psu_init.tcl are required"; usage; exit 1 }
foreach f [list $bitfile $psuinit] {
  if { ![file exists $f] } { puts "ERROR: file not found: $f"; exit 1 }
}
set bitfile [file normalize $bitfile]
set psuinit [file normalize $psuinit]

# Select a target of OUR cable by name
proc sel {name} {
  global cable
  targets -set -nocase -filter "name =~ \"$name\" && jtag_cable_name =~ \"*${cable}*\""
}

puts "INFO: connecting to $url"
connect -url $url
after 1000

# The debug access port of the PS is the target "PSU". After a bus access that never completed
# (for example a read of the remote window while the link was down) it shows up as
# "DAP (AXI AP transaction error, ...)" instead, without its PSU/APU children. Both names are
# accepted here and a system reset is attempted, but a reset does not reliably clear that
# state: it clears the PL while the access port stays in the error state. If the PSU target
# does not come back after the reset, power-cycle the board.
proc sel_dap {} {
  if { [catch {sel "PSU"}] } { sel "DAP*"; return 0 }
  return 1
}
if { [catch {sel_dap} healthy] } {
  puts "ERROR: no Zynq UltraScale+ (PSU or DAP target) found on a cable matching '*${cable}*': $healthy"
  puts [targets]
  exit 1
}
if { !$healthy } {
  puts "WARNING: the debug access port is in an error state (a bus access did not complete): resetting"
  if { !$doreset } { puts "ERROR: -noreset was given, but only a system reset recovers this state"; exit 1 }
}

if { $doreset } {
  # Alternate boot mode = JTAG (BOOT_MODE_USER: use_alt=1, alt_boot_mode=0). The register
  # survives the system reset, so the boot ROM comes back in JTAG mode and stays idle.
  # With the access port in the error state the write can fail: the reset is done anyway and
  # the boot mode is checked (and the reset repeated) afterwards.
  puts "INFO: selecting the JTAG boot mode and resetting the system"
  if { [catch {mwr -force 0xFF5E0200 0x0100} msg] } { puts "WARNING: could not write BOOT_MODE_USER before the reset: $msg" }
  if { [catch {rst -system} msg] } {
    puts "WARNING: rst -system failed ($msg), trying rst -srst"
    rst -srst
  }
  after 3000
  sel "PSU"
  if { [mrd -force -value 0xFF5E0200] != 0x0100 } {
    puts "INFO: boot mode was not JTAG after the reset: setting it and resetting once more"
    mwr -force 0xFF5E0200 0x0100
    rst -system
    after 3000
    sel "PSU"
  }
  puts [format "INFO: BOOT_MODE_USER = 0x%04X" [mrd -force -value 0xFF5E0200]]
}

# Program the PL (a system reset clears it)
# (the FPGA device of the cable is its top level "PS TAP" target: with more than one board
#  on the hw_server the fpga command must be given that target, never a default)
puts "INFO: programming the PL: $bitfile"
sel "PS TAP"
fpga -file $bitfile
puts "INFO: PL programmed"

# Initialise the PS from the hardware hand-off: MIO, PLLs, clocks, DDR, peripherals, SERDES,
# AXI port widths. Then open the PS-PL isolation and release the PL resets (pl_resetn0).
puts "INFO: running psu_init from $psuinit"
sel "APU*"
configparams force-mem-accesses 1
source $psuinit
psu_init
after 1000
psu_ps_pl_isolation_removal
after 1000
psu_ps_pl_reset_config
after 500
puts "INFO: PS initialised, PS-PL isolation removed, PL resets released"

# Quick proof of life: PS DDR and the local link status register
sel "PSU"
set pattern 0x5AC2C001
mwr -force 0x10000000 $pattern
set rb [mrd -force -value 0x10000000]
if { $rb == $pattern } {
  puts [format "INFO: PS DDR check at 0x10000000: wrote 0x%08X, read 0x%08X - OK" $pattern $rb]
} else {
  puts [format "ERROR: PS DDR check at 0x10000000: wrote 0x%08X, read 0x%08X" $pattern $rb]
  disconnect
  exit 1
}
puts [format "INFO: link status register (0xA1000000) = 0x%03X   (decode it with zcu106_mem.tcl status)" [mrd -force -value 0xA1000000]]

configparams force-mem-accesses 0
disconnect
puts "INFO: done"
