# Showing the cameras on a DisplayPort monitor

The two camera streams arrive in the ZCU106's DDR over the Chip2Chip link (see
[Using the cameras from Linux](linux_cameras)). This page describes the display path that puts
them on a monitor plugged into the ZCU106's DisplayPort socket, how to use it, and — because a
monitor is not always in reach — how to prove from the command line that the picture really got
there.

```{note}
**Status: measured on hardware.** Everything on this page has been run on a ZCU106 with a
Dell U2417H on its DisplayPort socket and both cameras live on an AUBoard 15P. The mode set,
the mixer, the pixel clock and the DisplayPort live input all worked on the first attempt;
one wiring change was needed in the block design, in the place section 2 predicted but not
in the way it predicted — see [the component order](#the-component-order-of-the-live-video-bus).

Measured with both cameras on screen (960x540 each, side by side):

| | |
|---|---|
| mixer vblank | 60.01 /s (1080p60) |
| each camera | 30.01 fps, CSI-2 and frame-buffer-writer interrupt counts 1:1 — **no frame dropped** |
| CPU | ~17 % of the four cores (one `gst-launch-1.0` process at ~60 % of one core) |
| soak | 12 minutes continuous, no stall, no kernel message |
```

## 1. How the picture reaches the monitor

The ZynqMP DisplayPort controller can take its pixels from one of two places: from its own DMA
engine reading a framebuffer in DDR (the "non-live" path, which is what you get on a board with
no PL video at all), or from the PL over a parallel pixel bus (the **live video** input). This
design uses the live input, which is also what the `rpi-camera-fmc` reference design does:

```
 PS DDR                PL                                          PS
┌────────────┐   ┌───────────────────────────────────────┐   ┌──────────────┐
│ CAM0 frames├──►│ v_mix layer 1  ┐                      │   │              │
│            │   │                ├─► AXI4-Stream RGB ───┼──►│ DisplayPort  ├──► monitor
│ CAM2 frames├──►│ v_mix layer 2  ┘   v_axi4s_vid_out    │   │ (live video) │
└────────────┘   │                                       │   └──────────────┘
                 │  v_tc ── 1080p60 timing               │
                 │  clk_wiz ── pixel clock (retuned)     │
                 └───────────────────────────────────────┘
```

* **Video Mixer (`v_mix`)** is the compositor. Each of its *memory layers* is an AXI master that
  reads one picture straight out of DDR, and the mixer overlays them on a background at
  programmable positions. One layer per camera.
* **AXI4-Stream to Video Out (`v_axi4s_vid_out`)** converts the mixer's stream into the parallel
  pixel bus the PS DisplayPort live input expects, and crosses from the mixer's clock to the
  pixel clock.
* **Video Timing Controller (`v_tc`)** generates the 1080p60 blanking and sync.
* **Clocking Wizard (`clk_wiz`)** makes the pixel clock. It is built with dynamic reconfiguration
  so the DisplayPort driver can retune it to whatever mode is selected (148.5 MHz for 1080p60).

On the Linux side this is **one DRM card, provided by the mixer**, not by the DisplayPort:

* `xlnx-mixer` registers the DRM device (driver name `xlnx`, bus id `a2000000.v_mix`), one CRTC,
  and **one plane per mixer layer**.
* `zynqmp-dpsub` in live mode registers only a `drm_bridge` — it creates **no card of its own**.
  That is why `modetest -M xlnx` is the right invocation and why there is no `card` for the
  DisplayPort.
* The two are joined by the kernel command line option `xlnx_mixer.connect_drm_bridge=1`. Without
  it the mixer falls back to the legacy `xlnx_bridge` interface, which the 2025.2 DisplayPort
  driver no longer provides; the mixer then comes up with a CRTC and planes but **no connector**,
  and `modetest` shows zero connectors.

GStreamer's `kmssink` writes a camera's frames onto one plane, i.e. one mixer layer.

