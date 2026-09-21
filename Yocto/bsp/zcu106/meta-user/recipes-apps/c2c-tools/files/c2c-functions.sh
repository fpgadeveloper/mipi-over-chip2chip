# SPDX-License-Identifier: MIT
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# c2c-functions.sh - helpers shared by the c2c-* tools. POSIX sh; sourced, not
# executed.
#
# Address map of the MIPI over Chip2Chip design, as seen from the ZCU106:
#   0xA000_0000 - 0xA0FF_FFFF  the AXI Chip2Chip window: every access is carried
#                              over the Aurora link to the AUBoard 15P. With the
#                              link down the access never completes and the AXI
#                              bus stalls, so check the link first.
#   0xA100_0000                AXI GPIO in the ZCU106 itself: link status bits.
# The defaults can be overridden from the environment.

C2C_STATUS_ADDR=${C2C_STATUS_ADDR:-0xA1000000}
C2C_WIN_BASE=${C2C_WIN_BASE:-0xA0000000}
C2C_WIN_SIZE=${C2C_WIN_SIZE:-0x01000000}

# Status bits that must both be set for the window to be usable:
# bit 0 channel_up (Aurora) and bit 3 link_status (AXI Chip2Chip).
C2C_UP_MASK=0x9

c2c_die() {
	echo "${0##*/}: $*" >&2
	exit 2
}

c2c_need_root() {
	[ "$(id -u)" -eq 0 ] || c2c_die "must be run as root (use sudo)"
}

# c2c_is_num STRING - true for 0x-prefixed hexadecimal or plain decimal.
c2c_is_num() {
	case "$1" in
	0[xX]*)
		_c2c_h=${1#0[xX]}
		case "$_c2c_h" in
		'' | *[!0-9a-fA-F]*) return 1 ;;
		esac
		;;
	'' | *[!0-9]*) return 1 ;;
	esac
	return 0
}

# c2c_rd32 ADDR - print the 32-bit word at physical address ADDR as 0xXXXXXXXX.
c2c_rd32() {
	_c2c_val=
	if command -v devmem2 >/dev/null 2>&1; then
		# "Read at address  0xA1000000 (0xffff9c4f1000): 0x0000000F"
		_c2c_out=$(devmem2 "$1" w 2>&1) || {
			echo "$_c2c_out" >&2
			return 1
		}
		_c2c_val=$(printf '%s\n' "$_c2c_out" |
			sed -n 's/^.*at address[^:]*: *\(0[xX][0-9a-fA-F]*\).*$/\1/p' |
			sed -n '1p')
	elif command -v devmem >/dev/null 2>&1; then
		_c2c_out=$(devmem "$1" 32 2>&1) || {
			echo "$_c2c_out" >&2
			return 1
		}
		_c2c_val=$_c2c_out
	else
		echo "neither devmem2 nor devmem is installed" >&2
		return 1
	fi
	c2c_is_num "$_c2c_val" || {
		echo "unexpected devmem output: $_c2c_out" >&2
		return 1
	}
	printf '0x%08X\n' $((_c2c_val & 0xFFFFFFFF))
}

# c2c_wr32 ADDR VALUE - write the 32-bit word VALUE to physical address ADDR.
c2c_wr32() {
	if command -v devmem2 >/dev/null 2>&1; then
		_c2c_out=$(devmem2 "$1" w "$2" 2>&1) || {
			echo "$_c2c_out" >&2
			return 1
		}
	elif command -v devmem >/dev/null 2>&1; then
		devmem "$1" 32 "$2" || return 1
	else
		echo "neither devmem2 nor devmem is installed" >&2
		return 1
	fi
}

# c2c_link_up - 0 when the link is up, 1 when it is down, 2 when the status
# register could not be read. Leaves the register value in C2C_STATUS.
c2c_link_up() {
	C2C_STATUS=$(c2c_rd32 "$C2C_STATUS_ADDR") || return 2
	[ $((C2C_STATUS & C2C_UP_MASK)) -eq $((C2C_UP_MASK)) ]
}

# c2c_in_window ADDR - true when ADDR lies in the Chip2Chip window.
c2c_in_window() {
	[ $(($1)) -ge $((C2C_WIN_BASE)) ] &&
		[ $(($1)) -lt $((C2C_WIN_BASE + C2C_WIN_SIZE)) ]
}

# c2c_guard ADDR FORCE - exit unless ADDR is safe to access: outside the window,
# or the link is up, or FORCE is 1.
c2c_guard() {
	c2c_in_window "$1" || return 0
	[ "$2" = 1 ] && return 0
	c2c_link_up
	case $? in
	0) return 0 ;;
	1)
		echo "${0##*/}: $1 is in the Chip2Chip window and the link is DOWN" \
			"(status $C2C_STATUS); refusing, the access would stall the bus." \
			"Use -f to override." >&2
		exit 1
		;;
	*) c2c_die "cannot read the link status at $C2C_STATUS_ADDR" ;;
	esac
}
