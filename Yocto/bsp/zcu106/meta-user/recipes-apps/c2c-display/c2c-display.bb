# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "Show the remote camera streams on the ZCU106 DisplayPort monitor"
DESCRIPTION = "c2c-display sets the DisplayPort mode through the PL video mixer \
and puts one camera per mixer overlay layer, side by side or one full screen. It \
also carries the read-only 'check' command, which reports the DRM connector, \
EDID, CRTC, plane and mixer register state that tells you whether the picture \
really reached the monitor - see docs/source/display.md. The optional \
c2c-display.service starts the display at boot; it is shipped disabled."
SECTION = "utils"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://c2c-display \
    file://c2c-display.default \
    file://c2c-display.service \
"

S = "${WORKDIR}"

# POSIX sh. modetest comes from libdrm-tests, kmssink from the bad plugin set,
# v4l2src from the good set; the register readback of "check" goes through
# c2c_rd32 of c2c-tools, which is also what the other c2c-* tools use.
# c2c-cameras provides c2c-init-cams, which c2c-display re-runs to set the
# remote scaler to the window size (the mixer layers cannot downscale), and
# /etc/default/c2c-cameras, which it reads for the sensor mode and the picture
# controls.
RDEPENDS:${PN} = "libdrm-tests c2c-tools c2c-cameras v4l-utils"
RRECOMMENDS:${PN} = "gstreamer1.0 gstreamer1.0-plugins-good-meta gstreamer1.0-plugins-bad-meta"

inherit systemd

SYSTEMD_SERVICE:${PN} = "c2c-display.service"
# Shipped DISABLED: the default boot is "cameras ready, display idle". Enabling
# the unit is not enough on its own either - C2C_DISPLAY_ENABLE must also be set
# in /etc/default/c2c-display.
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -d ${D}${bindir}
    install -d ${D}${sysconfdir}/default
    install -d ${D}${systemd_system_unitdir}

    install -m 0755 ${WORKDIR}/c2c-display ${D}${bindir}/c2c-display
    install -m 0644 ${WORKDIR}/c2c-display.default ${D}${sysconfdir}/default/c2c-display
    install -m 0644 ${WORKDIR}/c2c-display.service ${D}${systemd_system_unitdir}/
}
