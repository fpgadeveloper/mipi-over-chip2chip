#!/bin/sh
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# deploy_sd.sh - run as root on a RAM-resident Linux on the board: stream an EDF wic
# image from an HTTP server onto the SD card, verify it by reading it back, then
# install BOOT.BIN on the first (esp, FAT) partition and verify that too.
#   usage: [SKIP_WRITE=1] [PREFLIGHT_ONLY=1] deploy_sd.sh <base-url> [device]
# The server must offer: rootfs.wic.gz  rootfs.wic.size  rootfs.wic.md5  (size and md5
# of the UNCOMPRESSED image)  BOOT.BIN  BOOT.BIN.sha256
#
# The RAM-disk Linux has BUSYBOX dd, which supports ONLY
#     if=  of=  bs=  count=  skip=  seek=
# There is no conv= at all (not conv=fsync, not conv=notrunc): passing one makes
# busybox dd exit 1 with a usage error and write NOTHING.  Truncation is a no-op on
# a block device, so nothing here needs it.  busybox head also has no -c.
set -eu
# busybox ash and bash have pipefail; plain POSIX sh does not
(set -o pipefail) 2>/dev/null && set -o pipefail
URL=${1:?usage: deploy_sd.sh <base-url> [device]}
DEV=${2:-/dev/mmcblk0}

SIZE=$(wget -q -O - "$URL/rootfs.wic.size")
MD5=$(wget -q -O - "$URL/rootfs.wic.md5")
BSHA=$(wget -q -O - "$URL/BOOT.BIN.sha256")
echo "image: $SIZE bytes, md5 $MD5"
sectors=$(cat "/sys/block/${DEV##*/}/size")
[ $((sectors * 512)) -ge "$SIZE" ] || { echo "ERROR: card too small ($sectors sectors)"; exit 1; }

# No automounter and no partition rescans while the card is being written and read
# back: a read-write mount of an ext4 partition changes its superblock, and the
# read-back checksum would no longer match.
systemctl stop systemd-udevd-control.socket systemd-udevd-kernel.socket systemd-udevd 2>/dev/null || true
for m in $(grep "^$DEV" /proc/mounts | cut -d' ' -f1); do umount "$m"; done
if grep -q "^$DEV" /proc/mounts; then echo "ERROR: $DEV still mounted"; exit 1; fi

# --- pre-flight -------------------------------------------------------------
# A card that cannot take a 4 MiB write will not take an 8 GiB one.  This costs a
# few seconds and fails in place of a 15-minute write + verify.  It is also the
# check that catches the failure mode of a card that was NOT power-cycled before
# the JTAG RAM-disk boot: an SD card that has negotiated UHS-I 1.8 V signalling
# stays in 1.8 V until its power is removed, a warm JTAG reset does not remove it,
# and the re-initialising host then drives 3.3 V into it.  The symptom is writes
# that report success and do not stick.  See docs/source/deploy.md.
preflight() {
    ro=$(cat "/sys/block/${DEV##*/}/ro" 2>/dev/null || echo 0)
    [ "$ro" = 0 ] || { echo "ERROR: $DEV is read-only (ro=$ro)"; exit 1; }
    before=$(dmesg | grep -c "I/O error" || true)
    end=$((sectors / 2048 - 8))          # last 8 MiB, past the image
    if [ "${PREFLIGHT_ONLY:-0}" = 1 ]; then
        # Standalone card test: stay clear of the image so a deployed card is not
        # damaged by checking it.  Only the space past the image is written.
        offs="$((SIZE / 1048576 + 100)) $end"
    else
        # The whole card is about to be overwritten, so the low end is fair game -
        # and the low end is where the partition table and BOOT.BIN will land.
        # ORDER MATTERS: test the harmless end of the card FIRST.  A card in the
        # "not power-cycled" state erases without programming, and 1 MiB is inside
        # partition 1 where the BOOT.BIN of a still-bootable card lives: testing
        # there first destroys a working image on a card that then refuses the
        # new one.  The loop stops at the first failure, so the low offset is only
        # touched once the card has proved that it can program.
        offs="$end 1"
    fi
    for off in $offs; do
        dd if=/dev/urandom of=/tmp/pf.pat bs=1M count=4 2>/dev/null
        want=$(md5sum /tmp/pf.pat | cut -d' ' -f1)
        if ! dd if=/tmp/pf.pat of="$DEV" bs=1M seek="$off" count=4 2>/tmp/pf.err; then
            echo "ERROR: pre-flight write at ${off}MiB failed: $(tr '\n' ' ' < /tmp/pf.err)"
            exit 1
        fi
        sync
        echo 3 > /proc/sys/vm/drop_caches
        got=$(dd if="$DEV" bs=1M skip="$off" count=4 2>/dev/null | md5sum | cut -d' ' -f1)
        if [ "$want" != "$got" ]; then
            echo "ERROR: PRE-FLIGHT VERIFY FAILED at ${off}MiB (wrote $want, read $got)"
            echo "  The card is not accepting writes.  Before concluding that it is dead:"
            echo "  power-cycle the board (a warm JTAG reset does NOT reset the card),"
            echo "  boot the RAM-disk Linux again and re-run.  If it still fails from a"
            echo "  cold start, the card is faulty - replace it."
            exit 1
        fi
    done
    after=$(dmesg | grep -c "I/O error" || true)
    if [ "$after" != "$before" ]; then
        echo "ERROR: $((after - before)) new block-layer I/O error(s) during the pre-flight"
        dmesg | grep "I/O error" | tail -5
        exit 1
    fi
    rm -f /tmp/pf.pat /tmp/pf.err
    echo "pre-flight OK: 4 MiB written and read back at $(echo "$offs" | sed 's/ /MiB and /')MiB, no I/O errors"
}

