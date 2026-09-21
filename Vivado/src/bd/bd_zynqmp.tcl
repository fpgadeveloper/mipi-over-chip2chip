# Opsero Electronic Design Inc. Copyright 2026
#
################################################################
# Block design build script for the Zynq UltraScale+ HOST target
# of the mipi-over-chip2chip system (role "host": zcu106)
################################################################
#
# This script is sourced by scripts/build.tcl, which provides these variables:
#   target, block_name (c2c), board_name, cams, role
#
# The host side is only the chip-to-chip link: the video pipelines live on the remote
# (mezzanine) FPGA and need nothing here beyond the window, the DDR path and the interrupts.
#
#   PS M_AXI_HPM0_FPD --> axi_smc_ctrl --+--> axi_c2c/s_axi_lite   0xA000_0000 16M  (remote window)
#                                        +--> axi_gpio_link/S_AXI  0xA100_0000 64K  (local link status)
#
#   axi_c2c/m_axi --> axi_mmu_ddr --> PS S_AXI_HP0_FPD             0x0000_0000 2G   (PS DDR low)
#
#   axi_c2c <--AXI4-Stream--> aurora_64b66b <--> SFP0 cage (GTH Quad 225, channel 2)
#
# DISPLAY PATH (DisplayPort visualisation of the two remote cameras)
#
#   PS S_AXI_HP3_FPD <-- display_pipeline/M00_AXI <-- v_mix m_axi_mm_video1/2   (layer reads from DDR)
#   v_mix --AXI4-Stream RGB 24b--> v_axi4s_vid_out --native 24b--> PS dp_live_video_in_*
#   v_tc generates the 1080p60 timing; clk_wiz (DRP) generates the pixel clock.
#
#   PS M_AXI_HPM0_FPD --> axi_smc_ctrl/M02 --> display_pipeline/s_axi_ctrl -+-> v_mix   0xA200_0000 64K
#                                                                          +-> v_tc    0xA201_0000 64K
#                                                                          +-> clk_wiz 0xA202_0000 64K
#
# The two camera frames arrive in PS DDR as packed RGB24 (V4L2 RGB3, what the remote
# v_frmbuf_wr writes with its "bgr888" device-tree format). The mixer memory layers are
# therefore configured as format 20 ("RGB8" in the Vivado GUI), which is the SAME memory
# layout: 3 bytes per pixel in R,G,B order = DRM_FORMAT_BGR888. Nothing in the path
# converts colour space: the layers, the mixer master layer and the DP live video input
# are all RGB, so gstreamer can go v4l2src -> kmssink with no CPU colour conversion.
# See docs/source/display.md for the format reasoning and the verification checks.
#
# The AXI Chip2Chip is the C2C *slave*: the AXI4 memory mapped traffic of the remote
# (mezzanine) FPGA comes out of its m_axi port and lands in the PS DDR. The AXI4-Lite
# channel runs the other way: the PS is the AXI4-Lite master of the remote peripherals.
# The parameters of the link are fixed by the link contract; the values that both boards
# must share are documented in docs/link_contract_deviations.md.
#
# Link status bits (axi_gpio_link channel 1, all inputs, and the same layout on the
# remote board):
#   bit0 channel_up          bit5 axi_c2c_multi_bit_error_out
#   bit1 lane_up             bit6 axi_c2c_config_error_out
#   bit2 gt_pll_lock         bit7 hard_err
#   bit3 axi_c2c_link_status bit8 soft_err
#   bit4 axi_c2c_link_error  bit9 mmcm_not_locked
#        (always 0: a C2C slave with an Aurora PHY has no link_error output)
#
# Link debug controls (axi_gpio_link channel 2, all outputs, reset value 0):
#   bit2:0 Aurora/GT loopback (000 normal, 010 near-end PMA loopback)
#   bit3   link reset request (1 = hold pma_init asserted; pulse it after a loopback change)
#
# Interrupts: axi_c2c_m2s_intr_out[3:0] -> pl_ps_irq0[3:0] (GIC SPI 89..92)
#             v_mix interrupt            -> pl_ps_irq0[4]   (GIC SPI 93)
#             v_tc irq                   -> pl_ps_irq0[5]   (GIC SPI 94)

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

################################################################
# Link parameters (see the link contract)
################################################################

# GT location of the SFP cage used for the link, per host board:
#   quad / lane : Aurora 64B/66B names of the GT quad and channel
#   refclk      : Aurora refclk selection. The Aurora GUI only offers the two refclk inputs
#                 of the GT's own quad. When the board's free-running refclk enters another
#                 quad, the same-numbered input of the GT's own quad is selected here and the
#                 refclk port is placed on the real pins by the constraints; Vivado then
#                 routes the clock over the dedicated north/south refclk routing.
dict set gt_dict zcu106 quad   Quad_X0Y2
dict set gt_dict zcu106 lane   X0Y10
dict set gt_dict zcu106 refclk MGTREFCLK1_of_Quad_X0Y2

if { ![dict exists $gt_dict $board_name] } {
  error "bd_zynqmp.tcl: no SFP GT location is defined for board '$board_name'"
}

# Line rate (Gbps) and GT reference clock (MHz): must be identical on both boards
set line_rate   10.3125
set refclk_mhz  156.25

################################################################
# Processor system
################################################################

# Add the Processor System and apply board preset
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1" }  [get_bd_cells zynq_ultra_ps_e_0]

