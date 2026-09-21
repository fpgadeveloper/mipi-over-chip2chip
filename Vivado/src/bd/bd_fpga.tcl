################################################################
# Block design build script for the processor-less FPGA target (role "mezzanine")
################################################################
#
# Target: auboard (Tria AUBoard 15P, xcau15p-ffvb676-2-e)
#
# This block design has NO processor. It is the AXI Chip2Chip MASTER of the two-board system:
#
#   * its AXI4 slave port (s_axi) carries memory mapped traffic TO the host (the DDR of the
#     ZCU106 appears at 0x0000_0000-0x7FFF_FFFF),
#   * its AXI4-Lite master port (m_axi_lite) carries the register accesses that COME FROM the
#     host and drives the local peripherals.
#
# The link is one Aurora 64B/66B lane at 10.3125 Gbps on the SFP+ cage.
#
# Link and bring-up: the link, a JTAG to AXI master for bring-up without a processor, and three small
# peripherals that let either side prove the link: a GPIO with the LEDs and the link status,
# a scratch BRAM, and a frequency counter on the Aurora user clock.
#
# Cameras: one MIPI CSI-2 capture pipeline per camera of the "cams" list (hierarchy mipi_<n>,
# the pipe of the rpi-camera-fmc reference design for this board without its display half):
#
#   mipi_csi2_rx_subsystem (2 lanes, RAW10) -> axis_subset_converter (RAW10 -> 8 bit)
#     -> v_demosaic -> v_gamma_lut -> v_proc_ss (scaler only) -> v_frmbuf_wr
#
# plus an AXI IIC (sensor) and an AXI GPIO (camera enable + resets of the video IP) per
# camera, and ONE interrupt controller whose output is interrupt 0 of the link. The frame
# buffer writers write into the DDR of the host through the link.
#
# Clocks
# ------
#   sys_clk_300mhz (board, 300 MHz differential) -> clk_wiz -> clk_100M, clk_200M, clk_video
#   clk_100M       : AXI4-Lite, Aurora init_clk, GT DRP clock, AXI4 side of the Chip2Chip core
#   clk_200M       : reference clock of the MIPI D-PHYs
#   clk_video      : video clock of the pipelines (AXI4-Stream, the HLS video IP and their
#                    AXI4-Lite ports, the AXI4 masters of the frame buffer writers), see
#                    "video_clk_mhz" below
#   sfp_refclk     : 156.25 MHz GT reference clock (see the note in auboard.xdc about the quad)
#   user_clk_out   : Aurora user clock (161.1328125 MHz at 10.3125 Gbps), clocks the PHY side
#                    of the AXI Chip2Chip core
#
# Address map (must match docs/ and the block design of the host, the AXI Chip2Chip core
# passes addresses through 1:1)
# ----------------------------------------------------------------------------------------
#   0x0000_0000 2G    axi_c2c/s_axi   the DDR of the host, through the link  (jtag_axi and the
#                                     frame buffer writers; the writers see nothing else)
#   0xA000_0000 64K   axi_gpio_sys    ch1 out: bit1..0 = leds[1:0] (bit3..2 not connected)
#                                     ch2 in : link status, see "Status bits" below
#   0xA001_0000 8K    axi_bram_ctrl   8K scratch BRAM
#   0xA002_0000 64K   axi_gpio_freq   ch1 in : frequency of user_clk_out in Hz
#                                     ch2 in : number of measurements (+1 per second)
#   0xA003_0000 64K   axi_gpio_dbg    ch1 out: bit2..0 = Aurora loopback (0 = normal operation,
#                                     2 = near-end PMA loopback). Bring-up aid: a write of a
#                                     non-zero value from the host takes the link down.
#   0xA004_0000 64K   axi_intc        interrupt controller, output = interrupt 0 of the link
#
#   Per camera, CAM0 at 0xA010_0000 and CAM2 at 0xA020_0000 (offsets are the same):
#   +0x0_0000   64K   mipi_<n>/mipi_csi2_rx_subsyst_0
#   +0x1_0000   64K   mipi_<n>/axi_iic_0
#   +0x2_0000   64K   mipi_<n>/axi_gpio_0     bit 0 camera IO0 (enable), bit 1 camera IO1,
#                                             bit 2/3/4/6 = active low reset of demosaic /
#                                             v_proc / v_gamma_lut / v_frmbuf_wr; reset value 0x1
#   +0x3_0000   64K   mipi_<n>/demosaic_0
#   +0x4_0000   64K   mipi_<n>/v_gamma_lut
#   +0x5_0000   64K   mipi_<n>/v_frmbuf_wr
#   +0x8_0000   256K  mipi_<n>/v_proc
#
#   NOTE: a video IP whose reset bit is 0 does not answer on AXI4-Lite, and an access to it
#   never completes (it blocks the register path for everybody). Release the reset first.
#
#   Interrupt inputs of axi_intc (all level, active high):
#     0 CAM0 csirxss   1 CAM0 frmbuf_wr   2 CAM0 iic   3 CAM2 csirxss   4 CAM2 frmbuf_wr
#     5 CAM2 iic       6 CAM0 demosaic    7 CAM0 gamma 8 CAM2 demosaic  9 CAM2 gamma
#
#   The local peripherals are reached by BOTH the host (axi_c2c/m_axi_lite) and jtag_axi.
#   axi_c2c/m_axi_lite cannot reach axi_c2c/s_axi (no loop through the link).
#
# Status bits (axi_gpio_sys ch2, same layout on both boards)
# ----------------------------------------------------------
#   0 channel_up             4 axi_c2c_link_error_out        8 soft_err
#   1 lane_up                5 axi_c2c_multi_bit_error_out   9 mmcm_not_locked
#   2 gt_pll_lock            6 axi_c2c_config_error_out      10 SFP LOS       (board pin)
#   3 axi_c2c_link_status    7 hard_err                      11 SFP TX fault  (board pin)
#
# LEDs (port leds[3:0]; the board has four red LEDs, active high, labelled LED1..LED4)
# ----------------------------------------------------------------------------------
#   leds[3] (board LED4) = Aurora channel_up        leds[1] (LED2) = axi_gpio_sys ch1 bit 1
#   leds[2] (board LED3) = AXI Chip2Chip link up    leds[0] (LED1) = axi_gpio_sys ch1 bit 0
#   The link state is thus visible without any software, and the host can prove a register
#   write with the two GPIO LEDs.
#
################################################################

# CHECKING IF PROJECT EXISTS
if { [get_projects -quiet] eq "" } {
   puts "ERROR: Please open or create a project!"
   return 1
}

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

create_bd_design $block_name

current_bd_design $block_name

set parentCell [get_bd_cells /]

# Get object for parentCell
set parentObj [get_bd_cells $parentCell]
if { $parentObj == "" } {
   puts "ERROR: Unable to find parent cell <$parentCell>!"
   return
}

# Make sure parentObj is hier blk
set parentType [get_property TYPE $parentObj]
if { $parentType ne "hier" } {
   puts "ERROR: Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."
   return
}

# Save current instance; Restore later
set oldCurInst [current_bd_instance .]

# Set parent object as current
current_bd_instance $parentObj

# The RTL modules of this block design (src/hdl/) are added to the project by build.tcl
foreach ref_module {freq_counter bit_sync pipe_gpio} {
  if { [llength [get_files -quiet ${ref_module}.v]] == 0 } {
    error "RTL module ${ref_module}.v is not in the project (expected in src/hdl/)"
  }
}

# Base addresses of the local peripherals (the link contract)
set addr_c2c_mm     0x00000000
set addr_gpio_sys   0xA0000000
set addr_bram       0xA0010000
set addr_gpio_freq  0xA0020000
set addr_gpio_dbg   0xA0030000
set addr_intc       0xA0040000
# Video pipelines: base address per camera port, and {offset range} of the IP of a pipeline
set addr_cam_base   [dict create 0 0xA0100000 2 0xA0200000]
set addr_cam_offs   [dict create \
  mipi_csi2_rx_subsyst_0 {0x00000 64K} \
  axi_iic_0              {0x10000 64K} \
  axi_gpio_0             {0x20000 64K} \
  demosaic_0             {0x30000 64K} \
  v_gamma_lut            {0x40000 64K} \
  v_frmbuf_wr            {0x50000 64K} \
  v_proc                 {0x80000 256K} \
]

