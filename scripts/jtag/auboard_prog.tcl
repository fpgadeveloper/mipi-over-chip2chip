# Opsero Electronic Design Inc. Copyright 2026
#
# Program the AUBoard 15P (xcau15p) over JTAG with a bitstream. Nothing is written to the
# configuration flash, so this is VOLATILE: the design is lost at the next power cycle and
# the board comes back with whatever image is in its flash. That is what you want while you
# are iterating on the mezzanine design.
#
# To have the board load the design by itself at every power-on (about 1.5 to 2 s after the
# power comes on, with no JTAG cable and no operator), write it into the configuration flash
# with auboard_flash.tcl instead - see docs/source/flash.md. A JTAG load from this script
# always overrides the flash image until the next power cycle, so the two are not exclusive.
#
# Usage (from any directory):
#
#   vivado -mode batch -nolog -nojournal -notrace -source auboard_prog.tcl -tclargs <bit file> [options]
#
# Options:
#   -url <host:port>    hw_server to connect to           (default 127.0.0.1:3121)
#   -cable <pattern>    part of the name of the JTAG cable (default 1234-oj1A, the on-board
#                       USB-JTAG of the AUBoard 15P)
#
# The script connects to a hw_server that is ALREADY RUNNING and only opens the JTAG target
# whose name matches the cable pattern, so other boards on the same hw_server are untouched.
#
#*****************************************************************************************

set url     127.0.0.1:3121
set cable   1234-oj1A
set bitfile ""

for {set i 0} {$i < [llength $argv]} {incr i} {
  set arg [lindex $argv $i]
  switch -- $arg {
    -url   { incr i; set url   [lindex $argv $i] }
    -cable { incr i; set cable [lindex $argv $i] }
    default { set bitfile $arg }
  }
}

if { $bitfile eq "" } {
  puts "ERROR: no bit file given"
  puts "Usage: vivado -mode batch -nolog -nojournal -notrace -source auboard_prog.tcl -tclargs <bit file> \[-url host:port\] \[-cable pattern\]"
  exit 1
}
if { ![file exists $bitfile] } {
  puts "ERROR: bit file not found: $bitfile"
  exit 1
}
set bitfile [file normalize $bitfile]

open_hw_manager
connect_hw_server -url $url

# Select the JTAG target by the name of its cable
set targets [get_hw_targets -quiet -filter "NAME =~ *${cable}*"]
if { [llength $targets] != 1 } {
  puts "ERROR: expected exactly one JTAG target matching '*${cable}*', found [llength $targets]"
  puts "       targets on $url: [get_hw_targets -quiet]"
  disconnect_hw_server
  exit 1
}
current_hw_target $targets
open_hw_target

set device [get_hw_devices -quiet xcau15p*]
if { [llength $device] != 1 } {
  puts "ERROR: no xcau15p on target $targets (devices: [get_hw_devices -quiet])"
  close_hw_target
  disconnect_hw_server
  exit 1
}
current_hw_device $device

# The debug probes file (next to the bit file) names the JTAG to AXI master; it is optional
set ltxfile "[file rootname $bitfile].ltx"
if { ![file exists $ltxfile] } { set ltxfile "" }

puts "INFO: programming $device on $targets"
puts "INFO:   bit file: $bitfile"
set_property PROGRAM.FILE $bitfile $device
set_property PROBES.FILE $ltxfile $device
set_property FULL_PROBES.FILE $ltxfile $device
program_hw_devices $device
refresh_hw_device $device

# DONE pin = bit 14 of the configuration status register (the names of the per-bit properties
# differ between device families, the register itself does not)
set config_status [get_property REGISTER.CONFIG_STATUS $device]
set done [expr {($config_status >> 14) & 1}]
puts "INFO: CONFIG_STATUS = $config_status, DONE pin = $done"
puts "INFO: JTAG to AXI masters found: [get_hw_axis -quiet]"

close_hw_target
disconnect_hw_server

if { $done != 1 } {
  puts "ERROR: the device did not configure (DONE is low)"
  exit 1
}
puts "INFO: programmed"