## 2. The pixel format, and why nothing has to be converted

This is the part that differs from the reference design, so it is worth being precise.

Our capture format is fixed by the remote hardware: the frame-buffer writers on the AUBoard only
support `RGB8`, so `/dev/videoN` delivers **packed 24-bit RGB, 3 bytes per pixel in R, G, B
order**. The same layout has three different names depending on which subsystem is talking:

| Subsystem | Name | Meaning |
|---|---|---|
| Device tree (`xilinx-frmbuf`) | `"bgr888"` | the remote `v_frmbuf_wr` node's `xlnx,vformat` |
| V4L2 | `RGB3` = `V4L2_PIX_FMT_RGB24` | what `v4l2-ctl --get-fmt-video` reports |
| DRM | `BG24` = `DRM_FORMAT_BGR888` | what `modetest` lists for the plane |
| GStreamer | `RGB` | the `video/x-raw,format=` caps value |
| Video Mixer IP | format **20**, labelled `RGB8` in the Vivado GUI | `CONFIG.LAYERn_VIDEO_FORMAT` |

They really are all the same bytes. The DRM and V4L2 naming conventions run in opposite
directions — DRM names components from the most significant end of a little-endian word, V4L2
names bytes in memory order — so `DRM_FORMAT_BGR888` and `V4L2_PIX_FMT_RGB24` describe an
identical buffer. The kernel says so directly: in `drivers/dma/xilinx/xilinx_frmbuf.c` the single
table entry with `dts_name = "bgr888"` carries `id = XILINX_FRMBUF_FMT_RGB8` (20),
`drm_fmt = DRM_FORMAT_BGR888` **and** `v4l2_fmt = V4L2_PIX_FMT_RGB24`. The mixer uses the same
format numbering as the frame-buffer IP, so choosing **20** for the mixer layers makes the mixer
read exactly the bytes the remote pipeline wrote.

**So there is no byte-order mismatch to fix.** `v4l2src ! kmssink` moves frames from the capture
queue to a mixer layer with no colour conversion and no repacking — which matters, because a
software `videoconvert` on two 1080p streams would cost far more CPU than this board has to
spare.

The choice propagates one step further. The mixer's *master* layer format also has to be
something the DisplayPort live input accepts, and the driver maps it like this
(`xlnx_mix_video_to_media_bus_format`):

| `xlnx,video-format` / `CONFIG.VIDEO_FORMAT` | media bus format | accepted by the DP live input? |
|---|---|---|
| `0` RGB | `MEDIA_BUS_FMT_RGB888_1X24` | yes |
| `1` YUV444 | `MEDIA_BUS_FMT_VUY8_1X24` | yes |
| `2` YUV422 | `MEDIA_BUS_FMT_UYVY8_1X16` | yes (what the reference uses) |

The reference design picks YUV422 because *its* layers are already YUYV — its cameras go through
a VPSS with colour-space conversion, so YUV costs it nothing. Ours are RGB. Keeping the master
layer RGB as well means **no conversion anywhere in the path**: no RGB→YUV in the mixer, no
chroma subsampling of the camera data, and no YUV→RGB again in the DisplayPort. That is why this
design sets `VIDEO_FORMAT 0` and `xlnx,video-format = <0>` where the reference sets `2`.

```{note}
`xlnx,disp-bridge` is deliberately **not** set on our mixer node. It selects the legacy bridge
path, whose bus format for an RGB master is `MEDIA_BUS_FMT_RBG888_1X24` (note: R-B-G) — which is
*not* in the DisplayPort's list of accepted live formats. With `connect_drm_bridge=1` the DRM
bridge path is used and the format comes from `xlnx,video-format`, so the legacy property would
only be a trap.
```

(the-component-order-of-the-live-video-bus)=
### The component order of the live video bus — measured, and it is a G/B crossover

