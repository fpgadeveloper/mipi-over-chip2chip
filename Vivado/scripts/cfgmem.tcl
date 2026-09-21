# Opsero Electronic Design Inc. Copyright 2026
#
# Create the configuration memory file (.mcs) of a target from the bitstream that the
# implementation run produced, so that the design can be written into the board's
# configuration flash and loaded by the FPGA at every power-on.
#
# This is only needed for a target whose board boots from a configuration flash and has no
# processor to load the bitstream. In this repo that is the "auboard" target: the AUBoard
# 15P has its mode pins hard-wired to Master SPI and boots from its own quad SPI flash.
# The "zcu106" target boots from an SD card through the FSBL of its BOOT.BIN, which already
# carries the bitstream, so it has no .mcs.
#
# Run it after the bitstream exists (./build.sh xsa --target <target>), from any directory:
#
#   vivado -mode batch -nolog -nojournal -notrace \
#     -source Vivado/scripts/cfgmem.tcl -tclargs <target-name>
#
# Outputs, next to the exported hardware in Vivado/<target>/ (a gitignored build directory):
#
#   c2c_wrapper.mcs   the configuration memory file, to be programmed with
#                     scripts/jtag/auboard_flash.tcl or with the Vivado Hardware Manager
#   c2c_wrapper.prm   the memory map that write_cfgmem writes alongside the .mcs
#
# The .mcs is only as good as the configuration properties compiled into the bitstream. The
# constraints of the target must set the bus width, the configuration rate and the
# configuration mode to match the flash and the interface used here, otherwise the FPGA
# boots in the wrong mode and never reaches DONE. For the AUBoard, see the bitstream section
# of Vivado/src/constraints/auboard.xdc.
#
#*****************************************************************************************

# Targets that boot from a configuration flash: { cfgmem part, size in MB, interface }.
# The cfgmem part name must be one of "get_cfgmem_parts" and must match the flash fitted on
# the board; the size is the size of that flash and has to be a power of two.
#
#   auboard   AUBoard 15P, U17 = ISSI IS25WP512M, 512 Mb = 64 MB, quad SPI, 1.8 V
#
dict set flash_dict auboard { is25wp512m-spi-x1_x2_x4 64 SPIx4 }

if { $argc >= 1 } {
  set target [lindex $argv 0]
} elseif { ![info exists target] } {
  puts ""
  puts "This script creates the configuration memory file (.mcs) of a target."
  puts ""
  puts "  vivado -mode batch -nolog -nojournal -notrace \\"
  puts "    -source Vivado/scripts/cfgmem.tcl -tclargs <target-name>"
  puts ""
  puts "Targets with a configuration flash: [dict keys $flash_dict]"
  return
}

if { ![dict exists $flash_dict $target] } {
  puts "ERROR: target '$target' has no configuration flash in this repo."
  puts "       Targets with a configuration flash: [dict keys $flash_dict]"
  puts "       The host target boots from its SD card: its bitstream is inside BOOT.BIN."
  exit 1
}
lassign [dict get $flash_dict $target] cfgmem_part flash_size_mb interface

# The Vivado directory of the repo, resolved from the location of this script, so that the
# command line above works from any directory
set vivado_dir [file normalize [file join [file dirname [file normalize [info script]]] ..]]
set block_name c2c

set bitfile [file join $vivado_dir $target ${target}.runs impl_1 ${block_name}_wrapper.bit]
set mcsfile [file join $vivado_dir $target ${block_name}_wrapper.mcs]

if { ![file exists $bitfile] } {
  puts "ERROR: bitstream not found: $bitfile"
  puts "       Build it first: ./build.sh xsa --target $target"
  exit 1
}

puts "INFO: target      : $target"
puts "INFO: bitstream   : $bitfile ([file size $bitfile] bytes)"
puts "INFO: cfgmem part : $cfgmem_part"
puts "INFO: flash size  : $flash_size_mb MB"
puts "INFO: interface   : $interface"

# -checksum makes write_cfgmem print a 32 bit checksum of the image, which the programmer
# prints again when it verifies the flash
write_cfgmem -force -format MCS -size $flash_size_mb -interface $interface -checksum \
  -loadbit "up 0x0 $bitfile" $mcsfile

if { ![file exists $mcsfile] } {
  puts "ERROR: write_cfgmem did not produce $mcsfile"
  exit 1
}
puts "INFO: wrote $mcsfile ([file size $mcsfile] bytes)"
set prmfile [file rootname $mcsfile].prm
if { [file exists $prmfile] } {
  puts "INFO: wrote $prmfile"
}
puts "INFO: program it with:"
puts "INFO:   vivado -mode batch -nolog -nojournal -notrace \\"
puts "INFO:     -source scripts/jtag/auboard_flash.tcl -tclargs $mcsfile -verify"
