# Opsero Electronic Design Inc. Copyright 2026
#
# Constraints for the "auboard" target: Tria AUBoard 15P (xcau15p-ffvb676-2-e), the
# processor-less mezzanine of the MIPI over Chip2Chip system.
#
# Pin sources: Avnet board definition files (submodules/avnet-bdf/aub15p/1.1) and the
# AUBoard 15P hardware user guide (SFP+ side band signals, which are not in the board files).

########################################################################################
# System clock and reset
########################################################################################

# SYS_CLK: 300 MHz LVDS oscillator on GC pins of bank 64 (VCCO 1.2 V)
set_property PACKAGE_PIN AD21 [get_ports sys_clk_300mhz_clk_p]
set_property PACKAGE_PIN AE21 [get_ports sys_clk_300mhz_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports sys_clk_300mhz_clk_p]
set_property IOSTANDARD DIFF_SSTL12 [get_ports sys_clk_300mhz_clk_n]

# The clock wizard IP defines SYS_CLK with a period of 3.333 ns. Periods have a resolution of
# 1 ps, so that is 300.03 MHz: 100 ppm FAST. The MIPI D-PHY cores run their PLL at the very top
# of its range (200 MHz x 15 / 2 = 1500 MHz, fixed by the IP); with the fast clock the tools
# compute 1500.15 MHz and raise two critical warnings (DRC AVAL-350, FVCO out of range) for a
# PLL that really runs at 1500.000 MHz. The clock is therefore redefined here, rounded UP
# (3.334 ns: 1499.7 MHz, the check passes). That period is 0.02 % longer than the real one; the
# 3 ps of setup uncertainty give the difference back to the timing analysis (it is 2 ps for the
# slowest clock, the 100 MHz one). The input jitter is the value of the clock wizard IP.
create_clock -name sys_clk_300mhz_clk_p -period 3.334 [get_ports sys_clk_300mhz_clk_p]
set_input_jitter [get_clocks sys_clk_300mhz_clk_p] 0.033
set_clock_uncertainty -setup 0.003 [get_clocks -include_generated_clocks sys_clk_300mhz_clk_p]

# SYS_RST_N: reset push button, active low (bank 65)
set_property PACKAGE_PIN V19 [get_ports system_resetn]
set_property IOSTANDARD LVCMOS12 [get_ports system_resetn]

########################################################################################
# SFP+ cage: Aurora 64B/66B lane
########################################################################################

# The SFP+ cage is wired to GT quad 226, channel 3 = GTHE4_CHANNEL_X0Y11. The channel LOC
# comes from the constraints of the Aurora IP (C_START_QUAD/C_START_LANE in bd_fpga.tcl) and
# agrees with these pins.
set_property PACKAGE_PIN G5 [get_ports {sfp_tx_txp[0]}]
set_property PACKAGE_PIN G4 [get_ports {sfp_tx_txn[0]}]
set_property PACKAGE_PIN F2 [get_ports {sfp_rx_rxp[0]}]
set_property PACKAGE_PIN F1 [get_ports {sfp_rx_rxn[0]}]

# GT reference clock: 156.25 MHz from the programmable clock generator of the board (U57),
# which outputs this frequency at power-up without any programming.
#
# NOTE - the reference clock is NOT in the quad of the SFP+ transceiver. It enters the device
# on MGTREFCLK1 of quad 224 (GTHE4_COMMON_X0Y0), two quads SOUTH of quad 226, which is the
# furthest that UltraScale+ allows. The Aurora IP only offers the reference clocks of its own
# quad, so bd_fpga.tcl selects "MGTREFCLK1 of Quad_X0Y2" and the pins below move the clock
# input buffer (IBUFDS_GTE4) to where the clock really is. The design connects the buffer to
# GTREFCLK0/GTREFCLK01 of the transceiver primitives as for a clock of the same quad; Vivado
# routes it over the dedicated north-bound reference clock lines (through quad 225) and swaps
# it onto the GTNORTHREFCLK inputs of the transceiver by itself. Do not LOC the buffer or the
# GTHE4_COMMON, and do not change the reference clock selection of the core.
set_property PACKAGE_PIN Y7 [get_ports sfp_refclk_clk_p]
set_property PACKAGE_PIN Y6 [get_ports sfp_refclk_clk_n]
create_clock -name sfp_refclk -period 6.400 [get_ports sfp_refclk_clk_p]

# SFP+ side band signals
# TX_DISABLE (bank 65): low = transmitter enabled, the same as fitting jumper J17
set_property PACKAGE_PIN N22 [get_ports sfp_tx_disable]
set_property IOSTANDARD LVCMOS12 [get_ports sfp_tx_disable]
# TX_FAULT (bank 65): high = fault
set_property PACKAGE_PIN V26 [get_ports sfp_tx_fault]
set_property IOSTANDARD LVCMOS12 [get_ports sfp_tx_fault]
# LOS (bank 85): high = loss of signal
set_property PACKAGE_PIN E10 [get_ports sfp_los]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_los]

########################################################################################
# User LEDs (red, active high, bank 85)
########################################################################################

