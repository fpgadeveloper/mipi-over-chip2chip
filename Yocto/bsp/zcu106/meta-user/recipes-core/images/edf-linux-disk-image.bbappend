# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# MIPI over Chip2Chip reference-design rootfs packages, layered on the amd-edf
# base image. Every recipe named here exists in the rel-v2025.2 EDF layers
# (poky, meta-oe, meta-networking); none depends on a MACHINE_FEATURE.

# Video capture: v4l2-ctl / v4l2-compliance (v4l-utils), media-ctl, yavta, and
# GStreamer with the complete base and good plugin sets. v4l2src is in the good
# set (video4linux2), videoconvert / videoscale are in the base set; the amd-edf
# base image installs no GStreamer at all, so they are requested by their -meta
# packages rather than left to a recommendation.
C2C_VIDEO_PACKAGES = " \
    v4l-utils \
    media-ctl \
    yavta \
    gstreamer1.0 \
    gstreamer1.0-plugins-base-meta \
    gstreamer1.0-plugins-good-meta \
"

# The bad plugin set (fpsdisplaysink, kmssink, the video parsers) is handy but
# not required by the design. Set C2C_GST_BAD = "" in local.conf to leave it out.
C2C_GST_BAD ?= "gstreamer1.0-plugins-bad-meta"

# Bring-up and bench tools. Most of these are already part of the amd-edf base
# image; they are listed so that the image stays usable on the bench (register
# access, I2C, Ethernet tests, overlays built on the target) if the base changes.
# sshd comes from the ssh-server-openssh image feature of the base recipe. No
# key or password is installed by this BSP: the first login is on the UART.
#
# c2c-cameras carries the compiled device-tree overlay of the remote camera
# pipelines, the pipeline init script and c2c-cameras.service, which brings the
# cameras up automatically at boot once the Chip2Chip link is up. It is enabled
# by default and is harmless without the second board.
C2C_BENCH_PACKAGES = " \
    c2c-tools \
    c2c-cameras \
    devmem2 \
    i2c-tools \
    libgpiod-tools \
    dtc \
    python3-core \
    python3-mmap \
    ethtool \
    iproute2 \
    iperf3 \
    phytool \
    tcpdump \
"

# DisplayPort output of the two camera streams (docs/source/display.md).
# libdrm-tests is modetest, which sets the mode and is also how the display is
# inspected; c2c-display is the wrapper that drives it. kmssink, the GStreamer
# element that puts a camera on a mixer layer, is in the BAD plugin set, so
# C2C_GST_BAD above is REQUIRED for the display - clearing it leaves capture
# working but no picture on the monitor.
C2C_DISPLAY_PACKAGES = " \
    libdrm \
    libdrm-tests \
    c2c-display \
"

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL:append = " ${C2C_VIDEO_PACKAGES} ${C2C_GST_BAD} ${C2C_BENCH_PACKAGES} ${C2C_DISPLAY_PACKAGES}"
