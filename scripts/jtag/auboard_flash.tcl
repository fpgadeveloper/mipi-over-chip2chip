# Opsero Electronic Design Inc. Copyright 2026
#
# Write a configuration memory file (.mcs) into the quad SPI configuration flash of the
# AUBoard 15P over JTAG, so that the FPGA loads the design by itself at every power-on.
# The flash is U17, an ISSI IS25WP512M (512 Mb = 64 MB, 1.8 V), and the mode pins of the
# board are hard-wired to Master SPI, so whatever is in this flash is what the board comes
# up with. JTAG always overrides it: a bitstream programmed with auboard_prog.tcl replaces
# the running design until the next power cycle, and leaves the flash untouched.
#
# Create the .mcs first (it is not a build product of ./build.sh):
#
#   vivado -mode batch -nolog -nojournal -notrace \
#     -source Vivado/scripts/cfgmem.tcl -tclargs auboard
#
# Usage (from any directory):
#
#   vivado -mode batch -nolog -nojournal -notrace -source auboard_flash.tcl -tclargs <mcs file> [options]
#   vivado -mode batch -nolog -nojournal -notrace -source auboard_flash.tcl -tclargs -erase-only [options]
#   vivado -mode batch -nolog -nojournal -notrace -source auboard_flash.tcl -tclargs -readback <file> [options]
#
# Modes:
#   <mcs file>          erase the sectors the image needs, then program them
#   -erase-only         erase the whole flash and program nothing. The board then comes up
#                       unconfigured (DONE low) until something is written back into it.
#   -readback <file>    read the whole flash into <file> and program nothing. The format is
#                       taken from the extension: .bin (raw, 64 MB) or .mcs. Take a backup
#                       of the image the board shipped with before you overwrite it.
#
# Options:
#   -verify             read the flash back after programming and compare it with the .mcs
#   -boot               make the FPGA reconfigure from the flash when the script is done,
#                       instead of leaving the indirect programming bitstream in it. This is
#                       a convenience only: a power cycle is the real test.
#   -url <host:port>    hw_server to connect to           (default 127.0.0.1:3121)
#   -cable <pattern>    part of the name of the JTAG cable (default 1234-oj1A, the on-board
#                       USB-JTAG of the AUBoard 15P)
#   -part <cfgmem>      configuration memory part          (default is25wp512m-spi-x1_x2_x4)
#
# The script connects to a hw_server that is ALREADY RUNNING and only opens the JTAG target
# whose name matches the cable pattern, so other boards on the same hw_server are untouched.
#
# Indirect programming works by loading a small programming bitstream into the FPGA, which
# then drives the flash. Vivado picks that bitstream itself. It replaces the design that was
# running, so the Chip2Chip link drops while the flash is written and the design comes back
# only after a power cycle (or with -boot).
#
# The time of every phase is printed as a "TIME:" line.
#
#*****************************************************************************************

set url      127.0.0.1:3121
set cable    1234-oj1A
set part     is25wp512m-spi-x1_x2_x4
set mcsfile  ""
set readback ""
set erase_only 0
set verify   0
set boot     0

for {set i 0} {$i < [llength $argv]} {incr i} {
  set arg [lindex $argv $i]
  switch -- $arg {
    -url        { incr i; set url      [lindex $argv $i] }
    -cable      { incr i; set cable    [lindex $argv $i] }
    -part       { incr i; set part     [lindex $argv $i] }
    -readback   { incr i; set readback [lindex $argv $i] }
    -erase-only { set erase_only 1 }
    -verify     { set verify 1 }
    -boot       { set boot 1 }
    default     { set mcsfile $arg }
  }
}

proc usage {} {
  puts "Usage: vivado -mode batch -nolog -nojournal -notrace -source auboard_flash.tcl -tclargs <mcs file> \[options\]"
  puts "       ... -tclargs -erase-only \[options\]"
  puts "       ... -tclargs -readback <file> \[options\]"
  puts "  options: -verify  -boot  -url <host:port>  -cable <pattern>  -part <cfgmem part>"
}

# Exactly one mode
set modes [expr {($mcsfile ne "") + ($readback ne "") + $erase_only}]
if { $modes != 1 } {
  if { $modes == 0 } { puts "ERROR: no .mcs file, -erase-only or -readback given" } \
                else { puts "ERROR: give exactly one of <mcs file>, -erase-only, -readback <file>" }
  usage
  exit 1
}
if { $mcsfile ne "" } {
  if { ![file exists $mcsfile] } {
    puts "ERROR: configuration memory file not found: $mcsfile"
    puts "       Create it with: vivado -mode batch -source Vivado/scripts/cfgmem.tcl -tclargs auboard"
    exit 1
  }
  set mcsfile [file normalize $mcsfile]
}
if { $readback ne "" } {
  set readback [file normalize $readback]
  set rb_format [string trimleft [string tolower [file extension $readback]] .]
  if { $rb_format eq "" } { set rb_format bin ; append readback .bin }
  if { $rb_format ni {bin mcs} } {
    puts "ERROR: the readback file must end in .bin or .mcs, got: $readback"
    exit 1
  }
  file mkdir [file dirname $readback]
}

# Elapsed seconds since the last call, for the TIME: lines
set stamp [clock milliseconds]
proc lap {} {
  global stamp
  set now [clock milliseconds]
  set elapsed [expr {($now - $stamp) / 1000.0}]
  set stamp $now
  return [format %.1f $elapsed]
}

#-----------------------------------------------------------------------------------------
# Connect
#-----------------------------------------------------------------------------------------

