echo "JTAG ramdisk boot: kernel 0x00200000, initrd 0x10000000, dtb 0x00100000"
# Same command line as the pre-built device tree's /chosen/bootargs, plus
# modprobe.blacklist=mali. The out-of-tree Mali GPU module of the pre-built
# PetaLinux root filesystem is loaded by udev, and its very first register read
# (mali_pp_reset_wait) takes an asynchronous SError and panics the kernel when
# the GPU has not been powered up the way a normal boot powers it up - which is
# exactly the case after this JTAG sequence resets a running system. Measured:
# "SError Interrupt on CPU3, code 0x00000000bf000002" /
# "Kernel panic - not syncing: Asynchronous SError Interrupt" at 16 s, in
# mali_probe. Nothing in this procedure needs a GPU.
setenv bootargs "earlycon console=ttyPS0,115200 root=/dev/ram0 rw init_fatal_sh=1 cma=1000M modprobe.blacklist=mali"
booti 0x00200000 0x10000000 0x00100000