# Configure the PS
#   M_AXI_HPM0_FPD (GP0) : register access, 32-bit region at 0xA000_0000
#   S_AXI_HP0_FPD  (GP2) : inbound DMA of the remote FPGA, 64-bit to match the C2C AXI width
#   S_AXI_HP3_FPD  (GP5) : video mixer layer reads from PS DDR (display path)
#   pl_clk0              : 100 MHz for AXI, the Aurora init clock and the GT DRP clock.
#                          FIXED BY THE LINK: the Aurora init/DRP clock and the C2C AXI
#                          clock must stay at 100 MHz, so the display path gets its own
#                          PS clock instead of re-purposing this one.
#   pl_clk1              : 250 MHz for the video mixer and its AXI ports. Taken from the PS
#                          rather than an MMCM so that no PL clocking resource is spent and
#                          pl_clk0 is left untouched (1500 MHz IOPLL / 6 = 250 MHz).
# DisplayPort: the PS DP controller drives the monitor over PS-GTR lanes (nothing to do with
# the PL GTH quad used by the link), AUX on MIO 27..30. PSU__USE__VIDEO enables the "live
# video" input so the PL video mixer output feeds the DP instead of the DPDMA.
# All the other peripherals of the board preset (DDR4, UART, SD, GEM3, I2C, ...) are kept.
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {64} \
  CONFIG.PSU__USE__S_AXI_GP5 {1} \
  CONFIG.PSU__SAXIGP5__DATA_WIDTH {128} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
  CONFIG.PSU__FPGA_PL1_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {250} \
  CONFIG.PSU__DISPLAYPORT__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__DISPLAYPORT__LANE0__ENABLE {1} \
  CONFIG.PSU__DISPLAYPORT__LANE0__IO {GT Lane1} \
  CONFIG.PSU__DISPLAYPORT__LANE1__ENABLE {1} \
  CONFIG.PSU__DISPLAYPORT__LANE1__IO {GT Lane0} \
  CONFIG.PSU__DPAUX__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__DPAUX__PERIPHERAL__IO {MIO 27 .. 30} \
  CONFIG.PSU__DP__LANE_SEL {Dual Lower} \
  CONFIG.PSU__DP__REF_CLK_FREQ {27} \
  CONFIG.PSU__DP__REF_CLK_SEL {Ref Clk3} \
  CONFIG.PSU__USE__VIDEO {1} \
  CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE {1} \
  CONFIG.PSU__GPIO_EMIO__PERIPHERAL__IO {2} \
] [get_bd_cells zynq_ultra_ps_e_0]

# Add a processor system reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps_100M
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins rst_ps_100M/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_ps_100M/ext_reset_in]

# PS AXI port clocks
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]

# Display clock domain (pl_clk1, 250 MHz) and its reset
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] [get_bd_pins zynq_ultra_ps_e_0/saxihp3_fpd_aclk]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_disp_250M
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] [get_bd_pins rst_disp_250M/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_disp_250M/ext_reset_in]

################################################################
# Aurora 64B/66B
################################################################

# Shared logic in the core: the core contains the IBUFDS_GTE4 of the refclk, the QPLL
# and the user clock BUFG_GTs. C_INIT_CLK is not set here: in a block design it is a
# read-only parameter that is propagated from the clock connected to init_clk. DRP_FREQ is
# a disabled parameter in this configuration (fixed at 100 MHz).
set aurora [create_bd_cell -type ip -vlnv xilinx.com:ip:aurora_64b66b aurora_64b66b_0]
set_property -dict [list \
  CONFIG.C_AURORA_LANES {1} \
  CONFIG.C_LINE_RATE $line_rate \
  CONFIG.C_REFCLK_FREQUENCY $refclk_mhz \
  CONFIG.dataflow_config {Duplex} \
  CONFIG.interface_mode {Streaming} \
  CONFIG.flow_mode {None} \
  CONFIG.crc_mode {false} \
  CONFIG.SupportLevel {1} \
  CONFIG.SINGLEEND_INITCLK {true} \
  CONFIG.C_START_QUAD [dict get $gt_dict $board_name quad] \
  CONFIG.C_START_LANE [dict get $gt_dict $board_name lane] \
  CONFIG.C_REFCLK_SOURCE [dict get $gt_dict $board_name refclk] \
] $aurora

# GT reference clock
set gt_refclk [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 gt_refclk]
set_property CONFIG.FREQ_HZ [expr {int($refclk_mhz*1000000)}] $gt_refclk
connect_bd_intf_net $gt_refclk [get_bd_intf_pins aurora_64b66b_0/GT_DIFF_REFCLK1]

# GT serial pins (SFP cage)
create_bd_intf_port -mode Master -vlnv xilinx.com:display_aurora64b66b:GT_Serial_Transceiver_Pins_TX_rtl:1.0 sfp_tx
connect_bd_intf_net [get_bd_intf_pins aurora_64b66b_0/GT_SERIAL_TX] [get_bd_intf_ports sfp_tx]
create_bd_intf_port -mode Slave -vlnv xilinx.com:display_aurora64b66b:GT_Serial_Transceiver_Pins_RX_rtl:1.0 sfp_rx
connect_bd_intf_net [get_bd_intf_ports sfp_rx] [get_bd_intf_pins aurora_64b66b_0/GT_SERIAL_RX]

# Init clock (also the GT DRP clock)
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins aurora_64b66b_0/init_clk]

# Unused control inputs
set const_low [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_low]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $const_low
connect_bd_net [get_bd_pins const_low/dout] [get_bd_pins aurora_64b66b_0/power_down]
connect_bd_net [get_bd_pins const_low/dout] [get_bd_pins aurora_64b66b_0/gt_rxcdrovrden_in]

################################################################
# AXI Chip2Chip (slave)
################################################################

