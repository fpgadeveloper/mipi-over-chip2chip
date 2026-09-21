# Opsero Electronic Design Inc. Copyright 2026
#
# Run the bare-metal camera demo on the ZCU106 over JTAG, and pull the captured frames
# out of the PS DDR afterwards.
#
# It does the same job as booting BOOT.BIN from the SD card, but without touching the
# card: system reset -> program the PL -> PMU firmware -> the REAL FSBL -> release the
# PS-PL isolation and pl_resetn0 -> the application. The FSBL only removes the isolation
# and releases pl_resetn0 when it loads the bitstream itself, which it does not do here,
# so the script calls the two psu_init.tcl procs for that by hand (see do_run) - without
# them no PL slave answers and the first AXI read of the application hangs the A53.
# The FSBL (not the Tcl psu_init of zcu106_init.tcl) is used on purpose:
# after a Tcl-only psu_init, block reads of the PS DDR on this board have been seen to
# end in an "AP transaction timeout" that costs a power cycle, and this script has to do
# a 6 MB block read at the end.
#
# Usage (from any directory):
#
#   xsdb zcu106_baremetal.tcl [options] [command]
#
# Commands:
#   run                  reset, program, boot the application and leave it running (default)
#   dump                 only dump frames from a board that is already running the demo
#   run+dump             "run", wait for the capture, then dump  (the usual one)
#
# Options:
#   -ws <dir>       Vitis workspace   (default ../../Vitis/zcu106_workspace, relative to
#                   this script)
#   -app <name>     application component name              (default cam_test)
#   -plat <name>    platform component name                 (default zcu106_platform)
#   -bit <file>     bitstream             (default: the .bit out of the ZCU106 XSA)
#   -xsa <file>     ZCU106 XSA            (default ../../Vivado/zcu106/c2c_wrapper.xsa)
#   -url <url>      hw_server to connect to                 (default tcp:127.0.0.1:3121)
#   -cable <pat>    part of the name of the JTAG cable      (default "FT232H 11093")
#   -out <dir>      where the frame dumps go                (default ./frames)
#   -addr0 <a>      DDR address of the CAM0 frame to dump   (default 0x20000000)
#   -addr2 <a>      DDR address of the CAM2 frame to dump   (default 0x22000000)
#   -width <n>      frame width in pixels                   (default 1920)
#   -height <n>     frame height in lines                   (default 1080)
#   -wait <s>       seconds to wait after the application starts before dumping (default 25)
#   -pmufw <file>   PMU firmware ELF (default: the one the platform exports, see below)
#   -nopmufw        skip the PMU firmware (it is only needed once after a power cycle)
#
# THE ADDRESSES TO DUMP DO NOT HAVE TO BE GIVEN. Which slot a frame is frozen in depends
# on how many frames were captured, so the application publishes the geometry and the
# frozen address of each camera in a small block in DDR at 0x1FFF0000 and the dump reads
# it (see read_app_info below and Vitis/common/src/remote.h). -addr0 / -addr2 are the
# fallback for a board whose application is not at that point yet; they are also what the
# UART prints ("frozen frame").
#
# The application STOPS its frame buffer writers on a frame boundary and switches the
# sensors off before it idles, so the frames in DDR are static and a dump cannot tear.
#
# WHAT CAN HANG, AND HOW TO GET OUT OF IT
#   - The application refuses to touch the remote window while the link is down, so the
#     usual cause of a hung debug access port is gone. If the AUBoard is reset or
#     re-programmed WHILE the application runs, the next access still hangs the A53 and
#     the PS debug access port reports as "DAP (AXI AP transaction error ...)".
#     Recovery: power-cycle the ZCU106 (a system reset does not reliably clear it).
#   - Never soft-reboot after a PL DMA wedge on this board; power-cycle.
#
# The script connects to a hw_server that is ALREADY RUNNING and only selects targets of
# the JTAG cable that matches the pattern, so the AUBoard on the same hw_server is
# untouched.
#
#*****************************************************************************************

set here [file dirname [file normalize [info script]]]
set repo [file normalize [file join $here .. ..]]

set url      tcp:127.0.0.1:3121
set cable    "FT232H 11093"
set ws       [file join $repo Vitis zcu106_workspace]
set appname  cam_test
set platname zcu106_platform
set bitfile  ""
set xsafile  [file join $repo Vivado zcu106 c2c_wrapper.xsa]
set outdir   "frames"
set addr0    0x20000000
set addr2    0x22000000
set width    1920
set height   1080
set waitsec  25
set dopmufw  1
set pmufile  ""
set command  "run+dump"

