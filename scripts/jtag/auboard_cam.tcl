# Opsero Electronic Design Inc. Copyright 2026
#
# Bring-up and test of the video pipelines of the "auboard" design over JTAG (JTAG to AXI
# master), without the host: register map, sensor I2C, MIPI CSI-2 reception.
#
# Usage (from any directory):
#
#   vivado -mode batch -nolog -nojournal -notrace -source auboard_cam.tcl -tclargs <command> [args] [options]
#
# Commands:
#   regs                 read an identifying/status register of every IP of both pipelines and of
#                        the interrupt controller (releases the resets of the video IP first, and
#                        restores the GPIOs afterwards)
#   camid <0|2>          enable the camera and read the chip ID of the IMX219 over I2C
#   stream <0|2>         program the IMX219 (1920x1080, 2 lanes, RAW10: the register table of the
#                        rpi-camera-fmc reference application), start streaming and sample the
#                        status registers of the MIPI CSI-2 RX subsystem. Also starts the demosaic
#                        and gamma LUT IP. The scaler is NOT configured, so the video stream
#                        stops in front of it after a few lines, the line buffer of the CSI-2
#                        RX fills ("stream line buffer full") and its counters stop. Every
#                        sample therefore restarts the demosaic and gamma LUT IP, which lets up
#                        to two frames through, and checks those (see csi_monitor). Continuous
#                        flow through the whole pipeline is not tested.
#   csi <0|2>            the samples of "stream" only (the sensor must already be streaming;
#                        restarts the demosaic and gamma LUT IP)
#   stop <0|2>           stop streaming (IMX219 standby) and put the pipeline back into its
#                        power-up state (GPIO = 0x1: camera enabled, video IP in reset)
#   irq <0|2>            check the path of the interrupts into the interrupt controller
#   i2cscan <0|2>        scan the I2C bus of the camera for devices (the Raspberry Pi camera v2
#                        has the IMX219 at 0x10 and a crypto chip at 0x64), with the camera
#                        enable pin high and low
#   i2crd <0|2> <reg> [<count>]      read IMX219 registers
#   i2cwr <0|2> <reg> <value>        write an IMX219 register
#
# Options:
#   -url <host:port>    hw_server to connect to           (default 127.0.0.1:3121)
#   -cable <pattern>    part of the name of the JTAG cable (default 1234-oj1A)
#   -samples <n>        number of status samples of stream/csi (default 5, one per second)
#
# The script connects to a hw_server that is ALREADY RUNNING and only opens the JTAG target
# whose name matches the cable pattern, so other boards on the same hw_server are untouched.
#
# IMPORTANT: a video IP (demosaic, gamma LUT, scaler, frame buffer write) whose reset bit in
# the GPIO of its pipeline is 0 does not answer on AXI4-Lite. An access to it never completes
# and blocks the register path of the design, for the host as well; only re-programming the
# device recovers it. The commands of this script release the reset before they touch an IP.
#
# Address map (see Vivado/src/bd/bd_fpga.tcl), CAM0 at 0xA0100000, CAM2 at 0xA0200000:
#   +0x00000 MIPI CSI-2 RX subsystem    +0x30000 v_demosaic     +0x80000 v_proc_ss: h scaler
#   +0x10000 AXI IIC                    +0x40000 v_gamma_lut    +0x90000   reset GPIO
#   +0x20000 AXI GPIO                   +0x50000 v_frmbuf_wr    +0xA0000   v scaler
#   0xA0040000 AXI INTC
#
#*****************************************************************************************

array set CAM_BASE {0 0xA0100000 2 0xA0200000}
set OFF_CSI      0x00000
set OFF_IIC      0x10000
set OFF_GPIO     0x20000
set OFF_DEMOSAIC 0x30000
set OFF_GAMMA    0x40000
set OFF_FRMBUF   0x50000
set OFF_VPSS_HSC 0x80000
set OFF_VPSS_RST 0x90000
set OFF_VPSS_VSC 0xA0000
set ADDR_INTC    0xA0040000

# Inputs of the interrupt controller
array set INTC_BIT {0,csi 0 0,frmbuf 1 0,iic 2 2,csi 3 2,frmbuf 4 2,iic 5 0,demosaic 6 0,gamma 7 2,demosaic 8 2,gamma 9}

# GPIO of a pipeline
set GPIO_CAM_IO0      0x01
set GPIO_RST_DEMOSAIC 0x04
set GPIO_RST_VPROC    0x08
set GPIO_RST_GAMMA    0x10
set GPIO_RST_FRMBUFWR 0x40
set GPIO_RST_ALL      0x5C

