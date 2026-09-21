# Opsero Electronic Design Inc. Copyright 2026
#
# Project build script
#
# This script requires the target name to be specified upon launch. This can be done
# in two ways:
#
#   1. Using a single argument passed to the script via tclargs.
#      eg. vivado -mode batch -source build.tcl -notrace -tclargs <target-name>
#
#   2. By setting the target variable before sourcing the script.
#      eg. set target <target-name>
#          source build.tcl -notrace
#
# For a list of possible targets, see below.
#
# The targets of this repo are NOT alternative variants: they are the two halves of one
# two-board system, and both must be built:
#
#   * role "host"      - the board with the processor (runs Linux, controls the system)
#   * role "mezzanine" - the processor-less FPGA board that carries the cameras
#
# Variables that the block design scripts (src/bd/bd_<bd_script>.tcl) can rely on:
#
#   target         target label, also the Vivado project name    (eg. zcu106 | auboard)
#   design_name    same as target
#   block_name     name of the block design                      (c2c)
#   board_url      board vendor as used in the board part        (eg. xilinx.com | avnet-tria)
#   board_name     board name as used in the board part          (eg. zcu106 | auboard_15p)
#   proj_board     full board part that was selected
#   fpga_part      device part of the board                      (eg. xcau15p-ffvb676-2-e)
#   cams           list of RPi Camera FMC ports with a pipeline  (eg. {0 2})
#   bd_script      block design script suffix                    (zynqmp | fpga)
#   role           role of the target in the system              (host | mezzanine)
#   mipi_loc_dict  MIPI pin LOCs of the mezzanine target(s), see src/bd/mipi_locs.tcl
#   origin_dir     the Vivado directory of the repo (".")
#
#*****************************************************************************************

# Check the version of Vivado used
set version_required "2025.2"
set ver [lindex [split $::env(XILINX_VIVADO) /] end-1]
if {![string equal $ver $version_required]} {
  puts "###############################"
  puts "### Failed to build project ###"
  puts "###############################"
  puts "This project was designed for use with Vivado $version_required."
  puts "You are using Vivado $ver. Please install Vivado $version_required,"
  puts "or download the project sources from a commit of the Git repository"
  puts "that was intended for your version of Vivado ($ver)."
  return
}

# Add Xilinx board store to the repo paths
set_param board.repoPaths [get_property LOCAL_ROOT_DIR [xhub::get_xstores xilinx_board_store]]

# Possible targets
# Each target is described by: { board_url board_name { cams } bd_script role }
# (generated from config/data.json by config/update.py - do not edit by hand)
# UPDATER START
dict set target_dict zcu106 { xilinx.com zcu106 { 0 2 } zynqmp host }
dict set target_dict auboard { avnet-tria auboard_15p { 0 2 } fpga mezzanine }
# UPDATER END

# Function to display the options and get user input
proc selectTarget {target_dict} {
    # Create a list to hold the keys in order
    set keys_list [dict keys $target_dict]
    set keys_list [lsort $keys_list]

    # Forever loop until we break it when the user confirms their selection
    while {1} {
        # Initialize a counter for the numbering
        set counter 0

        # Display options
        puts "Possible target designs:"
        foreach key $keys_list {
            incr counter
            puts "  $counter: $key"
        }

        # Ask for user input
        set user_choice -1
        while {($user_choice < 1) || ($user_choice > $counter)} {
            puts -nonewline "Choose target design (1-$counter): "
            flush stdout
            gets stdin user_choice

            # Check if the input is a valid number
            if {![string is integer -strict $user_choice]} {
                set user_choice -1
                continue
            }
        }

        # Confirm selection
        set selected_key [lindex $keys_list [expr {$user_choice - 1}]]
        puts -nonewline "Confirm selection '$selected_key' (Y/n): "
        flush stdout
        gets stdin confirmation

        # Check confirmation
        if {[string match -nocase "y*" $confirmation] || [string equal -length 1 "" $confirmation]} {
            # If the user confirmed, return the selected key
            return $selected_key
        }
    }
}

# Target can be specified by creating the target variable before sourcing, or in the command line arguments
if { [info exists target] } {
  if { ![dict exists $target_dict $target] } {
    puts "Invalid target specified: $target"
    exit 1
  }
} elseif { $argc == 0 } {
  set target [selectTarget $target_dict]
} else {
  set target [lindex $argv 0]
  if { ![dict exists $target_dict $target] } {
    puts "Invalid target specified: $target"
    exit 1
  }
}

# At this point of the script, we are guaranteed to have a valid target
puts "Target design: $target"

set design_name ${target}
set block_name c2c
set board_url [lindex [dict get $target_dict $target] 0]
set board_name [lindex [dict get $target_dict $target] 1]
set cams [lindex [dict get $target_dict $target] 2]
set bd_script [lindex [dict get $target_dict $target] 3]
set role [lindex [dict get $target_dict $target] 4]

# Set the reference directory for source file relative paths (by default the value is script directory path)
set origin_dir "."

# Check that the sources of the target exist before a project is created, so that a
# missing file never leaves a half-made project behind
set xdc_path "$origin_dir/src/constraints/${target}.xdc"
set bd_script_path "$origin_dir/src/bd/bd_${bd_script}.tcl"
# (a Tcl error ends a batch run with a non-zero exit code, but leaves a GUI session open)
foreach required_file [list $xdc_path $bd_script_path] {
  if {![file exists $required_file]} {
    puts "ERROR: Required source file not found: $required_file"
    error "Required source file not found: $required_file"
  }
}