# Video pipelines (the values of the rpi-camera-fmc reference design for this board)
# Maximum resolution of the video IP, has an impact on the resource usage
set max_cols 1920
set max_rows 1232
# Samples per clock of the video pipelines
set pipe_samples_pc 1
# Video clock in MHz. The reference design uses 300 MHz. At one sample per clock the video
# clock must be faster than the pixel rate of the sensor during a line: the 2 lane link of
# the IMX219 delivers up to 182.4 Mpixel/s.
set video_clk_mhz 300.000
# Data width of the AXI4 master of the frame buffer writers. The link is 64 bit wide
# (C_AXI_DATA_WIDTH of the Chip2Chip core), so 64 avoids a width conversion.
set frmbuf_mm_width 64
# Burst length of the frame buffer writers in beats. Every burst costs a round trip over the
# link (the write response comes from the host), so short bursts limit the throughput. The
# reference design writes 16 beats of 128 bit = 256 bytes per burst into local DDR; with the
# 64 bit master of this design 16 beats would be 128 bytes. 64 beats = 512 bytes per burst.
# (Measured on hardware with this value: both cameras at 1920x1080 RGB24, 47.6 fps each,
# about 592 MB/s through the link with no dropped frames; see docs/source/linux_cameras.md.)
set frmbuf_burst_len 64

########################################################################################
# Clock and reset
########################################################################################

# Board system clock: 300 MHz differential (SYS_CLK, bank 64)
set sys_clk_300mhz [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 sys_clk_300mhz ]
set_property -dict [ list CONFIG.FREQ_HZ {300000000} ] $sys_clk_300mhz

# Board reset push button (SYS_RST_N, active low)
set system_resetn [ create_bd_port -dir I -type rst system_resetn ]
set_property -dict [ list CONFIG.POLARITY {ACTIVE_LOW} ] $system_resetn

# Clock wizard: 300 MHz -> 100 MHz (AXI), 200 MHz (MIPI D-PHY reference) and the video clock
# (one MMCM for all three: the device has only three MMCMs)
set clk_wiz [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz ]
set_property -dict [list \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
  CONFIG.PRIM_IN_FREQ {300.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
  CONFIG.CLK_OUT1_PORT {clk_100M} \
  CONFIG.CLKOUT2_USED {true} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.CLK_OUT2_PORT {clk_200M} \
  CONFIG.CLKOUT3_USED {true} \
  CONFIG.CLKOUT3_REQUESTED_OUT_FREQ $video_clk_mhz \
  CONFIG.CLK_OUT3_PORT {clk_video} \
  CONFIG.NUM_OUT_CLKS {3} \
  CONFIG.RESET_PORT {resetn} \
  CONFIG.RESET_TYPE {ACTIVE_LOW} \
  CONFIG.USE_LOCKED {true} \
] $clk_wiz
connect_bd_intf_net [get_bd_intf_ports sys_clk_300mhz] [get_bd_intf_pins clk_wiz/CLK_IN1_D]
connect_bd_net [get_bd_ports system_resetn] [get_bd_pins clk_wiz/resetn]

# Reset of the 100 MHz domain: push button + MMCM lock
set rst_clk_100M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_clk_100M ]
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins rst_clk_100M/slowest_sync_clk]
connect_bd_net [get_bd_ports system_resetn] [get_bd_pins rst_clk_100M/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz/locked] [get_bd_pins rst_clk_100M/dcm_locked]

# Reset of the video clock domain
set rst_clk_video [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_clk_video ]
connect_bd_net [get_bd_pins clk_wiz/clk_video] [get_bd_pins rst_clk_video/slowest_sync_clk]
connect_bd_net [get_bd_ports system_resetn] [get_bd_pins rst_clk_video/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz/locked] [get_bd_pins rst_clk_video/dcm_locked]

########################################################################################
# Aurora 64B/66B: one lane, 10.3125 Gbps, streaming, shared logic in the core
########################################################################################

# The SFP+ cage is GT quad 226, channel 3 (GTHE4_CHANNEL_X0Y11). The reference clock pins of
# the board are NOT in that quad, see the note in auboard.xdc. The IP only offers the
# reference clocks of its own quad, the XDC places the clock buffer on the real pins.
# C_INIT_CLK is not set here: in a block design it is taken from the clock on init_clk
# (100 MHz). DRP_FREQ is fixed at 100 MHz by the IP in this configuration.
set aurora [ create_bd_cell -type ip -vlnv xilinx.com:ip:aurora_64b66b:13.0 aurora ]
set_property -dict [list \
  CONFIG.C_AURORA_LANES {1} \
  CONFIG.C_LINE_RATE {10.3125} \
  CONFIG.C_REFCLK_FREQUENCY {156.25} \
  CONFIG.dataflow_config {Duplex} \
  CONFIG.interface_mode {Streaming} \
  CONFIG.flow_mode {None} \
  CONFIG.crc_mode {false} \
  CONFIG.SupportLevel {1} \
  CONFIG.SINGLEEND_INITCLK {true} \
  CONFIG.C_START_QUAD {Quad_X0Y2} \
  CONFIG.C_START_LANE {X0Y11} \
  CONFIG.C_REFCLK_SOURCE {MGTREFCLK1_of_Quad_X0Y2} \
] $aurora

# GT reference clock: 156.25 MHz from the board clock generator (runs without programming)
set sfp_refclk [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 sfp_refclk ]
set_property -dict [ list CONFIG.FREQ_HZ {156250000} ] $sfp_refclk
connect_bd_intf_net [get_bd_intf_ports sfp_refclk] [get_bd_intf_pins aurora/GT_DIFF_REFCLK1]

# GT serial pins of the SFP+ cage
make_bd_intf_pins_external -name sfp_tx [get_bd_intf_pins aurora/GT_SERIAL_TX]
make_bd_intf_pins_external -name sfp_rx [get_bd_intf_pins aurora/GT_SERIAL_RX]

connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins aurora/init_clk]

########################################################################################
# AXI Chip2Chip: master, Aurora 64B/66B PHY, AXI4-Lite master port
########################################################################################

# C_INTERFACE_TYPE  2 = Aurora 64B/66B
# C_INTERFACE_MODE  1 = Compact 2:1 (the only setting that fits a 64 bit AXI data bus in ONE
#                       Aurora lane, Compact 1:1 needs two lanes)
# C_INCLUDE_AXILITE 2 = the core has the AXI4-Lite MASTER port m_axi_lite (the GUI calls this
#                       "Slave" mode: the AXI4-Lite master of the system is on the other side)
# C_AXI_ID_WIDTH and C_AXI_WUSER_WIDTH cannot be set here: the master core takes them from
# the connection of s_axi when the block design is validated (checked below).
set axi_c2c [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_chip2chip:5.0 axi_c2c ]
set_property -dict [list \
  CONFIG.C_MASTER_FPGA {1} \
  CONFIG.C_AXI_BUS_TYPE {0} \
  CONFIG.C_AXI_DATA_WIDTH {64} \
  CONFIG.C_AXI_ADDR_WIDTH {32} \
  CONFIG.C_INTERFACE_TYPE {2} \
  CONFIG.C_INTERFACE_MODE {1} \
  CONFIG.C_INCLUDE_AXILITE {2} \
  CONFIG.C_AXI_LITE_DATA_WIDTH {32} \
  CONFIG.C_AXI_LITE_ADDR_WIDTH {32} \
  CONFIG.C_INTERRUPT_WIDTH {4} \
  CONFIG.C_ECC_ENABLE {true} \
  CONFIG.C_EN_AXI_LINK_HNDLR {false} \
] $axi_c2c

