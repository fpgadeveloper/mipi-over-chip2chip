# Opsero Electronic Design Inc. Copyright 2026
#
# AXI access to the "auboard" design over JTAG (JTAG to AXI master), for bring-up and test of
# the processor-less AUBoard 15P without the host.
#
# Usage (from any directory):
#
#   vivado -mode batch -nolog -nojournal -notrace -source auboard_axi.tcl -tclargs <command> [args] [options]
#
# Commands:
#   status                        report the DONE pin, decode the link status bits, print the
#                                 measured frequency of the Aurora user clock and the GT
#                                 reference clock it implies
#   rd <addr> [<count>]           read <count> 32 bit words (default 1)
#   wr <addr> <data> [<data> ...] write 32 bit words to consecutive word addresses
#   leds <value>                  write the LED GPIO (bit1..0 drive LED2..1) and read it back
#   loopback <0..7>               Aurora loopback: 0 = normal, 1 = near-end PCS, 2 = near-end PMA
#   test                          LED GPIO read-back test + pattern test of the scratch BRAM
#
# Options:
#   -url <host:port>    hw_server to connect to           (default 127.0.0.1:3121)
#   -cable <pattern>    part of the name of the JTAG cable (default 1234-oj1A)
#   -force              allow rd/wr in 0x0000_0000-0x7FFF_FFFF (the DDR of the host through the
#                       link) although the link is down. Such a transaction never completes:
#                       expect an error, and re-program the device if the master stays stuck.
#
# Numbers may be given in hex (0xA0000000) or decimal. The exit code is 0 on success.
#
# The script connects to a hw_server that is ALREADY RUNNING and only opens the JTAG target
# whose name matches the cable pattern, so other boards on the same hw_server are untouched.
#
# Address map of the design (see Vivado/src/bd/bd_fpga.tcl):
#   0xA0000000 axi_gpio_sys  +0x0 ch1 out: LEDs    +0x8 ch2 in: link status
#   0xA0010000 scratch BRAM, 8K
#   0xA0020000 axi_gpio_freq +0x0 ch1 in: user clock in Hz    +0x8 ch2 in: measurement count
#   0xA0030000 axi_gpio_dbg  +0x0 ch1 out: Aurora loopback
#   0xA0040000 axi_intc, 0xA0100000 CAM0 pipeline, 0xA0200000 CAM2 pipeline: see auboard_cam.tcl,
#              which tests them. NOTE: a video IP of a pipeline that is held in reset by the GPIO
#              of its pipeline (the power-up state) does not answer; an "rd"/"wr" to it never
#              completes and blocks the register path until the device is re-programmed.
#
#*****************************************************************************************

set ADDR_GPIO_LEDS   0xA0000000
set ADDR_GPIO_STATUS 0xA0000008
set ADDR_BRAM        0xA0010000
set BRAM_BYTES       8192
set ADDR_FREQ        0xA0020000
set ADDR_FREQ_COUNT  0xA0020008
set ADDR_LOOPBACK    0xA0030000

# Status bit names, bit 0 first (the link contract)
set STATUS_BITS {
  channel_up lane_up gt_pll_lock c2c_link_status c2c_link_error c2c_multi_bit_error
  c2c_config_error hard_err soft_err mmcm_not_locked sfp_los sfp_tx_fault
}

# Aurora 64B/66B: line rate = refclk * 66 (10.3125 Gbps from 156.25 MHz), and the user clock
# is line rate / 64, so refclk = user clock * 64 / 66
set USER_CLK_NOMINAL_HZ 161132812.5
set REFCLK_NOMINAL_HZ   156250000.0

set url   127.0.0.1:3121
set cable 1234-oj1A
set force 0
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
set command [lindex $words 0]
set cmdargs [lrange $words 1 end]

proc usage {} {
  puts "Usage: vivado -mode batch -nolog -nojournal -notrace -source auboard_axi.tcl -tclargs <command> \[args\] \[options\]"
  puts "  status | rd <addr> \[<count>\] | wr <addr> <data> \[<data> ...\] | leds <value> | loopback <0..7> | test"
  puts "  options: -url <host:port>  -cable <pattern>  -force"
}

