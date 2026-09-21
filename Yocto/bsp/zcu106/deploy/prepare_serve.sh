#!/bin/sh
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# prepare_serve.sh - host side of the network deployment: collect what deploy_sd.sh
# downloads into one directory, ready to be served over HTTP.
#   usage: prepare_serve.sh <Yocto/<target>/images/linux> <output-dir>
#   then:  python3 -m http.server 8000 --bind <host-ip> --directory <output-dir>
# The image is served gzip-compressed (every RAM-disk Linux can gunzip); the size and
# the md5 are those of the UNCOMPRESSED image, which is what ends up on the card.
set -eu
IMG=${1:?usage: prepare_serve.sh <images-dir> <output-dir>}
OUT=${2:?usage: prepare_serve.sh <images-dir> <output-dir>}
HERE=$(dirname "$(readlink -f "$0")")
mkdir -p "$OUT"
cp -f "$IMG/BOOT.BIN" "$HERE/deploy_sd.sh" "$OUT/"
sha256sum "$OUT/BOOT.BIN" | cut -d' ' -f1 > "$OUT/BOOT.BIN.sha256"
xzcat "$IMG/rootfs.wic.xz" > "$OUT/rootfs.wic"
wc -c < "$OUT/rootfs.wic" > "$OUT/rootfs.wic.size"
md5sum "$OUT/rootfs.wic" | cut -d' ' -f1 > "$OUT/rootfs.wic.md5"
gzip -1 -f "$OUT/rootfs.wic"
ls -l "$OUT"
