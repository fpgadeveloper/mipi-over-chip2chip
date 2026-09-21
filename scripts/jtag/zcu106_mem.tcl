# Opsero Electronic Design Inc. Copyright 2026
#
# Read and write the memory map of the ZCU106 host design over JTAG (no software running).
# Run zcu106_init.tcl first: it programs the PL and initialises the PS.
#
# Usage (from any directory):
#
#   xsdb zcu106_mem.tcl [options] <command> [arguments]
#
# Commands:
#   status                     read the local link status register and decode its bits
#   mrd <addr> [words]         read 32-bit words
#   mwr <addr> <value> ...     write 32-bit words
#   ddrtest [addr] [words]     write/read-back a pattern in the PS DDR (default 0x10000000, 256)
#   loopback <0..7>            Aurora/GT loopback mode (0 normal, 2 near-end PMA), then a link reset
#   linkreset                  pulse the link reset request (pma_init of the link)
#   remote                     read the first registers of the remote board through the link
#                              (only when the link is up, see the warning below)
#
# Options:
#   -url <url>          hw_server to connect to            (default tcp:127.0.0.1:3121)
#   -cable <pattern>    part of the name of the JTAG cable (default "FT232H 11093")
#   -force              access the remote window even when the link is reported down
#
# Address map of the design (see Vivado/src/bd/bd_zynqmp.tcl):
#   0x0000_0000 - 0x7FFF_FFFF  PS DDR low
#   0xA000_0000 - 0xA0FF_FFFF  remote window: the peripherals of the remote board, through the link
#   0xA100_0000                local axi_gpio_link: +0x0 link status (in), +0x8 link debug (out)
#
# WARNING: an access to the remote window while the link is DOWN never completes (the AXI
# Chip2Chip has no timeout in this configuration). Over JTAG this hangs the debug access port
# of the PS, which then reports as "DAP (AXI AP transaction error ...)" instead of "PSU".
# zcu106_init.tcl attempts a system reset for this, but a reset does not reliably recover the
# access port (rst -system, rst -srst and a DP ABORT can all leave it in the error state), so
# expect to power-cycle the board. This script therefore refuses such an access unless the
# status shows channel_up=1 and link_status=1, or -force is given.
#
# NOTE on DDR accesses: prefer single-word "mrd"/"mwr" after a Tcl-only psu_init. A block read
# - such as the 256-word read of "ddrtest" - has been seen to end in "AP transaction timeout"
# and hang the debug access port, while single-word accesses to the same address worked
# immediately before. Recovery from that state costs a power cycle, so use "ddrtest" knowing
# that, and keep to single-word accesses when a hang would be expensive.
#
#*****************************************************************************************

set url    tcp:127.0.0.1:3121
set cable  "FT232H 11093"
set force  0

set ADDR_STATUS  0xA1000000
set ADDR_CTRL    0xA1000008
set REMOTE_BASE  0xA0000000
set REMOTE_HIGH  0xA0FFFFFF

set words {}
for {set i 0} {$i < [llength $argv]} {incr i} {
  set arg [lindex $argv $i]
  switch -- $arg {
    -url    { incr i; set url   [lindex $argv $i] }
    -cable  { incr i; set cable [lindex $argv $i] }
    -force  { set force 1 }
    default { lappend words $arg }
  }
}
set cmd  [lindex $words 0]
set args_ [lrange $words 1 end]

proc usage {} {
  puts "Usage: xsdb zcu106_mem.tcl \[-url url\] \[-cable pattern\] \[-force\] <command> \[arguments\]"
  puts "  status | mrd <addr> \[words\] | mwr <addr> <value> ... | ddrtest \[addr\] \[words\]"
  puts "  loopback <0..7> | linkreset | remote"
}

# Link status bits, LSB first (the same layout on both boards)
set status_bits {
  channel_up lane_up gt_pll_lock c2c_link_status c2c_link_error c2c_multi_bit_error
  c2c_config_error hard_err soft_err mmcm_not_locked
}

proc rd {addr} { return [mrd -force -value $addr] }
proc wr {addr value} { mwr -force $addr $value }

proc read_status {} {
  global ADDR_STATUS
  return [expr {[rd $ADDR_STATUS] & 0x3FF}]
}

proc print_status {value} {
  global status_bits
  puts [format "link status (0xA1000000) = 0x%03X" $value]
  set i 0
  foreach name $status_bits {
    puts [format "  bit%d %-20s = %d" $i $name [expr {($value >> $i) & 1}]]
    incr i
  }
  set up [expr {($value & 0x009) == 0x009}]
  puts [format "  => Aurora channel %s, Chip2Chip link %s" \
    [expr {($value & 1) ? "UP" : "DOWN"}] [expr {($value & 8) ? "UP" : "DOWN"}]]
  return $up
}

proc link_is_up {} { return [expr {([read_status] & 0x009) == 0x009}] }