if { $command ni {status rd wr leds loopback test} } {
  usage
  exit 1
}

#-----------------------------------------------------------------------------------------
# AXI transactions
#-----------------------------------------------------------------------------------------

proc axi_rd {addr} {
  global axi
  create_hw_axi_txn -force rd_txn $axi -type read -address [format %08X $addr] -len 1
  run_hw_axi -quiet [get_hw_axi_txns rd_txn]
  return [expr "0x[get_property DATA [get_hw_axi_txns rd_txn]]"]
}

proc axi_wr {addr data} {
  global axi
  create_hw_axi_txn -force wr_txn $axi -type write -address [format %08X $addr] -len 1 \
    -data [format %08X [expr {$data & 0xFFFFFFFF}]]
  run_hw_axi -quiet [get_hw_axi_txns wr_txn]
}

# Burst write/read of a list of 32 bit words (at most 256). The data of a burst is one hex
# string in which the FIRST beat (lowest address) is the RIGHTMOST word.
proc axi_wr_burst {addr wordlist} {
  global axi
  set data ""
  foreach w $wordlist { set data "[format %08X [expr {$w & 0xFFFFFFFF}]]$data" }
  create_hw_axi_txn -force wrb_txn $axi -type write -address [format %08X $addr] \
    -len [llength $wordlist] -data $data
  run_hw_axi -quiet [get_hw_axi_txns wrb_txn]
}

proc axi_rd_burst {addr count} {
  global axi
  create_hw_axi_txn -force rdb_txn $axi -type read -address [format %08X $addr] -len $count
  run_hw_axi -quiet [get_hw_axi_txns rdb_txn]
  set data [string map {_ {}} [get_property DATA [get_hw_axi_txns rdb_txn]]]
  set wordlist {}
  for {set i [expr {$count - 1}]} {$i >= 0} {incr i -1} {
    lappend wordlist [expr "0x[string range $data [expr {$i * 8}] [expr {$i * 8 + 7}]]"]
  }
  return $wordlist
}

proc read_status {} {
  global ADDR_GPIO_STATUS
  return [axi_rd $ADDR_GPIO_STATUS]
}

proc link_is_up {status} {
  # channel_up (bit 0) and c2c_link_status (bit 3)
  return [expr {($status & 0x9) == 0x9}]
}

# Refuse to enter the window of the link while the link is down (the transaction would hang)
proc check_window {addr count} {
  global force
  if { $addr < 0x80000000 && !$force } {
    set status [read_status]
    if { ![link_is_up $status] } {
      puts [format "ERROR: 0x%08X is in the window of the link (the DDR of the host), and the link is down (status 0x%03X)." $addr $status]
      puts "       A transaction into a link that is down never completes. Use -force to try anyway."
      return 0
    }
  }
  return 1
}

#-----------------------------------------------------------------------------------------
# Commands
#-----------------------------------------------------------------------------------------

proc cmd_status {} {
  global STATUS_BITS ADDR_GPIO_LEDS ADDR_FREQ ADDR_FREQ_COUNT ADDR_LOOPBACK
  global USER_CLK_NOMINAL_HZ REFCLK_NOMINAL_HZ device
  # DONE pin = bit 14 of the configuration status register. After a power cycle this says
  # whether the FPGA configured itself out of the configuration flash (see flash.md).
  set config_status [get_property REGISTER.CONFIG_STATUS $device]
  puts [format "CONFIG_STATUS = 0x%08X, DONE pin = %d" $config_status [expr {($config_status >> 14) & 1}]]
  set status [read_status]
  puts [format "status (0xA0000008) = 0x%03X" $status]
  set bit 0
  foreach name $STATUS_BITS {
    puts [format "  bit %2d %-20s %d" $bit $name [expr {($status >> $bit) & 1}]]
    incr bit
  }
  puts [format "link: %s" [expr {[link_is_up $status] ? "UP (Aurora channel up and AXI Chip2Chip link up)" : "DOWN"}]]
  puts [format "LED GPIO (0xA0000000) = 0x%X" [axi_rd $ADDR_GPIO_LEDS]]
  puts [format "Aurora loopback (0xA0030000) = %d" [expr {[axi_rd $ADDR_LOOPBACK] & 7}]]

  set count0 [axi_rd $ADDR_FREQ_COUNT]
  set freq   [axi_rd $ADDR_FREQ]
  puts [format "user_clk frequency (0xA0020000) = %d Hz  (measurement number %d, one per second)" $freq $count0]
  if { $freq == 0 } {
    puts "  the Aurora user clock is NOT running (no GT reference clock, or the GT is held in reset)"
  } else {
    set refclk [expr {$freq * 64.0 / 66.0}]
    puts [format "  expected %.1f Hz at 10.3125 Gbps: deviation %+.1f ppm (measured against the 300 MHz board oscillator)" \
      $USER_CLK_NOMINAL_HZ [expr {($freq - $USER_CLK_NOMINAL_HZ) / $USER_CLK_NOMINAL_HZ * 1e6}]]
    puts [format "  implied GT reference clock = user_clk * 64 / 66 = %.1f Hz (nominal %.1f Hz)" $refclk $REFCLK_NOMINAL_HZ]
  }
  return 0
}

