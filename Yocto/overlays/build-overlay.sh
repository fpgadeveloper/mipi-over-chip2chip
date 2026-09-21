#!/usr/bin/env bash
#
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# build-overlay.sh - compile c2c-cams.dtso on the HOST (cpp + dtc -@) and, with
# --check, test-apply the result offline to a COPY of the base device tree.
#
#   ./build-overlay.sh                      build into ./out/
#   ./build-overlay.sh --check [system.dtb] build, then fdtoverlay onto a copy of
#                                           system.dtb (default: the one of the
#                                           zcu106 Yocto build) and verify the merge
#
# Output (./out/, or $OUT_DIR):
#   c2c-cams.dtbo          the overlay to apply:  c2c-overlay apply cams c2c-cams.dtbo
#   c2c-cams.pp.dtso       the same source after cpp: plain dtc can compile it, so
#                          "c2c-overlay apply cams c2c-cams.pp.dtso" works on the target
#   c2c-cams-flat.dtbo     fallback variant (-DC2C_FLAT): no bus node, no DMA limit
#
# Tools: cpp from the host; dtc / fdtoverlay from PATH, else from the native
# sysroot of the Yocto workspace (DTC_DIR=/path/to/bin overrides both).
#
# Environment overrides (used by the Yocto recipe
# Yocto/bsp/zcu106/meta-user/recipes-apps/c2c-cameras/c2c-cameras.bb, which runs
# THIS script so that the image is built from the same source with the same
# flags as a host build - there is only one copy of c2c-cams.dtso in the repo):
#   OUT_DIR   where to write the products (default ./out/). bitbake must not
#             write into the source tree.
#   CPP       the C preprocessor command, may have arguments (default "cpp",
#             which is what the recipe uses too: cpp is part of bitbake's
#             HOSTTOOLS, so a bitbake task and a host build run the same one).

set -euo pipefail

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
src=$here/c2c-cams.dtso
out=${OUT_DIR:-$here/out}
yocto=$(dirname "$here")
# CPP may carry arguments ("gcc -E"), so keep it as an array.
read -r -a cpp_cmd <<<"${CPP:-cpp}"