# Chip2Chip <-> Aurora
connect_bd_intf_net [get_bd_intf_pins axi_c2c/AXIS_TX] [get_bd_intf_pins aurora/USER_DATA_S_AXIS_TX]
connect_bd_intf_net [get_bd_intf_pins aurora/USER_DATA_M_AXIS_RX] [get_bd_intf_pins axi_c2c/AXIS_RX]
connect_bd_net [get_bd_pins aurora/user_clk_out] [get_bd_pins axi_c2c/axi_c2c_phy_clk]
connect_bd_net [get_bd_pins aurora/channel_up] [get_bd_pins axi_c2c/axi_c2c_aurora_channel_up]
connect_bd_net [get_bd_pins aurora/mmcm_not_locked_out] [get_bd_pins axi_c2c/aurora_mmcm_not_locked]
connect_bd_net [get_bd_pins axi_c2c/aurora_pma_init_out] [get_bd_pins aurora/pma_init]
connect_bd_net [get_bd_pins axi_c2c/aurora_reset_pb] [get_bd_pins aurora/reset_pb]
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins axi_c2c/aurora_init_clk]
connect_bd_net [get_bd_pins rst_clk_100M/peripheral_reset] [get_bd_pins axi_c2c/aurora_pma_init_in]

# AXI ID and WUSER width of the link. The master core does not let the user set them: it
# copies them from whatever drives s_axi when the block design is validated. A SmartConnect
# offers 0/0 today and something else when masters are added or removed, but the widths are part of
# the link contract (the host side is configured with ID 6 / WUSER 4). A register slice
# with user defined widths in front of s_axi pins them; the SmartConnect then drives the
# narrower ID zero extended.
set c2c_regslice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice c2c_regslice ]
set_property -dict [list \
  CONFIG.ID_WIDTH {6} \
  CONFIG.WUSER_WIDTH {4} \
] $c2c_regslice
connect_bd_intf_net [get_bd_intf_pins c2c_regslice/M_AXI] [get_bd_intf_pins axi_c2c/s_axi]
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins c2c_regslice/aclk]
connect_bd_net [get_bd_pins rst_clk_100M/peripheral_aresetn] [get_bd_pins c2c_regslice/aresetn]

# AXI clocks and reset of the Chip2Chip core
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins axi_c2c/s_aclk]
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins axi_c2c/m_axi_lite_aclk]
connect_bd_net [get_bd_pins rst_clk_100M/peripheral_aresetn] [get_bd_pins axi_c2c/s_aresetn]

# Interrupts to the host: bit 0 = the interrupt controller of the video pipelines (axi_intc,
# connected in "Interrupt controller" below), bits 3..1 are not used and stay 0. The Chip2Chip
# core forwards the LEVEL of its interrupt inputs.
set irq_zero [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 irq_zero ]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $irq_zero
set irq_concat [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 irq_concat ]
set_property -dict [list CONFIG.NUM_PORTS {4}] $irq_concat
foreach i {1 2 3} {
  connect_bd_net [get_bd_pins irq_zero/dout] [get_bd_pins irq_concat/In$i]
}
connect_bd_net [get_bd_pins irq_concat/dout] [get_bd_pins axi_c2c/axi_c2c_m2s_intr_in]

########################################################################################
# JTAG to AXI master (bring-up and test without a processor)
########################################################################################

set jtag_axi [ create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi ]
set_property -dict [list \
  CONFIG.PROTOCOL {0} \
  CONFIG.M_AXI_ADDR_WIDTH {32} \
  CONFIG.M_AXI_DATA_WIDTH {32} \
] $jtag_axi
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins jtag_axi/aclk]
connect_bd_net [get_bd_pins rst_clk_100M/peripheral_aresetn] [get_bd_pins jtag_axi/aresetn]

########################################################################################
# Local peripherals
########################################################################################

# axi_gpio_sys: ch1 = 4 outputs (LEDs), ch2 = 12 status inputs
set axi_gpio_sys [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_sys ]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {4} \
  CONFIG.C_ALL_OUTPUTS {1} \
  CONFIG.C_DOUT_DEFAULT {0x00000000} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {12} \
  CONFIG.C_ALL_INPUTS_2 {1} \
] $axi_gpio_sys

# axi_gpio_freq: ch1 = measured frequency, ch2 = measurement counter
set axi_gpio_freq [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_freq ]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {32} \
  CONFIG.C_ALL_INPUTS {1} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {32} \
  CONFIG.C_ALL_INPUTS_2 {1} \
] $axi_gpio_freq

# axi_gpio_dbg: ch1 = Aurora loopback control
set axi_gpio_dbg [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_dbg ]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {3} \
  CONFIG.C_ALL_OUTPUTS {1} \
  CONFIG.C_DOUT_DEFAULT {0x00000000} \
] $axi_gpio_dbg
connect_bd_net [get_bd_pins axi_gpio_dbg/gpio_io_o] [get_bd_pins aurora/loopback]

# Scratch BRAM. The controller is an AXI4-Lite slave like every other local peripheral, so
# that the register interconnect is a pure (small) AXI4-Lite one; a burst of jtag_axi is
# split into single beats by the protocol converter in front of that interconnect.
set axi_bram_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl axi_bram_ctrl ]
set_property -dict [list \
  CONFIG.PROTOCOL {AXI4LITE} \
  CONFIG.DATA_WIDTH {32} \
  CONFIG.SINGLE_PORT_BRAM {1} \
  CONFIG.ECC_TYPE {0} \
] $axi_bram_ctrl
set axi_bram [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen axi_bram ]
set_property -dict [list CONFIG.Memory_Type {Single_Port_RAM}] $axi_bram
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl/BRAM_PORTA] [get_bd_intf_pins axi_bram/BRAM_PORTA]

# Frequency counter on the Aurora user clock, measured against the 100 MHz clock
set freq_counter [ create_bd_cell -type module -reference freq_counter freq_counter ]
set_property -dict [list CONFIG.REF_HZ {100000000}] $freq_counter
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins freq_counter/ref_clk]
connect_bd_net [get_bd_pins aurora/user_clk_out] [get_bd_pins freq_counter/meas_clk]
connect_bd_net [get_bd_pins freq_counter/freq_hz] [get_bd_pins axi_gpio_freq/gpio_io_i]
connect_bd_net [get_bd_pins freq_counter/update_cnt] [get_bd_pins axi_gpio_freq/gpio2_io_i]

########################################################################################
# Link status: synchronised to the 100 MHz domain, to the status GPIO and to the LEDs
########################################################################################

# SFP+ cage side band signals
set sfp_los [ create_bd_port -dir I sfp_los ]
set sfp_tx_fault [ create_bd_port -dir I sfp_tx_fault ]

# Status bit 6: the master core has no axi_c2c_config_error_out, the bit reads 0 if so
set status_zero [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 status_zero ]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $status_zero

set status_concat [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 status_concat ]
set_property -dict [list CONFIG.NUM_PORTS {12}] $status_concat
connect_bd_net [get_bd_pins aurora/channel_up]                   [get_bd_pins status_concat/In0]
connect_bd_net [get_bd_pins aurora/lane_up]                      [get_bd_pins status_concat/In1]
connect_bd_net [get_bd_pins aurora/gt_pll_lock]                  [get_bd_pins status_concat/In2]
connect_bd_net [get_bd_pins axi_c2c/axi_c2c_link_status_out]     [get_bd_pins status_concat/In3]
connect_bd_net [get_bd_pins axi_c2c/axi_c2c_link_error_out]      [get_bd_pins status_concat/In4]
connect_bd_net [get_bd_pins axi_c2c/axi_c2c_multi_bit_error_out] [get_bd_pins status_concat/In5]
if { [llength [get_bd_pins -quiet axi_c2c/axi_c2c_config_error_out]] } {
  connect_bd_net [get_bd_pins axi_c2c/axi_c2c_config_error_out]  [get_bd_pins status_concat/In6]
} else {
  connect_bd_net [get_bd_pins status_zero/dout]                  [get_bd_pins status_concat/In6]
}
connect_bd_net [get_bd_pins aurora/hard_err]                     [get_bd_pins status_concat/In7]
connect_bd_net [get_bd_pins aurora/soft_err]                     [get_bd_pins status_concat/In8]
connect_bd_net [get_bd_pins aurora/mmcm_not_locked_out]          [get_bd_pins status_concat/In9]
connect_bd_net [get_bd_ports sfp_los]                            [get_bd_pins status_concat/In10]
connect_bd_net [get_bd_ports sfp_tx_fault]                       [get_bd_pins status_concat/In11]