set positional {}
for {set i 0} {$i < [llength $argv]} {incr i} {
  set arg [lindex $argv $i]
  switch -- $arg {
    -url      { incr i; set url      [lindex $argv $i] }
    -cable    { incr i; set cable    [lindex $argv $i] }
    -ws       { incr i; set ws       [lindex $argv $i] }
    -app      { incr i; set appname  [lindex $argv $i] }
    -plat     { incr i; set platname [lindex $argv $i] }
    -bit      { incr i; set bitfile  [lindex $argv $i] }
    -xsa      { incr i; set xsafile  [lindex $argv $i] }
    -out      { incr i; set outdir   [lindex $argv $i] }
    -addr0    { incr i; set addr0    [lindex $argv $i] }
    -addr2    { incr i; set addr2    [lindex $argv $i] }
    -width    { incr i; set width    [lindex $argv $i] }
    -height   { incr i; set height   [lindex $argv $i] }
    -wait     { incr i; set waitsec  [lindex $argv $i] }
    -pmufw    { incr i; set pmufile  [lindex $argv $i] }
    -nopmufw  { set dopmufw 0 }
    default   { lappend positional $arg }
  }
}
if { [llength $positional] > 0 } { set command [lindex $positional 0] }
if { [lsearch -exact {run dump run+dump} $command] < 0 } {
  puts "ERROR: unknown command '$command' (run | dump | run+dump)"
  exit 1
}

#-----------------------------------------------------------------------------------------
# Locate the artifacts of the Vitis workspace
#-----------------------------------------------------------------------------------------

set elffile   [file join $ws $appname build $appname.elf]
set swdir     [file join $ws $platname export $platname sw]
set fsblfile  [file join $swdir boot fsbl.elf]

proc need {what path} {
  if { ![file exists $path] } {
    puts "ERROR: $what not found: $path"
    puts "       Build it first:  ./build.sh standalone --target zcu106"
    exit 1
  }
}

if { $command ne "dump" } {
  need "application ELF" $elffile
  need "FSBL"            $fsblfile

  # PMU firmware. A bare-metal platform does not generate one into sw/boot (only
  # the FSBL), but Vitis exports a prebuilt PMU firmware next to it - the same
  # MicroBlaze ELF it uses for emulation, which runs perfectly well on the real
  # PMU. Order: -pmufw, then sw/boot/pmufw.elf, then sw/qemu/pmufw.elf.
  if { $dopmufw && $pmufile eq "" } {
    foreach cand [list [file join $swdir boot pmufw.elf] \
                       [file join $swdir qemu pmufw.elf]] {
      if { [file exists $cand] } { set pmufile $cand; break }
    }
    if { $pmufile eq "" } {
      puts "WARNING: no PMU firmware found under [file join $swdir]"
      puts "         Continuing without it: for this demo only the PMU gate"
      puts "         (0xFFCA0038) matters, and that is opened below. Pass"
      puts "         -pmufw <file> if you do want one."
      set dopmufw 0
    }
  }
  if { $dopmufw } { need "PMU firmware" $pmufile }

  # The bitstream and psu_init.tcl: out of the XSA unless a bitstream was given.
  # psu_init.tcl is always taken from the XSA - see do_run() for what it is needed for.
  need "ZCU106 XSA" $xsafile
  set exdir [file join [file dirname [file normalize $xsafile]] jtag_init]
  file mkdir $exdir
  if { [catch {exec unzip -o -q [file normalize $xsafile] psu_init.tcl *.bit -d $exdir} msg] } {
    puts "ERROR: could not extract psu_init.tcl and the bitstream from $xsafile: $msg"
    exit 1
  }
  set psuinit [file join $exdir psu_init.tcl]
  need "psu_init.tcl" $psuinit
  if { $bitfile eq "" } {
    set bitfile [lindex [glob -nocomplain -directory $exdir *.bit] 0]
  }
  need "bitstream" $bitfile
  set bitfile [file normalize $bitfile]
}

#-----------------------------------------------------------------------------------------
# Target selection: only ever targets of OUR cable
#-----------------------------------------------------------------------------------------

proc sel {name} {
  global cable
  targets -set -nocase -filter "name =~ \"$name\" && jtag_cable_name =~ \"*${cable}*\""
}

puts "INFO: connecting to $url"
connect -url $url
after 1000

