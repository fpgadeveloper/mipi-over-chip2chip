
# Opsero Electronic Design Inc. Copyright 2025

# MIPI pin LOC constraints are required in the configuration of the MIPI subsystem IPs.
# The following code constructs a nested dictionary that contains the MIPI pin assignments
# for each target board, which is then used by the script that builds the block diagram.

# To use the dictionary:
#   * Get the bank number:          dict get <target> <interface> bank
#   * Get the clk_p pin:            dict get <target> <interface> clk pin
#   * Get the clk_p pin name:       dict get <target> <interface> clk pin_name
#   * Get the data<0-1>_p pin:      dict get <target> <interface> data<0-1> pin
#   * Get the data<0-1>_p pin name: dict get <target> <interface> data<0-1> pin_name

# Only the mezzanine target (the board that carries the RPi Camera FMC) has MIPI pins. The host
# target has no entry in this dictionary. All four camera ports of the FMC are listed, the block
# design only uses the ports of the target's "cams" list (see config/data.json).
# These values are copied unchanged from the rpi-camera-fmc reference design.

dict set mipi_loc_dict auboard 0 bank 66
dict set mipi_loc_dict auboard 0 clk { pin F24 pin_name IO_L16P_T2U_N6_QBC_AD3P_66 }
dict set mipi_loc_dict auboard 0 data0 { pin D26 pin_name IO_L23P_T3U_N8_66 }
dict set mipi_loc_dict auboard 0 data1 { pin H26 pin_name IO_L17P_T2U_N8_AD10P_66 }
dict set mipi_loc_dict auboard 1 bank 66
dict set mipi_loc_dict auboard 1 clk { pin L24 pin_name IO_L10P_T1U_N6_QBC_AD4P_66 }
dict set mipi_loc_dict auboard 1 data0 { pin K21 pin_name IO_L5P_T0U_N8_AD14P_66 }
dict set mipi_loc_dict auboard 1 data1 { pin L20 pin_name IO_L6P_T0U_N10_AD6P_66 }
dict set mipi_loc_dict auboard 2 bank 66
dict set mipi_loc_dict auboard 2 clk { pin G24 pin_name IO_L13P_T2L_N0_GC_QBC_66 }
dict set mipi_loc_dict auboard 2 data0 { pin H23 pin_name IO_L14P_T2L_N2_GC_66 }
dict set mipi_loc_dict auboard 2 data1 { pin J25 pin_name IO_L15P_T2L_N4_AD11P_66 }
dict set mipi_loc_dict auboard 3 bank 66
dict set mipi_loc_dict auboard 3 clk { pin L22 pin_name IO_L7P_T1L_N0_QBC_AD13P_66 }
dict set mipi_loc_dict auboard 3 data0 { pin M25 pin_name IO_L8P_T1L_N2_AD5P_66 }
dict set mipi_loc_dict auboard 3 data1 { pin K25 pin_name IO_L9P_T1L_N4_AD12P_66 }