set status_sync [ create_bd_cell -type module -reference bit_sync status_sync ]
set_property -dict [list CONFIG.WIDTH {12}] $status_sync
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins status_sync/clk]
connect_bd_net [get_bd_pins status_concat/dout] [get_bd_pins status_sync/din]
connect_bd_net [get_bd_pins status_sync/dout] [get_bd_pins axi_gpio_sys/gpio2_io_i]

# LEDs: leds[3] = channel_up, leds[2] = Chip2Chip link up, leds[1:0] = GPIO bits 1..0
set led_gpio_slice [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 led_gpio_slice ]
set_property -dict [list CONFIG.DIN_WIDTH {4} CONFIG.DIN_FROM {1} CONFIG.DIN_TO {0}] $led_gpio_slice
connect_bd_net [get_bd_pins axi_gpio_sys/gpio_io_o] [get_bd_pins led_gpio_slice/Din]

set led_chup_slice [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 led_chup_slice ]
set_property -dict [list CONFIG.DIN_WIDTH {12} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0}] $led_chup_slice
connect_bd_net [get_bd_pins status_sync/dout] [get_bd_pins led_chup_slice/Din]

set led_link_slice [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 led_link_slice ]
set_property -dict [list CONFIG.DIN_WIDTH {12} CONFIG.DIN_FROM {3} CONFIG.DIN_TO {3}] $led_link_slice
connect_bd_net [get_bd_pins status_sync/dout] [get_bd_pins led_link_slice/Din]

set led_concat [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 led_concat ]
set_property -dict [list CONFIG.NUM_PORTS {3}] $led_concat
connect_bd_net [get_bd_pins led_gpio_slice/Dout] [get_bd_pins led_concat/In0]
connect_bd_net [get_bd_pins led_link_slice/Dout] [get_bd_pins led_concat/In1]
connect_bd_net [get_bd_pins led_chup_slice/Dout] [get_bd_pins led_concat/In2]

set leds [ create_bd_port -dir O -from 3 -to 0 leds ]
connect_bd_net [get_bd_pins led_concat/dout] [get_bd_ports leds]

# SFP+ transmitter enable: TX_DISABLE low = transmitter on (same as fitting jumper J17)
set sfp_tx_disable_const [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 sfp_tx_disable_const ]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $sfp_tx_disable_const
set sfp_tx_disable [ create_bd_port -dir O sfp_tx_disable ]
connect_bd_net [get_bd_pins sfp_tx_disable_const/dout] [get_bd_ports sfp_tx_disable]

########################################################################################
# Video pipelines
########################################################################################