find_tool() {
	local t=$1 p
	if [ -n "${DTC_DIR:-}" ] && [ -x "$DTC_DIR/$t" ]; then
		echo "$DTC_DIR/$t"
		return
	fi
	if p=$(command -v "$t" 2>/dev/null); then
		echo "$p"
		return
	fi
	for p in "$yocto"/*/build/tmp/sysroots-components/x86_64/dtc-native/usr/bin/"$t"; do
		if [ -x "$p" ]; then
			echo "$p"
			return
		fi
	done
	echo "build-overlay.sh: $t not found (install device-tree-compiler or set DTC_DIR)" >&2
	exit 2
}

check=0
base=
while [ $# -gt 0 ]; do
	case $1 in
	--check)
		check=1
		if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then
			base=$2
			shift
		fi
		;;
	-h | --help)
		sed -n '7,22p' "$0"
		exit 0
		;;
	*)
		echo "build-overlay.sh: unknown argument: $1" >&2
		exit 2
		;;
	esac
	shift
done

command -v "${cpp_cmd[0]}" >/dev/null || {
	echo "build-overlay.sh: C preprocessor '${cpp_cmd[0]}' not found (set CPP=)" >&2
	exit 2
}
dtc=$(find_tool dtc)
mkdir -p "$out"

# build NAME [cpp flags]: cpp exactly as the kernel does for its .dts files, then
# dtc -@ so that the labels of the overlay end up in __symbols__ / __fixups__.
# graph_child_address is a style check ("ports" with a single port@0 needs no
# #address-cells); the xlnx,video binding wants reg = <0> there, so it is off.
build() {
	local name=$1
	shift
	"${cpp_cmd[@]}" -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P "$@" \
		"$src" -o "$out/$name.pp.dtso"
	"$dtc" -@ -I dts -O dtb -W no-graph_child_address "${DTC_FLAGS[@]}" \
		-o "$out/$name.dtbo" "$out/$name.pp.dtso"
	echo "built $out/$name.dtbo"
}

# An overlay is compiled WITHOUT its base tree, so dtc cannot see the
# #address-cells / #size-cells of &amba_pl (2 / 2 in system.dtb) and assumes the
# defaults 2 / 1. Default variant: that gives 2 avoid_default_addr_size warnings
# on bus@a0000000 (its ranges / dma-ranges are written for 2 / 2) plus 2
# "failed prerequisite" notes. Without ANY -W option the build prints exactly
# those 4 lines and the 2 graph_child_address ones, nothing else (measured), so
# these switches hide no other finding. Note: with the prerequisite switched
# off, do not rely on dtc for unique_unit_address; --check addresses every node
# by its full path instead.
DTC_FLAGS=(-W no-avoid_default_addr_size)
build c2c-cams
# The flat variant hangs the nodes directly under &amba_pl, so the same blindness
# hits every reg property as well.
DTC_FLAGS=(-W no-reg_format -W no-avoid_default_addr_size)
build c2c-cams-flat -DC2C_FLAT
rm -f "$out/c2c-cams-flat.pp.dtso"

[ "$check" -eq 1 ] || exit 0

# ---- offline test: merge into a COPY of the base tree ----------------------
fdtoverlay=$(find_tool fdtoverlay)
if [ -z "$base" ]; then
	base=$yocto/zcu106/images/linux/system.dtb
fi
[ -r "$base" ] || {
	echo "build-overlay.sh: base tree $base not found" >&2
	exit 2
}
cp "$base" "$out/base-copy.dtb"

fdtget=$(find_tool fdtget)
fail=0
bad() {
	echo "build-overlay.sh: CHECK FAILED: $*" >&2
	fail=1
}
# prop NODE PROPERTY -> cells in hex, space separated ("" when missing)
prop() { "$fdtget" -t x "$m" "$1" "$2" 2>/dev/null || true; }
# expect_ref WHAT NODE PROPERTY TARGET-NODE: the FIRST cell of PROPERTY must be
# the phandle of TARGET-NODE, i.e. the label resolved to the node we meant.
expect_ref() {
	local want got
	want=$(prop "$4" phandle)
	got=$(prop "$2" "$3")
	got=${got%% *}
	[ -n "$want" ] && [ "$got" = "$want" ] ||
		bad "$v: $1: $2 $3 = <${got:-missing}>, phandle of $4 = <${want:-missing}>"
}
# expect_pair A B: two endpoints that must point at each other.
expect_pair() {
	expect_ref "endpoint" "$1" remote-endpoint "$2"
	expect_ref "endpoint" "$2" remote-endpoint "$1"
}

for v in c2c-cams c2c-cams-flat; do
	m=$out/$v.merged.dtb
	"$fdtoverlay" -i "$out/base-copy.dtb" -o "$m" "$out/$v.dtbo"
	"$dtc" -q -I dtb -O dts -o "$out/$v.merged.dts" "$m"
	case $v in
	*-flat) b=/amba_pl ;;
	*) b=/amba_pl/bus@a0000000 ;;
	esac
	intc=$b/interrupt-controller@a0040000
	expect_ref "cascade" "$intc" interrupt-parent /axi/interrupt-controller@f9010000
	expect_ref "clock" "$intc" clocks "$b/clk-rmt-axi"
	for cam in 0:a01 2:a02; do
		n=${cam%%:*}
		p=${cam##*:}
		gpio=$b/gpio@${p}20000
		iic=$b/i2c@${p}10000
		csi=$b/mipi_csi2_rx_subsystem@${p}00000
		dem=$b/v_demosaic@${p}30000
		gam=$b/v_gamma_lut@${p}40000
		fb=$b/v_frmbuf_wr@${p}50000
		vpss=$b/v_proc_ss@${p}80000
		vcap=$b/vcap_mipi_${n}_v_proc
		sensor=$iic/sensor@10
		for d in "$dem" "$gam" "$vpss" "$fb"; do
			expect_ref "reset" "$d" reset-gpios "$gpio"
		done
		for d in "$csi" "$iic" "$fb"; do
			expect_ref "irq" "$d" interrupt-parent "$intc"
		done
		expect_ref "dma" "$vcap" dmas "$fb"
		expect_ref "clock" "$gpio" clocks "$b/clk-rmt-axi"
		expect_ref "clock" "$iic" clocks "$b/clk-rmt-axi"
		expect_ref "clock" "$csi" clocks "$b/clk-rmt-dphy"
		for d in "$dem" "$gam" "$vpss" "$fb"; do
			expect_ref "clock" "$d" clocks "$b/clk-rmt-video"
		done
		expect_ref "clock" "$sensor" clocks "$b/clk-imx219"
		expect_ref "supply" "$sensor" VANA-supply "$b/regulator-imx219-vana"
		expect_ref "supply" "$sensor" VDIG-supply "$b/regulator-imx219-vdig"
		expect_ref "supply" "$sensor" VDDL-supply "$b/regulator-imx219-vddl"
		expect_pair "$sensor/port/endpoint" "$csi/ports/port@0/endpoint"
		expect_pair "$csi/ports/port@1/endpoint" "$dem/ports/port@0/endpoint"
		expect_pair "$dem/ports/port@1/endpoint" "$gam/ports/port@0/endpoint"
		expect_pair "$gam/ports/port@1/endpoint" "$vpss/ports/port@0/endpoint"
		expect_pair "$vpss/ports/port@1/endpoint" "$vcap/ports/port@0/endpoint"
	done
	# A reference fdtoverlay left unresolved keeps the placeholder 0xffffffff.
	if grep -nE '(remote-endpoint|interrupt-parent|clocks|gpios|supply|dmas) = <[^>]*0xffffffff' \
		"$out/$v.merged.dts"; then
		bad "$v: unresolved phandle placeholder(s) above"
	fi
	[ "$fail" -eq 0 ] && echo "checked $v against $(basename "$base"): every reference resolves to the intended node"
done
exit "$fail"