open_hw_manager
connect_hw_server -url $url

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
refresh_hw_device -quiet $device

set cfgmem_part [lindex [get_cfgmem_parts -quiet $part] 0]
if { $cfgmem_part eq "" } {
  puts "ERROR: unknown configuration memory part: $part"
  close_hw_target
  disconnect_hw_server
  exit 1
}
# 512 Mb -> 64 MB
set flash_bytes [expr {[get_property MEM_DENSITY $cfgmem_part] * 1024 * 1024 / 8}]

puts "INFO: device      : $device on $targets"
puts "INFO: cfgmem part : [get_property NAME $cfgmem_part] ([get_property MEM_MANUFACTURER $cfgmem_part], [get_property MEM_DENSITY $cfgmem_part] Mb, [get_property DATA_WIDTH $cfgmem_part])"
puts "INFO: flash size  : $flash_bytes bytes"

set rc 1
if {[catch {

  create_hw_cfgmem -hw_device $device $cfgmem_part
  set cfgmem [current_hw_cfgmem]
  # The AUBoard leaves the unused configuration pins to the board's own pull-ups
  set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem

  # Load the indirect programming bitstream that drives the flash. This replaces the design
  # that was running in the FPGA.
  lap
  set indirect [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
  puts "INFO: indirect programming bitstream: $indirect"
  create_hw_bitstream -hw_device $device $indirect
  program_hw_devices $device
  puts "TIME: indirect programming bitstream loaded in [lap] s"

  if { $readback ne "" } {

    puts "INFO: reading the whole flash into $readback ($rb_format)"
    readback_hw_cfgmem -force -format $rb_format -offset 0x0 -datacount $flash_bytes \
      -file $readback $cfgmem
    puts "TIME: readback of $flash_bytes bytes in [lap] s"
    if { ![file exists $readback] } { error "the readback file was not written" }
    puts "INFO: $readback ([file size $readback] bytes)"

  } elseif { $erase_only } {

    puts "INFO: erasing the WHOLE flash ($flash_bytes bytes). The board will come up"
    puts "INFO: unconfigured (DONE low) until something is written back into it."
    set_property PROGRAM.ADDRESS_RANGE {entire_device} $cfgmem
    set_property PROGRAM.FILES         [list ""] $cfgmem
    set_property PROGRAM.BLANK_CHECK   0 $cfgmem
    set_property PROGRAM.ERASE         1 $cfgmem
    set_property PROGRAM.CFG_PROGRAM   0 $cfgmem
    set_property PROGRAM.VERIFY        0 $cfgmem
    set_property PROGRAM.CHECKSUM      0 $cfgmem
    program_hw_cfgmem -hw_cfgmem $cfgmem
    puts "TIME: erase (whole device) in [lap] s"

  } else {

    set prmfile [file rootname $mcsfile].prm
    puts "INFO: mcs file    : $mcsfile ([file size $mcsfile] bytes)"
    set_property PROGRAM.ADDRESS_RANGE {use_file} $cfgmem
    set_property PROGRAM.FILES         [list $mcsfile] $cfgmem
    if { [file exists $prmfile] } {
      puts "INFO: prm file    : $prmfile"
      set_property PROGRAM.PRM_FILES [list $prmfile] $cfgmem
    }
    set_property PROGRAM.BLANK_CHECK 0 $cfgmem
    set_property PROGRAM.CHECKSUM    0 $cfgmem

    # Erase, program and verify are three passes so that each one is timed on its own
    set_property PROGRAM.ERASE 1 $cfgmem
    set_property PROGRAM.CFG_PROGRAM 0 $cfgmem
    set_property PROGRAM.VERIFY 0 $cfgmem
    program_hw_cfgmem -hw_cfgmem $cfgmem
    puts "TIME: erase in [lap] s"

    set_property PROGRAM.ERASE 0 $cfgmem
    set_property PROGRAM.CFG_PROGRAM 1 $cfgmem
    program_hw_cfgmem -hw_cfgmem $cfgmem
    puts "TIME: program in [lap] s"

    if { $verify } {
      set_property PROGRAM.CFG_PROGRAM 0 $cfgmem
      set_property PROGRAM.VERIFY 1 $cfgmem
      program_hw_cfgmem -hw_cfgmem $cfgmem
      puts "TIME: verify in [lap] s"
      puts "INFO: the flash matches $mcsfile"
    } else {
      puts "INFO: not verified (-verify was not given)"
    }
  }

  if { $boot } {
    puts "INFO: making the FPGA reconfigure from the flash"
    boot_hw_device $device
    after 2000
    refresh_hw_device -quiet $device
    set config_status [get_property REGISTER.CONFIG_STATUS $device]
    set done [expr {($config_status >> 14) & 1}]
    puts [format "INFO: CONFIG_STATUS = 0x%08X, DONE pin = %d" $config_status $done]
    puts "TIME: boot from flash in [lap] s"
    if { $done != 1 } {
      error "the FPGA did not configure from the flash (DONE is low)"
    }
  }
  set rc 0

} errmsg]} {
  puts "ERROR: $errmsg"
  set rc 1
}

close_hw_target
disconnect_hw_server

if { $rc == 0 } {
  if { $readback ne "" } {
    puts "INFO: read back"
  } elseif { $erase_only } {
    puts "INFO: erased"
  } else {
    puts "INFO: programmed. Power-cycle the board to load the design out of the flash"
    puts "INFO: (the FPGA still holds the indirect programming bitstream until then)."
  }
}
exit $rc
