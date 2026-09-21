#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# init_c2c_cams.sh - configure the remote camera pipelines of the MIPI over
# Chip2Chip design (run on the ZCU106, AFTER "c2c-overlay apply cams ...").
#
#   imx219 -> mipi_csi2_rx_subsystem -> v_demosaic -> v_gamma_lut -> v_proc_ss
#          -> vcap_mipi_<N>_v_proc (/dev/videoX)
#
# Usage: init_c2c_cams.sh [SRC_W SRC_H [OUT_W OUT_H]]
#   SRC  sensor mode: 1920x1080 (default), 1640x1232 (2x2 binned, full field of
#        view) or 640x480. 3280x2464 does NOT fit the video IP (max 1920x1232).
#   OUT  size after the scaler (default = SRC), at most 1920x1232.
#
# Adapted from init_cams.sh of the rpi-camera-fmc reference design. POSIX sh (no
# bash on the image is assumed).
# STATUS: RUN ON HARDWARE 2026-09-20 (ZCU106 + AUBoard 15P, both cameras).
# The topology parsing and the Bayer read-back work against the real v4l-utils
# output ("stream:0 fmt:..." layout). One fix was needed against hardware: the
# capture format now carries an explicit bytesperline / sizeimage, see the
# comment at the v4l2-ctl --set-fmt-video call below.
#
# Formats, from the drivers of linux-xlnx 6.12.40:
#  * The sensor sends RAW10. The CSI-2 RX driver keeps ONE format for both pads
#    and the demosaic sink pad accepts any Bayer depth, so the 10->8 bit
#    axis_subset_converter between them needs no entity: SRGGB10_1X10 is used up
#    to the demosaic sink pad. The Bayer ORDER follows the flips of the sensor
#    (no flip RGGB, hflip GRBG, vflip GBRG, both BGGR); the code the sensor
#    reports is read back and passed on, the demosaic driver programs its phase
#    from it. Set hflip / vflip BEFORE running this script.
#  * From the demosaic source pad on everything is RBG888_1X24: the scaler-only
#    v_proc_ss has no colour conversion and v_frmbuf_wr has RGB8 only, so the
#    one capture format is RGB24 (fourcc RGB3, 3 bytes per pixel).
#  * The size of /dev/videoX must equal the scaler source pad, or STREAMON fails
#    with EINVAL (xvip_dma_verify_format) - this script sets both.

SRC_W=${1:-1920}
SRC_H=${2:-1080}
OUT_W=${3:-$SRC_W}
OUT_H=${4:-$SRC_H}
PIXFMT=RGB3
RGB=RBG888_1X24
MAX_W=1920
MAX_H=1232

die() {
	echo "${0##*/}: $*" >&2
	exit 1
}

for v in "$SRC_W" "$SRC_H" "$OUT_W" "$OUT_H"; do
	case $v in '' | *[!0-9]*) die "sizes must be numbers (got '$v')" ;; esac
done
[ "$SRC_W" -le $MAX_W ] && [ "$SRC_H" -le $MAX_H ] ||
	die "sensor mode ${SRC_W}x${SRC_H} exceeds the video IP (${MAX_W}x${MAX_H})"
[ "$OUT_W" -le $MAX_W ] && [ "$OUT_H" -le $MAX_H ] ||
	die "output ${OUT_W}x${OUT_H} exceeds the video IP (${MAX_W}x${MAX_H})"
command -v media-ctl >/dev/null 2>&1 || die "media-ctl not found"
command -v v4l2-ctl >/dev/null 2>&1 || die "v4l2-ctl not found"

# entity TOPOLOGY PATTERN - full name of the first entity whose name matches.
# "- entity 5: a0100000.mipi_csi2_rx_subsystem (2 pads, 2 links)"
# "- entity 8: imx219 1-0010 (1 pad, 1 link)"          <- name contains a space
entity() {
	printf '%s\n' "$1" |
		sed -n "s/^- entity [0-9]*: \(.*$2.*\) ([0-9]* pads\{0,1\}, .*$/\1/p" |
		sed -n '1p'
}

# setfmt MEDIA ENTITY PAD FORMAT
setfmt() {
	media-ctl -d "$1" -V "\"$2\":$3 [$4]" ||
		die "$1: cannot set '$4' on \"$2\":$3"
}

echo "Remote camera pipelines: sensor ${SRC_W}x${SRC_H} -> scaler ${OUT_W}x${OUT_H} $PIXFMT"