The 24-bit parallel bus out of `v_axi4s_vid_out` is mapped onto the DisplayPort's 36-bit live
pixel port (three 12-bit components) in `bd_zynqmp.tcl`, each byte left-justified in its 12-bit
field. The two buses **do not use the same component order**, and the mapping has to cross two
of the three over:

| bus | order | why |
|---|---|---|
| native out of `v_axi4s_vid_out` | `[23:16]=R, [15:8]=B, [7:0]=G` | Xilinx video IP carries "RGB" on a 24-bit stream as **R-B-G**. That is `MEDIA_BUS_FMT_RBG888_1X24` — the very bus format the note below says the legacy `xlnx_bridge` path reports for an RGB mixer master layer. |
| DisplayPort live input | field 2 = R, field 1 = G, field 0 = B | `MEDIA_BUS_FMT_RGB888_1X24`, which is what the mixer's DRM-bridge path advertises to `zynqmp-dpsub`. |

So red already lands correctly and **green and blue have to be exchanged**. `vid_concat`
therefore takes `native[15:8]` for field 0 and `native[7:0]` for field 1.

This was measured, not deduced. With the three slices wired straight through, a 1920x1080
RGB24 frame in DDR containing four bars — red, green, blue, white — came out of the monitor
as **red, blue, green, white**: red correct, green and blue exchanged, white still white,
geometry perfect. The mixer's own background-colour registers said the same thing
independently: writing `BACKGROUND_Y_R` gave a red screen, `BACKGROUND_U_G` a blue one and
`BACKGROUND_V_B` a green one.

Note that the symptom is **not** the red/blue swap one might expect: red is the component
that is already right. If you ever see a colour problem here, drive four known bars rather
than one flat colour — a full-screen flat colour is exactly what a webcam's auto white
balance destroys — and change **only** `vid_concat` in the `display_pipeline` hierarchy, then
rebuild the XSA. **Do not** fix it by changing the remote AUBoard pipeline or by inserting a
`videoconvert`: the first is a second board to rebuild and re-flash, the second costs CPU on
every frame forever.

## 3. What was added to the hardware

All of it lives in the `display_pipeline` hierarchy of `Vivado/src/bd/bd_zynqmp.tcl`. Nothing of
the link design changed: `pl_clk0` is still 100 MHz, the remote window is still at `0xA000_0000`,
the link status GPIO at `0xA100_0000`, and the Chip2Chip interrupts still own `pl_ps_irq0[3:0]`.

### Registers

| Address | Size | Block |
|---|---|---|
| `0xA000_0000` | 16 M | AXI Chip2Chip window (remote peripherals) — unchanged |
| `0xA100_0000` | 64 K | link status / link debug GPIO — unchanged |
| **`0xA200_0000`** | **64 K** | **`v_mix` video mixer** |
| **`0xA201_0000`** | **64 K** | **`v_tc` timing controller** |
| **`0xA202_0000`** | **64 K** | **`clk_wiz` pixel clock wizard** |

The display block starts at `0xA200_0000` so that the 16 MB remote window and the GPIO never have
to move.

### Interrupts

| `pl_ps_irq0` bit | GIC SPI | Source |
|---|---|---|
| `[3:0]` | 89 – 92 | AXI Chip2Chip `axi_c2c_m2s_intr_out` — unchanged (link contract) |
| `[4]` | 93 | `v_mix` frame-done |
| `[5]` | 94 | `v_tc` |

### Clocks

| Clock | Rate | Drives |
|---|---|---|
| `pl_clk0` | 100 MHz | the link (Aurora init/DRP, Chip2Chip, AXI) **and** the display AXI-Lite registers. Fixed by the link — do not change. |
| `pl_clk1` | 250 MHz | `v_mix` datapath and its AXI master ports, `v_axi4s_vid_out` input side |
| `clk_wiz/clk_out1` | 148.5 MHz for 1080p60 | pixel clock; the DisplayPort driver retunes it per mode |

