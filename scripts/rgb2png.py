#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
"""rgb2png.py - turn a raw V4L2 RGB24 capture into a PNG (host side).

The capture devices of this design deliver V4L2_PIX_FMT_RGB24 ("RGB3"), three
bytes per pixel, no padding.  The ZCU106 image has no ffmpeg or ImageMagick, so
the frames are pulled to the build host and converted here.

    rgb2png.py FILE WIDTH HEIGHT [-o OUT.png] [--frame N] [--bgr]
               [--scale DIV] [--stats]

--bgr swaps the first and the third byte (use it if the picture comes out with
red and blue exchanged).  --stats prints per-channel mean/min/max, which tells
exposure problems from colour-order problems without looking at the picture.
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument("-o", "--out")
    ap.add_argument("--frame", type=int, default=-1,
                    help="frame index in a multi-frame file (default: the last)")
    ap.add_argument("--bgr", action="store_true", help="swap R and B")
    ap.add_argument("--scale", type=int, default=1, help="downscale by this integer factor")
    ap.add_argument("--stats", action="store_true")
    args = ap.parse_args()

    fsize = args.width * args.height * 3
    total = os.path.getsize(args.file)
    nframes = total // fsize
    if nframes == 0:
        sys.exit(f"{args.file}: {total} bytes is less than one {args.width}x{args.height} "
                 f"RGB24 frame ({fsize} bytes)")
    idx = args.frame if args.frame >= 0 else nframes + args.frame
    if not 0 <= idx < nframes:
        sys.exit(f"frame {args.frame} out of range (file holds {nframes})")

    with open(args.file, "rb") as fh:
        fh.seek(idx * fsize)
        buf = fh.read(fsize)
    img = np.frombuffer(buf, dtype=np.uint8).reshape(args.height, args.width, 3)

    if args.stats:
        names = "byte0 byte1 byte2"
        print(f"{args.file} frame {idx}/{nframes - 1}  {args.width}x{args.height}")
        for i, n in enumerate(names.split()):
            ch = img[:, :, i]
            print(f"  {n}: mean={ch.mean():7.2f} min={ch.min():3d} max={ch.max():3d} "
                  f"std={ch.std():6.2f}")
        # a crude "is it a picture or noise" indicator: neighbour difference
        d = np.abs(img[:, 1:, :].astype(np.int16) - img[:, :-1, :].astype(np.int16)).mean()
        print(f"  mean |horizontal neighbour difference| = {d:.2f}")

    if args.bgr:
        img = img[:, :, ::-1]
    if args.scale > 1:
        img = img[::args.scale, ::args.scale, :]

    out = args.out or os.path.splitext(args.file)[0] + ".png"
    Image.fromarray(np.ascontiguousarray(img)).save(out)
    print(f"wrote {out} ({img.shape[1]}x{img.shape[0]})")


if __name__ == "__main__":
    main()