# Append Avnet bdf to the board repo paths (needed for Auboard)
set_param board.repoPaths [concat [get_param board.repoPaths] [list [file normalize "../submodules/avnet-bdf"]]]
set proj_board [get_board_parts "$board_url:$board_name:*" -latest_file_version]
# Check if the board files are installed, if not, install them
if { $proj_board == "" } {
    puts "Failed to find board files for $board_name. Installing board files..."
    xhub::refresh_catalog [xhub::get_xstores xilinx_board_store]
    xhub::install [xhub::get_xitems $board_url:xilinx_board_store:$board_name*]
    set proj_board [get_board_parts "$board_url:$board_name:*" -latest_file_version]
} else {
    puts "Board files found for $board_name"
}

set fpga_part [get_property PART_NAME [get_board_parts $proj_board]]

# Set the directory path for the original project from where this script was exported
set orig_proj_dir "[file normalize "$origin_dir/$design_name"]"

# Create project
create_project $design_name $origin_dir/$design_name -part ${fpga_part}

# Set the directory path for the new project
set proj_dir [get_property directory [current_project]]

# Set project properties
# (no Vitis extensible-platform properties: neither target is an acceleration platform,
#  the XSAs are fixed hardware hand-offs)
set_property board_part $proj_board [current_project]

# Create 'sources_1' fileset (if not found)
if {[string equal [get_filesets -quiet sources_1] ""]} {
  create_fileset -srcset sources_1
}

# Set 'sources_1' fileset properties
set obj [get_filesets sources_1]
set_property -name "top" -value "${block_name}_wrapper" -objects $obj

# Create 'constrs_1' fileset (if not found)
if {[string equal [get_filesets -quiet constrs_1] ""]} {
  create_fileset -constrset constrs_1
}

# Set 'constrs_1' fileset object
set obj [get_filesets constrs_1]

# Add/Import constrs file and set constrs file properties
set file "[file normalize "$origin_dir/src/constraints/${target}.xdc"]"
set file_added [add_files -norecurse -fileset $obj $file]
set file "$origin_dir/src/constraints/${target}.xdc"
set file [file normalize $file]
set file_obj [get_files -of_objects [get_filesets constrs_1] [list "*$file"]]
set_property "file_type" "XDC" $file_obj

# Set 'constrs_1' fileset properties
set obj [get_filesets constrs_1]
set_property "target_constrs_file" "[file normalize "$origin_dir/src/constraints/${target}.xdc"]" $obj

# Create 'sim_1' fileset (if not found)
if {[string equal [get_filesets -quiet sim_1] ""]} {
  create_fileset -simset sim_1
}

# Set 'sim_1' fileset object
set obj [get_filesets sim_1]
# Empty (no sources present)

# Set 'sim_1' fileset properties
set obj [get_filesets sim_1]
set_property -name "top" -value "${block_name}_wrapper" -objects $obj

# Create 'synth_1' run (if not found)
if {[string equal [get_runs -quiet synth_1] ""]} {
  create_run -name synth_1 -part ${fpga_part} -flow {Vivado Synthesis 2025} -strategy "Vivado Synthesis Defaults" -report_strategy {No Reports} -constrset constrs_1
} else {
  set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]
  set_property flow "Vivado Synthesis 2025" [get_runs synth_1]
}
set obj [get_runs synth_1]

# set the current synth run
current_run -synthesis [get_runs synth_1]

# Create 'impl_1' run (if not found)
if {[string equal [get_runs -quiet impl_1] ""]} {
  create_run -name impl_1 -part ${fpga_part} -flow {Vivado Implementation 2025} -strategy "Vivado Implementation Defaults" -report_strategy {No Reports} -constrset constrs_1 -parent_run synth_1
} else {
  set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]
  set_property flow "Vivado Implementation 2025" [get_runs impl_1]
}
set obj [get_runs impl_1]
set_property -name "steps.write_bitstream.args.readback_file" -value "0" -objects $obj
set_property -name "steps.write_bitstream.args.verbose" -value "0" -objects $obj

# set the current impl run
current_run -implementation [get_runs impl_1]

puts "INFO: Project created:${design_name}"

# Add the RTL sources (src/hdl/) to the project. The block design scripts instantiate them as
# module references, so they must be in the project before the block design is created.
set hdl_files [lsort [glob -nocomplain -directory $origin_dir/src/hdl *.v *.sv *.vhd]]
if { [llength $hdl_files] > 0 } {
  add_files -norecurse -fileset [get_filesets sources_1] $hdl_files
}

# Create the MIPI LOC dictionary that is used by the block design script
source $origin_dir/src/bd/mipi_locs.tcl

# Create block design
# A failure here must not look like a success: the partial block design is saved so that
# it can be inspected in the Vivado GUI, and the script ends with a Tcl error (in batch
# mode Vivado then exits with a non-zero code, which the build runner reports).
if {[catch {source $bd_script_path} errmsg]} {
    puts "ERROR: Block design creation failed: $errmsg"
    puts "ERROR: The partial project was kept for inspection: $orig_proj_dir"
    puts "ERROR: Remove it before the next attempt: ./build.sh clean --target $target --stage project"
    catch {save_bd_design}
    close_project
    error "Block design creation failed: $errmsg"
}

# Generate the wrapper
make_wrapper -files [get_files *${block_name}.bd] -top
add_files -norecurse ${design_name}/${design_name}.gen/sources_1/bd/${block_name}/hdl/${block_name}_wrapper.v

# Update the compile order
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Ensure parameter propagation has been performed
close_bd_design [current_bd_design]
open_bd_design [get_files ${block_name}.bd]
validate_bd_design -force
save_bd_design