`pl_clk1` is taken from the PS rather than an MMCM so that no PL clocking resource is spent and
`pl_clk0` is untouched. Like `pl_clk0` it is pinned on with an `xlnx,fclk` node in
`system-user.dtsi`, so the mixer's registers stay readable even when no mode is set.

### Data path

The mixer reads the camera frames from PS DDR through **`S_AXI_HP3_FPD`**, a different PS slave
port from the one the remote FPGA writes them into (`S_AXI_HP0_FPD`). Its address space is
restricted to DDR low (`0x0000_0000` – `0x7FFF_FFFF`) exactly as the remote FPGA's is: that is
where the CMA buffers are, and where a 32-bit master can reach.

### What the device tree generator produces

`sdtgen` derives the mixer, timing controller and clock wizard nodes from the XSA. Checked
against the SDT of this build, it gets these right on its own — no override needed:

| Property | Generated value | Why it matters |
|---|---|---|
| `reset-gpios` (v_mix) | `<&gpio 78 1>` | from the EMIO connection; the driver's probe fails without it |
| `clocks` (v_mix) | `<&zynqmp_clk 72>` = `pl_clk1` | the 250 MHz datapath clock |
| `interrupts` | v_mix SPI 93, v_tc SPI 94 | matches the block design |
| `xlnx,vformat` on `layer_0/1/2` | `"BG24"` | = `DRM_FORMAT_BGR888`, exactly the bytes the cameras deliver |
| `xlnx,video-format` (v_mix) | `<0>` | RGB master layer |
| `xlnx,num-layers`, `xlnx,dma-addr-width` | `<3>`, `<32>` | 32-bit master, so buffers must be in low DDR |

and, importantly, it puts **no** `xlnx,logo-layer` boolean on the mixer node — with that present
`xlnx_mix_dt_parse` returns early and never reads `xlnx,video-format` or fills in the CRTC port.

Two things it gets wrong, which `system-user.dtsi` has to fix:

* **`xlnx,pixels-per-clock = <4>` on the timing controller.** The generator emits the IP's
  maximum, not the configured value; this pipeline is 1 pixel per clock. The bridge driver uses
  this to compute the timing it programs, so leaving it at 4 gives a wrong line length.
* **The node is named `v_tc_0@a2010000`**, so the platform device is `a2010000.v_tc_0`, not
  `a2010000.v_tc`. Anything matching on the device name has to allow for it.

Everything else `system-user.dtsi` adds is what the XSA simply cannot describe: the OF-graph
links from the mixer to the DisplayPort to the connector, the `dp_live_video_in_clk` entry in the
dpsub's clock list, the `psgtr` reference clock (the generated `psgtr` node declares no clocks at
all, so `xpsgtr_xlate` rejects reference clock 3 and the DP probe fails with `-EINVAL`), and the
kernel command line.

### Mixer configuration

| Parameter | Value | Why |
|---|---|---|
| `NR_LAYERS` | 3 | master layer 0 + one memory layer per camera |
| `VIDEO_FORMAT` | 0 (RGB) | section 2 |
| `LAYER1/2_VIDEO_FORMAT` | 20 (`RGB8`) | section 2 |
| `MAX_COLS` / `MAX_ROWS` | 1920 / 1080 | the output resolution |
| `LAYER1/2_MAX_WIDTH` | 1920 | so a single camera can be shown full screen |
| `SAMPLES_PER_CLOCK` | 1 | must match `xlnx,pixels-per-clock` on the `v_tc` node |

Layer 0 is the mixer's streaming input and is **tied off** in the block design: nothing feeds it,
so the mixer paints its background-colour register behind the two camera windows. This mirrors
the reference design.

The mixer's reset comes from **PS EMIO GPIO bit 0** (Linux GPIO 78), not from a `proc_sys_reset`.
That is not a style choice: `xlnx_mixer` calls `devm_gpiod_get(dev, "reset", ...)` in probe and
fails with *"No reset gpio info from dts for mixer"* if the device tree has no `reset-gpios`, and
that property is generated from this block-design connection.