proc cmd_rd {addr count} {
  if { ![check_window $addr $count] } { return 1 }
  for {set i 0} {$i < $count} {incr i} {
    set a [expr {$addr + 4 * $i}]
    puts [format "0x%08X: 0x%08X" $a [axi_rd $a]]
  }
  return 0
}

proc cmd_wr {addr datalist} {
  if { ![check_window $addr [llength $datalist]] } { return 1 }
  set a $addr
  foreach d $datalist {
    axi_wr $a $d
    puts [format "0x%08X <= 0x%08X" $a [expr {$d & 0xFFFFFFFF}]]
    incr a 4
  }
  return 0
}

proc cmd_leds {value} {
  global ADDR_GPIO_LEDS
  axi_wr $ADDR_GPIO_LEDS $value
  set rb [axi_rd $ADDR_GPIO_LEDS]
  puts [format "LED GPIO <= 0x%X, read back 0x%X" [expr {$value & 0xF}] $rb]
  return [expr {$rb != ($value & 0xF)}]
}

proc cmd_loopback {value} {
  global ADDR_LOOPBACK
  axi_wr $ADDR_LOOPBACK $value
  puts [format "Aurora loopback <= %d, read back %d" [expr {$value & 7}] [axi_rd $ADDR_LOOPBACK]]
  return 0
}