#   C_MASTER_FPGA     0 : C2C slave (has the m_axi AXI4 master port)
#   C_INTERFACE_TYPE  2 : Aurora 64B/66B PHY  (0/1 = SelectIO SDR/DDR, 3 = Aurora 8B/10B)
#   C_INTERFACE_MODE  1 : Compact 2:1, the only setting that fits a 64-bit AXI data bus in ONE
#                         Aurora lane (Compact 1:1 makes C_AURORA_WIDTH 2 = a two lane, 128-bit
#                         stream). The IP picks 0 or 1 depending on the ORDER in which its
#                         parameters are set, so it is always set explicitly (and checked below).
#   C_INCLUDE_AXILITE 1 : this side has the AXI4-Lite *slave* port s_axi_lite (the Vivado GUI calls
#                         this "Master": the side where the AXI4-Lite master lives). The remote
#                         board uses 2 (port m_axi_lite).
#   C_M_AXI_ID_WIDTH / C_M_AXI_WUSER_WIDTH : must be equal to the C_AXI_ID_WIDTH / C_AXI_WUSER_WIDTH
#                         of the remote C2C master, which are propagated from its s_axi port.
set axi_c2c [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_chip2chip axi_c2c]
set_property -dict [list \
  CONFIG.C_MASTER_FPGA {0} \
  CONFIG.C_INTERFACE_TYPE {2} \
  CONFIG.C_AXI_BUS_TYPE {0} \
  CONFIG.C_AXI_DATA_WIDTH {64} \
  CONFIG.C_AXI_ADDR_WIDTH {32} \
  CONFIG.C_M_AXI_ID_WIDTH {6} \
  CONFIG.C_M_AXI_WUSER_WIDTH {4} \
  CONFIG.C_INTERRUPT_WIDTH {4} \
  CONFIG.C_ECC_ENABLE {true} \
  CONFIG.C_EN_AXI_LINK_HNDLR {false} \
  CONFIG.C_COMMON_CLK {0} \
  CONFIG.C_INCLUDE_AXILITE {1} \
] $axi_c2c
# Set on its own and last, so that no other parameter update can change it again
set_property -dict [list CONFIG.C_INTERFACE_MODE {1}] $axi_c2c

# AXI4-Stream between the C2C and the Aurora
connect_bd_intf_net [get_bd_intf_pins axi_c2c/AXIS_TX] [get_bd_intf_pins aurora_64b66b_0/USER_DATA_S_AXIS_TX]
connect_bd_intf_net [get_bd_intf_pins aurora_64b66b_0/USER_DATA_M_AXIS_RX] [get_bd_intf_pins axi_c2c/AXIS_RX]

# PHY clock, status and resets between the C2C and the Aurora
connect_bd_net [get_bd_pins aurora_64b66b_0/user_clk_out] [get_bd_pins axi_c2c/axi_c2c_phy_clk]
connect_bd_net [get_bd_pins aurora_64b66b_0/channel_up] [get_bd_pins axi_c2c/axi_c2c_aurora_channel_up]
connect_bd_net [get_bd_pins aurora_64b66b_0/mmcm_not_locked_out] [get_bd_pins axi_c2c/aurora_mmcm_not_locked]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_c2c/aurora_init_clk]
connect_bd_net [get_bd_pins axi_c2c/aurora_pma_init_out] [get_bd_pins aurora_64b66b_0/pma_init]
connect_bd_net [get_bd_pins axi_c2c/aurora_reset_pb] [get_bd_pins aurora_64b66b_0/reset_pb]

# AXI clocks and reset of the C2C
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_c2c/m_aclk]
connect_bd_net [get_bd_pins rst_ps_100M/peripheral_aresetn] [get_bd_pins axi_c2c/m_aresetn]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_c2c/s_axi_lite_aclk]

# No interrupts are sent to the remote board
set const_intr [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_intr]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $const_intr
connect_bd_net [get_bd_pins const_intr/dout] [get_bd_pins axi_c2c/axi_c2c_s2m_intr_in]

################################################################
# Register access: PS -> remote window + local link status GPIO
################################################################

#   M00 -> axi_c2c/s_axi_lite       (remote window)
#   M01 -> axi_gpio_link/S_AXI      (local link status)
#   M02 -> display_pipeline/s_axi_ctrl (video mixer, timing controller, pixel clock wizard)
set axi_smc_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_ctrl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] $axi_smc_ctrl
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_smc_ctrl/aclk]
connect_bd_net [get_bd_pins rst_ps_100M/peripheral_aresetn] [get_bd_pins axi_smc_ctrl/aresetn]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_smc_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_ctrl/M00_AXI] [get_bd_intf_pins axi_c2c/s_axi_lite]

# Link status / link debug GPIO
set axi_gpio_link [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_link]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {10} \
  CONFIG.C_ALL_INPUTS {1} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {4} \
  CONFIG.C_ALL_OUTPUTS_2 {1} \
  CONFIG.C_DOUT_DEFAULT_2 {0x00000000} \
] $axi_gpio_link
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_gpio_link/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ps_100M/peripheral_aresetn] [get_bd_pins axi_gpio_link/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_smc_ctrl/M01_AXI] [get_bd_intf_pins axi_gpio_link/S_AXI]