### Sizing: why the windows are 960x540

The video mixer's layers can only **upscale**. Two 1920x1080 windows therefore do not fit on a
1920x1080 screen. The downscaling is done where a scaler already exists — the VPSS on the
AUBoard — by capturing at the window size:

```
init_c2c_cams.sh 1920 1080 960 540
```

Two 960x540 windows then sit side by side, vertically centred. This also *reduces* the traffic on
the Chip2Chip link, because the frames are already small when they cross it.

## 4. Using it

Everything below runs on the ZCU106, as root (`kmssink` needs DRM master).

**The cameras are not this tool's job.** `c2c-cameras.service` owns them: at boot it waits for
the Chip2Chip link, applies the overlay and configures both pipelines (see
[Using the cameras from Linux](linux_cameras)). The only prerequisite for the display is that it
has finished:

```
c2c-cameras status        # service state : ready   /   health : OK
```

`c2c-display` calls `c2c-cameras health` itself before it touches a capture device, and
refuses to start if the AUBoard has been reset since the drivers probed — opening a capture
device in that state hangs the CPU. It passes the health check's **exit status 5** straight
on, so a wrapper can tell that case apart from "no monitor" or "no cameras".

Then, as root:

```
c2c-display               # both cameras, 960x540 each, side by side (= "c2c-display both")
c2c-display cam0          # CAM0 alone, full screen
c2c-display cam2          # CAM2 alone, full screen
c2c-display off           # stop the display, blank the screen ("stop" is an alias)
```

### How the display and the camera service share the pipelines

The mixer's layers can only upscale, so a 960x540 window needs the frames to *leave the AUBoard*
at 960x540 — but `c2c-cameras.service` configures the pipelines at the full 1920x1080 by default.
`c2c-display` resolves that itself: when the capture size does not match the window it re-runs
`c2c-init-cams` for the size it needs, then re-applies `C2C_CAM_CTRLS` from
`/etc/default/c2c-cameras` (the init script resets the gain controls and knows nothing about the
gamma defaults the service applies). It says so when it does it. Pass `-k` to forbid the change
and be told what to run instead.

This is the one place the display touches what the service set up, and it is not permanent:

```
systemctl restart c2c-cameras     # pipelines back to the service's own size
```

A single camera full screen (`cam0` / `cam2`) uses 1920x1080, which is the service's default, so
nothing is rescaled at all.

**The display does not start at boot.** `c2c-display.service` exists but is shipped *disabled*,
and even when enabled it does nothing unless `C2C_DISPLAY_ENABLE=1` in `/etc/default/c2c-display`.
The default boot of this image is therefore cameras ready, monitor idle. To change that:

```
sed -i 's/^C2C_DISPLAY_ENABLE=.*/C2C_DISPLAY_ENABLE=1/' /etc/default/c2c-display
systemctl enable --now c2c-display
```

The unit is `Requires=`/`After=`/`PartOf=` `c2c-cameras.service`, so it starts after the cameras
are ready and — importantly — stops with them. That matters at shutdown: `c2c-cameras stop` halts
the remote frame-buffer writers, and GStreamer must not still be pulling frames when it does.

### By hand

The equivalent of one camera on one plane, without the wrapper:

```
sudo modetest -M xlnx -D a2000000.v_mix -s 43@41:1920x1080-60@BG24

sudo gst-launch-1.0 v4l2src device=/dev/video-cam0 io-mode=mmap ! \
  video/x-raw,format=RGB,width=960,height=540,framerate=30/1 ! \
  kmssink bus-id=a2000000.v_mix plane-id=35 \
  render-rectangle="< 0, 270, 960, 540 >" \
  show-preroll-frame=false sync=false can-scale=true
```