proc cmd_test {} {
  global ADDR_GPIO_LEDS ADDR_BRAM BRAM_BYTES
  set errors 0

  # LED GPIO: 4 bit output register, every value, read back
  set led_errors 0
  set before [axi_rd $ADDR_GPIO_LEDS]
  for {set v 0} {$v < 16} {incr v} {
    axi_wr $ADDR_GPIO_LEDS $v
    set rb [axi_rd $ADDR_GPIO_LEDS]
    if { $rb != $v } {
      puts [format "  LED GPIO: wrote 0x%X, read 0x%X" $v $rb]
      incr led_errors
    }
  }
  axi_wr $ADDR_GPIO_LEDS $before
  puts "LED GPIO read-back test: 16 values, $led_errors errors"
  incr errors $led_errors

  # BRAM: the whole memory, single beat and burst accesses
  set nwords [expr {$BRAM_BYTES / 4}]

  # 1. address-in-data with single beat writes on a sparse set (every address bit), burst read
  set single_errors 0
  set probes {0}
  for {set b 2} {(1 << $b) < $BRAM_BYTES} {incr b} { lappend probes [expr {1 << $b}] }
  lappend probes [expr {$BRAM_BYTES - 4}]
  foreach off $probes { axi_wr [expr {$ADDR_BRAM + $off}] [expr {0xC2C00000 | $off}] }
  foreach off $probes {
    set rb [axi_rd [expr {$ADDR_BRAM + $off}]]
    if { $rb != (0xC2C00000 | $off) } {
      puts [format "  BRAM +0x%04X: wrote 0x%08X, read 0x%08X" $off [expr {0xC2C00000 | $off}] $rb]
      incr single_errors
    }
  }
  puts "BRAM single beat test: [llength $probes] words (one per address bit), $single_errors errors"
  incr errors $single_errors

  # 2. the whole memory with 256 beat bursts: pseudo random data, then its complement
  foreach pass {0 1} {
    set burst_errors 0
    set seed 0x1234ABCD
    set expected {}
    for {set i 0} {$i < $nwords} {incr i} {
      # 32 bit xorshift
      set seed [expr {($seed ^ ($seed << 13)) & 0xFFFFFFFF}]
      set seed [expr {$seed ^ ($seed >> 17)}]
      set seed [expr {($seed ^ ($seed << 5)) & 0xFFFFFFFF}]
      lappend expected [expr {$pass ? ($seed ^ 0xFFFFFFFF) : $seed}]
    }
    for {set i 0} {$i < $nwords} {incr i 256} {
      axi_wr_burst [expr {$ADDR_BRAM + 4 * $i}] [lrange $expected $i [expr {$i + 255}]]
    }
    set readback {}
    for {set i 0} {$i < $nwords} {incr i 256} {
      set readback [concat $readback [axi_rd_burst [expr {$ADDR_BRAM + 4 * $i}] 256]]
    }
    for {set i 0} {$i < $nwords} {incr i} {
      if { [lindex $readback $i] != [lindex $expected $i] } {
        if { $burst_errors < 8 } {
          puts [format "  BRAM +0x%04X: wrote 0x%08X, read 0x%08X" [expr {4 * $i}] [lindex $expected $i] [lindex $readback $i]]
        }
        incr burst_errors
      }
    }
    # The order of the words in a burst is checked with a single beat read of the first word
    set first [axi_rd $ADDR_BRAM]
    if { $first != [lindex $expected 0] } {
      puts [format "  BRAM +0x0000: burst wrote 0x%08X, single beat read 0x%08X" [lindex $expected 0] $first]
      incr burst_errors
    }
    puts "BRAM burst test pass [expr {$pass + 1}] ([expr {$pass ? "inverted" : "pseudo random"}] data): $nwords words, $burst_errors errors"
    incr errors $burst_errors
  }

  puts [expr {$errors == 0 ? "TEST PASSED" : "TEST FAILED: $errors errors"}]
  return [expr {$errors != 0}]
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

set axi [lindex [get_hw_axis -quiet] 0]
if { $axi eq "" } {
  puts "ERROR: no JTAG to AXI master found in the device. Is the auboard bitstream loaded"
  puts "       (scripts/jtag/auboard_prog.tcl), and is its 100 MHz clock running?"
  close_hw_target
  disconnect_hw_server
  exit 1
}
reset_hw_axi $axi

#-----------------------------------------------------------------------------------------
# Run the command
#-----------------------------------------------------------------------------------------

set rc 1
if {[catch {
  switch -- $command {
    status   { set rc [cmd_status] }
    rd       {
      if { [llength $cmdargs] < 1 } { usage } else {
        set count [expr {[llength $cmdargs] > 1 ? [lindex $cmdargs 1] : 1}]
        set rc [cmd_rd [expr {[lindex $cmdargs 0]}] [expr {$count}]]
      }
    }
    wr       {
      if { [llength $cmdargs] < 2 } { usage } else {
        set datalist {}
        foreach d [lrange $cmdargs 1 end] { lappend datalist [expr {$d}] }
        set rc [cmd_wr [expr {[lindex $cmdargs 0]}] $datalist]
      }
    }
    leds     { if { [llength $cmdargs] < 1 } { usage } else { set rc [cmd_leds [expr {[lindex $cmdargs 0]}]] } }
    loopback { if { [llength $cmdargs] < 1 } { usage } else { set rc [cmd_loopback [expr {[lindex $cmdargs 0]}]] } }
    test     { set rc [cmd_test] }
  }
} errmsg]} {
  puts "ERROR: AXI transaction failed: $errmsg"
  puts "       If the JTAG to AXI master stays stuck (a transaction into a link that is down"
  puts "       never completes), re-program the device with scripts/jtag/auboard_prog.tcl."
  catch { reset_hw_axi $axi }
  set rc 1
}

close_hw_target
disconnect_hw_server
exit $rc