# Creates the capture pipeline of one camera in the hierarchy mipi_<index>. This is the pipe of
# the rpi-camera-fmc reference design for this board (bd_mb.tcl) without its display half
# (no v_frmbuf_rd, no AXI4-Stream output), with two differences:
#   * the resets of the video IP come from the AXI GPIO through synchronisers in the video
#     clock domain (pipe_gpio.v) and not straight from the GPIO register,
#   * the AXI4 master of the frame buffer writer goes out of the hierarchy directly.
proc create_mipi_pipe { index loc_dict } {
  global pipe_samples_pc
  global max_cols
  global max_rows
  global frmbuf_mm_width
  global frmbuf_burst_len

  set hier_obj [create_bd_cell -type hier mipi_$index]
  current_bd_instance $hier_obj

  # Pins of the block
  create_bd_pin -dir I -type clk dphy_clk_200M
  create_bd_pin -dir I -type clk s_axi_lite_aclk
  create_bd_pin -dir I -type rst aresetn
  create_bd_pin -dir I -type clk video_aclk
  create_bd_pin -dir I -type rst video_aresetn
  create_bd_pin -dir O -type intr mipi_sub_irq
  create_bd_pin -dir O -type intr demosaic_irq
  create_bd_pin -dir O -type intr gamma_lut_irq
  create_bd_pin -dir O -type intr frmbufwr_irq
  create_bd_pin -dir O -type intr iic2intc_irpt
  create_bd_pin -dir O GPIO0
  create_bd_pin -dir O GPIO1

  # Interfaces of the block
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_CTRL
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_VIDEO
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_MM
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 MIPI_PHY_IF
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 IIC

  # AXI GPIO: camera enable and the resets of the video IP (bit layout: see pipe_gpio.v).
  # Reset value 0x1 = camera enabled, all video IP in reset.
  set axi_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
  set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_DOUT_DEFAULT {0x00000001} ] $axi_gpio

  set pipe_gpio [create_bd_cell -type module -reference pipe_gpio pipe_gpio]
  connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins pipe_gpio/gpio_o]
  connect_bd_net [get_bd_pins pipe_gpio/cam_io0] [get_bd_pins GPIO0]
  connect_bd_net [get_bd_pins pipe_gpio/cam_io1] [get_bd_pins GPIO1]

  # MIPI CSI-2 RX subsystem (the settings of the reference design)
  set clk_pin [dict get $loc_dict clk pin]
  set clk_pin_name [dict get $loc_dict clk pin_name]
  set data0_pin [dict get $loc_dict data0 pin]
  set data0_pin_name [dict get $loc_dict data0 pin_name]
  set data1_pin [dict get $loc_dict data1 pin]
  set data1_pin_name [dict get $loc_dict data1 pin_name]
  set bank [dict get $loc_dict bank]
  set mipi_csi2_rx_subsyst [ create_bd_cell -type ip -vlnv xilinx.com:ip:mipi_csi2_rx_subsystem mipi_csi2_rx_subsyst_0 ]
  set_property -dict [ list \
    CONFIG.SupportLevel {1} \
    CONFIG.CMN_NUM_LANES {2} \
    CONFIG.CMN_PXL_FORMAT {RAW10} \
    CONFIG.C_DPHY_LANES {2} \
    CONFIG.CMN_NUM_PIXELS $pipe_samples_pc \
    CONFIG.C_EN_CSI_V2_0 {true} \
    CONFIG.C_HS_LINE_RATE {420} \
    CONFIG.C_HS_SETTLE_NS {158} \
    CONFIG.DPY_LINE_RATE {420} \
    CONFIG.CLK_LANE_IO_LOC $clk_pin \
    CONFIG.CLK_LANE_IO_LOC_NAME $clk_pin_name \
    CONFIG.DATA_LANE0_IO_LOC $data0_pin \
    CONFIG.DATA_LANE0_IO_LOC_NAME $data0_pin_name \
    CONFIG.DATA_LANE1_IO_LOC $data1_pin \
    CONFIG.DATA_LANE1_IO_LOC_NAME $data1_pin_name \
    CONFIG.HP_IO_BANK_SELECTION $bank \
  ] $mipi_csi2_rx_subsyst

  # AXIS subset converter: RAW10 -> the 8 most significant bits
  set subset_conv_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_subset_converter subset_conv_0 ]
  if { $pipe_samples_pc == 1 } {
    set_property -dict [ list \
     CONFIG.M_TDATA_NUM_BYTES {1} \
     CONFIG.S_TDATA_NUM_BYTES {2} \
     CONFIG.TDATA_REMAP {tdata[9:2]} \
    ] $subset_conv_0
  } else {
    set_property -dict [ list \
     CONFIG.M_TDATA_NUM_BYTES {2} \
     CONFIG.S_TDATA_NUM_BYTES {3} \
     CONFIG.TDATA_REMAP {tdata[19:12],tdata[9:2]} \
    ] $subset_conv_0
  }

  # Demosaic
  set v_demosaic_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:v_demosaic demosaic_0 ]
  set_property -dict [ list \
    CONFIG.SAMPLES_PER_CLOCK $pipe_samples_pc \
    CONFIG.MAX_COLS $max_cols \
    CONFIG.MAX_DATA_WIDTH {8} \
    CONFIG.MAX_ROWS $max_rows \
    CONFIG.ALGORITHM {1} \
    CONFIG.USE_URAM {0} \
  ] $v_demosaic_0

  # Gamma LUT
  set v_gamma_lut [ create_bd_cell -type ip -vlnv xilinx.com:ip:v_gamma_lut v_gamma_lut ]
  set_property -dict [ list \
    CONFIG.SAMPLES_PER_CLOCK $pipe_samples_pc \
    CONFIG.MAX_COLS $max_cols \
    CONFIG.MAX_DATA_WIDTH {8} \
    CONFIG.MAX_ROWS $max_rows \
  ] $v_gamma_lut

  # Video processing subsystem: scaler only
  set v_proc [ create_bd_cell -type ip -vlnv xilinx.com:ip:v_proc_ss v_proc ]
  set_property -dict [ list \
    CONFIG.C_MAX_COLS $max_cols \
    CONFIG.C_MAX_ROWS $max_rows \
    CONFIG.C_ENABLE_DMA {false} \
    CONFIG.C_MAX_DATA_WIDTH {8} \
    CONFIG.C_TOPOLOGY {0} \
    CONFIG.C_SCALER_ALGORITHM {2} \
    CONFIG.C_ENABLE_CSC {false} \
    CONFIG.C_SAMPLES_PER_CLK $pipe_samples_pc \
    CONFIG.C_COLORSPACE_SUPPORT {2} \
  ] $v_proc

  # Frame buffer write: the video formats of the reference design (the defaults of the IP),
  # 32 bit addresses (the DDR of the host is at 0x0000_0000-0x7FFF_FFFF)
  set v_frmbuf_wr [create_bd_cell -type ip -vlnv xilinx.com:ip:v_frmbuf_wr v_frmbuf_wr]
  set_property -dict [list \
   CONFIG.C_M_AXI_MM_VIDEO_DATA_WIDTH $frmbuf_mm_width \
   CONFIG.SAMPLES_PER_CLOCK $pipe_samples_pc \
   CONFIG.AXIMM_DATA_WIDTH $frmbuf_mm_width \
   CONFIG.AXIMM_ADDR_WIDTH {32} \
   CONFIG.AXIMM_BURST_LENGTH $frmbuf_burst_len \
   CONFIG.MAX_COLS $max_cols \
   CONFIG.MAX_ROWS $max_rows \
  ] $v_frmbuf_wr

  # AXI IIC of the sensor
  set axi_iic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic axi_iic_0]

  # AXI4-Lite interconnects: one in the 100 MHz domain, one in the video clock domain
  set axi_int_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_int_ctrl ]
  set_property -dict [list CONFIG.NUM_MI {3}] $axi_int_ctrl
  # (No register slice option on these interconnects: S00_HAS_REGSLICE turns the slave port
  # into an AXI4 port, and the register interconnect of the top level then becomes an AXI4
  # crossbar with a protocol converter per peripheral - see the check after validation.)
  set axi_int_video [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_int_video ]
  set_property -dict [list CONFIG.NUM_MI {4}] $axi_int_video

  # Resets of the video IP: GPIO bits, synchronised to the video clock
  connect_bd_net [get_bd_pins video_aclk] [get_bd_pins pipe_gpio/video_clk]
  connect_bd_net [get_bd_pins pipe_gpio/demosaic_rst_n] [get_bd_pins demosaic_0/ap_rst_n]
  connect_bd_net [get_bd_pins pipe_gpio/vproc_rst_n] [get_bd_pins v_proc/aresetn_ctrl]
  connect_bd_net [get_bd_pins pipe_gpio/gamma_rst_n] [get_bd_pins v_gamma_lut/ap_rst_n]
  connect_bd_net [get_bd_pins pipe_gpio/frmbuf_wr_rst_n] [get_bd_pins v_frmbuf_wr/ap_rst_n]

  # 200 MHz D-PHY clock
  connect_bd_net [get_bd_pins dphy_clk_200M] [get_bd_pins mipi_csi2_rx_subsyst_0/dphy_clk_200M]
  # Video clock
  connect_bd_net [get_bd_pins video_aclk] [get_bd_pins mipi_csi2_rx_subsyst_0/video_aclk]
  connect_bd_net [get_bd_pins video_aclk] [get_bd_pins subset_conv_0/aclk]
  connect_bd_net [get_bd_pins video_aclk] [get_bd_pins v_frmbuf_wr/ap_clk]
  connect_bd_net [get_bd_pins video_aclk] [get_bd_pins demosaic_0/ap_clk]
  connect_bd_net [get_bd_pins video_aclk] [get_bd_pins v_proc/aclk_axis]
  connect_bd_net [get_bd_pins video_aclk] [get_bd_pins v_proc/aclk_ctrl]
  connect_bd_net [get_bd_pins video_aclk] [get_bd_pins v_gamma_lut/ap_clk]
  foreach p {ACLK S00_ACLK M00_ACLK M01_ACLK M02_ACLK M03_ACLK} {
    connect_bd_net [get_bd_pins video_aclk] [get_bd_pins axi_int_video/$p]
  }
  # 100 MHz AXI4-Lite clock
  foreach p {ACLK S00_ACLK M00_ACLK M01_ACLK M02_ACLK} {
    connect_bd_net [get_bd_pins s_axi_lite_aclk] [get_bd_pins axi_int_ctrl/$p]
  }
  connect_bd_net [get_bd_pins s_axi_lite_aclk] [get_bd_pins mipi_csi2_rx_subsyst_0/lite_aclk]
  connect_bd_net [get_bd_pins s_axi_lite_aclk] [get_bd_pins axi_iic_0/s_axi_aclk]
  connect_bd_net [get_bd_pins s_axi_lite_aclk] [get_bd_pins axi_gpio_0/s_axi_aclk]
  # Video resets
  connect_bd_net [get_bd_pins video_aresetn] [get_bd_pins subset_conv_0/aresetn]
  connect_bd_net [get_bd_pins video_aresetn] [get_bd_pins mipi_csi2_rx_subsyst_0/video_aresetn]
  foreach p {ARESETN S00_ARESETN M00_ARESETN M01_ARESETN M02_ARESETN M03_ARESETN} {
    connect_bd_net [get_bd_pins video_aresetn] [get_bd_pins axi_int_video/$p]
  }
  # AXI4-Lite resets
  foreach p {ARESETN S00_ARESETN M00_ARESETN M01_ARESETN M02_ARESETN} {
    connect_bd_net [get_bd_pins aresetn] [get_bd_pins axi_int_ctrl/$p]
  }
  connect_bd_net [get_bd_pins aresetn] [get_bd_pins mipi_csi2_rx_subsyst_0/lite_aresetn]
  connect_bd_net [get_bd_pins aresetn] [get_bd_pins axi_iic_0/s_axi_aresetn]
  connect_bd_net [get_bd_pins aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
  # AXI4-Lite, 100 MHz domain
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins S_AXI_CTRL] [get_bd_intf_pins axi_int_ctrl/S00_AXI]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins axi_int_ctrl/M00_AXI] [get_bd_intf_pins mipi_csi2_rx_subsyst_0/csirxss_s_axi]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins axi_int_ctrl/M01_AXI] [get_bd_intf_pins axi_iic_0/S_AXI]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins axi_int_ctrl/M02_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
  # AXI4-Lite, video clock domain
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins S_AXI_VIDEO] [get_bd_intf_pins axi_int_video/S00_AXI]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins axi_int_video/M00_AXI] [get_bd_intf_pins demosaic_0/s_axi_CTRL]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins axi_int_video/M01_AXI] [get_bd_intf_pins v_gamma_lut/s_axi_CTRL]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins axi_int_video/M02_AXI] [get_bd_intf_pins v_proc/s_axi_ctrl]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins axi_int_video/M03_AXI] [get_bd_intf_pins v_frmbuf_wr/s_axi_CTRL]
  # AXI4-Stream
  connect_bd_intf_net [get_bd_intf_pins mipi_csi2_rx_subsyst_0/video_out] [get_bd_intf_pins subset_conv_0/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins subset_conv_0/M_AXIS] [get_bd_intf_pins demosaic_0/s_axis_video]
  connect_bd_intf_net [get_bd_intf_pins demosaic_0/m_axis_video] [get_bd_intf_pins v_gamma_lut/s_axis_video]
  connect_bd_intf_net [get_bd_intf_pins v_gamma_lut/m_axis_video] [get_bd_intf_pins v_proc/s_axis]
  connect_bd_intf_net [get_bd_intf_pins v_proc/m_axis] [get_bd_intf_pins v_frmbuf_wr/s_axis_video]
  # AXI4 master of the frame buffer writer
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins v_frmbuf_wr/m_axi_mm_video] [get_bd_intf_pins M_AXI_MM]
  # MIPI D-PHY
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins MIPI_PHY_IF] [get_bd_intf_pins mipi_csi2_rx_subsyst_0/mipi_phy_if]
  # I2C
  connect_bd_intf_net [get_bd_intf_pins IIC] [get_bd_intf_pins axi_iic_0/IIC]
  # Interrupts
  connect_bd_net [get_bd_pins mipi_sub_irq] [get_bd_pins mipi_csi2_rx_subsyst_0/csirxss_csi_irq]
  connect_bd_net [get_bd_pins demosaic_irq] [get_bd_pins demosaic_0/interrupt]
  connect_bd_net [get_bd_pins gamma_lut_irq] [get_bd_pins v_gamma_lut/interrupt]
  connect_bd_net [get_bd_pins frmbufwr_irq] [get_bd_pins v_frmbuf_wr/interrupt]
  connect_bd_net [get_bd_pins iic2intc_irpt] [get_bd_pins axi_iic_0/iic2intc_irpt]

  current_bd_instance \
}