(Connector 43 / CRTC 41 and planes 35, 37, 39 are what this build actually enumerates —
`c2c-display check` prints them, and they are not guaranteed across kernels. Use
`/dev/video-cam0` / `/dev/video-cam2`, not `/dev/videoN`: the numbering swaps between boots,
see the *stable names* section of [Using the cameras from Linux](linux_cameras).)

Measured plane-to-layer mapping for this build: **plane 35 = mixer layer 1, plane 37 = layer 2,
plane 39 = the primary, i.e. the tied-off streaming layer 0.** All three offer `BG24` only.

Points that are easy to get wrong, all of them inherited from the reference design's hard-won
experience:

* **Pin the refresh rate** (`-60`). Monitors often prefer a mode the PL pixel clock cannot
  produce; the DisplayPort then drives no valid pixels and the screen simply stays dark.
* **Connector and CRTC ids are not stable** across kernels or boards. Look them up
  (`modetest -M xlnx -D a2000000.v_mix`) — or let `c2c-display` do it, which is why it exists.
* **`render-rectangle` needs the spaced `"< x, y, w, h >"` form.** The caps parser is strict about
  the spaces.
* **`can-scale=true` is required.** With `can-scale=false` the 2025.2 `kmssink` silently ignores
  `render-rectangle` and draws the picture centred instead.
* **Use the overlay planes, not the primary.** `c2c-display` picks the planes whose type is
  `Overlay` and whose format is `BG24`.
* **The format after `@` in the `modetest -s` line is the *primary* plane's format**, which comes
  from the generated `xlnx,vformat` of `layer_0` and is not necessarily `BG24`. Read it off
  `modetest -M xlnx -D a2000000.v_mix -p` — `c2c-display` does this for you.
* **`io-mode=mmap` only.** The buffers have to come from the capture driver, which allocates them
  in the low 2 GB where the remote frame-buffer writers can reach.

Other commands:

```
c2c-display pattern      # modetest colour bars: no cameras, no link involved
c2c-display check        # read-only diagnostics (next section)
c2c-display -d /dev/video-cam0    # a specific capture device, full screen
c2c-display both -w 640 -H 480    # smaller windows (rescales the pipelines)
c2c-display both -k               # refuse to rescale; tell me what to run
```

## 5. Verifying without looking at the monitor

`c2c-display check` collects all of the following; this section says what each item proves, so a
failure can be placed.

**Did the DisplayPort link come up at all?** — independent of the mixer, the cameras and the
Chip2Chip link.

```
cat /sys/class/drm/card*-DP-*/status          # -> connected
wc -c < /sys/class/drm/card*-DP-*/edid        # -> non-zero: the monitor answered on AUX
modetest -M xlnx -D a2000000.v_mix -c -p      # connector row must read "connected"
```

```{important}
Two traps that made a perfectly good monitor look broken during bring-up, both now handled by
`c2c-display check`:

* **`modetest` prints only the sections it is asked for.** `-p` alone has **no `Connectors:`
  section at all**, so any connector lookup over that output finds nothing and reports
  "no connected DisplayPort connector" on a working board. Always pass `-c -p`.
* **Size the EDID by reading it, not with `test -s`.** `/sys/class/drm/card*-DP-*/edid` is a
  binary sysfs attribute declared with `.size = 0`, so `stat()` reports 0 bytes however much
  data it returns: `[ -s .../edid ]` is false while `wc -c < .../edid` says 256.
```

An EDID that really is empty with `status=connected` means the hot-plug pin is asserted but the
AUX channel is not working — suspect the `psgtr` reference-clock node before anything in the PL.

**Is there a connector at all?** If `modetest -c` lists zero connectors, the mixer did not attach
to the DisplayPort bridge. Check `/proc/cmdline` for `xlnx_mixer.connect_drm_bridge=1` first; then
`dmesg | grep -iE 'dpsub|mixer'` for `DP output port not connected` (the `dp-connector` node is
missing or unlinked) or `'xlnx,video-format' property missing`.