# Refuse an access that would hang the debug access port
proc check_remote_access {addr nwords} {
  global REMOTE_BASE REMOTE_HIGH force
  set last [expr {$addr + 4*$nwords - 1}]
  if { $last < $REMOTE_BASE || $addr > $REMOTE_HIGH } { return }
  if { [link_is_up] } { return }
  if { $force } {
    puts "WARNING: the link is down and -force was given: this access may hang the JTAG target"
    return
  }
  puts [format "ERROR: 0x%08X is in the remote window and the link is DOWN: the access would never" $addr]
  puts "       complete and would hang the JTAG debug port (recovery: zcu106_init.tcl). Use -force to try anyway."
  print_status [read_status]
  disconnect
  exit 2
}

proc link_reset {} {
  global ADDR_CTRL
  set ctrl [expr {[rd $ADDR_CTRL] & 0x7}]
  wr $ADDR_CTRL [expr {$ctrl | 0x8}]
  after 100
  wr $ADDR_CTRL $ctrl
}

if { $cmd eq "" } { usage; exit 1 }

connect -url $url
after 500
if { [catch {targets -set -nocase -filter "name =~ \"PSU\" && jtag_cable_name =~ \"*${cable}*\""} msg] } {
  puts "ERROR: no Zynq UltraScale+ (PSU target) found on a cable matching '*${cable}*': $msg"
  exit 1
}

set rc 0
switch -- $cmd {
  status {
    print_status [read_status]
    puts [format "link debug  (0xA1000008) = 0x%X  (bit2:0 loopback, bit3 link reset request)" [expr {[rd $ADDR_CTRL] & 0xF}]]
  }
  mrd {
    set addr [expr {[lindex $args_ 0]}]
    set n [expr {[llength $args_] > 1 ? [lindex $args_ 1] : 1}]
    check_remote_access $addr $n
    for {set k 0} {$k < $n} {incr k} {
      set a [expr {$addr + 4*$k}]
      puts [format "%08X: %08X" $a [rd $a]]
    }
  }
  mwr {
    if { [llength $args_] < 2 } { usage; set rc 1 } else {
      set addr [expr {[lindex $args_ 0]}]
      set values [lrange $args_ 1 end]
      check_remote_access $addr [llength $values]
      set k 0
      foreach v $values {
        set a [expr {$addr + 4*$k}]
        wr $a $v
        puts [format "%08X <= %08X" $a [expr {$v}]]
        incr k
      }
    }
  }
  ddrtest {
    set addr [expr {[llength $args_] > 0 ? [lindex $args_ 0] : 0x10000000}]
    set n    [expr {[llength $args_] > 1 ? [lindex $args_ 1] : 256}]
    set data {}
    for {set k 0} {$k < $n} {incr k} {
      lappend data [format "0x%08X" [expr {(0xC2C00000 ^ ($k * 0x01010101) ^ ($k << 20)) & 0xFFFFFFFF}]]
    }
    mwr -force $addr $data
    set back [mrd -force -value $addr $n]
    set errors 0
    for {set k 0} {$k < $n} {incr k} {
      if { [lindex $back $k] != [lindex $data $k] } {
        if { $errors < 8 } {
          puts [format "  MISMATCH at 0x%08X: wrote %s read 0x%08X" [expr {$addr + 4*$k}] [lindex $data $k] [lindex $back $k]]
        }
        incr errors
      }
    }
    puts [format "ddrtest: %d words at 0x%08X, %d errors - %s" $n $addr $errors [expr {$errors ? "FAILED" : "OK"}]]
    if { $errors } { set rc 1 }
  }
  loopback {
    set mode [expr {[lindex $args_ 0] & 0x7}]
    wr $ADDR_CTRL $mode
    link_reset
    after 1500
    puts "loopback = $mode, link reset done"
    print_status [read_status]
  }
  linkreset {
    link_reset
    after 1500
    print_status [read_status]
  }
  remote {
    check_remote_access $REMOTE_BASE 1
    # Remote board (link contract): GPIO at +0x0 (ch1 LEDs, ch2 status), BRAM at +0x10000,
    # user clock frequency counter at +0x20000
    puts [format "remote axi_gpio_sys  LEDs   (0xA0000000) = 0x%08X" [rd 0xA0000000]]
    set rs [expr {[rd 0xA0000008] & 0x3FF}]
    puts "remote board status (0xA0000008):"
    print_status $rs
    puts [format "remote axi_gpio_freq       (0xA0020000) = %d Hz" [rd 0xA0020000]]
    set pattern 0xC2C0BEEF
    set old [rd 0xA0010000]
    wr 0xA0010000 $pattern
    set rb [rd 0xA0010000]
    puts [format "remote BRAM                (0xA0010000) : was 0x%08X, wrote 0x%08X, read 0x%08X - %s" \
      $old $pattern $rb [expr {$rb == $pattern ? "OK" : "FAILED"}]]
    if { $rb != $pattern } { set rc 1 }
  }
  default { puts "ERROR: unknown command: $cmd"; usage; set rc 1 }
}

disconnect
exit $rc
