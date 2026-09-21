# SPDX-License-Identifier: MIT
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
"""pre_build.py - link the application against the maths library.

Run by the shared Vitis workspace builder through its "pre_build_script" hook
(see Vitis/py/args.json), after the sources have been copied into the
application component and before it is built:

    python3 py/pre_build.py <app_src_dir>

WHY: pipe.c uses pow() to build the gamma curve, and the link line that the
Vitis application component generates is

    -Wl,--start-group,-lxilstandalone,-lxiltimer,-lxil,-lgcc,-lc -Wl,--end-group

with no -lm, so pow() comes out as an undefined reference.  The application
component has a supported hook for exactly this: USER_LINK_LIBRARIES in the
UserConfig.cmake that is generated into the component's src directory.  This
script fills it in.

It is idempotent and safe to run on an already-patched component.
"""

import os
import re
import sys

LIBS = ["m"]
MARKER = "set(USER_LINK_LIBRARIES"


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: pre_build.py <app_src_dir>")
    app_src = sys.argv[1]
    cfg = os.path.join(app_src, "UserConfig.cmake")
    if not os.path.isfile(cfg):
        # Nothing to do: a template-based app may not have one.
        print(f"[pre_build] no UserConfig.cmake in {app_src}; skipping")
        return

    with open(cfg, "r", encoding="utf-8") as fh:
        text = fh.read()

    missing = [lib for lib in LIBS
               if not re.search(rf"^\s*{re.escape(lib)}\s*$", text, re.M)]
    if not missing:
        print("[pre_build] UserConfig.cmake already links " + " ".join(LIBS))
        return

    idx = text.find(MARKER)
    if idx < 0:
        sys.exit(f"[pre_build] ERROR: no '{MARKER}' block in {cfg}")
    end = text.find(")", idx)
    if end < 0:
        sys.exit(f"[pre_build] ERROR: unterminated '{MARKER}' block in {cfg}")

    insertion = "".join(f"\t{lib}\n" for lib in missing)
    text = text[:end] + insertion + text[end:]

    with open(cfg, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"[pre_build] added {' '.join(missing)} to USER_LINK_LIBRARIES in {cfg}")


if __name__ == "__main__":
    main()
