# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "Helper scripts for the AXI Chip2Chip link of the MIPI over Chip2Chip design"
DESCRIPTION = "c2c-link-status decodes the Aurora / AXI Chip2Chip link status, \
c2c-peek and c2c-poke access registers and refuse to touch the Chip2Chip window \
while the link is down, c2c-overlay applies the device-tree overlay of the remote \
peripherals once the link is up, c2c-latency times single-word reads through the window."
SECTION = "utils"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://c2c-functions.sh \
    file://c2c-link-status \
    file://c2c-peek \
    file://c2c-poke \
    file://c2c-overlay \
    file://c2c-latency \
"

S = "${WORKDIR}"

# The scripts are POSIX sh. Register access goes through devmem2; dtc is only
# needed by c2c-overlay when it is handed an overlay source instead of a .dtbo.
# c2c-latency is the one python tool (mmap + ctypes on /dev/mem).
RDEPENDS:${PN} = "devmem2 python3-core python3-ctypes python3-mmap"
RRECOMMENDS:${PN} = "dtc"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -d ${D}${bindir} ${D}${datadir}/c2c-tools
    install -m 0644 ${WORKDIR}/c2c-functions.sh ${D}${datadir}/c2c-tools/
    for f in c2c-link-status c2c-peek c2c-poke c2c-overlay c2c-latency; do
        install -m 0755 ${WORKDIR}/$f ${D}${bindir}/
    done
}
