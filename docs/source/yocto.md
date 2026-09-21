# Yocto

The Linux image of the host board (target `zcu106`) is built with the AMD Embedded
Development Framework (EDF) Yocto flow. There is no PetaLinux project for this design, and
the processor-less `auboard` target has no software. (The host also has a bare-metal
application, which needs none of this page — see [Bare-metal demo](baremetal).)

The board support package `Yocto/bsp/zcu106/` is complete: the image it builds boots on the
ZCU106, brings up the board Ethernet port and SSH, checks the Chip2Chip link, **starts the
two remote camera pipelines by itself** — see [Using the cameras from Linux](linux_cameras)
— and can put them on a DisplayPort monitor — see
[Showing the cameras on a DisplayPort monitor](display).

```
./build.sh yocto --target zcu106
```

This stage requires a native Linux machine. The build flow, its prerequisites and the
instructions to write the image to an SD card are described in `Yocto/README.md` of the
repository.

```{warning}
**Do not run this stage from a shell that has sourced the PetaLinux `settings.sh`.** It puts
the PetaLinux sysroot at the front of `PATH`, which shadows the system `python3` and adds a
`lopper` whose support files are not where `gen-machineconf` expects them. `gen-machineconf`
then cannot import `bb.tinfoil`, decides bitbake is unavailable, and the stage fails during
configuration with:

    [WARNING] The lopper 'lops' or 'embeddedsw configuration' files in your path are not correct
    [ERROR] The esw-conf configuration files are missing.  Bitbake is unavailable to build lopper

Source only the Vivado and Vitis `settings64.sh`.

(A host whose `tar` breaks BitBake's fakeroot used to need the PetaLinux `tar` on `PATH` as
well. The build flow now handles that by itself — see
[the `tar` / pseudo host issue](host-tar-pseudo) — so there is no reason to bring any part of
the PetaLinux environment into this shell.)
```

[Deploying and updating the Linux image](deploy) covers a first deployment without access
to the SD card and the update of a running board.

## What the image contains

* The board fixes that the XSA-derived device tree lacks: the console on `ttyPS0`, the TI
  DP83867 PHY of the board Ethernet port (GEM3) with a fixed MAC address, and the kernel
  command line (`/chosen/bootargs`, including `cma=1024M` for the capture buffers).
* `xlnx,fclk` nodes for `pl_clk0` and `pl_clk1`. `pl_clk0` runs the whole PL side of the link
  (the AXI-Lite port of the AXI Chip2Chip core, the Aurora `init_clk`, the link status GPIO)
  and `pl_clk1` the video mixer of the display path. The generated Linux device tree drops the
  node that holds them on, and the remaining consumers disable the clock when they go idle; the
  added nodes keep them enabled. A mixer register read with `pl_clk1` stopped never completes.
* A kernel with the V4L2 / media controller core, the AMD video pipeline drivers, the IMX219
  sensor driver, run-time device tree overlays (`CONFIG_OF_OVERLAY`, `CONFIG_OF_CONFIGFS`) and
  the three DRM patches the `v_mix` → `zynqmp-dpsub` bridge pipeline needs.
* `v4l2-ctl`, `media-ctl`, `yavta`, `modetest` (`libdrm-tests`) and GStreamer with the
  `v4l2src` and `kmssink` elements.
* An SSH server, `devmem2`, `i2c-tools`, `ethtool`, `iperf3`, `phytool`, `dtc` and Python 3.
* **The device-tree overlay of the remote camera pipelines and the service that applies it** —
  the `c2c-cameras` recipe (below) — together with the udev rules that give the stable names
  `/dev/video-cam0` / `/dev/video-cam2`.
* **`c2c-display`**, the DisplayPort output of the two camera streams. Its service is shipped
  *disabled* and refuses unless `C2C_DISPLAY_ENABLE=1` in `/etc/default/c2c-display`, so the
  default boot is cameras ready, monitor idle — see
  [Showing the cameras on a DisplayPort monitor](display).

## The camera overlay and its service (`c2c-cameras`)

`Yocto/bsp/zcu106/meta-user/recipes-apps/c2c-cameras/` compiles
`Yocto/overlays/c2c-cams.dtso` at build time and installs:

| Installed | From |
|---|---|
| `/lib/firmware/c2c/c2c-cams.dtbo`, `c2c-cams-flat.dtbo` | `Yocto/overlays/c2c-cams.dtso`, compiled by `Yocto/overlays/build-overlay.sh` |
| `/usr/bin/c2c-init-cams` (+ the alias `init_c2c_cams.sh`) | `Yocto/overlays/init_c2c_cams.sh` |
| `/usr/bin/c2c-cameras`, `c2c-cameras.service`, `/etc/default/c2c-cameras` | the recipe's own `files/` |

**There is exactly one copy of the overlay source, the init script and the overlay build script
in the repository.** They are not forked into the layer: the recipe adds `Yocto/overlays/` to
`FILESEXTRAPATHS` with a path relative to the recipe itself
(`${THISDIR}/../../../../../overlays`), so the bitbake fetcher takes the very files a developer
edits and builds by hand. The path is inside the repository and uses no symlinks, so it survives
a fresh clone and a source export, and bitbake hashes the contents of every fetched file — edit
the `.dtso` and the recipe and the image rebuild by themselves.