# Constants for the pins of the RPi Camera FMC that are common to all cameras (the values of
# the reference design, which drives them from an AXI GPIO with this reset value)
#   clk_sel[0] = CAM1_CLK_SEL, clk_sel[1] = CAM3_CLK_SEL (clock switches of CAM1/CAM3, the
#   cameras of this design have no switch): 01b for this board
set clk_sel_const [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 clk_sel_const]
set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {0x01}] $clk_sel_const
create_bd_port -dir O -from 1 -to 0 clk_sel
connect_bd_net [get_bd_pins clk_sel_const/dout] [get_bd_ports clk_sel]
#   rsvd_gpio[4] = CAM_IO0_DIR, [5] = CAM_IO1_DIR (1 = FPGA drives the camera IO pins)
#   rsvd_gpio[6] = CAM_IO0_OE_N, [7] = CAM_IO1_OE_N (0 = level translators enabled)
#   rsvd_gpio[3:0], [9:8] = reserved pins, driven low
set rsvd_gpio_const [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 rsvd_gpio_const]
set_property -dict [list CONFIG.CONST_WIDTH {10} CONFIG.CONST_VAL {0x030}] $rsvd_gpio_const
create_bd_port -dir O -from 9 -to 0 rsvd_gpio
connect_bd_net [get_bd_pins rsvd_gpio_const/dout] [get_bd_ports rsvd_gpio]

# One pipeline per camera
foreach i $cams {
  create_mipi_pipe $i [dict get $mipi_loc_dict $target $i]
  # The strobe propagation pins of the D-PHY (unused pins between the clock lane and a data
  # lane in another nibble) must go to the top level
  foreach strobe [get_bd_pins -quiet mipi_$i/mipi_csi2_rx_subsyst_0/bg*_nc] {
    set strobe_pin_name [file tail $strobe]
    create_bd_port -dir I mipi_${i}_$strobe_pin_name
    connect_bd_net [get_bd_ports mipi_${i}_$strobe_pin_name] [get_bd_pins $strobe]
  }
  # Clocks and resets
  connect_bd_net [get_bd_pins clk_wiz/clk_200M] [get_bd_pins mipi_$i/dphy_clk_200M]
  connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins mipi_$i/s_axi_lite_aclk]
  connect_bd_net [get_bd_pins clk_wiz/clk_video] [get_bd_pins mipi_$i/video_aclk]
  connect_bd_net [get_bd_pins rst_clk_100M/peripheral_aresetn] [get_bd_pins mipi_$i/aresetn]
  connect_bd_net [get_bd_pins rst_clk_video/peripheral_aresetn] [get_bd_pins mipi_$i/video_aresetn]
  # MIPI D-PHY
  create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:mipi_phy_rtl:1.0 mipi_phy_if_$i
  connect_bd_intf_net [get_bd_intf_ports mipi_phy_if_$i] -boundary_type upper [get_bd_intf_pins mipi_$i/MIPI_PHY_IF]
  # I2C
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 iic_$i
  connect_bd_intf_net [get_bd_intf_ports iic_$i] [get_bd_intf_pins mipi_$i/IIC]
  # Camera IO pins
  create_bd_port -dir O mipi_${i}_gpio0
  create_bd_port -dir O mipi_${i}_gpio1
  connect_bd_net [get_bd_pins mipi_$i/GPIO0] [get_bd_ports mipi_${i}_gpio0]
  connect_bd_net [get_bd_pins mipi_$i/GPIO1] [get_bd_ports mipi_${i}_gpio1]
}

########################################################################################
# Interrupt controller
########################################################################################

# One interrupt controller for all the pipelines. Its output is a LEVEL, active high (the
# Chip2Chip core forwards levels), and drives interrupt 0 of the link. The order of the
# inputs is the interrupt specifier in the device tree of the host:
#   first csirxss, frmbuf_wr, iic per camera, then demosaic, gamma per camera.
set intr_list {}
foreach i $cams {
  lappend intr_list mipi_$i/mipi_sub_irq mipi_$i/frmbufwr_irq mipi_$i/iic2intc_irpt
}
foreach i $cams {
  lappend intr_list mipi_$i/demosaic_irq mipi_$i/gamma_lut_irq
}

set axi_intc [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc ]
set_property -dict [list \
  CONFIG.C_IRQ_CONNECTION {1} \
  CONFIG.C_IRQ_IS_LEVEL {1} \
  CONFIG.C_IRQ_ACTIVE {1} \
  CONFIG.C_HAS_FAST {0} \
] $axi_intc
set intr_concat [ create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 intr_concat ]
set_property -dict [list CONFIG.NUM_PORTS [llength $intr_list]] $intr_concat
set intr_index 0
foreach intr $intr_list {
  connect_bd_net [get_bd_pins $intr] [get_bd_pins intr_concat/In$intr_index]
  incr intr_index
}
connect_bd_net [get_bd_pins intr_concat/dout] [get_bd_pins axi_intc/intr]
connect_bd_net [get_bd_pins axi_intc/irq] [get_bd_pins irq_concat/In0]

########################################################################################
# AXI interconnect
########################################################################################
#
#   jtag_axi ----------------> smc_mm ----M00----> c2c_regslice -> axi_c2c/s_axi (to the host)
#   mipi_<n>/M_AXI_MM -------->  |
#   (frame buffer writers,       +-------M01----+
#    s_axi only)                                v
#   axi_c2c/m_axi_lite ----------------------> axi_periph ---> local peripherals
#                                              (AXI4-Lite)       +-> mipi_<n>/S_AXI_CTRL  (100 MHz)
#                                                                +-> mipi_<n>/S_AXI_VIDEO (video clock)
#
# The register path of the host (m_axi_lite) only ever sees axi_periph, so it cannot loop
# back into the link.