# IMX219
set IMX219_I2C_ADDR 0x10
# Register table of the reference application (rpi-camera-fmc, Vitis/common/src/imx219.c):
# 1920x1080, 2 lanes, RAW10, frame length 1113, line length 3448 (about 47.5 frames/s).
# The last entry (0x0100 = 1) starts streaming.
set IMX219_CFG {
  0x30EB 0x05  0x30EB 0x0C  0x300A 0xFF  0x300B 0xFF  0x30EB 0x05  0x30EB 0x09
  0x0114 0x01  0x0128 0x00  0x012A 0x18  0x012B 0x00
  0x0160 0x04  0x0161 0x59  0x0162 0x0D  0x0163 0x78
  0x0164 0x02  0x0165 0xA8  0x0166 0x0A  0x0167 0x27
  0x0168 0x02  0x0169 0xB4  0x016A 0x06  0x016B 0xEB
  0x016C 0x07  0x016D 0x80  0x016E 0x04  0x016F 0x38
  0x0170 0x01  0x0171 0x01  0x0174 0x00  0x0175 0x00
  0x018C 0x0A  0x018D 0x0A
  0x0301 0x05  0x0303 0x01  0x0304 0x03  0x0305 0x03  0x0306 0x00  0x0307 0x39
  0x0309 0x0A  0x030B 0x01  0x030C 0x00  0x030D 0x72
  0x455E 0x00  0x471E 0x4B  0x4767 0x0F  0x4750 0x14  0x4540 0x00  0x47B4 0x14
  0x4713 0x30  0x478B 0x10  0x478F 0x10  0x4793 0x10  0x4797 0x0E  0x479B 0x0E
  0x0100 0x01
}
set IMX219_WIDTH  1920
set IMX219_HEIGHT 1080

set url     127.0.0.1:3121
set cable   1234-oj1A
set samples 5
set words {}
for {set i 0} {$i < [llength $argv]} {incr i} {
  set arg [lindex $argv $i]
  switch -- $arg {
    -url     { incr i; set url     [lindex $argv $i] }
    -cable   { incr i; set cable   [lindex $argv $i] }
    -samples { incr i; set samples [lindex $argv $i] }
    default  { lappend words $arg }
  }
}
set command [lindex $words 0]
set cmdargs [lrange $words 1 end]

proc usage {} {
  puts "Usage: vivado -mode batch -nolog -nojournal -notrace -source auboard_cam.tcl -tclargs <command> \[args\] \[options\]"
  puts "  regs | camid <0|2> | stream <0|2> | csi <0|2> | stop <0|2> | irq <0|2> | i2cscan <0|2> | i2crd <0|2> <reg> \[<count>\] | i2cwr <0|2> <reg> <value>"
  puts "  options: -url <host:port>  -cable <pattern>  -samples <n>"
}