**Did a mode actually get programmed?** The timing controller and the pixel clock tell you,
without a monitor:

```
devmem2 0xA2010000 w        # v_tc CTL: bit0 set = the generator is running
devmem2 0xA2010060 w        # v_tc GASIZE: height<<16 | width -> 0x04380780 for 1920x1080
cat /sys/kernel/debug/clk/*clk_out1*/clk_rate    # 148500000 for 1080p60
```

A pixel clock that is not the mode's clock is the classic symptom of a mis-assigned PL clock in
the generated device tree.

**Is the mixer compositing?**

```{warning}
The video mixer is an HLS core: its AXI4-Lite port runs in the 250 MHz `pl_clk1` domain, and the
control interconnect crosses into it. **If `pl_clk1` is stopped, a read of a mixer register never
completes and hangs the CPU that issued it** — the same failure mode as touching the Chip2Chip
window with the link down, and it needs the same recovery: a power cycle, not a reboot.
`system-user.dtsi` pins `pl_clk1` on with an `xlnx,fclk` node, and `c2c-display check` confirms
`/sys/kernel/debug/clk/pl1_ref/clk_enable_count` before reading anything (pass `-f` to override).
Check it yourself before using `devmem` by hand. The timing controller and the clock wizard are in
the `pl_clk0` domain and are always safe.
```

```
devmem2 0xA2000000 w        # AP_CTRL: auto-restart (bit7) set, idle (bit2) clear
devmem2 0xA2000010 w        # active width  -> 0x780 (1920)
devmem2 0xA2000018 w        # active height -> 0x438 (1080)
devmem2 0xA2000040 w        # LAYERENABLE: bit1 and bit2 set = both camera layers on
devmem2 0xA2000218 w        # layer 1 width  -> 0x3C0 (960)
devmem2 0xA2000220 w        # layer 1 stride -> 0xB40 (960*3) - proves the RGB24 stride
devmem2 0xA2000240 w        # layer 1 buffer address - must be below 0x80000000
devmem2 0xA2000318 w        # layer 2 width
devmem2 0xA2000340 w        # layer 2 buffer address
```

Layer N's register block starts at `0xA200_0000 + 0x100 * (N+1)`; within a block, `+0x08` is
start X, `+0x10` start Y, `+0x18` width, `+0x20` stride, `+0x28` height and `+0x40` the buffer
address.

A layer buffer address of 0 means `kmssink` never pushed a frame. An address at or above
`0x8000_0000` means the framebuffer landed outside the low DDR — the mixer's AXI master is 32-bit
and would read rubbish.

**Are frames flowing, and are any dropped?**

```
grep -E 'v_mix|vcap|frmbuf' /proc/interrupts   # v_mix count rises at the refresh rate
```

and let GStreamer count for you:

```
sudo gst-launch-1.0 v4l2src device=/dev/video-cam0 io-mode=mmap ! \
  video/x-raw,format=RGB,width=960,height=540,framerate=30/1 ! \
  fpsdisplaysink video-sink="kmssink bus-id=a2000000.v_mix plane-id=35 can-scale=true" \
  text-overlay=false sync=false -v
```

`rendered: N, dropped: 0` with `current:` near the capture rate means every captured frame
reached a mixer layer.

**And, best of all, look at it with a camera.** Two independent optical checks are available on
this bench and they should both be used, in this order:

1. **A webcam on the build host, pointed at the ZCU106's monitor.** Any webcam and any
   snapshot tool will do; the Opsero bench uses a Logitech C920 and a wrapper that writes a
   settled 1920x1080 still. This is the *primary* check, because it is completely independent
   of the design under test — it does not use the Chip2Chip link, the cameras, or anything
   else that could be broken.