`do_compile` runs `build-overlay.sh` (with `OUT_DIR` pointing into the work directory so that
nothing is written into the source tree), which means the compiler flags — and the reasons for
the two documented `-W no-...` switches — are single-sourced too: **a host build and the image
build produce a byte-identical `.dtbo`.** `dtc` comes from `dtc-native`, `cpp` from bitbake's
`HOSTTOOLS`.

What the service does at boot, how it behaves without the second board, and how to configure it
is described in [Using the cameras from Linux](linux_cameras).

The first login is on the UART as user `amd-edf` with an empty password, which has to be
changed immediately. No SSH key or password is built into the image.

## The Chip2Chip window and the link status

The peripherals of the AUBoard 15P are accessed through the AXI Chip2Chip window of the
ZCU106, `0xA0000000` to `0xA0FFFFFF`. Every access to this window is carried over the
Aurora link. **While the link is down such an access never completes and stalls the AXI
bus**, so always check the link first. The link status is read from an AXI GPIO of the
ZCU106 itself (`0xA1000000`), which is safe to read in any state.

The image provides these helper tools (run them with `sudo`):

| Command | Purpose |
|---------|---------|
| `c2c-link-status` | Prints the decoded status bits. The exit status is 0 only when `channel_up` and `link_status` are both set. `-q` prints nothing, `-r` prints the raw value, `-w SECONDS` waits for the link. |
| `c2c-peek ADDRESS [COUNT]` | Reads 32-bit words. An address in the Chip2Chip window is only read when the link is up (`-f` overrides). |
| `c2c-poke ADDRESS VALUE` | Writes a 32-bit word, with the same check. Note that `devmem2` reads the register before and after the write. |
| `c2c-latency [N]` | Times N single-word reads of a remote register against the same loop on a local one (in images built after this tool was added). |
| `c2c-overlay apply NAME FILE` | Applies a device tree overlay (`.dtbo`, or a source that is compiled on the target) once the link is up. `remove NAME` and `list` are also available. |

For the same reason the device tree nodes of the remote peripherals are not part of the
base device tree: their drivers are built into the kernel and would access the remote
registers while Linux boots, whether or not the AUBoard 15P is ready. They are applied as an
overlay after the link check instead.

## Reusing downloads and shared state of other builds

A first build downloads several gigabytes of sources and pre-built shared state from AMD.
If other EDF 2025.2 workspaces exist on the build machine, they can be used as read-only
mirrors. Create the file `Yocto/zcu106/build/conf/site.conf` (the `Yocto/zcu106/` workspace
is not tracked by git) **before** the first build:

```
SSTATE_MIRRORS:prepend = " \
file://.* file:///path/to/other/workspace/build/sstate-cache/PATH \n \
"
SOURCE_MIRROR_URL:forcevariable = "file:///path/to/other/workspace/build/downloads"
```

BitBake reads `site.conf` before `local.conf`, and the `local.conf` of the EDF template
assigns both variables with `=`. That is why `:prepend` and `:forcevariable` are used: a
plain assignment (or `?=`) in `site.conf` would be silently overridden. Objects found in a
mirror are linked into the workspace; nothing is written to the mirror. To check that the
settings took effect:

```
cd Yocto/zcu106 && source ./edf-init-build-env build
bitbake -e | grep -E '^(SSTATE_MIRRORS|SOURCE_MIRROR_URL)='
```

`site.conf` lives in the build directory, which `./build.sh clean --stage yocto` deletes. Keep a
copy outside the workspace if you use it.

## Rebuilding after a change

The runner re-runs the Yocto stage only when one of the products in
`Yocto/zcu106/images/linux/` is missing — otherwise it prints `skipped (images exist)`. After a
change to the BSP (`bsp/zcu106/**`) or to `Yocto/overlays/`, delete one product to force it:

```
rm Yocto/zcu106/images/linux/BOOT.BIN
./build.sh yocto --target zcu106 --jobs 32
```

BitBake itself decides what actually has to be rebuilt, so a rootfs-only change is quick.
`Yocto/zcu106/configdone.txt` does **not** have to be deleted for a BSP change: the `meta-user`
layer is used in place, so a new recipe under `recipes-*/` is picked up on the next parse.
Deleting it forces `gen-machineconf` to run again, which is only needed after a change to the
Vivado design or to `bsp/zcu106/conf/local.conf.append`.

(host-tar-pseudo)=
## Known host issue: `tar` under pseudo — handled by the flow

**You do not have to do anything about this.** It is written up because the symptom is
striking, because the build prints `[hostfix]` lines when it applies the fix, and because a
host that defeats even the automatic fix needs the fallbacks at the end of this section.

On a host whose `tar` carries the distribution's security fix for **CVE-2025-45582** —
Ubuntu's `tar 1.35+dfsg-3ubuntu0.x`, and the equivalent in the RHEL 9 family — `do_package`
fails with a page of

