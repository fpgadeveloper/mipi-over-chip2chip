/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * Every configuration parameter of the demo in one place.
 *
 * The addresses of the remote IP are NOT here: they come from the platform,
 * out of the User DTS (Vitis/common/dts/remote_pipeline.dtsi) by way of
 * xparameters.h.  See remote.h.
 */

#ifndef CONFIG_H_
#define CONFIG_H_

/* ---- video mode ---------------------------------------------------------
 * The IMX219 is programmed for 1920x1080 (the register table of the
 * rpi-camera-fmc reference application) and the scaler passes the frame
 * through 1:1: unlike the reference design, this one does not have to shrink
 * the picture to fit four streams on one screen.  Both cameras at 1080p RGB8
 * have been measured through this link at the sensor's full 47.6 frames/s.
 */
#define VMODE_WIDTH          1920
#define VMODE_HEIGHT         1080
#define VMODE_FRAMERATE      60      /* the video-timing table entry to use */

#define VPROC_WIDTH_OUT      1920
#define VPROC_HEIGHT_OUT     1080
#define VPROC_FRAMERATE_OUT  60

#define COLOR_FORMAT_ID      XVIDC_CSF_RGB

/* ---- gamma --------------------------------------------------------------
 * The gamma LUT powers up LINEAR, which gives a dark, contrasty picture, and
 * this pipeline has no automatic white balance, so raw RGB comes out green
 * (green has twice as many Bayer samples as red or blue).
 *
 * The Linux side of this design fixes both with ONE mechanism: a PER CHANNEL
 * gamma EXPONENT, out = 255 * (in/255)^g, with red and blue lifted harder than
 * green so that the stronger lift stands in for the missing white balance.
 * The triple below is the one measured there - v4l2 controls
 * red/green/blue_gamma_correction = 5 / 6 / 5, i.e. exponents 0.5 / 0.6 / 0.5 -
 * see docs/source/linux_cameras.md section 4.  1.0 = linear = no correction.
 *
 * Gamma LUT 0/1/2 drive memory bytes 0/1/2 = R/G/B; that mapping was measured
 * on this hardware (logs/mipi-over-chip2chip/phase6_baremetal.md), not assumed.
 */
#define GAMMA_RED            0.50
#define GAMMA_GREEN          0.60
#define GAMMA_BLUE           0.50

#define PIXEL_SIZE           8       /* bits per component */
#define GAMMA_TABLE_SIZE     256     /* 2^PIXEL_SIZE */
#define GAMMA_TABLE_MAX      255     /* the full scale the exponent works on */

/* ---- capture ------------------------------------------------------------ */
/* Frames to capture per camera before the application freezes and idles. */
#define CAPTURE_FRAMES       60
/* Give up on a camera that has not produced a frame in this many milliseconds. */
#define CAPTURE_TIMEOUT_MS   5000
/*
 * Freeze: frames to let the writer put into ONE slot before it is stopped, so
 * that the slot certainly holds a whole frame whatever the exact instant the
 * IP samples its buffer address register.  See FrmbufFreeze().
 */
#define FREEZE_FRAMES        3
#define FREEZE_TIMEOUT_MS    1000

#endif /* CONFIG_H_ */
