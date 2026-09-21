# SPDX-License-Identifier: MIT
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
"""user_dts.py - compose the "User DTS" that Vitis hands to sdtgen.

REPO-LOCAL helper, used only by this design.  It exists because the hardware of
this reference design lives in TWO FPGAs: the ZCU106 XSA describes the PS and the
AXI Chip2Chip core, and everything else - the two camera pipelines - sits in the
AUBoard and can only be described to Vitis with a device tree.  See
docs/source/baremetal.md and Vitis/common/dts/remote_pipeline.dtsi.

Two pieces go into the file that sdtgen finally includes:

  1. `Vitis/common/dts/remote_pipeline.dtsi` - hand written, version controlled:
     the `&amba_pl { ... }` nodes of every remote IP.  This is the interesting
     part and it never changes when the ZCU106 design is rebuilt.

  2. an `&cpus_a53 { /delete-property/ address-map; address-map = ...; }` block.
     Lopper only generates driver configuration for nodes that the processor
     cluster can actually reach, and a device tree property cannot be appended
     to - it has to be deleted and written out again in full.  The existing
     entries therefore have to be copied from the address map of the CURRENT
     ZCU106 XSA, which changes whenever that design changes.  Copying them by
     hand would rot; this module reads them back from an SDT that sdtgen
     generates from the XSA, and appends the remote nodes.  Cost: one extra
     sdtgen run (about a minute) per clean workspace build.

The composed file is written into the Vitis workspace, not into the source tree:
it is build output, derived from the XSA.

Controlled from `Vitis/py/args.json`:
    "user_dtsi":             path of the hand written part, relative to Vitis/
    "user_dtsi_address_map": true  -> re-list the A53 address map (see above)
                             false -> pass the hand written part unchanged
"""

import os
import re
import shutil
import subprocess
import sys

# Entries appended to the address map of the A53 cluster: every remote node the
# bare-metal drivers must see, as <0 addr &label 0 addr 0 size>.  Keep in step
# with remote_pipeline.dtsi (the labels have to exist there).
REMOTE_ADDRESS_MAP = [
    ("c2c_intc",      0xA0040000, 0x10000),
    ("cam0_csi",      0xA0100000, 0x01000),
    ("cam0_csi_rx",   0xA0100000, 0x01000),
    ("cam0_iic",      0xA0110000, 0x10000),
    ("cam0_gpio",     0xA0120000, 0x10000),
    ("cam0_demosaic", 0xA0130000, 0x10000),
    ("cam0_gamma",    0xA0140000, 0x10000),
    ("cam0_frmbuf",   0xA0150000, 0x10000),
    ("cam0_vpss",     0xA0180000, 0x40000),
    ("cam0_vpss_hsc", 0xA0180000, 0x10000),
    ("cam0_vpss_rst", 0xA0190000, 0x10000),
    ("cam0_vpss_vsc", 0xA01A0000, 0x10000),
    ("cam2_csi",      0xA0200000, 0x01000),
    ("cam2_csi_rx",   0xA0200000, 0x01000),
    ("cam2_iic",      0xA0210000, 0x10000),
    ("cam2_gpio",     0xA0220000, 0x10000),
    ("cam2_demosaic", 0xA0230000, 0x10000),
    ("cam2_gamma",    0xA0240000, 0x10000),
    ("cam2_frmbuf",   0xA0250000, 0x10000),
    ("cam2_vpss",     0xA0280000, 0x40000),
    ("cam2_vpss_hsc", 0xA0280000, 0x10000),
    ("cam2_vpss_rst", 0xA0290000, 0x10000),
    ("cam2_vpss_vsc", 0xA02A0000, 0x10000),
]

CLUSTER = "cpus_a53"


def info(msg):
    print(f"[user_dts] {msg}", flush=True)


def _run_sdtgen(xsa_path, out_dir):
    """Generate a plain SDT from the XSA with xsct/sdtgen (no User DTS)."""
    os.makedirs(out_dir, exist_ok=True)
    xsct = shutil.which("xsct")
    if not xsct:
        raise RuntimeError("xsct not found on PATH (source the Vitis settings64.sh)")
    cmd = [xsct, "-eval",
           f"sdtgen set_dt_param -dir {out_dir} -xsa {xsa_path}; sdtgen generate_sdt"]
    log = os.path.join(out_dir, "sdtgen.log")
    info(f"running sdtgen to read back the address map of &{CLUSTER} ...")
    with open(log, "w", encoding="utf-8") as fh:
        rc = subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT)
    top = os.path.join(out_dir, "system-top.dts")
    if rc != 0 or not os.path.isfile(top):
        raise RuntimeError(f"sdtgen failed (rc={rc}); see {log}")
    return top