# Status bits (the order is fixed by the link contract)
set status_concat [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 status_concat]
set_property -dict [list CONFIG.NUM_PORTS {10}] $status_concat
connect_bd_net [get_bd_pins aurora_64b66b_0/channel_up] [get_bd_pins status_concat/In0]
connect_bd_net [get_bd_pins aurora_64b66b_0/lane_up] [get_bd_pins status_concat/In1]
connect_bd_net [get_bd_pins aurora_64b66b_0/gt_pll_lock] [get_bd_pins status_concat/In2]
connect_bd_net [get_bd_pins axi_c2c/axi_c2c_link_status_out] [get_bd_pins status_concat/In3]
connect_bd_net [get_bd_pins const_low/dout] [get_bd_pins status_concat/In4]
connect_bd_net [get_bd_pins axi_c2c/axi_c2c_multi_bit_error_out] [get_bd_pins status_concat/In5]
connect_bd_net [get_bd_pins axi_c2c/axi_c2c_config_error_out] [get_bd_pins status_concat/In6]
connect_bd_net [get_bd_pins aurora_64b66b_0/hard_err] [get_bd_pins status_concat/In7]
connect_bd_net [get_bd_pins aurora_64b66b_0/soft_err] [get_bd_pins status_concat/In8]
connect_bd_net [get_bd_pins aurora_64b66b_0/mmcm_not_locked_out] [get_bd_pins status_concat/In9]
connect_bd_net [get_bd_pins status_concat/dout] [get_bd_pins axi_gpio_link/gpio_io_i]

# Debug controls: loopback[2:0] and the link reset request
set slice_loopback [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_loopback]
set_property -dict [list CONFIG.DIN_WIDTH {4} CONFIG.DIN_FROM {2} CONFIG.DIN_TO {0}] $slice_loopback
connect_bd_net [get_bd_pins axi_gpio_link/gpio2_io_o] [get_bd_pins slice_loopback/Din]
connect_bd_net [get_bd_pins slice_loopback/Dout] [get_bd_pins aurora_64b66b_0/loopback]

set slice_link_reset [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 slice_link_reset]
set_property -dict [list CONFIG.DIN_WIDTH {4} CONFIG.DIN_FROM {3} CONFIG.DIN_TO {3}] $slice_link_reset
connect_bd_net [get_bd_pins axi_gpio_link/gpio2_io_o] [get_bd_pins slice_link_reset/Din]

# pma_init of the link = system reset OR link reset request. The C2C sequences the
# pma_init and reset_pb of the Aurora from this input.
set or_pma_init [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilvector_logic:1.0 or_pma_init]
set_property -dict [list CONFIG.C_OPERATION {or} CONFIG.C_SIZE {1}] $or_pma_init
connect_bd_net [get_bd_pins rst_ps_100M/peripheral_reset] [get_bd_pins or_pma_init/Op1]
connect_bd_net [get_bd_pins slice_link_reset/Dout] [get_bd_pins or_pma_init/Op2]
connect_bd_net [get_bd_pins or_pma_init/Res] [get_bd_pins axi_c2c/aurora_pma_init_in]

################################################################
# Inbound DMA: remote FPGA -> PS DDR
################################################################

