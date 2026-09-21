# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "Automatic start of the remote MIPI camera pipelines over AXI Chip2Chip"
DESCRIPTION = "Compiles the device-tree overlay of the two camera pipelines that live \
on the AUBoard 15P and ships it with a systemd service that, at boot, waits for the \
Chip2Chip link, checks that the AUBoard really runs the camera design, applies the \
overlay once and configures both V4L2 pipelines. Without the second board the service \
reports that and the ZCU106 boots and runs normally."
SECTION = "utils"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# ---------------------------------------------------------------------------
# ONE source of truth for the overlay and the pipeline init script.
#
# c2c-cams.dtso, build-overlay.sh and init_c2c_cams.sh are NOT copied into this
# layer. FILESEXTRAPATHS points the bitbake file:// fetcher at Yocto/overlays/
# of this repository, addressed relative to THIS recipe:
#
#   ${THISDIR}                = <repo>/Yocto/bsp/zcu106/meta-user/recipes-apps/c2c-cameras
#   ${THISDIR}/../../../../../overlays  = <repo>/Yocto/overlays
#
# so there is exactly one copy of each file in the repository, the same one a
# developer builds by hand with Yocto/overlays/build-overlay.sh, and the same one
# docs/source/linux_cameras.md documents. The path is inside the repo and uses no
# symlinks, so it survives a fresh clone and a tarball export; bitbake hashes the
# contents of every fetched file, so editing the .dtso or the init script
# re-triggers this recipe and the image.
#
# do_compile runs build-overlay.sh itself (OUT_DIR keeps it out of the source
# tree), so the compiler flags - and the reasons for the two -W switches - are
# single-sourced as well: a host build and this image build produce a
# byte-identical .dtbo.
# ---------------------------------------------------------------------------
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../../../overlays:"

SRC_URI = " \
    file://c2c-cams.dtso \
    file://build-overlay.sh \
    file://init_c2c_cams.sh \
    file://c2c-cameras \
    file://c2c-cameras.service \
    file://c2c-cameras.default \
    file://99-c2c-cameras.rules \
"

S = "${WORKDIR}"
B = "${WORKDIR}/overlay-build"

# dtc-native gives dtc (and fdtoverlay/fdtget) on PATH for build-overlay.sh.
DEPENDS = "dtc-native"

# c2c-tools provides c2c-link-status / c2c-overlay / c2c-functions.sh, which the
# service uses; the V4L2 tools are what init_c2c_cams.sh drives.
RDEPENDS:${PN} = "c2c-tools v4l-utils media-ctl"

inherit systemd

SYSTEMD_SERVICE:${PN} = "c2c-cameras.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_configure[noexec] = "1"

do_compile() {
    mkdir -p ${B}
    # OUT_DIR keeps the products out of the source tree; the preprocessor is the
    # host "cpp", which is part of HOSTTOOLS (and so is on PATH here, from the
    # hosttools symlink farm), exactly as in a host build. dtc comes from
    # dtc-native. A host build and this one therefore produce a byte-identical
    # .dtbo - verified against the blob that was brought up on hardware.
    OUT_DIR="${B}" ${WORKDIR}/build-overlay.sh
    test -s ${B}/c2c-cams.dtbo
    test -s ${B}/c2c-cams-flat.dtbo
}

do_install() {
    install -d ${D}${bindir}
    install -d ${D}${nonarch_base_libdir}/firmware/c2c
    install -d ${D}${sysconfdir}/default
    install -d ${D}${systemd_system_unitdir}

    # The overlay of the remote camera pipelines, and the documented fallback
    # variant without the simple-pm-bus / dma-ranges node.
    install -m 0644 ${B}/c2c-cams.dtbo ${D}${nonarch_base_libdir}/firmware/c2c/
    install -m 0644 ${B}/c2c-cams-flat.dtbo ${D}${nonarch_base_libdir}/firmware/c2c/

    # The pipeline init script. It is installed under the name the service and
    # the documentation use; the second name keeps the hand procedure that
    # docs/source/linux_cameras.md described before this recipe existed working
    # verbatim.
    install -m 0755 ${WORKDIR}/init_c2c_cams.sh ${D}${bindir}/c2c-init-cams
    ln -sf c2c-init-cams ${D}${bindir}/init_c2c_cams.sh

    install -m 0755 ${WORKDIR}/c2c-cameras ${D}${bindir}/c2c-cameras
    install -m 0644 ${WORKDIR}/c2c-cameras.default ${D}${sysconfdir}/default/c2c-cameras
    install -m 0644 ${WORKDIR}/c2c-cameras.service ${D}${systemd_system_unitdir}/

    # Stable names for the two pipelines: /dev/video-cam0, /dev/video-cam2 and
    # the matching media/subdev links. The /dev/videoN numbering is probe order
    # and swaps between boots, so nothing may key on it.
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/99-c2c-cameras.rules ${D}${sysconfdir}/udev/rules.d/
}

CONFFILES:${PN} = "${sysconfdir}/default/c2c-cameras"

FILES:${PN} += " \
    ${nonarch_base_libdir}/firmware/c2c \
    ${systemd_system_unitdir}/c2c-cameras.service \
"