2. **CAM0, through the link.** Aim CAM0 at the same monitor, and a frame captured from
   `/dev/video-cam0` and pulled back to the host (`scripts/filedrop.py`,
   `scripts/rgb2png.py`) shows what the monitor is displaying. This closes the loop through
   the whole system at once. With the live camera windows on screen it produces the recursive
   "monitor inside the monitor" effect, which is itself a strong confirmation that both
   halves work.

```{warning}
**Do not answer the colour-order question with one flat colour.** A full-screen saturated
colour is precisely what a webcam's auto white balance and auto exposure compensate away: a
pure blue screen photographed that way came back as pale cyan, and a pure green one as
near-white. Put **several** known colours in the same frame instead — four vertical bars of
red, green, blue and white — so the average is neutral and the comparison is relative:

    # on the build host: a 1920x1080 RGB24 four-bar frame, R,G,B,white
    # on the board:
    gst-launch-1.0 filesrc location=/tmp/bars.rgb ! \
      rawvideoparse use-sink-caps=false width=1920 height=1080 format=rgb framerate=10/1 ! \
      imagefreeze ! kmssink bus-id=a2000000.v_mix plane-id=35 \
      show-preroll-frame=false sync=false can-scale=true

This is the test that found the G/B crossover of
[section 2](#the-component-order-of-the-live-video-bus): the bars came out red, blue, green,
white. A "solid red" test alone would have shown red and concluded, wrongly, that the mapping
was correct.
```

A second, independent probe that needs no framebuffer at all: the mixer's background-colour
registers with every layer disabled (`0x28` R, `0x30` G, `0x38` V_B on this build). They are
what the screen shows when `modetest -s` sets a mode, because the primary plane is the
tied-off streaming layer.

## 6. Bringing it up the first time

Work up from the parts that cannot fail to the parts that can, so that a failure is always
attributable:

1. Boot with no monitor expectations; check `dmesg` for `xlnx-mixer` and `zynqmp-dpsub` probe
   messages and for a DRM card.
2. `c2c-display check` — connector, EDID, CRTC, planes. No cameras involved.
3. `c2c-display pattern` — a mode is set and colour bars appear. Confirm with the webcam. This
   proves mixer + pixel clock + DisplayPort, still with no cameras and no link.
4. `c2c-cameras status` — the service should already have brought the cameras up at boot.
   Capture a frame to a file to confirm they still work (the display path must not have
   disturbed them).
5. `c2c-display` — both windows. It rescales the pipelines to 960x540 on the way. Confirm with
   the webcam, then with a CAM0 capture.
6. Check colour order against a **four-bar** frame, not a solid colour (see the warning in
   section 5).
7. `systemctl restart c2c-cameras` — the pipelines go back to 1920x1080, proving the display
   borrowed them rather than took them over.

What this order found the first time it was run, for reference: steps 1-3 passed unchanged —
probe, connector, EDID, mode set and a lit screen all worked on the first attempt — and the
only hardware change needed was the green/blue crossover of section 2, found at step 6. The
rest of the findings were in the tooling: `check` looked at a `modetest` dump with no
connectors in it, sized the EDID with `test -s`, and the rescale path dropped the picture
controls (`set --` inside a loop over `"$@"`). None of them was visible without a monitor,
which is the argument for doing steps 3 and 5 with a camera pointed at the screen.

## 7. Known limitations

* The mixer layers cannot downscale, so the capture size and the window size must be equal.
  `c2c-display` reconfigures the remote scaler to match, which means running it changes what
  `c2c-cameras.service` configured until the service is restarted. `-k` forbids that.
* 1080p60 only. The timing controller is configured for it and the pixel clock wizard is built
  around it; other modes need the refresh rate pinned to something the wizard can make.
* Layer 0 (the mixer's streaming master layer) is tied off in hardware but still appears as the
  DRM *primary* plane. Setting a mode on it is what `modetest -s` does and is harmless — what is
  actually displayed behind the camera windows is the mixer's background colour.
* There is no on-screen text, cursor or window decoration: `kmssink` writes pixels to a plane and
  nothing else is running on the DRM card.