# The only master is the m_axi port of the C2C and the only slave is the PS, so no
# interconnect is needed, only an address filter: the AXI MMU passes the window that is
# assigned in the address map (PS DDR low) and answers everything else with DECERR, so the
# remote FPGA can never reach the PS peripherals, the OCM or the PL address ranges.
# (A SmartConnect is not used here: it only accepts a WUSER width that is a multiple of the
# WDATA byte count, and the 4-bit WUSER of the C2C m_axi port is part of the link contract.)
set axi_mmu_ddr [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_mmu axi_mmu_ddr]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins axi_mmu_ddr/aclk]
connect_bd_net [get_bd_pins rst_ps_100M/peripheral_aresetn] [get_bd_pins axi_mmu_ddr/aresetn]
connect_bd_intf_net [get_bd_intf_pins axi_c2c/m_axi] [get_bd_intf_pins axi_mmu_ddr/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_mmu_ddr/M_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

################################################################
# Display pipeline: DDR -> video mixer -> PS DisplayPort live video
################################################################

# Everything the monitor needs lives in this hierarchy:
#
#   v_mix          two memory layers, one per remote camera, read straight out of the CMA
#                  buffers that the remote v_frmbuf_wr filled. Layer format 20 ("RGB8") is
#                  packed 24-bit R,G,B = DRM_FORMAT_BGR888 = V4L2 RGB24, byte for byte what
#                  /dev/video0 and /dev/video1 deliver, so kmssink needs no conversion.
#                  Layer 0 (the master/background streaming layer) is tied off: the mixer
#                  paints its background colour register behind the two camera windows.
#   v_tc           1080p60 timing generator (the mode the DRM driver programs at run time)
#   v_axi4s_vid_out  AXI4-Stream -> native video, asynchronous (mixer clock -> pixel clock)
#   clk_wiz        pixel clock, dynamically reconfigured by the DRM driver over AXI4-Lite
#
# The mixer cannot downscale (its layers only upsample), so two 1080p windows do not fit on a
# 1080p screen at full size. The remote VPSS is a scaler, so the downscaling is done there at
# run time (media-ctl): capture each camera at 960x540 and the two windows sit side by side.
# The layers are still sized for 1920x1080 so a single camera can be shown full screen.
proc create_display_pipeline { } {

  set hier_obj [create_bd_cell -type hier display_pipeline]
  current_bd_instance $hier_obj

  # Interface pins
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M00_AXI
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi_ctrl

  # Pins
  create_bd_pin -dir I -type clk clk
  create_bd_pin -dir I -type rst resetn
  create_bd_pin -dir I -type clk s_axi_aclk
  create_bd_pin -dir I -type rst s_axi_aresetn
  create_bd_pin -dir I -type rst ext_reset_in
  create_bd_pin -dir I -from 1 -to 0 emio_gpio
  create_bd_pin -dir O -type intr irq_vmix
  create_bd_pin -dir O -type intr irq_v_tc
  create_bd_pin -dir O vid_active_video
  create_bd_pin -dir O -from 35 -to 0 vid_data
  create_bd_pin -dir O vid_hsync
  create_bd_pin -dir O vid_vsync
  create_bd_pin -dir O -type clk video_clk

  ##############################################################
  # Video mixer
  ##############################################################

  # NR_LAYERS 3 = master layer 0 (streaming, tied off) + layer 1 (CAM0) + layer 2 (CAM2).
  # VIDEO_FORMAT 0 = RGB on the master layer, which is what the Linux driver turns into
  # MEDIA_BUS_FMT_RGB888_1X24 and offers to the DisplayPort bridge; the DP live video input
  # accepts exactly that, so no colour space conversion happens anywhere in the path.
  set v_mix_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:v_mix v_mix_0]
  set_property -dict [list \
    CONFIG.NR_LAYERS {3} \
    CONFIG.VIDEO_FORMAT {0} \
    CONFIG.LAYER1_VIDEO_FORMAT {20} \
    CONFIG.LAYER2_VIDEO_FORMAT {20} \
    CONFIG.LAYER1_MAX_WIDTH {1920} \
    CONFIG.LAYER2_MAX_WIDTH {1920} \
    CONFIG.MAX_COLS {1920} \
    CONFIG.MAX_ROWS {1080} \
    CONFIG.SAMPLES_PER_CLOCK {1} \
  ] $v_mix_0

  ##############################################################
  # Timing generator and AXI4-Stream to native video
  ##############################################################

  # 1080p60: 2200 x 1125 total, 1920 x 1080 active, 148.5 MHz pixel clock.
  set v_tc_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:v_tc v_tc_0]
  set_property -dict [list \
    CONFIG.VIDEO_MODE {1080p} \
    CONFIG.GEN_HACTIVE_SIZE {1920} \
    CONFIG.GEN_HFRAME_SIZE {2200} \
    CONFIG.GEN_HSYNC_START {2008} \
    CONFIG.GEN_HSYNC_END {2052} \
    CONFIG.GEN_VACTIVE_SIZE {1080} \
    CONFIG.GEN_F0_VFRAME_SIZE {1125} \
    CONFIG.GEN_F0_VSYNC_VSTART {1083} \
    CONFIG.GEN_F0_VSYNC_VEND {1088} \
    CONFIG.GEN_F1_VFRAME_SIZE {1125} \
    CONFIG.GEN_F1_VSYNC_VSTART {1083} \
    CONFIG.GEN_F1_VSYNC_VEND {1088} \
    CONFIG.enable_detection {false} \
    CONFIG.max_clocks_per_line {8192} \
  ] $v_tc_0

  # C_S_AXIS_VIDEO_FORMAT 2 = RGB (3 components). With an 8-bit native component width the
  # native output bus vid_data is 24 bits: one byte per component, component 0 in the LSBs.
  # C_HAS_ASYNC_CLK 1 puts a FIFO between the mixer clock and the pixel clock.
  set v_axi4s_vid_out_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:v_axi4s_vid_out v_axi4s_vid_out_0]
  set_property -dict [list \
    CONFIG.C_HAS_ASYNC_CLK {1} \
    CONFIG.C_NATIVE_COMPONENT_WIDTH {8} \
    CONFIG.C_S_AXIS_VIDEO_FORMAT {2} \
    CONFIG.C_VTG_MASTER_SLAVE {1} \
  ] $v_axi4s_vid_out_0

  ##############################################################
  # Pixel clock
  ##############################################################

  # USE_DYN_RECONFIG puts an AXI4-Lite port on the wizard: the Linux clocking-wizard driver
  # reprograms the MMCM to the pixel clock of whatever mode the monitor and the DRM driver
  # agree on (148.5 MHz for 1080p60). The frequency requested here is only the power-up value.
  # With USE_DYN_RECONFIG the wizard has no separate reset port at all: the reset
  # parameters become disabled parameters and s_axi_aresetn resets the whole core.
  # (This is why the rpi-camera-fmc reference leaves its display clock wizard's
  # reset unconnected.)
  set clk_wiz_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0]
  set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {148.500} \
    CONFIG.USE_DYN_RECONFIG {true} \
    CONFIG.USE_LOCKED {true} \
  ] $clk_wiz_0

  # Reset of the pixel clock domain, released when the MMCM locks
  set proc_sys_reset_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset proc_sys_reset_0]

  ##############################################################
  # AXI interconnects
  ##############################################################

  # Control: one 100 MHz slave from the PS, three masters. The mixer is an HLS core, so its
  # AXI4-Lite port runs in the same clock domain as its datapath (250 MHz) - the interconnect
  # does that clock crossing. The timing controller and the clock wizard stay at 100 MHz.
  set axi_ic_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_ctrl]
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] $axi_ic_ctrl

  # Memory: the two mixer layer read ports -> one master to the PS HP3 port
  set axi_ic_mm [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_mm]
  set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $axi_ic_mm

  ##############################################################
  # Constants and slices
  ##############################################################

  # Master layer 0 is a streaming layer and nothing drives it: hold TVALID (and TDATA) low so
  # the mixer shows its background colour behind the camera layers.
  set const_low_24 [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_low_24]
  set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {24}] $const_low_24

  set const_high [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_high]
  set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] $const_high

  set const_low_4 [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_low_4]
  set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {4}] $const_low_4

  # Split the 24-bit native video bus into its three 8-bit components
  foreach {name from to} {slice_comp0 7 0 slice_comp1 15 8 slice_comp2 23 16} {
    set s [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 $name]
    set_property -dict [list CONFIG.DIN_WIDTH {24} CONFIG.DIN_FROM $from CONFIG.DIN_TO $to \
      CONFIG.DOUT_WIDTH {8}] $s
  }

  # The PS DisplayPort live video input is 36 bits = three 12-bit components, component 0 in
  # the LSBs. Our components are 8 bit, so each one is left-justified in its 12-bit field and
  # the four low bits of each field are tied low.
  #
  # The two buses do NOT use the same component order, which is why this is a re-order and
  # not a straight pass-through:
  #
  #   * the Xilinx video IP stream carries "RGB" as R-B-G - green in the LOW byte. That is
  #     MEDIA_BUS_FMT_RBG888_1X24 (note R-B-G), the bus format the legacy xlnx_bridge path
  #     reports for an RGB mixer master layer, and it is what v_axi4s_vid_out puts on the
  #     native bus: native[23:16] = R, native[15:8] = B, native[7:0] = G.
  #   * the DisplayPort live input wants MEDIA_BUS_FMT_RGB888_1X24, i.e. R in the top field
  #     and B in the bottom one: field 0 = B, field 1 = G, field 2 = R. That is the format
  #     the mixer's DRM-bridge path advertises to zynqmp-dpsub.
  #
  # So green and blue have to cross over and red stays put:
  #   vid_data[11:0]  = { native[15:8],  4'b0 }   field 0 = B
  #   vid_data[23:12] = { native[7:0],   4'b0 }   field 1 = G
  #   vid_data[35:24] = { native[23:16], 4'b0 }   field 2 = R
  #
  # Measured on hardware (2026-09-20): with the two lower slices connected straight through,
  # a red/green/blue/white bar frame in DDR came out of the monitor as red/BLUE/GREEN/white -
  # red correct, green and blue exchanged. See docs/source/display.md.
  set vid_concat [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 vid_concat]
  set_property -dict [list \
    CONFIG.NUM_PORTS {6} \
    CONFIG.IN0_WIDTH {4} CONFIG.IN1_WIDTH {8} \
    CONFIG.IN2_WIDTH {4} CONFIG.IN3_WIDTH {8} \
    CONFIG.IN4_WIDTH {4} CONFIG.IN5_WIDTH {8} \
  ] $vid_concat

  ##############################################################
  # Interface connections
  ##############################################################

  connect_bd_intf_net [get_bd_intf_pins s_axi_ctrl] [get_bd_intf_pins axi_ic_ctrl/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ctrl/M00_AXI] [get_bd_intf_pins v_mix_0/s_axi_CTRL]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ctrl/M01_AXI] [get_bd_intf_pins v_tc_0/ctrl]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ctrl/M02_AXI] [get_bd_intf_pins clk_wiz_0/s_axi_lite]

  connect_bd_intf_net [get_bd_intf_pins v_mix_0/m_axi_mm_video1] [get_bd_intf_pins axi_ic_mm/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins v_mix_0/m_axi_mm_video2] [get_bd_intf_pins axi_ic_mm/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_mm/M00_AXI] [get_bd_intf_pins M00_AXI]

  connect_bd_intf_net [get_bd_intf_pins v_mix_0/m_axis_video] [get_bd_intf_pins v_axi4s_vid_out_0/video_in]
  connect_bd_intf_net [get_bd_intf_pins v_tc_0/vtiming_out] [get_bd_intf_pins v_axi4s_vid_out_0/vtiming_in]

  ##############################################################
  # Clocks and resets
  ##############################################################

  # Mixer clock domain (250 MHz)
  foreach p {v_mix_0/ap_clk v_axi4s_vid_out_0/aclk \
             axi_ic_mm/ACLK axi_ic_mm/S00_ACLK axi_ic_mm/S01_ACLK axi_ic_mm/M00_ACLK \
             axi_ic_ctrl/M00_ACLK} {
    connect_bd_net [get_bd_pins clk] [get_bd_pins $p]
  }
  foreach p {v_axi4s_vid_out_0/aresetn \
             axi_ic_mm/ARESETN axi_ic_mm/S00_ARESETN axi_ic_mm/S01_ARESETN axi_ic_mm/M00_ARESETN \
             axi_ic_ctrl/M00_ARESETN} {
    connect_bd_net [get_bd_pins resetn] [get_bd_pins $p]
  }

  # The video mixer is reset from PS EMIO GPIO bit 0 (= Linux gpio 78: EMIO starts at 78).
  # The xlnx-mixer driver REQUIRES a "reset-gpios" property and pulses the line low then
  # high in probe, so the mixer reset has to be a GPIO the PS can drive - a proc_sys_reset
  # would leave the driver with nothing to claim and its probe would fail with
  # "No reset gpio info from dts for mixer". The device tree property is generated from
  # this connection. At power-up the EMIO output is low, i.e. the mixer is held in reset
  # until Linux probes it.
  set reset_vmix [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilslice:1.0 reset_vmix]
  set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0} \
    CONFIG.DOUT_WIDTH {1}] $reset_vmix
  connect_bd_net [get_bd_pins emio_gpio] [get_bd_pins reset_vmix/Din]
  connect_bd_net [get_bd_pins reset_vmix/Dout] [get_bd_pins v_mix_0/ap_rst_n]

  # AXI4-Lite clock domain (100 MHz)
  foreach p {v_tc_0/s_axi_aclk clk_wiz_0/s_axi_aclk clk_wiz_0/clk_in1 \
             axi_ic_ctrl/ACLK axi_ic_ctrl/S00_ACLK axi_ic_ctrl/M01_ACLK axi_ic_ctrl/M02_ACLK} {
    connect_bd_net [get_bd_pins s_axi_aclk] [get_bd_pins $p]
  }
  foreach p {v_tc_0/s_axi_aresetn clk_wiz_0/s_axi_aresetn \
             axi_ic_ctrl/ARESETN axi_ic_ctrl/S00_ARESETN axi_ic_ctrl/M01_ARESETN axi_ic_ctrl/M02_ARESETN} {
    connect_bd_net [get_bd_pins s_axi_aresetn] [get_bd_pins $p]
  }

  # Pixel clock domain
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins video_clk]
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins v_axi4s_vid_out_0/vid_io_out_clk]
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins v_tc_0/clk]
  connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins proc_sys_reset_0/dcm_locked]
  connect_bd_net [get_bd_pins ext_reset_in] [get_bd_pins proc_sys_reset_0/ext_reset_in]
  connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins v_tc_0/resetn]
  connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_reset] [get_bd_pins v_axi4s_vid_out_0/vid_io_out_reset]

  ##############################################################
  # Remaining port connections
  ##############################################################

  # Tie off the streaming master layer
  connect_bd_net [get_bd_pins const_low_24/dout] [get_bd_pins v_mix_0/s_axis_video_TDATA]
  connect_bd_net [get_bd_pins const_low_24/dout] [get_bd_pins v_mix_0/s_axis_video_TVALID]

  # Clock enables
  foreach p {v_axi4s_vid_out_0/aclken v_axi4s_vid_out_0/vid_io_out_ce \
             v_tc_0/clken v_tc_0/s_axi_aclken} {
    connect_bd_net [get_bd_pins const_high/dout] [get_bd_pins $p]
  }

  # Timing handshake between the video-out converter and the timing controller
  connect_bd_net [get_bd_pins v_axi4s_vid_out_0/sof_state_out] [get_bd_pins v_tc_0/sof_state]
  connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vtg_ce] [get_bd_pins v_tc_0/gen_clken]

  # Native video out -> the 36-bit DisplayPort live video bus
  connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_data] [get_bd_pins slice_comp0/Din]
  connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_data] [get_bd_pins slice_comp1/Din]
  connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_data] [get_bd_pins slice_comp2/Din]
  connect_bd_net [get_bd_pins const_low_4/dout] [get_bd_pins vid_concat/In0]
  # field 0 = B = native[15:8]; field 1 = G = native[7:0]  (the R-B-G / R-G-B crossover
  # explained above - swapping these two lines is the whole colour-order fix)
  connect_bd_net [get_bd_pins slice_comp1/Dout] [get_bd_pins vid_concat/In1]
  connect_bd_net [get_bd_pins const_low_4/dout] [get_bd_pins vid_concat/In2]
  connect_bd_net [get_bd_pins slice_comp0/Dout] [get_bd_pins vid_concat/In3]
  connect_bd_net [get_bd_pins const_low_4/dout] [get_bd_pins vid_concat/In4]
  connect_bd_net [get_bd_pins slice_comp2/Dout] [get_bd_pins vid_concat/In5]
  connect_bd_net [get_bd_pins vid_concat/dout] [get_bd_pins vid_data]

  connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_active_video] [get_bd_pins vid_active_video]
  connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_hsync] [get_bd_pins vid_hsync]
  connect_bd_net [get_bd_pins v_axi4s_vid_out_0/vid_vsync] [get_bd_pins vid_vsync]

  # Interrupts
  connect_bd_net [get_bd_pins v_mix_0/interrupt] [get_bd_pins irq_vmix]
  connect_bd_net [get_bd_pins v_tc_0/irq] [get_bd_pins irq_v_tc]

  current_bd_instance /
}