# smc_mm: memory mapped traffic towards the host. One slave port per frame buffer writer
# (video clock domain); those masters get the axi_c2c/s_axi segment only.
set smc_mm [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc_mm ]
set_property -dict [list CONFIG.NUM_SI [expr {1 + [llength $cams]}] CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {2}] $smc_mm
connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins smc_mm/aclk]
connect_bd_net [get_bd_pins clk_wiz/clk_video] [get_bd_pins smc_mm/aclk1]
connect_bd_net [get_bd_pins rst_clk_100M/peripheral_aresetn] [get_bd_pins smc_mm/aresetn]
connect_bd_intf_net [get_bd_intf_pins jtag_axi/M_AXI] [get_bd_intf_pins smc_mm/S00_AXI]
set si 1
foreach i $cams {
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins mipi_$i/M_AXI_MM] [get_bd_intf_pins smc_mm/S[format %02d $si]_AXI]
  incr si
}
connect_bd_intf_net [get_bd_intf_pins smc_mm/M00_AXI] [get_bd_intf_pins c2c_regslice/S_AXI]

# axi_periph: register path to the local peripherals. An AXI Interconnect, not a
# SmartConnect: every slave is AXI4-Lite, and the AXI4-Lite crossbar of the AXI Interconnect
# is a fraction of the size. Each entry: {slave interface, clock, reset}
set periph_list [list \
  [list axi_gpio_sys/S_AXI  clk_wiz/clk_100M rst_clk_100M/peripheral_aresetn] \
  [list axi_bram_ctrl/S_AXI clk_wiz/clk_100M rst_clk_100M/peripheral_aresetn] \
  [list axi_gpio_freq/S_AXI clk_wiz/clk_100M rst_clk_100M/peripheral_aresetn] \
  [list axi_gpio_dbg/S_AXI  clk_wiz/clk_100M rst_clk_100M/peripheral_aresetn] \
  [list axi_intc/s_axi      clk_wiz/clk_100M rst_clk_100M/peripheral_aresetn] \
]
foreach i $cams {
  lappend periph_list [list mipi_$i/S_AXI_CTRL  clk_wiz/clk_100M  rst_clk_100M/peripheral_aresetn]
  lappend periph_list [list mipi_$i/S_AXI_VIDEO clk_wiz/clk_video rst_clk_video/peripheral_aresetn]
}
set axi_periph [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_periph ]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI [llength $periph_list]] $axi_periph
foreach p {ACLK S00_ACLK S01_ACLK} {
  connect_bd_net [get_bd_pins clk_wiz/clk_100M] [get_bd_pins axi_periph/$p]
}
foreach p {ARESETN S00_ARESETN S01_ARESETN} {
  connect_bd_net [get_bd_pins rst_clk_100M/peripheral_aresetn] [get_bd_pins axi_periph/$p]
}
connect_bd_intf_net [get_bd_intf_pins axi_c2c/m_axi_lite] [get_bd_intf_pins axi_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smc_mm/M01_AXI] [get_bd_intf_pins axi_periph/S01_AXI]
set mi 0
foreach periph $periph_list {
  lassign $periph periph_intf periph_clk periph_rst
  set mi_name M[format %02d $mi]
  connect_bd_intf_net -boundary_type upper [get_bd_intf_pins axi_periph/${mi_name}_AXI] [get_bd_intf_pins $periph_intf]
  connect_bd_net [get_bd_pins $periph_clk] [get_bd_pins axi_periph/${mi_name}_ACLK]
  connect_bd_net [get_bd_pins $periph_rst] [get_bd_pins axi_periph/${mi_name}_ARESETN]
  # The clock and reset of the peripheral itself (the pipelines connect their own)
  set periph_cell [get_bd_cells [lindex [split $periph_intf /] 0]]
  if { [get_property TYPE $periph_cell] ne "hier" } {
    set clk_pin [get_bd_pins -quiet $periph_cell/s_axi_aclk]
    set rst_pin [get_bd_pins -quiet $periph_cell/s_axi_aresetn]
    connect_bd_net [get_bd_pins $periph_clk] $clk_pin
    connect_bd_net [get_bd_pins $periph_rst] $rst_pin
  }
  incr mi
}

########################################################################################
# Addresses (explicit: they are the link contract, both boards use the same numbers)
########################################################################################

# Local peripherals: seen by the host (through m_axi_lite of axi_c2c, its address space is
# called MAXI-Lite) and by jtag_axi
# {slave segment, offset, range} of every local peripheral
set periph_map [list \
  [list [get_bd_addr_segs axi_gpio_sys/S_AXI/Reg]   $addr_gpio_sys  64K] \
  [list [get_bd_addr_segs axi_bram_ctrl/S_AXI/Mem0] $addr_bram      8K] \
  [list [get_bd_addr_segs axi_gpio_freq/S_AXI/Reg]  $addr_gpio_freq 64K] \
  [list [get_bd_addr_segs axi_gpio_dbg/S_AXI/Reg]   $addr_gpio_dbg  64K] \
  [list [get_bd_addr_segs axi_intc/S_AXI/Reg]       $addr_intc      64K] \
]
foreach i $cams {
  dict for {ip offs_range} $addr_cam_offs {
    lassign $offs_range offs range
    set seg [get_bd_addr_segs -of_objects [get_bd_intf_pins -of_objects [get_bd_cells mipi_$i/$ip] -filter {MODE == Slave && VLNV =~ *aximm*}]]
    if { [llength $seg] != 1 } {
      error "mipi_$i/$ip: expected one AXI slave segment, found [llength $seg] ($seg)"
    }
    lappend periph_map [list $seg [format 0x%08X [expr {[dict get $addr_cam_base $i] + $offs}]] $range]
  }
}
foreach master {axi_c2c/MAXI-Lite jtag_axi/Data} {
  set space [get_bd_addr_spaces $master]
  foreach entry $periph_map {
    lassign $entry seg offset range
    assign_bd_address -target_address_space $space -offset $offset -range $range $seg -force
  }
}

# The DDR of the host through the link: jtag_axi and the frame buffer writers. The writers
# see nothing but this window (an address above it gets a DECERR from smc_mm).
assign_bd_address -target_address_space [get_bd_addr_spaces jtag_axi/Data] -offset $addr_c2c_mm -range 2G [get_bd_addr_segs axi_c2c/s_axi/Mem0] -force
foreach i $cams {
  set space [get_bd_addr_spaces mipi_$i/v_frmbuf_wr/Data_m_axi_mm_video]
  assign_bd_address -target_address_space $space -offset $addr_c2c_mm -range 2G [get_bd_addr_segs axi_c2c/s_axi/Mem0] -force
  # the local peripherals, which smc_mm could reach through M01, are excluded from the writers
  foreach entry $periph_map {
    exclude_bd_addr_seg -target_address_space $space [lindex $entry 0]
  }
}

# Restore current instance
current_bd_instance $oldCurInst

validate_bd_design

# Link parameters that the tools derive: report them, the host side must match
puts "INFO: \[link\] axi_c2c C_INTERFACE_MODE  = [get_property CONFIG.C_INTERFACE_MODE $axi_c2c]"
puts "INFO: \[link\] axi_c2c C_AXI_ID_WIDTH    = [get_property CONFIG.C_AXI_ID_WIDTH $axi_c2c]"
puts "INFO: \[link\] axi_c2c C_AXI_WUSER_WIDTH = [get_property CONFIG.C_AXI_WUSER_WIDTH $axi_c2c]"
puts "INFO: \[link\] axi_c2c C_AURORA_WIDTH    = [get_property CONFIG.C_AURORA_WIDTH $axi_c2c]"
puts "INFO: \[link\] aurora  C_INIT_CLK        = [get_property CONFIG.C_INIT_CLK $aurora]"
if { [get_property CONFIG.C_AXI_ID_WIDTH $axi_c2c] != 6 || [get_property CONFIG.C_AXI_WUSER_WIDTH $axi_c2c] != 4 } {
  error "axi_c2c did not get the AXI ID/WUSER widths of the link contract (6/4)"
}
if { [get_property CONFIG.C_INTERFACE_MODE $axi_c2c] != 1 } {
  error "axi_c2c C_INTERFACE_MODE is [get_property CONFIG.C_INTERFACE_MODE $axi_c2c], the link contract needs 1 (Compact 2:1)"
}
if { [get_property CONFIG.C_AURORA_WIDTH $axi_c2c] != 1 } {
  error "axi_c2c needs [get_property CONFIG.C_AURORA_WIDTH $axi_c2c] Aurora lanes, the link has one"
}