if { $command ni {regs camid stream csi stop irq i2cscan i2crd i2cwr} } {
  usage
  exit 1
}
if { $command ne "regs" } {
  set cam [lindex $cmdargs 0]
  if { ![info exists CAM_BASE($cam)] } {
    puts "ERROR: camera must be 0 or 2"
    usage
    exit 1
  }
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

proc show {name addr} {
  set v [axi_rd $addr]
  puts [format "  %-34s 0x%08X = 0x%08X" $name $addr $v]
  return $v
}

proc msleep {ms} { after $ms }

proc cam_addr {cam off} {
  global CAM_BASE
  return [expr {$CAM_BASE($cam) + $off}]
}

#-----------------------------------------------------------------------------------------
# GPIO of a pipeline
#-----------------------------------------------------------------------------------------

proc gpio_rd {cam} {
  global OFF_GPIO
  return [axi_rd [cam_addr $cam $OFF_GPIO]]
}
proc gpio_wr {cam value} {
  global OFF_GPIO
  # GPIO_TRI: all outputs (the IP is configured "all outputs", the write is harmless)
  axi_wr [cam_addr $cam $OFF_GPIO] $value
}
proc gpio_set {cam mask} { gpio_wr $cam [expr {[gpio_rd $cam] | $mask}] }
proc gpio_clr {cam mask} { gpio_wr $cam [expr {[gpio_rd $cam] & ~$mask}] }

#-----------------------------------------------------------------------------------------
# AXI IIC, register level, dynamic controller logic (PG090)
#-----------------------------------------------------------------------------------------

set IIC_GIE   0x01C
set IIC_ISR   0x020
set IIC_IER   0x028
set IIC_SOFTR 0x040
set IIC_CR    0x100
set IIC_SR    0x104
set IIC_TX    0x108
set IIC_RX    0x10C
set IIC_TXOCY 0x114
set IIC_RXOCY 0x118
set IIC_PIRQ  0x120

# SR bits
set IIC_SR_BB       0x04
set IIC_SR_RX_EMPTY 0x40
set IIC_SR_TX_EMPTY 0x80
# ISR bits
set IIC_ISR_ARB_LOST 0x01
set IIC_ISR_TX_ERR   0x02

proc iic_reg {cam off} {
  global OFF_IIC
  return [cam_addr $cam [expr {$OFF_IIC + $off}]]
}

proc iic_init {cam} {
  global IIC_SOFTR IIC_PIRQ IIC_CR IIC_ISR
  axi_wr [iic_reg $cam $IIC_SOFTR] 0xA
  axi_wr [iic_reg $cam $IIC_PIRQ] 0x0F
  axi_wr [iic_reg $cam $IIC_CR] 0x02
  axi_wr [iic_reg $cam $IIC_CR] 0x01
  # the interrupt status register toggles the bits that are written as 1
  axi_wr [iic_reg $cam $IIC_ISR] [axi_rd [iic_reg $cam $IIC_ISR]]
}

# Wait until (SR & mask) == value. Returns the last SR, or -1 after a timeout.
proc iic_wait_sr {cam mask value {tries 100}} {
  global IIC_SR
  for {set i 0} {$i < $tries} {incr i} {
    set sr [axi_rd [iic_reg $cam $IIC_SR]]
    if { ($sr & $mask) == $value } { return $sr }
    msleep 2
  }
  return -1
}

# End of a WRITE transaction: waits until the TX FIFO has drained and the bus is free.
# Returns "" or an error text. A slave that does not acknowledge (its address or a data byte)
# raises the "transmit error" interrupt; the rest of the TX FIFO is then never sent, so the
# core is reset to empty it.
proc iic_write_done {cam} {
  global IIC_ISR IIC_SR IIC_SR_BB IIC_SR_TX_EMPTY IIC_ISR_TX_ERR IIC_ISR_ARB_LOST
  set err "timeout"
  for {set i 0} {$i < 100} {incr i} {
    set isr [axi_rd [iic_reg $cam $IIC_ISR]]
    if { $isr & $IIC_ISR_ARB_LOST } { set err "arbitration lost"; break }
    if { $isr & $IIC_ISR_TX_ERR }   { set err "no acknowledge (NACK)"; break }
    set sr [axi_rd [iic_reg $cam $IIC_SR]]
    if { ($sr & ($IIC_SR_BB | $IIC_SR_TX_EMPTY)) == $IIC_SR_TX_EMPTY } { set err ""; break }
    msleep 2
  }
  if { $err ne "" } {
    set err [format "%s \[SR = 0x%02X, ISR = 0x%02X\]" $err [axi_rd [iic_reg $cam $IIC_SR]] [axi_rd [iic_reg $cam $IIC_ISR]]]
    iic_init $cam
  }
  return $err
}

# Start of a transaction: the bus must be free and the TX FIFO empty
proc iic_begin {cam} {
  global IIC_ISR IIC_SR_BB IIC_SR_TX_EMPTY
  if { [iic_wait_sr $cam [expr {$IIC_SR_BB | $IIC_SR_TX_EMPTY}] $IIC_SR_TX_EMPTY 20] < 0 } {
    iic_init $cam
  }
  axi_wr [iic_reg $cam $IIC_ISR] [axi_rd [iic_reg $cam $IIC_ISR]]
}

# Write <bytes> to the 7 bit address <dev>
proc iic_write {cam dev bytes} {
  global IIC_TX
  iic_begin $cam
  axi_wr [iic_reg $cam $IIC_TX] [expr {0x100 | ($dev << 1)}]
  set n [llength $bytes]
  for {set i 0} {$i < $n} {incr i} {
    set b [expr {[lindex $bytes $i] & 0xFF}]
    if { $i == $n - 1 } { set b [expr {$b | 0x200}] }
    axi_wr [iic_reg $cam $IIC_TX] $b
  }
  set err [iic_write_done $cam]
  if { $err ne "" } { error "I2C write to 0x[format %02X $dev] failed: $err" }
}

# Write <bytes> (the register address), repeated start, read <count> bytes.
# NOTE: the AXI IIC raises its "transmit error" interrupt at the END of every master read as
# well (the master does not acknowledge the last byte), so that flag only means "NACK" while
# the RX FIFO stays empty.
proc iic_write_read {cam dev bytes count} {
  global IIC_TX IIC_RX IIC_ISR IIC_SR IIC_SR_BB IIC_SR_RX_EMPTY IIC_ISR_TX_ERR IIC_ISR_ARB_LOST
  iic_begin $cam
  axi_wr [iic_reg $cam $IIC_TX] [expr {0x100 | ($dev << 1)}]
  foreach b $bytes {
    axi_wr [iic_reg $cam $IIC_TX] [expr {$b & 0xFF}]
  }
  axi_wr [iic_reg $cam $IIC_TX] [expr {0x100 | ($dev << 1) | 1}]
  axi_wr [iic_reg $cam $IIC_TX] [expr {0x200 | $count}]
  set data {}
  set err ""
  for {set i 0} {$i < 200 && [llength $data] < $count} {incr i} {
    if { !([axi_rd [iic_reg $cam $IIC_SR]] & $IIC_SR_RX_EMPTY) } {
      lappend data [expr {[axi_rd [iic_reg $cam $IIC_RX]] & 0xFF}]
      continue
    }
    set isr [axi_rd [iic_reg $cam $IIC_ISR]]
    if { $isr & $IIC_ISR_ARB_LOST } { set err "arbitration lost"; break }
    # a transmit error with an RX FIFO that is (still) empty: nobody acknowledged
    if { ($isr & $IIC_ISR_TX_ERR) && ([axi_rd [iic_reg $cam $IIC_SR]] & $IIC_SR_RX_EMPTY) } {
      set err "no acknowledge (NACK)"; break
    }
    msleep 2
  }
  if { $err eq "" && [llength $data] < $count } { set err "timeout" }
  if { $err ne "" } {
    set err [format "%s after %d of %d bytes \[SR = 0x%02X, ISR = 0x%02X\]" $err [llength $data] $count \
      [axi_rd [iic_reg $cam $IIC_SR]] [axi_rd [iic_reg $cam $IIC_ISR]]]
    iic_init $cam
    error "I2C read from 0x[format %02X $dev] failed: $err"
  }
  # wait for the stop condition, then drop the (expected) transmit error flag
  iic_wait_sr $cam $IIC_SR_BB 0 50
  axi_wr [iic_reg $cam $IIC_ISR] [axi_rd [iic_reg $cam $IIC_ISR]]
  return $data
}

proc imx219_wr {cam reg value} {
  global IMX219_I2C_ADDR
  iic_write $cam $IMX219_I2C_ADDR [list [expr {($reg >> 8) & 0xFF}] [expr {$reg & 0xFF}] $value]
}
proc imx219_rd {cam reg {count 1}} {
  global IMX219_I2C_ADDR
  return [iic_write_read $cam $IMX219_I2C_ADDR [list [expr {($reg >> 8) & 0xFF}] [expr {$reg & 0xFF}]] $count]
}

# Power cycle of the camera with its enable pin, as the reference application does
proc cam_power_cycle {cam} {
  global GPIO_CAM_IO0
  gpio_clr $cam $GPIO_CAM_IO0
  msleep 100
  gpio_set $cam $GPIO_CAM_IO0
  msleep 100
}

#-----------------------------------------------------------------------------------------
# MIPI CSI-2 RX subsystem (PG232)
#-----------------------------------------------------------------------------------------

set CSI_ISR_BITS {
  31 frame_received 30 vcx_frame_error 29 rx_skewcalhs 28 yuv420_line_error 22 word_count_corruption
  21 incorrect_lane_config 20 short_packet_fifo_full 19 short_packet_fifo_not_empty
  18 stream_line_buffer_full 17 stop_state 13 sot_error 12 sot_sync_error 11 ecc_2bit_error
  10 ecc_1bit_error 9 crc_error 8 unsupported_data_type 7 vc3_frame_sync_error 6 vc3_frame_level_error
  5 vc2_frame_sync_error 4 vc2_frame_level_error 3 vc1_frame_sync_error 2 vc1_frame_level_error
  1 vc0_frame_sync_error 0 vc0_frame_level_error
}
# SoT, ECC, CRC, data type, word count, lane configuration, frame errors
set CSI_ISR_ERROR_MASK 0x50603FFF

proc csi_isr_names {isr} {
  global CSI_ISR_BITS
  set names {}
  foreach {bit name} $CSI_ISR_BITS {
    if { ($isr >> $bit) & 1 } { lappend names $name }
  }
  return $names
}

proc csi_sample {cam} {
  global OFF_CSI
  set base [cam_addr $cam $OFF_CSI]
  set status [axi_rd [expr {$base + 0x10}]]
  set isr    [axi_rd [expr {$base + 0x24}]]
  set clk    [axi_rd [expr {$base + 0x3C}]]
  set l0     [axi_rd [expr {$base + 0x40}]]
  set l1     [axi_rd [expr {$base + 0x44}]]
  set img1   [axi_rd [expr {$base + 0x60}]]
  set img2   [axi_rd [expr {$base + 0x64}]]
  return [list $status $isr $clk $l0 $l1 $img1 $img2]
}

proc csi_print_sample {n s} {
  lassign $s status isr clk l0 l1 img1 img2
  puts [format "  #%s status 0x%08X (packets %5d%s%s) ISR 0x%08X clk 0x%X lane0 0x%02X lane1 0x%02X img1 0x%08X (lines %d, bytes/line %d) img2 0x%02X (data type 0x%02X)" \
    $n $status [expr {($status >> 16) & 0xFFFF}] \
    [expr {($status & 0x8) ? ", line buffer full" : ""}] [expr {($status & 0x1) ? ", reset in progress" : ""}] \
    $isr $clk $l0 $l1 $img1 [expr {($img1 >> 16) & 0xFFFF}] [expr {$img1 & 0xFFFF}] $img2 [expr {$img2 & 0x3F}]]
  puts "     ISR: [csi_isr_names $isr]"
}

# Demosaic and gamma LUT as the reference application sets them up (their registers are
# cleared by their reset): size of the sensor mode, Bayer phase RGGB, start + auto restart
proc start_demosaic_gamma {cam} {
  global OFF_DEMOSAIC OFF_GAMMA IMX219_WIDTH IMX219_HEIGHT
  set base [cam_addr $cam $OFF_DEMOSAIC]
  axi_wr [expr {$base + 0x10}] $IMX219_WIDTH
  axi_wr [expr {$base + 0x18}] $IMX219_HEIGHT
  axi_wr [expr {$base + 0x28}] 0
  axi_wr [expr {$base + 0x00}] 0x81
  set base [cam_addr $cam $OFF_GAMMA]
  axi_wr [expr {$base + 0x10}] $IMX219_WIDTH
  axi_wr [expr {$base + 0x18}] $IMX219_HEIGHT
  axi_wr [expr {$base + 0x20}] 0
  axi_wr [expr {$base + 0x00}] 0x81
}

# Empties the video IP behind the CSI-2 RX subsystem: reset pulse on demosaic and gamma LUT,
# then start them again
proc flush_downstream {cam} {
  global GPIO_RST_DEMOSAIC GPIO_RST_GAMMA
  gpio_clr $cam [expr {$GPIO_RST_DEMOSAIC | $GPIO_RST_GAMMA}]
  msleep 20
  gpio_set $cam [expr {$GPIO_RST_DEMOSAIC | $GPIO_RST_GAMMA}]
  msleep 20
  start_demosaic_gamma $cam
}

# Checks the reception of the CSI-2 RX subsystem while the sensor streams.
#
# In this design the video stream can only flow continuously while the whole pipeline runs,
# down to the frame buffer writer and the DDR of the host. Standalone (scaler not configured)
# the pipeline fills up after a few lines, the line buffer of the CSI-2 RX core reports "full"
# and its packet and line counters STOP although the sensor keeps sending: a counter that
# stands still says nothing about the link. (A soft reset of the CSI-2 RX core does not help,
# the blockage is behind it: measured, the counters then stay at 0.)
#
# What does make room is a restart of the demosaic and gamma LUT IP: a video IP that starts
# discards its input up to the next start of frame, so the CSI-2 RX core passes the rest of
# the current frame (and sometimes one more frame) at the full rate of the sensor before the
# pipeline is full again. How many packets that is depends on where in the frame the restart
# happens: anything from a few lines to about two frames (measured: 395 .. 2461). Every sample
# does such a restart and then checks
#   * that the packet counter advanced at all (the control below shows 0 without a restart),
#   * the data type and the word count of the last long packet,
#   * that no protocol error bit is set (SoT, ECC, CRC, data type, word count, lane
#     configuration, frame sync/level). "Stream line buffer full" is expected and not counted.
# and all samples together must have seen at least one frame of lines (<min_total> packets).
# The first sample is a control without a restart: its packet delta shows whether the
# pipeline is stalled (0) or flowing.
proc csi_monitor {cam {exp_dt 0x2B} {exp_wc 2400} {min_total 1080}} {
  global OFF_CSI samples CSI_ISR_ERROR_MASK
  set base [cam_addr $cam $OFF_CSI]
  puts [format "CAM%d MIPI CSI-2 RX subsystem at 0x%08X" $cam $base]
  show "core configuration (0x00)" [expr {$base + 0x00}]
  show "protocol configuration (0x04)" [expr {$base + 0x04}]

  set p0 [expr {([axi_rd [expr {$base + 0x10}]] >> 16) & 0xFFFF}]
  axi_wr [expr {$base + 0x24}] 0xFFFFFFFF
  msleep 1000
  set s [csi_sample $cam]
  csi_print_sample control $s
  set p1 [expr {([lindex $s 0] >> 16) & 0xFFFF}]
  puts [format "     control (1 s, nothing restarted): packet counter advanced by %d" [expr {($p1 - $p0) & 0xFFFF}]]

  set good 0
  set errors 0
  set total 0
  for {set n 0} {$n < $samples} {incr n} {
    set p0 [expr {([axi_rd [expr {$base + 0x10}]] >> 16) & 0xFFFF}]
    axi_wr [expr {$base + 0x24}] 0xFFFFFFFF
    flush_downstream $cam
    msleep 300
    set s [csi_sample $cam]
    csi_print_sample $n $s
    lassign $s status isr clk l0 l1 img1 img2
    set delta [expr {((($status >> 16) & 0xFFFF) - $p0) & 0xFFFF}]
    incr total $delta
    puts "     packet counter advanced by $delta"
    set ok 1
    if { $delta == 0 } { set ok 0; puts "     -> no packet arrived" }
    if { ($img2 & 0x3F) != $exp_dt } { set ok 0; puts [format "     -> data type is not 0x%02X" $exp_dt] }
    if { ($img1 & 0xFFFF) != $exp_wc } { set ok 0; puts "     -> word count is not $exp_wc" }
    if { $isr & $CSI_ISR_ERROR_MASK } { set ok 0; incr errors; puts "     -> protocol error bits set" }
    if { $ok } { incr good }
  }
  puts [format "  good samples: %d of %d; packets received in the samples: %d (at least %d wanted); samples with protocol error bits: %d" $good $samples $total $min_total $errors]
  return [expr {($good == $samples && $total >= $min_total) ? 0 : 1}]
}

#-----------------------------------------------------------------------------------------
# Commands
#-----------------------------------------------------------------------------------------

proc cmd_regs {} {
  global ADDR_INTC OFF_CSI OFF_IIC OFF_GPIO OFF_DEMOSAIC OFF_GAMMA OFF_FRMBUF OFF_VPSS_HSC OFF_VPSS_RST OFF_VPSS_VSC
  global GPIO_RST_ALL
  set errors 0

  puts "AXI INTC at [format 0x%08X $ADDR_INTC]"
  show "ISR (0x00)" [expr {$ADDR_INTC + 0x00}]
  show "IPR (0x04)" [expr {$ADDR_INTC + 0x04}]
  set ier [show "IER (0x08)" [expr {$ADDR_INTC + 0x08}]]
  show "MER (0x1C)" [expr {$ADDR_INTC + 0x1C}]
  # IER has one bit per interrupt input: all ones reads back the number of inputs
  axi_wr [expr {$ADDR_INTC + 0x08}] 0xFFFFFFFF
  set rb [show "IER after writing 0xFFFFFFFF" [expr {$ADDR_INTC + 0x08}]]
  axi_wr [expr {$ADDR_INTC + 0x08}] $ier
  if { $rb != 0x3FF } { puts "  ERROR: expected 0x000003FF (10 interrupt inputs)"; incr errors }

  foreach cam {0 2} {
    puts "CAM$cam pipeline at [format 0x%08X [cam_addr $cam 0]]"
    set gpio0 [show "GPIO data" [cam_addr $cam $OFF_GPIO]]

    set base [cam_addr $cam $OFF_CSI]
    set v [show "CSI core configuration (0x00)" [expr {$base + 0x00}]]
    set v [show "CSI protocol configuration (0x04)" [expr {$base + 0x04}]]
    if { (($v >> 3) & 3) != 1 } { puts "  ERROR: expected maximum lanes = 2 (bits 4:3 = 1)"; incr errors }
    show "CSI core status (0x10)" [expr {$base + 0x10}]
    show "CSI global interrupt enable (0x20)" [expr {$base + 0x20}]
    show "CSI ISR (0x24)" [expr {$base + 0x24}]
    show "CSI IER (0x28)" [expr {$base + 0x28}]
    show "CSI clock lane info (0x3C)" [expr {$base + 0x3C}]
    show "CSI lane 0 info (0x40)" [expr {$base + 0x40}]
    show "CSI lane 1 info (0x44)" [expr {$base + 0x44}]

    set base [cam_addr $cam $OFF_IIC]
    show "IIC CR (0x100)" [expr {$base + 0x100}]
    set v [show "IIC SR (0x104)" [expr {$base + 0x104}]]
    if { ($v & 0xC0) != 0xC0 } { puts "  ERROR: expected RX and TX FIFO empty (0xC0)"; incr errors }
    show "IIC ISR (0x020)" [expr {$base + 0x020}]
    set v [show "IIC RX_FIFO_PIRQ (0x120)" [expr {$base + 0x120}]]
    show "IIC TSUSTA (0x128)" [expr {$base + 0x128}]

    # The video IP answer only when they are out of reset
    gpio_wr $cam [expr {$gpio0 | $GPIO_RST_ALL}]
    msleep 10
    show "GPIO data, resets released" [cam_addr $cam $OFF_GPIO]

    foreach {name off} [list demosaic $OFF_DEMOSAIC gamma_lut $OFF_GAMMA frmbuf_wr $OFF_FRMBUF] {
      set base [cam_addr $cam $off]
      set v [show "$name ap_ctrl (0x00)" $base]
      if { ($v & 0x4) == 0 } { puts "  ERROR: expected ap_idle (bit 2)"; incr errors }
      # width register: write, read back, restore
      set w [axi_rd [expr {$base + 0x10}]]
      axi_wr [expr {$base + 0x10}] 1920
      set rb [show "$name width (0x10) after writing 1920" [expr {$base + 0x10}]]
      axi_wr [expr {$base + 0x10}] $w
      if { $rb != 1920 } { puts "  ERROR: read back $rb"; incr errors }
    }
    show "frmbuf_wr video format (0x28)" [cam_addr $cam [expr {$OFF_FRMBUF + 0x28}]]

    # Scaler: its two HLS IP are behind a reset GPIO inside the subsystem (bit 1)
    set vrst [show "v_proc reset GPIO (+0x10000)" [cam_addr $cam $OFF_VPSS_RST]]
    axi_wr [cam_addr $cam $OFF_VPSS_RST] 0x3
    msleep 10
    show "v_proc reset GPIO after writing 3" [cam_addr $cam $OFF_VPSS_RST]
    foreach {name off} [list "v_proc h scaler" $OFF_VPSS_HSC "v_proc v scaler" $OFF_VPSS_VSC] {
      set v [show "$name ap_ctrl (0x00)" [cam_addr $cam $off]]
      if { ($v & 0x4) == 0 } { puts "  ERROR: expected ap_idle (bit 2)"; incr errors }
    }
    axi_wr [cam_addr $cam $OFF_VPSS_RST] $vrst

    # back to where the GPIO was
    gpio_wr $cam $gpio0
    show "GPIO data, restored" [cam_addr $cam $OFF_GPIO]
  }
  puts [expr {$errors == 0 ? "REGS PASSED" : "REGS FAILED: $errors errors"}]
  return [expr {$errors != 0}]
}

proc cmd_camid {cam} {
  global GPIO_CAM_IO0 OFF_GPIO
  puts "CAM$cam: GPIO = [format 0x%02X [gpio_rd $cam]]"
  cam_power_cycle $cam
  puts "CAM$cam: camera enabled (IO0 = 1), GPIO = [format 0x%02X [gpio_rd $cam]]"
  iic_init $cam
  set id [imx219_rd $cam 0x0000 2]
  puts [format "CAM%d: IMX219 model ID registers 0x0000/0x0001 = 0x%02X 0x%02X" $cam [lindex $id 0] [lindex $id 1]]
  if { [lindex $id 0] == 0x02 && [lindex $id 1] == 0x19 } {
    puts "CAMID PASSED: IMX219 found at I2C address 0x10"
    return 0
  }
  puts "CAMID FAILED: expected 0x02 0x19"
  return 1
}

proc cmd_stream {cam} {
  global IMX219_CFG IMX219_WIDTH IMX219_HEIGHT OFF_CSI OFF_DEMOSAIC OFF_GAMMA
  global GPIO_RST_DEMOSAIC GPIO_RST_GAMMA

  # Demosaic and gamma LUT, as the reference application sets them up. The scaler stays in
  # reset, so the stream ends in front of it.
  gpio_set $cam [expr {$GPIO_RST_DEMOSAIC | $GPIO_RST_GAMMA}]
  msleep 10
  start_demosaic_gamma $cam
  puts [format "CAM%d: demosaic ap_ctrl = 0x%02X, gamma LUT ap_ctrl = 0x%02X (0x81 = started, auto restart)" $cam \
    [axi_rd [cam_addr $cam $OFF_DEMOSAIC]] [axi_rd [cam_addr $cam $OFF_GAMMA]]]

  # Sensor: power cycle, standby, register table (its last entry starts streaming), gain
  cam_power_cycle $cam
  iic_init $cam
  set id [imx219_rd $cam 0x0000 2]
  puts [format "CAM%d: IMX219 model ID = 0x%02X 0x%02X" $cam [lindex $id 0] [lindex $id 1]]
  if { [lindex $id 0] != 0x02 || [lindex $id 1] != 0x19 } {
    puts "STREAM FAILED: no IMX219"
    return 1
  }
  # a soft reset of the CSI-2 RX controller clears its packet counter
  set base [cam_addr $cam $OFF_CSI]
  axi_wr [expr {$base + 0x00}] 0x3
  axi_wr [expr {$base + 0x00}] 0x1
  imx219_wr $cam 0x0100 0x00
  msleep 1
  set n 0
  foreach {reg value} $IMX219_CFG {
    imx219_wr $cam $reg $value
    incr n
  }
  imx219_wr $cam 0x0157 232
  puts "CAM$cam: IMX219 programmed ($n registers + gain), streaming"
  set rb [imx219_rd $cam 0x0100 1]
  set fc [imx219_rd $cam 0x0018 1]
  puts [format "CAM%d: IMX219 mode select 0x0100 = 0x%02X, frame count 0x0018 = 0x%02X" $cam [lindex $rb 0] [lindex $fc 0]]

  set rc [csi_monitor $cam]
  puts [format "CAM%d: demosaic ap_ctrl = 0x%02X, gamma LUT ap_ctrl = 0x%02X" $cam \
    [axi_rd [cam_addr $cam $OFF_DEMOSAIC]] [axi_rd [cam_addr $cam $OFF_GAMMA]]]
  set fc2 [imx219_rd $cam 0x0018 1]
  puts [format "CAM%d: IMX219 frame count 0x0018 = 0x%02X (was 0x%02X before the samples)" $cam [lindex $fc2 0] [lindex $fc 0]]
  puts [expr {$rc == 0 ? "STREAM PASSED: RAW10 packets arrived in every sample, without protocol errors" : "STREAM FAILED"}]
  puts "NOTE: continuous flow through the whole pipeline is NOT tested here (scaler not configured, no frame buffer)."
  return $rc
}

# Scan of the I2C bus: a one byte write (0x00) to every address; an address that is not
# acknowledged raises the transmit error of the AXI IIC
proc iic_scan {cam} {
  global IIC_TX
  set found {}
  iic_init $cam
  for {set dev 0x08} {$dev < 0x78} {incr dev} {
    iic_begin $cam
    axi_wr [iic_reg $cam $IIC_TX] [expr {0x100 | ($dev << 1)}]
    axi_wr [iic_reg $cam $IIC_TX] 0x200
    set err [iic_write_done $cam]
    if { $err eq "" } {
      lappend found [format 0x%02X $dev]
    } elseif { ![string match "no acknowledge*" $err] } {
      puts [format "  0x%02X: %s" $dev $err]
    }
  }
  iic_init $cam
  return $found
}

proc cmd_i2cscan {cam} {
  global GPIO_CAM_IO0
  gpio_set $cam $GPIO_CAM_IO0
  msleep 200
  puts "CAM$cam: GPIO = [format 0x%02X [gpio_rd $cam]] (camera enable HIGH): devices that acknowledge: [iic_scan $cam]"
  gpio_clr $cam $GPIO_CAM_IO0
  msleep 200
  puts "CAM$cam: GPIO = [format 0x%02X [gpio_rd $cam]] (camera enable LOW):  devices that acknowledge: [iic_scan $cam]"
  gpio_set $cam $GPIO_CAM_IO0
  msleep 100
  return 0
}

proc cmd_stop {cam} {
  global GPIO_CAM_IO0
  if {[catch {
    iic_init $cam
    imx219_wr $cam 0x0100 0x00
    puts "CAM$cam: IMX219 in standby"
  } errmsg]} {
    puts "CAM$cam: could not write the IMX219: $errmsg"
  }
  msleep 100
  gpio_wr $cam $GPIO_CAM_IO0
  puts "CAM$cam: GPIO = [format 0x%02X [gpio_rd $cam]] (camera enabled, video IP in reset)"
  return 0
}

# Interrupt path into the interrupt controller.
#   * AXI IIC: its interrupt status bits are EVENTS (the "TX FIFO empty" bit is not set just
#     because the FIFO is empty: after a reset the ISR reads 0xD0 with an empty FIFO). So the
#     test enables "TX FIFO empty" and "bus not busy" and then does a real transfer (a one byte
#     write to the IMX219, which only sets its register pointer; the camera must be enabled).
#   * CSI-2 RX subsystem: "frame received", needs a streaming camera.
proc cmd_irq {cam} {
  global ADDR_INTC INTC_BIT OFF_CSI IIC_GIE IIC_IER IIC_ISR IIC_TX IMX219_I2C_ADDR
  set errors 0
  # INTC: master enable + hardware interrupt enable, all inputs enabled
  axi_wr [expr {$ADDR_INTC + 0x08}] 0x3FF
  axi_wr [expr {$ADDR_INTC + 0x1C}] 0x3
  axi_wr [expr {$ADDR_INTC + 0x0C}] 0x3FF
  puts [format "INTC ISR before = 0x%03X" [axi_rd $ADDR_INTC]]

  iic_init $cam
  set bit $INTC_BIT($cam,iic)
  axi_wr [iic_reg $cam $IIC_IER] 0x14
  axi_wr [iic_reg $cam $IIC_GIE] 0x80000000
  set isr [axi_rd $ADDR_INTC]
  puts [format "IIC interrupts enabled, no transfer yet: IIC ISR = 0x%02X, INTC ISR = 0x%03X (bit %d = %d)" \
    [axi_rd [iic_reg $cam $IIC_ISR]] $isr $bit [expr {($isr >> $bit) & 1}]]
  iic_begin $cam
  axi_wr [iic_reg $cam $IIC_TX] [expr {0x100 | ($IMX219_I2C_ADDR << 1)}]
  axi_wr [iic_reg $cam $IIC_TX] 0x200
  set err [iic_write_done $cam]
  if { $err ne "" } { puts "  I2C transfer failed: $err"; incr errors }
  set isr [axi_rd $ADDR_INTC]
  puts [format "after a one byte I2C write: IIC ISR = 0x%02X, INTC ISR = 0x%03X, expected bit %d set: %s" \
    [axi_rd [iic_reg $cam $IIC_ISR]] $isr $bit [expr {(($isr >> $bit) & 1) ? "OK" : "MISSING"}]]
  if { !(($isr >> $bit) & 1) } { incr errors }
  axi_wr [iic_reg $cam $IIC_GIE] 0
  axi_wr [iic_reg $cam $IIC_IER] 0
  axi_wr [iic_reg $cam $IIC_ISR] [axi_rd [iic_reg $cam $IIC_ISR]]
  axi_wr [expr {$ADDR_INTC + 0x0C}] 0x3FF
  set isr [axi_rd $ADDR_INTC]
  puts [format "IIC interrupt disabled and acknowledged: INTC ISR = 0x%03X, expected bit %d clear: %s" $isr $bit \
    [expr {(($isr >> $bit) & 1) ? "STILL SET" : "OK"}]]
  if { ($isr >> $bit) & 1 } { incr errors }

  # CSI-2 RX: frame received (needs a streaming camera)
  set base [cam_addr $cam $OFF_CSI]
  axi_wr [expr {$base + 0x24}] 0xFFFFFFFF
  axi_wr [expr {$base + 0x28}] 0x80000000
  axi_wr [expr {$base + 0x20}] 0x1
  msleep 200
  set isr [axi_rd $ADDR_INTC]
  set bit $INTC_BIT($cam,csi)
  puts [format "CSI frame received interrupt enabled: CSI ISR = 0x%08X, INTC ISR = 0x%03X, bit %d: %s" \
    [axi_rd [expr {$base + 0x24}]] $isr $bit [expr {(($isr >> $bit) & 1) ? "set" : "clear (no frames: is the camera streaming?)"}]]
  axi_wr [expr {$base + 0x20}] 0x0
  axi_wr [expr {$base + 0x28}] 0x0
  axi_wr [expr {$base + 0x24}] 0xFFFFFFFF
  axi_wr [expr {$ADDR_INTC + 0x0C}] 0x3FF
  puts [format "CSI interrupt disabled and acknowledged: INTC ISR = 0x%03X" [axi_rd $ADDR_INTC]]

  # leave the interrupt controller as it was after configuration: everything disabled
  axi_wr [expr {$ADDR_INTC + 0x08}] 0x0
  puts [expr {$errors == 0 ? "IRQ PASSED (IIC interrupt path; the CSI line above is informational)" : "IRQ FAILED"}]
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
    regs   { set rc [cmd_regs] }
    camid  { set rc [cmd_camid $cam] }
    stream { set rc [cmd_stream $cam] }
    csi    { set rc [csi_monitor $cam] }
    stop   { set rc [cmd_stop $cam] }
    irq    { set rc [cmd_irq $cam] }
    i2cscan { set rc [cmd_i2cscan $cam] }
    i2crd  {
      if { [llength $cmdargs] < 2 } { usage } else {
        set reg [expr {[lindex $cmdargs 1]}]
        set count [expr {[llength $cmdargs] > 2 ? [lindex $cmdargs 2] : 1}]
        iic_init $cam
        set i 0
        foreach b [imx219_rd $cam $reg $count] {
          puts [format "CAM%d IMX219 0x%04X = 0x%02X" $cam [expr {$reg + $i}] $b]
          incr i
        }
        set rc 0
      }
    }
    i2cwr  {
      if { [llength $cmdargs] < 3 } { usage } else {
        iic_init $cam
        imx219_wr $cam [expr {[lindex $cmdargs 1]}] [expr {[lindex $cmdargs 2]}]
        puts [format "CAM%d IMX219 0x%04X <= 0x%02X" $cam [expr {[lindex $cmdargs 1]}] [expr {[lindex $cmdargs 2]}]]
        set rc 0
      }
    }
  }
} errmsg]} {
  puts "ERROR: $errmsg"
  puts "       If an AXI transaction does not complete (a video IP in reset was accessed), the"
  puts "       register path stays blocked: re-program the device (scripts/jtag/auboard_prog.tcl)."
  catch { reset_hw_axi $axi }
  set rc 1
}

close_hw_target
disconnect_hw_server
exit $rc