create_display_pipeline

# Control interface, memory interface, clocks and resets of the hierarchy
connect_bd_intf_net [get_bd_intf_pins axi_smc_ctrl/M02_AXI] [get_bd_intf_pins display_pipeline/s_axi_ctrl]
connect_bd_intf_net -boundary_type upper [get_bd_intf_pins display_pipeline/M00_AXI] \
  [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP3_FPD]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk1] [get_bd_pins display_pipeline/clk]
connect_bd_net [get_bd_pins rst_disp_250M/peripheral_aresetn] [get_bd_pins display_pipeline/resetn]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins display_pipeline/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ps_100M/peripheral_aresetn] [get_bd_pins display_pipeline/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_ps_100M/peripheral_aresetn] [get_bd_pins display_pipeline/ext_reset_in]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/emio_gpio_o] [get_bd_pins display_pipeline/emio_gpio]

# Native video and pixel clock to the PS DisplayPort live video input
connect_bd_net [get_bd_pins display_pipeline/vid_active_video] [get_bd_pins zynq_ultra_ps_e_0/dp_live_video_in_de]
connect_bd_net [get_bd_pins display_pipeline/vid_data] [get_bd_pins zynq_ultra_ps_e_0/dp_live_video_in_pixel1]
connect_bd_net [get_bd_pins display_pipeline/vid_hsync] [get_bd_pins zynq_ultra_ps_e_0/dp_live_video_in_hsync]
connect_bd_net [get_bd_pins display_pipeline/vid_vsync] [get_bd_pins zynq_ultra_ps_e_0/dp_live_video_in_vsync]
connect_bd_net [get_bd_pins display_pipeline/video_clk] [get_bd_pins zynq_ultra_ps_e_0/dp_video_in_clk]