# leds[0] = LED1: axi_gpio_sys ch1 bit 0          leds[2] = LED3: AXI Chip2Chip link up
# leds[1] = LED2: axi_gpio_sys ch1 bit 1          leds[3] = LED4: Aurora channel up
set_property PACKAGE_PIN A10 [get_ports {leds[0]}]
set_property PACKAGE_PIN B10 [get_ports {leds[1]}]
set_property PACKAGE_PIN B11 [get_ports {leds[2]}]
set_property PACKAGE_PIN C11 [get_ports {leds[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[*]}]

########################################################################################
# RPi Camera FMC (OP068) on the FMC connector: CAM0 and CAM2
########################################################################################

# Pins and IO standards are those of the rpi-camera-fmc reference design for this board
# (cross-checked against the pin constraints of the FPGA Board Repository for OP068 + AUBoard).
# The FMC pins are in bank 66 (HP) and bank 86 (HD), both powered by the FMC VADJ rail.

# I2C of the cameras (one bus per camera, no multiplexer)
set_property PACKAGE_PIN M21 [get_ports iic_0_scl_io]; # LA03_N
set_property PACKAGE_PIN M20 [get_ports iic_0_sda_io]; # LA03_P
set_property IOSTANDARD LVCMOS12 [get_ports iic_0_*]
set_property SLEW SLOW [get_ports iic_0_*]
set_property DRIVE 4 [get_ports iic_0_*]

set_property PACKAGE_PIN C13 [get_ports iic_2_scl_io]; # LA30_N
set_property PACKAGE_PIN C14 [get_ports iic_2_sda_io]; # LA30_P
set_property IOSTANDARD LVCMOS12 [get_ports iic_2_*]
set_property SLEW SLOW [get_ports iic_2_*]
set_property DRIVE 4 [get_ports iic_2_*]

# Camera IO pins: gpio0 = IO0 (camera enable of the Raspberry Pi cameras), gpio1 = IO1
set_property PACKAGE_PIN K18 [get_ports mipi_0_gpio0]; # LA12_N
set_property PACKAGE_PIN L18 [get_ports mipi_0_gpio1]; # LA12_P
set_property IOSTANDARD LVCMOS12 [get_ports mipi_0_gpio0]
set_property IOSTANDARD LVCMOS12 [get_ports mipi_0_gpio1]

set_property PACKAGE_PIN E23 [get_ports mipi_2_gpio0]; # LA19_N
set_property PACKAGE_PIN F23 [get_ports mipi_2_gpio1]; # LA19_P
set_property IOSTANDARD LVCMOS12 [get_ports mipi_2_gpio0]
set_property IOSTANDARD LVCMOS12 [get_ports mipi_2_gpio1]

# Clock switches of CAM1 and CAM3 (constant 01b, the cameras of this design have no switch)
set_property PACKAGE_PIN H13 [get_ports {clk_sel[0]}]; # LA25_N  CAM1_CLK_SEL
set_property PACKAGE_PIN J13 [get_ports {clk_sel[1]}]; # LA25_P  CAM3_CLK_SEL
set_property IOSTANDARD LVCMOS12 [get_ports {clk_sel[*]}]

# Reserved pins and the control pins of the level translators of the camera IO pins
# (constant 0x030: translators enabled, direction FPGA -> camera)
set_property PACKAGE_PIN J19 [get_ports {rsvd_gpio[0]}]; # LA04_P
set_property PACKAGE_PIN J20 [get_ports {rsvd_gpio[1]}]; # LA04_N
set_property PACKAGE_PIN J12 [get_ports {rsvd_gpio[2]}]; # LA07_P
set_property PACKAGE_PIN H12 [get_ports {rsvd_gpio[3]}]; # LA07_N
set_property PACKAGE_PIN K22 [get_ports {rsvd_gpio[4]}]; # LA13_P  CAM_IO0_DIR
set_property PACKAGE_PIN K23 [get_ports {rsvd_gpio[5]}]; # LA13_N  CAM_IO1_DIR
set_property PACKAGE_PIN J15 [get_ports {rsvd_gpio[6]}]; # LA27_P  CAM_IO0_OE_N
set_property PACKAGE_PIN J14 [get_ports {rsvd_gpio[7]}]; # LA27_N  CAM_IO1_OE_N
set_property PACKAGE_PIN D14 [get_ports {rsvd_gpio[8]}]; # LA29_P
set_property PACKAGE_PIN D13 [get_ports {rsvd_gpio[9]}]; # LA29_N
set_property IOSTANDARD LVCMOS12 [get_ports {rsvd_gpio[*]}]

# MIPI CSI-2, CAM0 (the same pins are given to the MIPI IP in src/bd/mipi_locs.tcl)
set_property PACKAGE_PIN F24 [get_ports {mipi_phy_if_0_clk_p}]; # LA00_CC_P
set_property PACKAGE_PIN F25 [get_ports {mipi_phy_if_0_clk_n}]; # LA00_CC_N
set_property PACKAGE_PIN D26 [get_ports {mipi_phy_if_0_data_p[0]}]; # LA06_P
set_property PACKAGE_PIN C26 [get_ports {mipi_phy_if_0_data_n[0]}]; # LA06_N
set_property PACKAGE_PIN H26 [get_ports {mipi_phy_if_0_data_p[1]}]; # LA02_P
set_property PACKAGE_PIN G26 [get_ports {mipi_phy_if_0_data_n[1]}]; # LA02_N

set_property IOSTANDARD MIPI_DPHY_DCI [get_ports mipi_phy_if_0_clk_p]
set_property IOSTANDARD MIPI_DPHY_DCI [get_ports mipi_phy_if_0_clk_n]
set_property IOSTANDARD MIPI_DPHY_DCI [get_ports mipi_phy_if_0_data_p[*]]
set_property IOSTANDARD MIPI_DPHY_DCI [get_ports mipi_phy_if_0_data_n[*]]

set_property DIFF_TERM_ADV TERM_100 [get_ports mipi_phy_if_0_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports mipi_phy_if_0_clk_n]
set_property DIFF_TERM_ADV TERM_100 [get_ports mipi_phy_if_0_data_p[*]]
set_property DIFF_TERM_ADV TERM_100 [get_ports mipi_phy_if_0_data_n[*]]

# MIPI CSI-2, CAM2
set_property PACKAGE_PIN G24 [get_ports {mipi_phy_if_2_clk_p}]; # LA18_CC_P
set_property PACKAGE_PIN G25 [get_ports {mipi_phy_if_2_clk_n}]; # LA18_CC_N
set_property PACKAGE_PIN H23 [get_ports {mipi_phy_if_2_data_p[0]}]; # LA24_P
set_property PACKAGE_PIN H24 [get_ports {mipi_phy_if_2_data_n[0]}]; # LA24_N
set_property PACKAGE_PIN J25 [get_ports {mipi_phy_if_2_data_p[1]}]; # LA17_CC_P
set_property PACKAGE_PIN J26 [get_ports {mipi_phy_if_2_data_n[1]}]; # LA17_CC_N

set_property IOSTANDARD MIPI_DPHY_DCI [get_ports mipi_phy_if_2_clk_p]
set_property IOSTANDARD MIPI_DPHY_DCI [get_ports mipi_phy_if_2_clk_n]
set_property IOSTANDARD MIPI_DPHY_DCI [get_ports mipi_phy_if_2_data_p[*]]
set_property IOSTANDARD MIPI_DPHY_DCI [get_ports mipi_phy_if_2_data_n[*]]

set_property DIFF_TERM_ADV TERM_100 [get_ports mipi_phy_if_2_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports mipi_phy_if_2_clk_n]
set_property DIFF_TERM_ADV TERM_100 [get_ports mipi_phy_if_2_data_p[*]]
set_property DIFF_TERM_ADV TERM_100 [get_ports mipi_phy_if_2_data_n[*]]

########################################################################################
# Timing exceptions
########################################################################################

# The clocks of the Aurora core (derived from sfp_refclk) and the clocks of the clock wizard
# (derived from SYS_CLK) come from two independent oscillators. The IP cores constrain their
# own clock domain crossings. The crossings of the RTL in src/hdl/ are constrained here.

# (c2c_i is the instance of the block design in the wrapper, <cell>/inst the RTL module of a
# module reference cell.)

# bit_sync (status_sync): the first flop of every synchroniser takes an asynchronous input
set_false_path -to [get_pins {c2c_i/status_sync/inst/sync0_reg[*]/D}]

# freq_counter: the two toggle synchronisers
set_false_path -to [get_pins {c2c_i/freq_counter/inst/gate_sync_reg[0]/D}]
set_false_path -to [get_pins {c2c_i/freq_counter/inst/cap_sync_reg[0]/D}]

# freq_counter: the captured count is stable for several cycles before it is sampled in the
# 100 MHz domain. Bound the delay of the bus to one period of the faster clock.
set_max_delay -datapath_only 6.000 \
  -from [get_cells {c2c_i/freq_counter/inst/cap_reg[*]}] \
  -to   [get_cells {c2c_i/freq_counter/inst/freq_hz_reg[*]}]

# pipe_gpio (one per video pipeline): the reset bits of the AXI GPIO (100 MHz domain) enter a
# synchroniser in the video clock domain
set_false_path -to [get_pins {c2c_i/mipi_*/pipe_gpio/inst/sync0_reg[*]/D}]

# Asynchronous board signals
set_false_path -from [get_ports system_resetn]
set_false_path -to [get_ports {leds[*]}]
# Camera enable / IO pins (static GPIO outputs) and the I2C buses of the cameras (100 kHz)
set_false_path -to [get_ports {mipi_*_gpio0 mipi_*_gpio1}]
set_false_path -to [get_ports {iic_*_scl_io iic_*_sda_io}]
set_false_path -from [get_ports {iic_*_scl_io iic_*_sda_io}]

########################################################################################
# Configuration
########################################################################################

# The device boots from a 512 Mb quad SPI flash (Master SPI x4)
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 31.9 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
