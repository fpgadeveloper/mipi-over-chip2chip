# Using the cameras from Linux

The two camera pipelines are on the AUBoard 15P; the ZCU106 reaches their registers through the
AXI Chip2Chip window at `0xA000_0000` and receives the frames by DMA into its own DDR. To Linux
they are ordinary V4L2 capture devices once the device-tree overlay has been applied.

Everything on this page was measured on hardware (ZCU106 + AUBoard 15P, AMD EDF Yocto,
linux-xlnx 6.12.40, both cameras Raspberry Pi Camera Module v2 on `CAM0` and `CAM2` of the
RPi Camera FMC).

## Before you start

The drivers of the remote peripherals are built into the kernel and touch their registers in
probe. **A register access through the link while the link is down never completes and hangs the
CPU**, so the nodes are not in the base device tree: they are added at run time, after a link
check, by a device-tree overlay.

The image does all of that by itself at boot (below). The manual procedure is kept in
[section 1b](#1b-doing-it-by-hand) because it is what the service automates, and because it is
what you fall back to while debugging.

(automatic-start)=
## 1. The cameras come up by themselves

The image ships the compiled overlay, the pipeline init script and a systemd service that puts
them together:

| File on the board | What |
|---|---|
| `/lib/firmware/c2c/c2c-cams.dtbo` | the compiled overlay of both pipelines (and `c2c-cams-flat.dtbo`, the fallback variant) |
| `/usr/bin/c2c-init-cams` | the pipeline init script (also reachable as `init_c2c_cams.sh`) |
| `/usr/bin/c2c-cameras` | the bring-up logic: `start`, `stop`, `status`, `health` |
| `/lib/systemd/system/c2c-cameras.service` | runs `c2c-cameras start` at boot; **enabled by default** |
| `/etc/default/c2c-cameras` | the settings below |
| `/etc/udev/rules.d/99-c2c-cameras.rules` | the stable names `/dev/video-cam0` / `/dev/video-cam2` and friends ([below](#stable-names)) |

**Nothing has to be done after a power-on.** With the AUBoard 15P powered and programmed, the
cameras are ready a few seconds after the login prompt:

```
systemctl status c2c-cameras
sudo c2c-cameras status
v4l2-ctl -d /dev/video-cam0 --stream-mmap=4 --stream-count=60 --stream-to=/tmp/cam0.rgb
```

What the service does, and why in this order:

1. **Waits for the link** — polls the link-status GPIO of the ZCU106 itself (`0xA100_0000`,
   always safe to read) for up to `C2C_LINK_TIMEOUT` seconds.
2. **Checks that the AUBoard is running _this_ design** — a link that is up only proves that two
   AXI Chip2Chip cores found each other, not that the address map behind it has camera
   pipelines. The service reads, read-only, the AUBoard's link-status GPIO (`0xA000_0008`, which
   every design of this repository has) and then the two per-pipeline GPIOs (`0xA012_0000` and
   `0xA022_0000`), which **only the camera design has**. An unmapped address in the window is not
   a hang: the AUBoard's AXI4-Lite interconnect answers with a DECERR, which arrives here as a
   `SIGBUS` in the reading process and nothing else (measured). So if the AUBoard is running
   another bitstream the probe fails cleanly and the service **refuses to apply the overlay**
   instead of letting every driver probe an address that does not exist.
3. **Checks that the AUBoard has not been reset since the drivers probed.** Read-only, and the
   one check that stops a board-hanging false success — see
   [the health check](#health-check). If it fails the service stops here with exit
   status **5** and says a reboot is needed; nothing further is touched.
4. **Quiesces the remote frame buffer writers** — see the warning below; this is what makes a
   warm `reboot` of the ZCU106 safe.
5. **Applies the overlay, once.** If it is already applied (a manual run, or a retry) it is not
   applied again.
6. **Waits for `/dev/media*` and `/dev/video*`** (up to `C2C_DEV_TIMEOUT` seconds).
7. **Runs `c2c-init-cams`** with the configured format and applies the default gamma controls.
8. **Stamps a generation marker** into the AUBoard's scratch BRAM, which is what step 3 of a
   later run compares against.

Everything lands in the journal:

```
journalctl -u c2c-cameras
```

```{warning}
**The AUBoard is not reset when the ZCU106 reboots.** If a capture was running, `v_frmbuf_wr`
is still armed with `AUTO_RESTART` and keeps DMAing frames into whatever physical address the
*previous* Linux gave it — into the memory of the system that is now booting. Before it applies
the overlay (and again at shutdown, through `ExecStop`), the service therefore halts both frame
buffer writers the same way their driver does: clear `ap_start` and `auto_restart` in `AP_CTRL`
and wait for `ap_idle`. That is a graceful stop at the end of the current frame — not a reset,
which applying the overlay would otherwise perform *mid-burst*, because the GPIO driver writes
`xlnx,dout-default = 1` when it probes and that drops all four video resets at once.
```

### When the second board is not there

The ZCU106 boots and runs completely normally; nothing in the system waits for this unit, so the
console, `sshd` and the rest of `multi-user.target` come up in parallel with it. The service
simply reports why the cameras are missing and gives up:

```
$ systemctl status c2c-cameras
× c2c-cameras.service - Remote MIPI cameras over AXI Chip2Chip
     Active: failed (Result: exit-code)
...
c2c-cameras[…]: the Chip2Chip link did not come up within 60s (status 0x00000004). The AUBoard
                15P is off, not programmed, or the cable is out - the cameras are NOT available.
c2c-cameras[…]: This is not fatal: the ZCU106 boots and runs normally without the second board.
                Power up and program the AUBoard, then retry with: systemctl restart c2c-cameras
```

The unit is left **failed** on purpose: it is what makes the state visible in
`systemctl status`.

### Bringing the cameras up later

Power up and program the AUBoard after the ZCU106 has booted, then:

```
sudo c2c-link-status -w 30          # optional: watch the link train
sudo systemctl restart c2c-cameras  # or: sudo c2c-cameras start
sudo c2c-cameras status
```

```{important}
**The retry is `restart`, not `start`.** systemd re-runs a `oneshot` unit on `start` only
while the unit is **not** active, and this unit stays `active (exited)` after a successful
boot (it has to, so that `ExecStop` can halt the remote frame buffer writers at shutdown).
So `systemctl start c2c-cameras` on a board whose cameras came up at boot is a silent no-op —
measured at 0.084 s with nothing written to the journal. That is harmless when the unit is
`failed` (no second board at boot), and exactly wrong in the case where a retry is most
tempting: the AUBoard was power-cycled while this board kept running.

`restart` is safe in every state. Everything the script does is idempotent: the overlay is
applied at most once per boot and a second attempt is skipped rather than repeated
(`overlay 'cams' is already applied, not applying it again`), and `ExecStop` only touches
frame buffer writers that are out of reset.
```

Both forms are idempotent and run exactly the same checks as the boot-time run.

(health-check)=
### Is it safe to capture right now? — `c2c-cameras health`

```
sudo c2c-cameras health
```

One line, read-only, and cheap enough to call from a capture wrapper before every run: it
reads the link status GPIO of this board and one register per remote pipeline, none of which
is ever held in reset. **Call it before opening a capture device in a script.** The exit
status is what to branch on:

| exit | meaning |
|---|---|
| 0 | link up, both pipelines out of reset — safe to capture |
| 3 | the Chip2Chip link is down |
| 4 | the link is up but the AUBoard is not running this design |
| **5** | **the AUBoard was reset behind the drivers' back — a reboot is required, and capturing now would hang the CPU** |

`c2c-cameras status` ends with the same verdict as a `health :` line and exits with the same
status, so a status that says `service state : ready` can no longer hide a dead mezzanine.

Exit 5 is the condition acceptance test T5 found. Two independent signals produce it, and
**both are needed**:

* **the per-pipeline GPIOs.** Bits 2, 3, 4 and 6 of `0xA012_0000` / `0xA022_0000` are the
  `reset_n` of `v_demosaic`, `v_proc_ss`, `v_gamma_lut` and `v_frmbuf_wr`. They read 0 at
  power-up and are set by the Linux drivers in their probe, so "the overlay is applied but a
  `reset_n` reads 0" is the dangerous state itself, observed directly. This fires the instant
  the AUBoard comes back.
* **a generation marker** in the AUBoard's scratch BRAM (the last 16 bytes of the 8 KiB at
  `0xA001_0000`, clear of `c2c-latency`). A successful bring-up stamps a magic word and a
  random generation there; reloading the AUBoard's fabric clears the BRAM.

The marker is not redundant, and the reason is worth knowing: **the GPIO signal does not
last.** Measured — immediately after an AUBoard power cycle both GPIOs read `0x01` and the
GPIO check fired; then a running capture was stopped, an ordinary stream teardown, and both
GPIOs read `0x5D` again with nobody having poked anything. The `gpio-xilinx` driver keeps the
output word in software, the video drivers touch their reset lines when a stream is released,
and the driver wrote its cached `0x5D` back into a register the mezzanine had reset to `0x01`.
The register then *looks* healthy while the IPs are still dead — the same trap as writing
`0x5D` by hand, except the drivers did it themselves. From that moment the marker is the only
thing that still knows.

If the marker cannot be written (an unreadable or read-only scratch BRAM) the service says so
and carries on with the GPIO check alone; detection is then weaker after a stream teardown.

### Settings — `/etc/default/c2c-cameras`

| Variable | Default | What |
|---|---|---|
| `C2C_CAMERAS_ENABLE` | `1` | `0` makes the service do nothing and succeed |
| `C2C_LINK_TIMEOUT` | `60` | seconds to wait for the link at boot |
| `C2C_DEV_TIMEOUT` | `30` | seconds to wait for the video devices after the overlay |
| `C2C_CAM_WIDTH` / `C2C_CAM_HEIGHT` | `1920` / `1080` | sensor mode (see section 2 for the legal ones) |
| `C2C_CAM_OUT_WIDTH` / `C2C_CAM_OUT_HEIGHT` | = sensor mode | size after the scaler |
| `C2C_CAM_CTRLS` | the gamma triple of section 4 | controls applied to every capture node; `""` leaves the driver defaults |
| `C2C_PROBE` | `1` | the design check of step 2. Leave it on |
| `C2C_NOLINK_STATUS` | `1` | `0` reports a missing link as success, for a ZCU106 used on its own (the retry is then `systemctl restart`) |

After a change: `sudo systemctl restart c2c-cameras`.

(1b-doing-it-by-hand)=
## 1b. Doing it by hand

This is the procedure the service automates; it still works, unchanged. Use it to apply a
modified overlay, or when you want to watch each step.

```
sudo systemctl stop c2c-cameras     # so it does not race you (only if it is active)
sudo c2c-link-status                # must say: link: UP
sudo c2c-overlay apply cams /lib/firmware/c2c/c2c-cams.dtbo
sudo c2c-init-cams                  # = init_c2c_cams.sh, 1080p RGB24 on both cameras
```

To build a modified overlay on the host and try it without rebuilding the image, edit
`Yocto/overlays/c2c-cams.dtso` — the **one** copy in the repository, the same file the image
recipe compiles — and:

```
cd Yocto/overlays
./build-overlay.sh --check          # -> out/c2c-cams.dtbo
```

then copy `out/c2c-cams.dtbo` to the board and hand it to `c2c-overlay apply`. `c2c-cameras
start` will use it too if you point `C2C_OVERLAY_FILE` at it.

Expected: `overlay 'cams' applied`, and in `dmesg`:

```
irq-xilinx: /amba_pl/bus@a0000000/interrupt-controller@a0040000: num_irq=10, edge=0x0
xilinx-frmbuf a0150000.v_frmbuf_wr: Xilinx AXI FrameBuffer Engine Driver Probed!!
xilinx-vpss-scaler a0180000.v_proc_ss: VPSS Scaler Probe Successful
xilinx-gamma-lut a0140000.v_gamma_lut: Xilinx 8-bit Video Gamma Correction LUT registered
xilinx-demosaic a0130000.v_demosaic: Xilinx Video Demosaic Probe Successful
xilinx-video amba_pl:bus@a0000000:vcap_mipi_0_v_proc: device registered
```
and the same set for the `a02x_xxxx` addresses (CAM2).

```{note}
`dmesg` also shows about thirty `Fixed dependency cycle(s)` lines, a few
`port@0 initialization failed` / `DMA initialization failed` lines while `xilinx-frmbuf` is still
deferred on its reset GPIO, `Entity type for entity ... was not initialized!` and
`OF: overlay: WARNING: memory leak will occur if overlay removed`. All four are harmless: the
V4L2 graph is cyclic by construction, the capture node retries until the frame buffer writer has
probed, and the overlay is never removed.
```

Rules:

* **Apply once per boot and never remove the overlay.** Removing it unbinds a cascaded interrupt
  controller, a V4L2 async graph and DMA channels, and every unbind touches remote registers. To
  start over, reboot.
* Do not hand the raw `.dtso` to `c2c-overlay`: it contains `#define`s. Use the `.dtbo`, or the
  preprocessed `out/c2c-cams.pp.dtso`.
* Never `devmem` / `c2c-peek` a video IP (demosaic, gamma, `v_proc_ss`, `v_frmbuf_wr`) before the
  overlay has been applied: their reset bits are 0 at power-up and a register access to an IP in
  reset never completes. The drivers release the resets in probe.

After the overlay you have two capture nodes, plus `/dev/v4l-subdev0..9`: sensor, CSI-2 RX,
demosaic, gamma LUT and scaler of each pipeline.

(stable-names)=
### Use the stable names, not the numbers

```{warning}
**Which camera is `/dev/video0` is not fixed — it changes from boot to boot.** The two
pipelines probe in whatever order their drivers finish, so `CAM0` is sometimes `/dev/video0`
and sometimes `/dev/video1`. Measured across consecutive boots of the same image on the same
hardware, the assignment swapped several times. **The sensors' I2C bus numbers move with it**
(`CAM0` has been seen on bus 3 and on bus 4), so those are not an identifier either.

Never hard-code `/dev/video0` = a particular camera in a script.
```

The image therefore ships `/etc/udev/rules.d/99-c2c-cameras.rules`, which gives every node of
both pipelines a name that does not move:

| Stable name | What |
|---|---|
| `/dev/video-cam0`, `/dev/video-cam2` | the capture nodes |
| `/dev/media-cam0`, `/dev/media-cam2` | the media devices |
| `/dev/v4l-subdev-cam<N>-sensor` | the IMX219 |
| `/dev/v4l-subdev-cam<N>-csi` | the MIPI CSI-2 RX subsystem |
| `/dev/v4l-subdev-cam<N>-demosaic`, `-gamma`, `-scaler` | the rest of the pipeline |

```
$ ls -l /dev/video-cam*
/dev/video-cam0 -> video1
/dev/video-cam2 -> video0
```

Use them everywhere:

```
v4l2-ctl -d /dev/video-cam0 --stream-mmap=4 --stream-count=60 --stream-to=/tmp/cam0.rgb
```

The rules key on the **platform device**, not on any number: the capture node and the media
device of a pipeline are both children of `amba_pl:bus@a0000000:vcap_mipi_<N>_v_proc`, and
every sub-device hangs off a platform device named after its register address
(`a01x_xxxx` = CAM0, `a02x_xxxx` = CAM2). `KERNELS==` walks that parent chain, so one key
serves both subsystems. `c2c-display` and `c2c-init-cams` use the stable names when they are
present.

```{note}
**In your own scripts, glob `/dev/video[0-9]*`, not `/dev/video*`.** `/dev/video-cam0` matches
the second pattern as well, so a plain `/dev/video*` loop sees each camera twice. The same
goes for `/dev/media[0-9]*`.
```

Underneath the names, the stable identity of a pipeline is its **entity name** and its
**register addresses**: `CAM0` is `vcap_mipi_0_v_proc` with the IP at `0xA01x_xxxx`, `CAM2` is
`vcap_mipi_2_v_proc` with the IP at `0xA02x_xxxx`. Both are visible in the media graph, which
is what to fall back on if the rules are not installed:

```
for m in /dev/media*; do
    ent=$(media-ctl -d $m -p | grep -oE 'vcap_mipi_[02]_v_proc' | head -1)
    vid=$(media-ctl -d $m -p | grep -oE '/dev/video[0-9]+' | head -1)
    echo "$m -> $vid  ($ent)"
done
```

```
/dev/media0 -> /dev/video0  (vcap_mipi_0_v_proc)     <- CAM0 on this boot
/dev/media1 -> /dev/video1  (vcap_mipi_2_v_proc)     <- CAM2 on this boot
```

`c2c-init-cams` prints the same thing for the boot it ran in — that is why it prints it — and
it is also in the journal (`journalctl -u c2c-cameras`):

```
 - CAM2: /dev/media0 = /dev/video0 (SRGGB10_1X10)
 - CAM0: /dev/media1 = /dev/video1 (SRGGB10_1X10)
```

`v4l2-ctl --list-devices` lists the nodes but does not say which camera is which.

Because of this, **the `/dev/videoN` numbers printed above are only the mapping of one
particular boot.** The examples below all use the stable names; if you work with a node
number instead, check yours before copying a command.

## 2. Set the formats

`c2c-init-cams` (the repository's `Yocto/overlays/init_c2c_cams.sh`, installed in the image;
`init_c2c_cams.sh` is a second name for the same file) configures both pipelines end to end
(links, every pad format, the capture format) and prints which device belongs to which camera.
The service runs it with the sizes from `/etc/default/c2c-cameras`; run it again at any time to
change them:

```
sudo c2c-init-cams                     # 1920x1080 sensor mode, no scaling
sudo c2c-init-cams 1920 1080 1280 720  # 1080p sensor, scaled to 720p
sudo c2c-init-cams 1640 1232 640 480   # binned full field of view, scaled to VGA
```
```
Remote camera pipelines: sensor 1920x1080 -> scaler 1920x1080 RGB3
 - CAM2: /dev/media0 = /dev/video0 (SRGGB10_1X10)
 - CAM0: /dev/media1 = /dev/video1 (SRGGB10_1X10)
```

Sensor modes the IMX219 driver offers: `3280x2464`, `1920x1080`, `1640x1232` (2x2 binned, full
field of view) and `640x480`. **`3280x2464` does not fit the video IP** (max 1920x1232), so the
useful ones are the other three. The scaler can change the size but not the colour space, and the
frame buffer writer has RGB8 only: **the one capture format is `RGB3`
(`V4L2_PIX_FMT_RGB24`, 3 bytes per pixel, byte 0 = R)**.

```{warning}
Always give `bytesperline` when you set the capture format by hand. `xvip_dma` clamps a requested
`bytesperline` only *upwards* to `width * 3`, and `v4l2-ctl --set-fmt-video=width=...` reads the
current format first and writes the untouched fields back — so the stride of a previous, wider
format survives a change to a smaller one and the frame buffer writer keeps advancing by the old
stride. Measured: after 1920x1080, a plain `--set-fmt-video=width=640,height=480,pixelformat=RGB3`
left `bytesperline` at 5760 and every frame came out with 160 lines of picture spread over 480
lines, in a buffer three times too large. `c2c-init-cams` sets `bytesperline` and `sizeimage`
explicitly; do the same if you configure the device yourself:

    v4l2-ctl -d /dev/video-cam0 --set-fmt-video=width=640,height=480,pixelformat=RGB3,bytesperline=1920,sizeimage=921600
```

## 3. Capture

Use MMAP buffers only (`--stream-mmap`, `io-mode=mmap`). The remote frame buffer writers are
32-bit masters that reach only `0x0000_0000 - 0x7FFF_FFFF` of the host DDR, and the overlay's
`dma-ranges` keeps the driver's buffers inside that window; a USERPTR or DMABUF buffer from the
DDR above 4 GB cannot be written by them.

```
# 60 frames of 1080p RGB24 to a raw file (6 220 800 bytes per frame)
v4l2-ctl -d /dev/video-cam0 --stream-mmap=4 --stream-count=60 --stream-to=/tmp/cam0.rgb

# frame rate only, nothing stored: proves the DMA and the interrupts over the link
v4l2-ctl -d /dev/video-cam0 --stream-mmap=6 --stream-count=300

# one file per frame, with the sequence numbers printed
yavta -n 6 -c60 -f RGB24 -s 1920x1080 -F/tmp/cam0-#.rgb /dev/video-cam0

# GStreamer: JPEG files
gst-launch-1.0 v4l2src device=/dev/video-cam0 io-mode=mmap num-buffers=10 ! \
  video/x-raw,format=RGB,width=1920,height=1080 ! videoconvert ! jpegenc ! \
  multifilesink location=/tmp/cam0-%03d.jpg

# GStreamer: frame rate to a fake sink
gst-launch-1.0 -v v4l2src device=/dev/video-cam0 io-mode=mmap num-buffers=300 ! \
  video/x-raw,format=RGB,width=1920,height=1080 ! \
  fpsdisplaysink video-sink=fakesink text-overlay=false sync=false
```

A raw `.rgb` file is turned into a PNG on a build host with `scripts/rgb2png.py`:

```
scripts/rgb2png.py cam0.rgb 1920 1080 --stats -o cam0.png
```

## 4. Picture quality

The pipeline has a demosaic, a gamma LUT and a scaler; it has **no auto-exposure and no automatic
white balance**, and the `v_proc_ss` is built without colour-space conversion. The picture
therefore depends entirely on the controls you set. All of them are on the video node:

```
v4l2-ctl -d /dev/video-cam0 --list-ctrls
```

| Control | Range | Notes |
|---|---|---|
| `exposure` | 4 .. (frame length - 4) | in lines; the maximum follows `vertical_blanking` |
| `analogue_gain` | 0 .. 232 | sensor gain = 256 / (256 - value) |
| `digital_gain` | 256 .. 4095 | 256 = unity; amplifies noise too |
| `vertical_blanking` | 32 .. 64455 | sets the frame rate (below) |
| `horizontal_flip` / `vertical_flip` | 0/1 | **changes the Bayer order**; set it, then re-run `c2c-init-cams` (the boot-time run has already happened) |
| `test_pattern` | menu | `1` = colour bars, generated in the sensor |
| `red_gamma_correction_1_0_1_10`, `green_gamma_correction_1_0_1_1`, `blue_gamma_correction_1_0_1_10` | 1 .. 40 | the gamma **exponent** x10: out = 255 (in/255)^(value/10). **10 = 1.0 = linear** |

Two settings matter most:

* **The gamma LUT defaults to 1.0, i.e. linear light.** Captures then look dark and contrasty.
  Set roughly 0.45, the sRGB display encode, on all three channels (`=4` or `=5`).
* **There is no white balance**, so raw RGB comes out green (green has twice as many Bayer
  samples). Compensate with a slightly *larger* exponent on green.

A good indoor starting point, and the settings used for the sample pictures of this design:

```
v4l2-ctl -d /dev/video-cam0 --set-ctrl=red_gamma_correction_1_0_1_10=5,green_gamma_correction_1_0_1_1=6,blue_gamma_correction_1_0_1_10=5
v4l2-ctl -d /dev/video-cam0 --set-ctrl=exposure=1759,analogue_gain=232,digital_gain=256
```

To check the colour order and the Bayer phase independently of the scene, switch the sensor's
colour bars on: row 540 of the captured frame must read white, yellow, cyan, green, magenta, red,
blue, black, with byte 0 = R, byte 1 = G, byte 2 = B.

```
v4l2-ctl -d /dev/video-cam0 --set-ctrl=test_pattern=1
v4l2-ctl -d /dev/video-cam0 --stream-mmap=4 --stream-count=6 --stream-to=/tmp/bars.rgb
v4l2-ctl -d /dev/video-cam0 --set-ctrl=test_pattern=0
```

## 5. Frame rate and what the link can carry

The sensor, not the link, sets the frame rate. At 1920x1080 the line length is
1920 + 1528 (hblank) = 3448 pixels at a pixel rate of 182.4 MHz, so

    frame time = 3448 x (1080 + vertical_blanking) / 182 400 000

| `vertical_blanking` | frame rate |
|---|---|
| 683 (driver default) | 30.0 fps |
| 32 (minimum) | 47.6 fps |

Measured, both cameras streaming at the same time, `RGB3` out of the frame buffer writers into
host DDR over one Aurora lane at 10.3125 Gb/s (AXI Chip2Chip "compact 2:1"):

| Case | Output size | Measured fps | Bytes/s over the link |
|---|---|---|---|
| CAM0 alone | 1920x1080 | 30.01 | 186.6 MB/s |
| CAM0 alone, `vblank=32` | 1920x1080 | 47.57 | 295.9 MB/s |
| CAM0 + CAM2 together | 1920x1080 | 30.01 each | 373.2 MB/s |
| **CAM0 + CAM2 together, `vblank=32`** | **1920x1080** | **47.57 each** | **591.8 MB/s** |
| CAM0 + CAM2 together, `vblank=32` | 1280x720 (scaler) | 47.57 each | 262.9 MB/s |
| CAM0 + CAM2 together | 640x480 from 1640x1232 (scaler) | 30.01 each | 55.3 MB/s |

Every figure is the sensor's own maximum for that `vertical_blanking`: **the link was never the
limit.** A 42-second soak of both cameras at 1920x1080 and 47.57 fps (2000 frames each) gave:

* exactly 2001 frame-buffer-writer interrupts and 2001 CSI-2 "frame received" interrupts per
  camera in `/proc/interrupts` — a 1:1 match, so **no frame was dropped**;
* `yavta` sequence numbers consecutive, every frame the full `sizeimage`;
* GStreamer `fpsdisplaysink`: `rendered: 289, dropped: 0, current: 30.01`;
* nothing in `dmesg` — in particular no `Stream Line Buffer Full!`, which is what the CSI-2 RX
  driver prints when the frame buffer writers cannot keep up and the back pressure reaches the
  receiver;
* CSI-2 RX `CSR` bit 1 (SLBF) = 0 and `ISR` = `0x0002_0000` (lane stop state only, no error bit)
  on both cameras;
* `c2c-link-status` = `0x0000000F` on the host and `0x0000000F` on the AUBoard: no link error, no
  multi-bit error, no Aurora hard or soft error.

**Sustainable: two 1920x1080 RGB24 streams at the sensor's maximum 47.6 fps, 592 MB/s, with no
frame loss.** That is roughly 60 % of the raw 10.3125 Gb/s lane, and it leaves the register path
responsive at the same time.

## Known limitations

* No auto-exposure, no auto white balance, no colour-space conversion: `RGB3` only, and exposure,
  gain and gamma are set by hand (section 4).
* `3280x2464` (the sensor's full resolution) exceeds the 1920x1232 maximum of the video IP.
* The overlay is applied once per boot and cannot be removed; to change it, reboot.
* `c2c-cameras.service` brings the cameras up **once**, at boot, and does not watch the link
  afterwards. If the AUBoard is power-cycled while the ZCU106 keeps running, the overlay stays
  applied but points at a design that was reset underneath it, and **the only way back is a
  reboot of the ZCU106** — issued *before* anything touches a camera. Linux itself survives
  the event unharmed, but the remote video IPs are back in reset and nothing in the running
  system releases them again. The service now **detects this and refuses** (exit 5, see
  [the health check](#health-check)) instead of reporting success; before that check it
  reported `remote cameras are ready` and the first capture hung the CPU. Measured; see
  [Troubleshooting](troubleshooting). Whether the AUBoard needs re-programming first depends
  on how it was loaded — a design in its configuration flash is back by itself within about
  two seconds and the link retrains on its own, a design loaded over JTAG is gone (see
  [Booting the AUBoard from its configuration flash](flash.md)). Bringing the AUBoard up
  *before* the overlay was ever applied is the case the manual retry
  (`systemctl restart c2c-cameras`) covers.
* **There is no recovery short of a reboot**, by design of the driver stack rather than of this
  service: the resets are released only in `probe`, the overlay cannot be removed safely, and
  an unbind would have to touch registers of IPs that are in reset — which is exactly the
  access that hangs. Writing the running GPIO value back by hand does not revive the IPs
  either (measured twice, see Troubleshooting).
* The service reports "no link" as a failed unit by default. Retry with
  `systemctl restart c2c-cameras` — `start` is a no-op whenever the unit is `active`. Set
  `C2C_NOLINK_STATUS=0` on a ZCU106 that is used without the second board.
* **The camera-to-`/dev/videoN` assignment is not stable across boots**, and neither are the
  sensors' I2C bus numbers. Use the [stable names](#stable-names) (`/dev/video-cam0`,
  `/dev/video-cam2`), or derive them from the media graph (`vcap_mipi_0_*` = `CAM0`,
  `vcap_mipi_2_*` = `CAM2`) — never from the node number.
* Interrupts of `v_demosaic` and `v_gamma_lut` (INTC inputs 6..9) are wired in hardware but no
  Linux driver uses them, so they are not described in the overlay and stay masked.
* The capture buffers must come from the capture driver (MMAP): the remote frame buffer writers
  are 32-bit masters limited to the low 2 GB of the host DDR.
