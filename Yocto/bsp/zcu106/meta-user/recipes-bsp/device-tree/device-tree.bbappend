# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Board-level (SoC-side) device-tree fixups, layered on top of the
# gen-machineconf / lopper-generated CONFIG_DTFILE (...-cortexaN-linux.dts). The
# PL hardware of the ZCU106 (AXI Chip2Chip, the link status GPIO) already comes
# from the SDT's pl.dtsi; this file carries only the board quirks the XSA /
# sdtgen output doesn't encode (see system-user.dtsi).
#
# The peripherals of the AUBoard (behind the Chip2Chip link) are deliberately NOT
# described here: they are not in the XSA of the ZCU106, and a driver that probes
# them while the link is down stalls the AXI bus. They are loaded at run time as
# a device-tree overlay, after a link check (see c2c-overlay in c2c-tools).
#
# meta-xilinx's device-tree.bb consumes EXTRA_DT_INCLUDE_FILES by copying each
# file into the DT build dir and appending `#include "<file>"` to the base DTS.
# Scope it to the Linux (APU) domain ONLY: the FSBL/PMU domain DTS files don't
# define the SoC peripheral labels these overrides reference, so dtc would fail
# with "Label or path ... not found". Match on os.path.basename(CONFIG_DTFILE)
# containing "linux" -- NOT the full path, which can itself contain "linux".
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

EXTRA_DT_INCLUDE_FILES:append = "${@' system-user.dtsi' if 'linux' in os.path.basename(d.getVar('CONFIG_DTFILE') or '') else ''}"