```
got *at() syscall for unknown directory, fd 4
unknown base path for fd 4, path volatile
couldn't allocate absolute path for 'volatile'.
tar: ./var/volatile: Cannot mkdir: Bad address
tar: Exiting with failure status due to previous errors
```

Such a `tar` resolves every path component during extraction with the `openat2()` **syscall**
instead of `openat()`:

```
openat2(AT_FDCWD, "var/", {flags=O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_PATH|O_DIRECTORY,
                           resolve=RESOLVE_BENEATH}, 24) = 4
```

**pseudo** — BitBake's fakeroot implementation — is an `LD_PRELOAD` library, so it can only
intercept libc calls. `openat2` has no libc wrapper; `tar` issues the raw syscall, pseudo never
sees it, and therefore never learns which directory file descriptor 4 refers to. The next
`*at()` call on that descriptor fails, and with it every fakeroot task that unpacks a tar
archive. It has nothing to do with the tar *version*: it is which syscalls that particular build
uses.

### What the flow does

`Yocto/scripts/hostfix.sh` runs before every BitBake invocation (from `configure-build.sh` and
from `build-image.sh`). It:

1. **Probes the host `tar`.** Not by version string — it extracts a two-level archive under the
   very `pseudo` this workspace uses and checks whether the nested member arrived. Where no
   `pseudo` has been built yet it falls back to watching for an `openat2()` under `strace`, then
   to looking for the `openat2` syscall number in the `tar` binary.
2. **Does nothing at all** when the host `tar` is good. This is the normal case and it costs one
   temporary directory.
3. When the `tar` is bad, **finds one that is not** — in order: a `tar` BitBake already built in
   this workspace, a Yocto buildtools / eSDK sysroot, a PetaLinux install if the host happens to
   have one. Each candidate goes through the same probe before it is used. If none is found, it
   lets BitBake build one (`bitbake tar-native`); OpenEmbedded marks this CVE *disputed* for its
   own `tar` recipe and ships no such patch, so an OE-built `tar` is good by construction. **No
   PetaLinux install and no download are required.**
4. **Installs it** as `Yocto/<target>/hostfix/bin/tar` and puts that directory first on `PATH`.
5. **Drops the stale `build/tmp/hosttools/tar` symlink.** This is the part that is easy to miss
   by hand: BitBake does not give tasks the caller's `PATH`. It resolves each `HOSTTOOLS` entry
   once and symlinks it into `build/tmp/hosttools/`, and `base.bbclass` only re-resolves a tool
   whose symlink is *missing*. A workspace that ever ran a build without the fix therefore keeps
   using the bad `tar` no matter what `PATH` later builds are given — the symptom then looks
   completely unrelated to `PATH`.

You will see it work:

```
[hostfix] host tar (/usr/bin/tar) cannot be used under pseudo (openat2); looking for a replacement
[hostfix] dropped the stale build/tmp/hosttools/tar symlink
[hostfix] using tar: .../tar-native/usr/bin/tar
[hostfix]   via .../Yocto/zcu106/hostfix/bin/tar (first on PATH)
```

`hostfix/` is inside the gitignored per-target workspace: it is a property of the build host,
not of the design. `HOSTFIX_DISABLE=1` turns the whole check off.

### If it cannot help — the fallbacks

The script says so loudly and names these. Any one of them is enough:

* **Put a good `tar` first on `PATH` yourself** before the build, and delete
  `Yocto/<target>/build/tmp/hosttools/tar` if a build already ran. A PetaLinux install ships a
  usable one — take *only* that binary, never the whole environment (see the warning above):

      mkdir -p Yocto/zcu106/hostfix/bin
      ln -sf <petalinux>/2025.2/sysroots/x86_64-petalinux-linux/usr/bin/tar \
             Yocto/zcu106/hostfix/bin/tar
      rm -f Yocto/zcu106/build/tmp/hosttools/tar
      PATH=$PWD/Yocto/zcu106/hostfix/bin:$PATH ./build.sh yocto --target zcu106 --jobs 32

* **Install the Yocto buildtools tarball** and source its environment script before building
  (`x86_64-buildtools-nativesdk-standalone-5.0.x.sh` from
  <https://downloads.yoctoproject.org/releases/yocto/>, about 30 MB — it ships `tar 1.35` built
  from unpatched sources). Delete the stale `hosttools/tar` afterwards, as above.

* **Fix pseudo instead**, which is what upstream did: pseudo commit `472c8977e023`
  (*ports/linux/pseudo_wrappers: Avoid openat2 usage via syscall*, first released in pseudo
  1.9.3) makes the `syscall()` interposer return `ENOSYS` for `SYS_openat2`, so `tar` falls back
  to plain `openat()`. A full `openat2` wrapper followed in 1.9.4, and oe-core carries it from
  scarthgap 5.0.16 on. This release is pinned to pseudo `1.9.0+git` (SRCREV `28dcefb809ce`),
  which predates all of it. Bumping that SRCREV from a layer fragment is the root-cause fix, but
  it changes `pseudo-native`'s signature — and `pseudo-native` sits under every fakeroot task —
  so it costs a large shared-state miss even on hosts that never had the problem. That is why
  the flow swaps a host binary instead.
