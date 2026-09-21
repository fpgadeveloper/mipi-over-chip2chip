# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " file://bsp.cfg"
KERNEL_FEATURES:append = " bsp.cfg"

# --- DisplayPort / video mixer fixes -----------------------------------------
# The three patches below are needed by the v_mix -> zynqmp-dpsub DRM *bridge*
# pipeline that the display path uses (kernel command line
# xlnx_mixer.connect_drm_bridge=1, set in system-user.dtsi /chosen/bootargs).
# They are taken unchanged from the rpi-camera-fmc reference design, where they
# are proven on this same 2025.2 / linux-xlnx 6.12 kernel, and they are not
# board specific.
#
# Without 0001 the display does not come up at all: xlnx_mix_probe calls
# component_add(), whose bind runs synchronously BEFORE mixer->master is set, so
# the devm_kzalloc(&mixer->master->dev, ...) in xlnx_mix_connector_init()
# dereferences NULL. The patch allocates the encoder with drmm_kzalloc(mixer->drm)
# and uses drmm_encoder_init(), which also fixes the teardown ordering.
SRC_URI:append = " file://0001-drm-xlnx-mixer-fix-NULL-deref-in-connector_init.patch"

# 0002 removes the manual drm_mode_config_cleanup() from xlnx_unbind(). The
# bridge-connector path registers the connector with drm_managed, so the manual
# cleanup plus drm_dev_put() frees it twice ("ida_free called for id=0 which is
# not allocated", then a NULL deref) on every poweroff / reboot.
SRC_URI:append = " file://0002-drm-xlnx-drv-drop-mode_config_cleanup-on-unbind.patch"

# 0003 calls drm_atomic_helper_shutdown() first in xlnx_unbind() so vblank is
# disabled before the managed teardown; it silences a WARN_ON in
# drm_vblank_init_release() on shutdown.
SRC_URI:append = " file://0003-drm-xlnx-drv-disable-vblank-before-cleanup-on-shutdown.patch"