# Register path: axi_periph and the interconnects of the pipelines must be pure AXI4-Lite
# interconnects (shared address, shared data crossbar, no protocol converters). One slave or
# master port that is not AXI4-Lite silently turns the crossbar into an AXI4 one with a
# protocol converter per port, which is several times the size.
foreach ic [concat axi_periph [get_bd_cells -quiet -hierarchical -filter {NAME == axi_int_ctrl || NAME == axi_int_video}]] {
  set ic [get_bd_cells $ic]
  set xbar [get_bd_cells $ic/xbar]
  set pcs [get_bd_cells -quiet $ic/*/auto_pc]
  puts "INFO: \[cam\] $ic crossbar: [get_property CONFIG.PROTOCOL $xbar] [get_property CONFIG.CONNECTIVITY_MODE $xbar], protocol converters: [llength $pcs]"
  if { [get_property CONFIG.PROTOCOL $xbar] ne "AXI4LITE" || [llength $pcs] != 0 } {
    error "$ic is not a pure AXI4-Lite interconnect (crossbar [get_property CONFIG.PROTOCOL $xbar], [llength $pcs] protocol converters)"
  }
}

# Interrupt controller: every input must be a level, active high, and so must the output
# (the Chip2Chip core forwards levels). The block design derives the kind of the inputs from
# the interrupt pins that are connected; check the result.
set n_intr [llength $intr_list]
set intr_mask [expr {(1 << $n_intr) - 1}]
puts "INFO: \[cam\] axi_intc C_NUM_INTR_INPUTS = [get_property CONFIG.C_NUM_INTR_INPUTS $axi_intc]"
puts "INFO: \[cam\] axi_intc C_KIND_OF_INTR    = [get_property CONFIG.C_KIND_OF_INTR $axi_intc] (bit = 1: edge)"
puts "INFO: \[cam\] axi_intc C_KIND_OF_LVL     = [get_property CONFIG.C_KIND_OF_LVL $axi_intc] (bit = 1: active high)"
puts "INFO: \[cam\] axi_intc C_ASYNC_INTR      = [get_property CONFIG.C_ASYNC_INTR $axi_intc] (bit = 1: input has a synchroniser)"
puts "INFO: \[cam\] axi_intc C_IRQ_IS_LEVEL/C_IRQ_ACTIVE/C_HAS_FAST = [get_property CONFIG.C_IRQ_IS_LEVEL $axi_intc]/[get_property CONFIG.C_IRQ_ACTIVE $axi_intc]/[get_property CONFIG.C_HAS_FAST $axi_intc]"
if { [get_property CONFIG.C_NUM_INTR_INPUTS $axi_intc] != $n_intr } {
  error "axi_intc has [get_property CONFIG.C_NUM_INTR_INPUTS $axi_intc] inputs, expected $n_intr"
}
if { ([get_property CONFIG.C_KIND_OF_INTR $axi_intc] & $intr_mask) != 0 } {
  error "axi_intc: not every interrupt input is a level"
}
if { ([get_property CONFIG.C_KIND_OF_LVL $axi_intc] & $intr_mask) != $intr_mask } {
  error "axi_intc: not every interrupt input is active high"
}
set intr_index 0
foreach intr $intr_list {
  puts "INFO: \[cam\] axi_intc input $intr_index = $intr"
  incr intr_index
}

# Facts of the video pipelines that the device tree of the host needs: configuration,
# clock frequencies and addresses, as validated
proc report_ip_facts { cell props } {
  set facts {}
  foreach prop $props {
    lappend facts "$prop=[get_property -quiet CONFIG.$prop $cell]"
  }
  puts "INFO: \[cam\] $cell ([get_property VLNV $cell]): [join $facts { }]"
  foreach pin [get_bd_pins -quiet -of_objects $cell -filter {TYPE == clk && DIR == I}] {
    puts "INFO: \[cam\]   clock [file tail $pin] = [get_property CONFIG.FREQ_HZ $pin] Hz"
  }
}
foreach i $cams {
  report_ip_facts [get_bd_cells mipi_$i/mipi_csi2_rx_subsyst_0] {CMN_NUM_LANES CMN_PXL_FORMAT CMN_NUM_PIXELS CMN_INC_VFB CMN_VC C_EN_CSI_V2_0 C_HS_LINE_RATE C_HS_SETTLE_NS DPY_LINE_RATE C_CSI_FILTER_USERDATATYPE C_CSI_EN_ACTIVELANES CSI_BUF_DEPTH C_EN_BG0_PIN0 SupportLevel DPY_EN_REG_IF AXIS_TDATA_WIDTH}
  report_ip_facts [get_bd_cells mipi_$i/subset_conv_0] {S_TDATA_NUM_BYTES M_TDATA_NUM_BYTES TDATA_REMAP}
  report_ip_facts [get_bd_cells mipi_$i/demosaic_0] {SAMPLES_PER_CLOCK MAX_COLS MAX_ROWS MAX_DATA_WIDTH ALGORITHM ENABLE_ZIPPER_REMOVAL USE_URAM}
  report_ip_facts [get_bd_cells mipi_$i/v_gamma_lut] {SAMPLES_PER_CLOCK MAX_COLS MAX_ROWS MAX_DATA_WIDTH}
  report_ip_facts [get_bd_cells mipi_$i/v_proc] {C_TOPOLOGY C_SCALER_ALGORITHM C_SAMPLES_PER_CLK C_MAX_DATA_WIDTH C_MAX_COLS C_MAX_ROWS C_H_SCALER_TAPS C_V_SCALER_TAPS C_H_SCALER_PHASES C_V_SCALER_PHASES C_ENABLE_CSC C_COLORSPACE_SUPPORT C_ENABLE_422 C_ENABLE_420 C_ENABLE_DMA C_ENABLE_INTERLACED}
  report_ip_facts [get_bd_cells mipi_$i/v_frmbuf_wr] {SAMPLES_PER_CLOCK MAX_COLS MAX_ROWS MAX_DATA_WIDTH AXIMM_DATA_WIDTH AXIMM_ADDR_WIDTH AXIMM_NUM_OUTSTANDING AXIMM_BURST_LENGTH HAS_RGB8 HAS_BGR8 HAS_RGBX8 HAS_BGRX8 HAS_YUV8 HAS_YUVX8 HAS_YUYV8 HAS_UYVY8 HAS_Y_UV8 HAS_Y_UV8_420 HAS_Y8 HAS_RGBX10 HAS_YUVX10 HAS_Y_UV10 HAS_Y_UV10_420 HAS_Y10 HAS_INTERLACED}
  report_ip_facts [get_bd_cells mipi_$i/axi_iic_0] {IIC_FREQ_KHZ TEN_BIT_ADR C_GPO_WIDTH C_SCL_INERTIAL_DELAY C_SDA_INERTIAL_DELAY}
  report_ip_facts [get_bd_cells mipi_$i/axi_gpio_0] {C_GPIO_WIDTH C_ALL_OUTPUTS C_DOUT_DEFAULT C_IS_DUAL}
}
foreach master {axi_c2c/MAXI-Lite jtag_axi/Data} {
  foreach seg [lsort [get_bd_addr_segs -of_objects [get_bd_addr_spaces $master]]] {
    puts "INFO: \[map\] [format %-70s $seg] [get_property OFFSET $seg] [get_property RANGE $seg]"
  }
}
foreach i $cams {
  foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces mipi_$i/v_frmbuf_wr/Data_m_axi_mm_video]] {
    puts "INFO: \[map\] [format %-70s $seg] [get_property OFFSET $seg] [get_property RANGE $seg]"
  }
}

save_bd_design