#-----------------------------------------------------------------------------------------
# run: reset, PL, PMUFW, FSBL, application
#-----------------------------------------------------------------------------------------

proc do_run {} {
  global bitfile fsblfile pmufile elffile dopmufw psuinit

  # The PSU target disappears (and turns into "DAP (AXI AP transaction error)") after an
  # AXI access that never completed. Both names are accepted; a reset is attempted either
  # way, but only a power cycle reliably clears that state.
  if { [catch {sel "PSU"}] } {
    puts "WARNING: the PS debug access port is in an error state (a bus access did not"
    puts "         complete). Resetting; if the PSU target does not come back, power-cycle."
    catch {sel "DAP*"}
  }

  # Alternate boot mode = JTAG, so the boot ROM stays idle after the reset no matter
  # where the boot-mode switches are.
  puts "INFO: selecting the JTAG boot mode and resetting the system"
  catch {mwr -force 0xFFFF0000 0x14000000}
  catch {mwr -force 0xFF5E0200 0x0100}
  if { [catch {rst -system} msg] } {
    puts "WARNING: rst -system failed ($msg), trying rst -srst"
    rst -srst
  }
  after 3000
  sel "PSU"
  if { [mrd -force -value 0xFF5E0200] != 0x0100 } {
    puts "INFO: boot mode was not JTAG after the reset: setting it and resetting once more"
    mwr -force 0xFF5E0200 0x0100
    rst -system
    after 3000
    sel "PSU"
  }

  # Let the PMU run our firmware: open the gate the boot ROM leaves closed.
  puts "INFO: opening the PMU gate"
  sel "PSU"
  set pmu_status [mrd -force -value 0xFFCA0038]
  mwr -force 0xFFCA0038 [expr {$pmu_status | 0x1C0}]

  if { $dopmufw } {
    puts "INFO: downloading the PMU firmware: $pmufile"
    sel "MicroBlaze PMU"
    dow $pmufile
    con
    after 1000
  }

  # Program the PL. A system reset clears it, so this must come after the reset.
  puts "INFO: programming the PL: $bitfile"
  sel "PS TAP"
  fpga -file $bitfile
  puts "INFO: PL programmed"

  # The REAL FSBL, not a Tcl psu_init: it initialises the PS exactly as a boot from the
  # SD card would, and leaves the DDR in a state where block reads are reliable.
  puts "INFO: running the FSBL: $fsblfile"
  sel "Cortex-A53 #0"
  rst -processor
  after 500
  configparams force-mem-accesses 1
  dow $fsblfile
  set bp [bpadd -addr &XFsbl_Exit]
  con -block -timeout 60
  bpremove $bp
  puts "INFO: FSBL done (PS initialised, DDR up)"

  # THE PL IS STILL ISOLATED AND HELD IN RESET AT THIS POINT.
  #
  # The FSBL removes the PS-PL isolation and releases pl_resetn0 in
  # XFsbl_PlWaitForDone(), i.e. only on the path where the FSBL ITSELF loads a
  # bitstream out of the boot image. Here the PL was programmed over JTAG and the
  # FSBL booted in JTAG mode with no boot image, so that code never ran: psu_init()
  # alone leaves the PL powered down behind the PS-PL isolation with pl_resetn0
  # asserted. Every PL slave then fails to answer - including axi_gpio_link at
  # 0xA1000000, which is on the ZCU106 itself - and the first AXI read of the
  # application never completes and hangs the A53 (recovery: power cycle).
  #
  # The two procs below are the ones the hardware hand-off ships for exactly this
  # job, and are what scripts/jtag/zcu106_init.tcl uses. Isolation removal is a
  # power-up request to the PMU, so it needs the PMU firmware to be running.
  puts "INFO: removing the PS-PL isolation and releasing pl_resetn0"
  sel "APU*"
  configparams force-mem-accesses 1
  # At the GLOBAL level: the procs of psu_init.tcl read their register tables with
  # "variable", so the "set ..._data {...}" of the file has to land in the global
  # namespace. A plain "source" inside this proc would make them local variables here.
  uplevel #0 [list source $psuinit]
  psu_ps_pl_isolation_removal
  after 500
  psu_ps_pl_reset_config
  after 500
  configparams force-mem-accesses 0
  puts "INFO: PS-PL isolation removed, PL resets released"

  # Proof of life before the application is let loose: the link status register is on the
  # ZCU106 side of the link and is the very first thing the application reads.
  sel "PSU"
  configparams force-mem-accesses 1
  if { [catch {mrd -force -value 0xA1000000} st] } {
    puts "ERROR: the link status register (0xA1000000) did not answer: $st"
    puts "       The PL is not reachable. Power-cycle the board and try again."
    configparams force-mem-accesses 0
    exit 1
  }
  configparams force-mem-accesses 0
  puts [format "INFO: link status register (0xA1000000) = 0x%03X" [expr {$st & 0x3FF}]]

  puts "INFO: downloading the application: $elffile"
  sel "Cortex-A53 #0"
  rst -processor
  after 500
  dow $elffile
  configparams force-mem-accesses 0
  puts "INFO: starting the application - watch the UART (115200 8N1)"
  con
}