################################################################
# Interrupts from the remote board and from the display pipeline
################################################################

# Through a concat so that more interrupt sources can be added later.
#   In0 = axi_c2c_m2s_intr_out[3:0] -> pl_ps_irq0[3:0], GIC SPI 89..92 (the link contract)
#   In1 = video mixer               -> pl_ps_irq0[4],   GIC SPI 93
#   In2 = timing controller         -> pl_ps_irq0[5],   GIC SPI 94
set intr_concat [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 intr_concat]
set_property -dict [list CONFIG.NUM_PORTS {3}] $intr_concat
connect_bd_net [get_bd_pins axi_c2c/axi_c2c_m2s_intr_out] [get_bd_pins intr_concat/In0]
connect_bd_net [get_bd_pins display_pipeline/irq_vmix] [get_bd_pins intr_concat/In1]
connect_bd_net [get_bd_pins display_pipeline/irq_v_tc] [get_bd_pins intr_concat/In2]
connect_bd_net [get_bd_pins intr_concat/dout] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

################################################################
# SFP control and LEDs
################################################################

# SFP TX disable: the board net is active low at the FPGA pin (SFPx_TX_DISABLE_B), so it is
# driven high to enable the transmitter
set const_high [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_high]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $const_high
create_bd_port -dir O sfp_tx_disable_b
connect_bd_net [get_bd_pins const_high/dout] [get_bd_ports sfp_tx_disable_b]

