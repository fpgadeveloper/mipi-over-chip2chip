# Opsero Electronic Design Inc. Copyright 2026
#
# This script runs synthesis, implementation and exports the hardware for a project.
#
# This script requires the target name and number of jobs to be specified upon launch.
# It can be lauched in two ways:
#
#   1. Using three arguments passed to the script via tclargs.
#      eg. vivado -mode batch -source xsa.tcl -notrace -tclargs <target-name> <jobs> <synth_only>
#
#   2. By setting the target variables before sourcing the script.
#      eg. set target <target-name>
#          set jobs <number-of-jobs>
#          source xsa.tcl -notrace
#
# Outputs (all in the project directory of the target, Vivado/<target>/):
#
#   c2c_wrapper.xsa                        exported hardware, bitstream included. This is
#                                          also produced for the processor-less target: it is
#                                          the artifact that the build runner looks for, and
#                                          it carries the bitstream and the hardware hand-off.
#   <target>.runs/impl_1/c2c_wrapper.bit   the bitstream
#   reports/timing_summary.rpt             report_timing_summary of the routed design
#   reports/utilization.rpt                report_utilization of the routed design
#   reports/utilization_hier.rpt           hierarchical utilization (per video pipeline)
#
# The timing result is also printed to the log on a single line:
#
#   TIMING: WNS=<ns> TNS=<ns> WHS=<ns> THS=<ns> TPWS=<ns> (MET|FAILED)
#
# When timing is not met, a "CRITICAL WARNING:" line is printed as well, so that the build
# runner flags it in its summary.
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

if { $argc == 3 } {
  set target [lindex $argv 0]
  puts "Target for the build: $target"
  set jobs [lindex $argv 1]
  puts "Number of jobs: $jobs"
  set synth_only [lindex $argv 2]
  puts "Synthesis only: $synth_only"
} elseif { [info exists target] } {
  puts "Target for the build: $target"
  if { ![info exists jobs] } {
    set jobs 8
  }
  if { ![info exists synth_only] } {
    set synth_only 0
  }
} else {
  puts ""
  puts "This script runs synthesis, implementation and exports the hardware for a project."
  puts "It can be launched in two ways:"
  puts ""
  puts "  1. Using three arguments passed to the script via tclargs."
  puts "     eg. vivado -mode batch -source xsa.tcl -notrace -tclargs <target-name> <jobs> <synth_only>"
  puts ""
  puts "  2. By setting the target variables before sourcing the script."
  puts "     eg. set target <target-name>"
  puts "         set jobs <number-of-jobs>"
  puts "         set synth_only <synth-only>"
  puts "         source xsa.tcl -notrace"
  return
}

# The build runner passes "false"; accept any Tcl boolean (0/1/true/false/yes/no)
if { ![string is boolean -strict $synth_only] } {
  puts "ERROR: synth_only must be a boolean, got: $synth_only"
  error "synth_only must be a boolean, got: $synth_only"
}
set synth_only [expr {$synth_only ? 1 : 0}]

set design_name ${target}
set block_name c2c

# Set the reference directory for source file relative paths (by default the value is script directory path)
set origin_dir "."

# Set the directory path for the original project from where this script was exported
set orig_proj_dir "[file normalize "$origin_dir/$design_name"]"

# Check that a run has completed, otherwise stop with an error that is visible in the log
# (a Tcl error ends a batch run with a non-zero exit code, which the build runner reports)
proc check_run {run_name} {
  set run [get_runs $run_name]
  set progress [get_property PROGRESS $run]
  set status [get_property STATUS $run]
  if { $progress != "100%" } {
    puts "ERROR: Run $run_name did not complete (progress: $progress, status: $status)"
    puts "ERROR: See the log of the run: [get_property DIRECTORY $run]/runme.log"
    error "Run $run_name failed: $status"
  }
  puts "INFO: Run $run_name completed: $status"
}

# Open project
open_project $origin_dir/$design_name/$design_name.xpr

# A project without the block design wrapper is the left-over of a failed project build
if { [llength [get_files -quiet ${block_name}_wrapper.v]] == 0 } {
  puts "ERROR: Project $design_name has no ${block_name}_wrapper.v: the block design was not created."
  puts "ERROR: Remove the project and build it again: ./build.sh clean --target $target --stage project"
  error "Project $design_name is incomplete"
}

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
check_run synth_1
if {$synth_only == 1} {
  write_hw_platform -force -file $origin_dir/$design_name/${block_name}_wrapper.xsa
} else {
  launch_runs impl_1 -jobs $jobs -to_step write_bitstream
  wait_on_run impl_1
  check_run impl_1
  write_hw_platform -fixed -include_bit -force -file $origin_dir/$design_name/${block_name}_wrapper.xsa
}
  validate_hw_platform -verbose $origin_dir/$design_name/${block_name}_wrapper.xsa

# Timing and utilization reports of the routed design, written to a fixed location. This is
# done after the hardware export so that the export itself is identical to the other Opsero
# reference designs. (The implementation run also leaves its default reports in
# <target>.runs/impl_1/.)
if {$synth_only != 1} {
  # Timing statistics of the implementation run
  set impl_run [get_runs impl_1]
  foreach stat {WNS TNS WHS THS TPWS} {
    set timing($stat) [get_property -quiet STATS.$stat $impl_run]
  }

  set report_dir $origin_dir/$design_name/reports
  file mkdir $report_dir
  if {[catch {
    open_run impl_1
    report_timing_summary -max_paths 10 -file $report_dir/timing_summary.rpt
    report_utilization -file $report_dir/utilization.rpt
    report_utilization -hierarchical -hierarchical_depth 3 -file $report_dir/utilization_hier.rpt
    # If the run did not record its statistics, read the worst slacks from the routed design
    if { ![string is double -strict $timing(WNS)] } {
      set timing(WNS) [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
    }
    if { ![string is double -strict $timing(WHS)] } {
      set timing(WHS) [get_property SLACK [get_timing_paths -hold -max_paths 1 -nworst 1]]
    }
  } errmsg]} {
    puts "WARNING: Could not write the timing/utilization reports: $errmsg"
  } else {
    puts "INFO: Reports written to [file normalize $report_dir]"
  }

  # Timing is met when the worst setup, hold and pulse width slacks are not negative.
  # A setup or hold slack that cannot be read is reported as a failure: an unknown timing
  # result must not pass silently.
  set timing_met 1
  foreach stat {WNS WHS} {
    if { ![string is double -strict $timing($stat)] || $timing($stat) < 0 } {
      set timing_met 0
    }
  }
  if { [string is double -strict $timing(TPWS)] && $timing(TPWS) < 0 } {
    set timing_met 0
  }
  set stats {}
  foreach stat {WNS TNS WHS THS TPWS} {
    if { $timing($stat) eq "" } { set timing($stat) "unknown" }
    lappend stats "$stat=$timing($stat)"
  }
  if { $timing_met } {
    puts "TIMING: [join $stats { }] (MET) target=$target"
  } else {
    puts "TIMING: [join $stats { }] (FAILED) target=$target"
    puts "CRITICAL WARNING: \[Opsero-Timing\] Target $target did not meet timing ([join $stats { }]). See $report_dir/timing_summary.rpt"
  }
}