#-----------------------------------------------------------------------------------------
# dump: pull frames out of the PS DDR
#-----------------------------------------------------------------------------------------

proc dump_frame {cam addr file words} {
  puts [format "INFO: dumping CAM%s from 0x%08X (%d words) to %s" $cam $addr $words $file]
  if { [catch {mrd -bin -file $file $addr $words} msg] } {
    puts "ERROR: the dump failed: $msg"
    puts "       If the debug access port is in an error state, power-cycle the board."
    return 0
  }
  return 1
}

# The application publishes the geometry and the address of the frame it froze, per
# camera, in a small block in DDR (see Vitis/common/src/remote.h): which slot a frame
# ends up in depends on the frame count, so the addresses are not known in advance.
# Returns 1 and overwrites addr0/addr2/width/height when the block is there.
proc read_app_info {} {
  global addr0 addr2 width height

  set info_addr 0x1FFF0000
  set magic     0x43324331
  if { [catch {mrd -force -value $info_addr 12} w] } { return 0 }
  if { [lindex $w 0] != $magic } { return 0 }

  set ncams [lindex $w 1]
  set width  [lindex $w 2]
  set height [lindex $w 3]
  for {set i 0} {$i < $ncams && $i < 2} {incr i} {
    set base [expr {6 + $i * 3}]
    set cam  [lindex $w $base]
    set addr [lindex $w [expr {$base + 1}]]
    set frames [lindex $w [expr {$base + 2}]]
    puts [format "INFO: the application froze CAM%d at 0x%08X after %d frames" \
          $cam $addr $frames]
    if { $cam == 0 } { set addr0 [format 0x%08X $addr] }
    if { $cam == 2 } { set addr2 [format 0x%08X $addr] }
  }
  return 1
}

proc do_dump {} {
  global outdir addr0 addr2 width height repo

  file mkdir $outdir

  sel "PSU"
  configparams force-mem-accesses 1
  if { ![read_app_info] } {
    puts "INFO: no frame information published in DDR (is the application running and"
    puts "      past its capture?) - using the addresses given on the command line"
  }

  # RGB8: 3 bytes per pixel, the stride is the line rounded up to the 64 bit AXI master.
  set stride [expr {(($width * 3) + 7) / 8 * 8}]
  set bytes  [expr {$stride * $height}]
  set words  [expr {$bytes / 4}]
  puts [format "INFO: frame geometry %dx%d, stride %d bytes, %d bytes per frame" \
        $width $height $stride $bytes]

  set ok0 [dump_frame 0 $addr0 [file join $outdir cam0.bin] $words]
  set ok2 [dump_frame 2 $addr2 [file join $outdir cam2.bin] $words]
  configparams force-mem-accesses 0

  puts ""
  puts "INFO: convert the dumps to PNG on this host with:"
  foreach {cam ok} [list 0 $ok0 2 $ok2] {
    if { $ok } {
      puts [format "  python3 %s %s %d %d --stats" \
            [file join $repo scripts rgb2png.py] \
            [file join $outdir cam${cam}.bin] $width $height]
    }
  }
  if { $stride != [expr {$width * 3}] } {
    puts ""
    puts "NOTE: the stride ($stride) is larger than width*3 ([expr {$width*3}]), so the"
    puts "      dump has padding at the end of every line and rgb2png.py needs the"
    puts "      padded width: use [expr {$stride/3}] as WIDTH and crop afterwards."
  }
}

#-----------------------------------------------------------------------------------------

if { $command eq "run" || $command eq "run+dump" } {
  do_run
}
if { $command eq "run+dump" } {
  puts "INFO: waiting ${waitsec}s for the capture to finish"
  after [expr {$waitsec * 1000}]
}
if { $command eq "dump" || $command eq "run+dump" } {
  do_dump
}

disconnect
puts "INFO: done"