if [ "${SKIP_WRITE:-0}" = 1 ]; then
    echo "SKIP_WRITE=1: not writing, verifying only"
else
    preflight
    if [ "${PREFLIGHT_ONLY:-0}" = 1 ]; then
        echo "PREFLIGHT_ONLY=1: stopping before the full write"
        exit 0
    fi
    echo "[$(date +%T)] writing $DEV ..."
    # busybox dd: no conv=fsync, no status=progress; sync afterwards instead
    wget -q -O - "$URL/rootfs.wic.gz" | gunzip -c | dd of="$DEV" bs=4M
    sync
fi
echo 3 > /proc/sys/vm/drop_caches
echo "[$(date +%T)] reading back $SIZE bytes ..."
# busybox head has no -c: read an exact number of blocks with dd instead
BS=4096; [ $((SIZE % BS)) -eq 0 ] || BS=512
got=$(dd if="$DEV" bs=$BS count=$((SIZE / BS)) 2>/dev/null | md5sum | cut -d' ' -f1)
echo "md5 read back: $got"
[ "$got" = "$MD5" ] || { echo "ERROR: IMAGE VERIFY FAILED"; exit 1; }
echo "[$(date +%T)] image verified"

# BLKRRPART: make the kernel read the new partition table
python3 -c "import fcntl,os; fd=os.open('$DEV',os.O_RDONLY); fcntl.ioctl(fd,0x125F); os.close(fd)"
sleep 2
fdisk -l "$DEV"

mkdir -p /mnt/p1 /mnt/p2
mount "${DEV}p1" /mnt/p1
wget -q -O /mnt/p1/BOOT.BIN "$URL/BOOT.BIN"
sync
umount /mnt/p1
echo 3 > /proc/sys/vm/drop_caches
mount -o ro "${DEV}p1" /mnt/p1
got=$(sha256sum /mnt/p1/BOOT.BIN | cut -d' ' -f1)
echo "p1 (esp):"; ls -la /mnt/p1
umount /mnt/p1
[ "$got" = "$BSHA" ] || { echo "ERROR: BOOT.BIN VERIFY FAILED"; exit 1; }
echo "BOOT.BIN verified: $got"
mount -o ro,noload "${DEV}p2" /mnt/p2
echo "p2 (boot):"; ls -la /mnt/p2
umount /mnt/p2
echo "[$(date +%T)] DEPLOY OK"