def _read_address_map(system_top, cluster=CLUSTER):
    """Return the text of the address-map property of <cluster> in system-top.dts.

    The property is one long `address-map = <...>, <...>;` statement inside the
    `<cluster>: cpus-...@0 { ... }` node.
    """
    with open(system_top, "r", encoding="utf-8") as fh:
        text = fh.read()
    start = text.find(f"{cluster}:")
    if start < 0:
        raise RuntimeError(f"no '{cluster}:' node in {system_top}")
    prop = text.find("address-map", start)
    if prop < 0:
        raise RuntimeError(f"no address-map property in the {cluster} node of {system_top}")
    end = text.find(";", prop)
    if end < 0:
        raise RuntimeError(f"unterminated address-map property in {system_top}")
    body = text[prop + len("address-map"):end]
    body = body.split("=", 1)[1] if "=" in body else body
    entries = re.findall(r"<[^>]*>", body)
    if not entries:
        raise RuntimeError(f"could not parse the address-map entries in {system_top}")
    return entries


def _address_map_block(entries):
    lines = [
        "",
        "/*",
        " * Re-listed address map of the A53 cluster (generated by Vitis/py/user_dts.py).",
        " *",
        f" * The first {len(entries)} entries are the ones sdtgen derived from the ZCU106 XSA;",
        " * they are copied here verbatim because a device tree property cannot be",
        " * appended to - it must be deleted and written out again in full.  The",
        " * entries after them are the remote IP of the AUBoard: without them lopper",
        " * considers those nodes unreachable from the A53 and generates no driver",
        " * configuration for them.",
        " */",
        f"&{CLUSTER} {{",
        "\t/delete-property/ address-map;",
        "\taddress-map = " + ",\n\t\t      ".join(entries) + ",",
    ]
    remote = []
    for label, addr, size in REMOTE_ADDRESS_MAP:
        remote.append(f"<0x0 0x{addr:08x} &{label} 0x0 0x{addr:08x} 0x0 0x{size:x}>")
    lines.append("\t\t      " + ",\n\t\t      ".join(remote) + ";")
    lines.append("};")
    lines.append("")
    return "\n".join(lines)


def compose(vitis_dir, xsa_path, out_dir, cfg):
    """Build the User DTS for this target and return its absolute path.

    vitis_dir : the repo's Vitis/ directory (where build-vitis.py runs)
    xsa_path  : the ZCU106 hardware hand-off
    out_dir   : the Vitis workspace (build output)
    cfg       : the parsed args.json
    """
    rel = cfg.get("user_dtsi")
    if not rel:
        return None
    src = os.path.normpath(os.path.join(vitis_dir, rel))
    if not os.path.isfile(src):
        raise RuntimeError(f"user_dtsi not found: {src}")

    os.makedirs(out_dir, exist_ok=True)
    dst = os.path.join(out_dir, os.path.basename(src))

    with open(src, "r", encoding="utf-8") as fh:
        text = fh.read()

    if cfg.get("user_dtsi_address_map", False):
        sdt_dir = os.path.join(out_dir, "sdt_probe")
        entries = _read_address_map(_run_sdtgen(xsa_path, sdt_dir))
        info(f"read {len(entries)} address-map entries from the XSA, "
             f"appending {len(REMOTE_ADDRESS_MAP)} remote node(s)")
        text += _address_map_block(entries)

    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(text)
    info(f"user DTS written to {dst}")
    return dst


if __name__ == "__main__":
    # Standalone use, for inspecting the composed file:
    #   python3 py/user_dts.py <xsa> <out_dir> [<args.json>]
    import json
    if len(sys.argv) < 3:
        sys.exit("usage: user_dts.py <xsa> <out_dir> [<args.json>]")
    here = os.path.dirname(os.path.abspath(__file__))
    vdir = os.path.dirname(here)
    aj = sys.argv[3] if len(sys.argv) > 3 else os.path.join(here, "args.json")
    with open(aj, "r", encoding="utf-8") as fh:
        compose(vdir, os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]),
                json.load(fh))