# LEDs: Aurora channel up, C2C link up, GT PLL locked
create_bd_port -dir O led_channel_up
connect_bd_net [get_bd_pins aurora_64b66b_0/channel_up] [get_bd_ports led_channel_up]
create_bd_port -dir O led_link_up
connect_bd_net [get_bd_pins axi_c2c/axi_c2c_link_status_out] [get_bd_ports led_link_up]
create_bd_port -dir O led_pll_lock
connect_bd_net [get_bd_pins aurora_64b66b_0/gt_pll_lock] [get_bd_ports led_pll_lock]

################################################################
# Addresses
################################################################

# PS -> remote window (the addresses pass through the link unchanged) and local GPIO
assign_bd_address -offset 0xA0000000 -range 0x01000000 \
  -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  [get_bd_addr_segs axi_c2c/s_axi_lite/Reg] -force
assign_bd_address -offset 0xA1000000 -range 0x00010000 \
  -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  [get_bd_addr_segs axi_gpio_link/S_AXI/Reg] -force

# Display pipeline registers. Kept above the 16 MB remote window (0xA000_0000) and the link
# status GPIO (0xA100_0000) so that neither has to move if the display path grows.
assign_bd_address -offset 0xA2000000 -range 0x00010000 \
  -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  [get_bd_addr_segs display_pipeline/v_mix_0/s_axi_CTRL/Reg] -force
assign_bd_address -offset 0xA2010000 -range 0x00010000 \
  -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  [get_bd_addr_segs display_pipeline/v_tc_0/ctrl/Reg] -force
assign_bd_address -offset 0xA2020000 -range 0x00010000 \
  -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  [get_bd_addr_segs display_pipeline/clk_wiz_0/s_axi_lite/Reg] -force

# The two video mixer layer read ports see PS DDR low only (the frame buffers are CMA in the
# low 2 GB). Everything else the HP3 port can reach is excluded, as for the remote FPGA.
foreach space {Data_m_axi_mm_video1 Data_m_axi_mm_video2} {
  set addr_space [get_bd_addr_spaces display_pipeline/v_mix_0/$space]
  assign_bd_address -offset 0x00000000 -range 0x80000000 \
    -target_address_space $addr_space \
    [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP5/HP3_DDR_LOW] -force
  foreach seg [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/SAXIGP5/*] {
    if { [get_property NAME $seg] ne "HP3_DDR_LOW" } {
      exclude_bd_addr_seg -quiet -target_address_space $addr_space $seg
    }
  }
}

# Remote FPGA -> PS DDR low (2 GB, mapped 1:1). Everything else that the HP0 port can reach
# is excluded: the remote FPGA has 32-bit addresses and must only reach the DDR.
assign_bd_address -offset 0x00000000 -range 0x80000000 \
  -target_address_space [get_bd_addr_spaces axi_c2c/MAXI] \
  [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW] -force
foreach seg [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/SAXIGP2/*] {
  if { [get_property NAME $seg] ne "HP0_DDR_LOW" } {
    exclude_bd_addr_seg -target_address_space [get_bd_addr_spaces axi_c2c/MAXI] $seg
  }
}

# Restore current instance
current_bd_instance $oldCurInst

validate_bd_design

# Link parameters that must be identical on both boards: report them in the build log and
# stop if the tools changed one of them
foreach p {C_MASTER_FPGA C_INTERFACE_TYPE C_INTERFACE_MODE C_INCLUDE_AXILITE C_AURORA_WIDTH \
           C_AXI_DATA_WIDTH C_AXI_ADDR_WIDTH C_M_AXI_ID_WIDTH C_M_AXI_WUSER_WIDTH \
           C_INTERRUPT_WIDTH C_ECC_ENABLE C_EN_AXI_LINK_HNDLR} {
  puts "INFO: \[link\] axi_c2c $p = [get_property CONFIG.$p $axi_c2c]"
}
foreach p {C_AURORA_LANES C_LINE_RATE C_REFCLK_FREQUENCY interface_mode flow_mode crc_mode \
           C_START_QUAD C_START_LANE C_REFCLK_SOURCE C_INIT_CLK DRP_FREQ} {
  puts "INFO: \[link\] aurora  $p = [get_property CONFIG.$p $aurora]"
}
if { [get_property CONFIG.C_INTERFACE_MODE $axi_c2c] != 1 } {
  error "axi_c2c C_INTERFACE_MODE is [get_property CONFIG.C_INTERFACE_MODE $axi_c2c], the link contract needs 1 (Compact 2:1)"
}
if { [get_property CONFIG.C_AURORA_WIDTH $axi_c2c] != 1 } {
  error "axi_c2c needs [get_property CONFIG.C_AURORA_WIDTH $axi_c2c] Aurora lanes, the link has one"
}

save_bd_design