found=0
# MEDIA_DEVICES="/dev/media1" restricts the run to one pipeline (default: all).
for media in ${MEDIA_DEVICES:-/dev/media[0-9]*}; do
	[ -e "$media" ] || continue
	topo=$(media-ctl -d "$media" -p 2>/dev/null) || continue
	printf '%s\n' "$topo" | grep -q '^driver  *xilinx-video' || continue

	video=$(printf '%s\n' "$topo" | sed -n 's#.*device node name \(/dev/video[0-9]*\).*#\1#p' | sed -n '1p')
	cam=$(printf '%s\n' "$topo" | sed -n 's/.*vcap_mipi_\([0-9]\)_v_proc.*/\1/p' | sed -n '1p')
	[ -n "$video" ] || continue

	SENSOR=$(entity "$topo" 'imx219')
	CSI=$(entity "$topo" 'mipi_csi2_rx_subsystem')
	DEM=$(entity "$topo" 'v_demosaic')
	GAM=$(entity "$topo" 'v_gamma_lut')
	VPSS=$(entity "$topo" 'v_proc_ss')
	VCAP=$(entity "$topo" 'vcap_mipi_')
	for e in "$SENSOR" "$CSI" "$DEM" "$GAM" "$VPSS" "$VCAP"; do
		[ -n "$e" ] || die "$media: an entity of the pipeline is missing (media-ctl -d $media -p)"
	done

	# Links. The driver creates them enabled (and not immutable), so this only
	# restores the state after somebody disabled one.
	media-ctl -d "$media" -l "\"$SENSOR\":0 -> \"$CSI\":0 [1]" \
		-l "\"$CSI\":1 -> \"$DEM\":0 [1]" \
		-l "\"$DEM\":1 -> \"$GAM\":0 [1]" \
		-l "\"$GAM\":1 -> \"$VPSS\":0 [1]" \
		-l "\"$VPSS\":1 -> \"$VCAP\":0 [1]" ||
		die "$media: cannot enable the links"

	# Sensor mode; then read back the Bayer code it really uses (flips).
	setfmt "$media" "$SENSOR" 0 "fmt:SRGGB10_1X10/${SRC_W}x${SRC_H}"
	got=$(media-ctl -d "$media" --get-v4l2 "\"$SENSOR\":0")
	BAYER=$(printf '%s\n' "$got" | sed -n 's/.*fmt:\(S[RGB]*10_1X10\)\/.*/\1/p' | sed -n '1p')
	size=$(printf '%s\n' "$got" | sed -n 's/.*fmt:[^/]*\/\([0-9]*x[0-9]*\).*/\1/p' | sed -n '1p')
	[ -n "$BAYER" ] || die "$media: sensor reports no 10-bit Bayer format: $got"
	[ "$size" = "${SRC_W}x${SRC_H}" ] ||
		die "$media: the sensor has no mode ${SRC_W}x${SRC_H} (it chose $size)"

	raw="fmt:$BAYER/${SRC_W}x${SRC_H} field:none colorspace:srgb"
	rgb_in="fmt:$RGB/${SRC_W}x${SRC_H} field:none colorspace:srgb"
	rgb_out="fmt:$RGB/${OUT_W}x${OUT_H} field:none colorspace:srgb"
	setfmt "$media" "$CSI" 0 "$raw"
	setfmt "$media" "$CSI" 1 "$raw"
	setfmt "$media" "$DEM" 0 "$raw"
	setfmt "$media" "$DEM" 1 "$rgb_in"
	setfmt "$media" "$GAM" 0 "$rgb_in"
	setfmt "$media" "$GAM" 1 "$rgb_in"
	setfmt "$media" "$VPSS" 0 "$rgb_in"
	setfmt "$media" "$VPSS" 1 "$rgb_out"

	# bytesperline and sizeimage MUST be given explicitly. xvip_dma clamps a
	# requested bytesperline only UP to width*3 (xilinx-dma.c
	# __xvip_dma_try_format: bpl = roundup(...); clamp(bpl, min_bpl, max_bpl)),
	# never down, and "v4l2-ctl --set-fmt-video=width=..." does G_FMT, changes
	# only the named fields and writes the struct back - so the stride of a
	# PREVIOUS, wider format survives a change to a smaller one. The frame
	# buffer writer then advances by the old stride: measured on hardware,
	# 1920x1080 -> 640x480 left bytesperline at 5760 and every captured frame
	# had 160 lines of picture spread over 480 lines (2 black lines between
	# each) in a buffer 3x too large.
	bpl=$((OUT_W * 3))
	v4l2-ctl -d "$video" \
		--set-fmt-video="width=$OUT_W,height=$OUT_H,pixelformat=$PIXFMT,bytesperline=$bpl,sizeimage=$((bpl * OUT_H))" ||
		die "$video: cannot set ${OUT_W}x${OUT_H} $PIXFMT"

	# A usable picture indoors; the defaults of the sensor are very dark.
	v4l2-ctl -d "$video" --set-ctrl=analogue_gain=200 2>/dev/null
	v4l2-ctl -d "$video" --set-ctrl=digital_gain=1000 2>/dev/null

	echo " - CAM${cam:-?}: $media = $video ($BAYER)"
	found=$((found + 1))
done

[ "$found" -gt 0 ] || die "no xilinx-video media device: overlay applied? camera connected? (dmesg | grep -i -e imx219 -e xilinx)"

cat <<EOF

Capture examples (replace /dev/video0 by the device printed above):

  # 1080p, 60 frames to a raw RGB24 file (6220800 bytes per frame)
  v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=60 --stream-to=/tmp/cam.rgb

  # the same with yavta: skip 5 frames, one file per frame
  yavta -n 4 -c30 --skip 5 -f RGB24 -s ${OUT_W}x${OUT_H} -F/tmp/cam-#.rgb /dev/video0

  # frame rate only (nothing stored): proves DMA + interrupts over the link
  v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=300

  # GStreamer: JPEG files
  gst-launch-1.0 v4l2src device=/dev/video0 io-mode=mmap num-buffers=30 ! \\
    video/x-raw,format=RGB,width=${OUT_W},height=${OUT_H},framerate=30/1 ! \\
    videoconvert ! jpegenc ! multifilesink location=/tmp/cam-%03d.jpg

Scaled-down modes (run this script again, then capture as above):

  ${0##*/} 1920 1080 1280 720     # 1080p crop of the sensor, scaled to 720p
  ${0##*/} 1640 1232 640 480      # full field of view (binned), scaled to VGA

Use io-mode=mmap / --stream-mmap only: the buffers must come from this driver
(below 0x8000_0000, the only DDR the remote frame buffer writers can reach).
EOF
