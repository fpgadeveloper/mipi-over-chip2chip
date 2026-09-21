# Opsero Electronic Design Inc. Copyright 2026
#
# Constraints for the ZCU106 host target of the mipi-over-chip2chip system
#
# The chip-to-chip link uses the SFP0 cage: GTH Quad 225, channel 2 = GTHE4_CHANNEL_X0Y10.

#------------------------------------------------------------------------------------------
# GT reference clock
#------------------------------------------------------------------------------------------
# USER_MGT_SI570_CLOCK1: 156.25 MHz at power-up, no programming needed (Si570 U56 through the
# Si53340 buffer U51). The pins U10/U9 are MGTREFCLK1 of Quad 226, ONE QUAD NORTH of the SFP0 GT
# (Quad 225): no free-running clock enters Quad 225 itself. The Aurora core is configured for
# MGTREFCLK1 of its own quad; placing the clock port on the real pins moves the IBUFDS_GTE4 of
# the core to GTHE4_COMMON_X0Y3, and Vivado routes its output to the QPLL of Quad 225 over the
# dedicated south reference clock routing (a GTH refclk can be shared up to two quads away).
set_property PACKAGE_PIN U10 [get_ports gt_refclk_clk_p]
set_property PACKAGE_PIN U9  [get_ports gt_refclk_clk_n]
create_clock -name gt_refclk -period 6.400 [get_ports gt_refclk_clk_p]

#------------------------------------------------------------------------------------------
# SFP0 serial pins (the GT channel itself is placed by the constraints of the Aurora core)
#------------------------------------------------------------------------------------------
set_property PACKAGE_PIN Y4  [get_ports {sfp_tx_txp[0]}]
set_property PACKAGE_PIN Y3  [get_ports {sfp_tx_txn[0]}]
set_property PACKAGE_PIN AA2 [get_ports {sfp_rx_rxp[0]}]
set_property PACKAGE_PIN AA1 [get_ports {sfp_rx_rxn[0]}]

#------------------------------------------------------------------------------------------
# SFP0 TX disable
#------------------------------------------------------------------------------------------
# SFP0_TX_DISABLE_B, bank 65 (1.2V). Active low at the FPGA pin: driven high by the design to
# enable the transmitter of the module. (With the default jumper fitted the transmitter is
# enabled whatever the FPGA drives, and a passive DAC cable has no transmitter to disable.)
set_property PACKAGE_PIN AE22 [get_ports sfp_tx_disable_b]
set_property IOSTANDARD LVCMOS12 [get_ports sfp_tx_disable_b]

#------------------------------------------------------------------------------------------
# User LEDs (bank 66, 1.2V)
#------------------------------------------------------------------------------------------
# GPIO_LED_0: Aurora channel up
set_property PACKAGE_PIN AL11 [get_ports led_channel_up]
set_property IOSTANDARD LVCMOS12 [get_ports led_channel_up]
# GPIO_LED_1: AXI Chip2Chip link up
set_property PACKAGE_PIN AL13 [get_ports led_link_up]
set_property IOSTANDARD LVCMOS12 [get_ports led_link_up]
# GPIO_LED_2: GT PLL locked (the 156.25 MHz reference clock is present)
set_property PACKAGE_PIN AK13 [get_ports led_pll_lock]
set_property IOSTANDARD LVCMOS12 [get_ports led_pll_lock]

#------------------------------------------------------------------------------------------
# Timing exceptions
#------------------------------------------------------------------------------------------
# The LEDs and the SFP control pin are static / asynchronous
set_false_path -to [get_ports {led_channel_up led_link_up led_pll_lock sfp_tx_disable_b}]

# The link status bits come from other clock domains (the Aurora user clock). They are read
# through the input synchronizer of the AXI GPIO, an XPM CDC that brings its own timing
# exception, so no constraint is needed here.
