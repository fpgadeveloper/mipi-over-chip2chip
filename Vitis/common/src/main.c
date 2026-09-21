/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * MIPI over Chip2Chip - bare-metal demo for the ZCU106.
 *
 * WHAT THIS DEMONSTRATES
 * ----------------------
 * Every camera IP this application drives lives in a DIFFERENT FPGA - the
 * Artix UltraScale+ of the Tria AUBoard 15P - and is reached over an AXI
 * Chip2Chip link on an SFP+ cable.  None of it is in the ZCU106 hardware
 * hand-off (XSA).  The standalone BSP nevertheless has the drivers and their
 * configuration tables, because the platform was built with a User Device Tree
 * that describes the remote hardware: Vitis/common/dts/remote_pipeline.dtsi.
 * Every base address below is an XPAR_* macro that came out of that file.
 *
 * WHAT IT DOES
 * ------------
 *   1. check the Chip2Chip link and REFUSE to go on if it is down
 *   2. probe both cameras over the remote AXI IIC
 *   3. bring each pipeline up: GPIO, reset release, IMX219 at 1920x1080,
 *      demosaic, gamma LUT, scaler, frame buffer writer
 *   4. capture CAPTURE_FRAMES frames per camera into the DDR of the ZCU106
 *   5. freeze: stop each writer on a frame boundary and switch the sensors
 *      off, so that the frames in DDR are static and a JTAG dump cannot race
 *      the hardware; report frame counts, frame rate and the frozen addresses
 *   6. idle, watching the link, so that a host can dump the frames over JTAG
 *      (scripts/jtag/zcu106_baremetal.tcl does all of this)
 *
 *   IMX219 --CSI-2--> csi2_rx -> subset(10->8) -> demosaic -> gamma
 *     -> scaler -> frmbuf_wr ==link==> ZCU106 DDR
 *
 * INTERRUPTS
 * ----------
 * The remote IP interrupt through an AXI INTC that is cascaded into the GIC.
 * The User DTS describes that (and the generated config tables carry the right
 * IntrId / IntrParent), but XSetupInterruptSystem() cannot wire that topology
 * up on a Cortex-A53: for an AXI INTC parent it installs XIntc_InterruptHandler
 * as the CPU's IRQ vector, which bypasses the GIC instead of hanging below it.
 * This application therefore POLLS.  See docs/source/baremetal.md.
 */

#include <stdint.h>

#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xstatus.h"
#include "sleep.h"

#include "config.h"
#include "frmbuf.h"
#include "i2c.h"
#include "imx219.h"
#include "link.h"
#include "pipe.h"
#include "remote.h"
#include "timer.h"

#define now_ms()  TimerNowMs()

#define APP_MAJ_VERSION 1
#define APP_MIN_VERSION 0

#define LINK_WAIT_MS    5000

/*
 * The two pipelines.  The base addresses are the XPAR_* macros the platform
 * generated FROM THE USER DTS - if the User DTS did not reach the platform
 * build, this file does not compile, which is exactly the check we want.
 */
static VideoPipe Cam0;
static VideoPipe Cam2;

static const VideoPipeBaseAddr CamBaseAddr0 = {
	XPAR_CAM0_GPIO_BASEADDR,
	XPAR_CAM0_IIC_BASEADDR,
	XPAR_CAM0_DEMOSAIC_BASEADDR,
	XPAR_CAM0_GAMMA_BASEADDR,
	XPAR_CAM0_VPSS_BASEADDR,
	XPAR_CAM0_FRMBUF_BASEADDR,
	CAM0_FRMBUF_BASEADDR
};

static const VideoPipeBaseAddr CamBaseAddr2 = {
	XPAR_CAM2_GPIO_BASEADDR,
	XPAR_CAM2_IIC_BASEADDR,
	XPAR_CAM2_DEMOSAIC_BASEADDR,
	XPAR_CAM2_GAMMA_BASEADDR,
	XPAR_CAM2_VPSS_BASEADDR,
	XPAR_CAM2_FRMBUF_BASEADDR,
	CAM2_FRMBUF_BASEADDR
};

typedef struct {
	VideoPipe               *Pipe;
	const VideoPipeBaseAddr *Base;
} CamEntry;

static CamEntry Cams[] = {
	{ &Cam0, &CamBaseAddr0 },
	{ &Cam2, &CamBaseAddr2 },
};
#define NUM_CAMS (sizeof(Cams) / sizeof(Cams[0]))

static const u8 CamIndex[NUM_CAMS] = { 0, 2 };

static void print_banner(void)
{
	xil_printf("\r\n\r\n");
	xil_printf("################################################################\r\n");
	xil_printf("#   MIPI over Chip2Chip - bare-metal camera demo  v%d.%d         #\r\n",
		   APP_MAJ_VERSION, APP_MIN_VERSION);
	xil_printf("#   ZCU106 (host) + Tria AUBoard 15P + RPi Camera FMC (OP068)  #\r\n");
	xil_printf("################################################################\r\n");
	xil_printf("\r\n");
	xil_printf("The camera IP of this design is in the FPGA of the AUBoard, not\r\n");
	xil_printf("in the ZCU106. The drivers below came from the User DTS of the\r\n");
	xil_printf("platform (Vitis/common/dts/remote_pipeline.dtsi).\r\n");
	xil_printf("\r\n");
	xil_printf("  remote window : 0x%08X (AXI Chip2Chip)\r\n",
		   (unsigned)(REMOTE_INTC_BASEADDR & 0xFF000000u));
	xil_printf("  remote INTC   : 0x%08X\r\n", (unsigned)REMOTE_INTC_BASEADDR);
	xil_printf("  CAM0 base     : 0x%08X   CAM2 base     : 0x%08X\r\n",
		   (unsigned)XPAR_CAM0_CSI_BASEADDR, (unsigned)XPAR_CAM2_CSI_BASEADDR);
	xil_printf("  link status   : 0x%08X (on the ZCU106)\r\n",
		   (unsigned)LINK_GPIO_BASEADDR);
	xil_printf("\r\n");
}

/*
 * Per-camera timing of the capture.  The two cameras do NOT start at the same
 * instant - programming an IMX219 is about sixty register writes on a 100 kHz
 * I2C bus, so the second camera starts a good third of a second after the
 * first - and measuring both against one common start time would understate
 * the rate of whichever started last.  Each camera is therefore timed from its
 * OWN first frame to its own last one.
 */
typedef struct {
	u32 FirstMs;      /* when this camera's first frame completed */
	u32 LastMs;       /* when its last one did */
	u32 MaxGapMs;     /* longest interval between two consecutive frames */
} CamTiming;

/*****************************************************************************/
/**
 * Capture loop: poll both frame buffer writers until every active camera has
 * produced CAPTURE_FRAMES frames, or until one of them stalls.
 */
static void capture(CamEntry *active[], int nactive, CamTiming timing[])
{
	u32 start = now_ms();
	u32 last_progress[NUM_CAMS];
	int stalled[NUM_CAMS];
	int done = 0;

	for (int i = 0; i < nactive; i++) {
		last_progress[i] = start;
		stalled[i] = FALSE;
		timing[i].FirstMs = 0;
		timing[i].LastMs = 0;
		timing[i].MaxGapMs = 0;
	}

	xil_printf("Capturing %d frames per camera ...\r\n", CAPTURE_FRAMES);

	while (done < nactive) {
		u32 t = now_ms();

		done = 0;
		for (int i = 0; i < nactive; i++) {
			Frmbuf *fb = &(active[i]->Pipe->Frmbuf);

			if (FrmbufPoll(fb)) {
				if (fb->FrameCount == 1) {
					timing[i].FirstMs = t;
				} else {
					u32 gap = t - timing[i].LastMs;

					if (gap > timing[i].MaxGapMs) {
						timing[i].MaxGapMs = gap;
					}
				}
				timing[i].LastMs = t;
				last_progress[i] = t;
			}
			if (fb->FrameCount >= CAPTURE_FRAMES || stalled[i]) {
				done++;
			} else if ((t - last_progress[i]) > CAPTURE_TIMEOUT_MS) {
				xil_printf("  CAM%d: no frame for %d ms, giving up "
					   "(%u frames captured)\r\n",
					   active[i]->Pipe->Index, CAPTURE_TIMEOUT_MS,
					   (unsigned)fb->FrameCount);
				stalled[i] = TRUE;
				done++;
			}
		}
		/* Watch the link while we wait: a drop here explains everything. */
		if ((LinkStatus() & LINK_ST_READY_MASK) != LINK_ST_READY_MASK) {
			xil_printf("  ERROR: the Chip2Chip link went down during "
				   "the capture\r\n");
			LinkPrintStatus("  link status: ");
			return;
		}
	}
}

/*****************************************************************************/
/**
 * Stop with a whole frame in DDR: freeze the writers first (they need the
 * stream to be running to reach a frame boundary), then stop the sensors, so
 * that nothing at all writes the frame buffers while they are dumped.
 */
static void freeze(CamEntry *active[], int nactive, u32 captured[])
{
	xil_printf("\r\nFreezing the frames in DDR:\r\n");
	for (int i = 0; i < nactive; i++) {
		VideoPipe *p = active[i]->Pipe;

		captured[i] = p->Frmbuf.FrameCount;
		xil_printf("  CAM%d: ", p->Index);
		if (FrmbufFreeze(&(p->Frmbuf)) == XST_SUCCESS) {
			xil_printf("writer stopped on a whole frame at 0x%08X\r\n",
				   (unsigned)p->Frmbuf.LastGoodAddr);
		} else {
			xil_printf("WARNING: no frame completed within %d ms, the frame "
				   "at 0x%08X may be torn\r\n", FREEZE_TIMEOUT_MS,
				   (unsigned)p->Frmbuf.LastGoodAddr);
		}
	}
	for (int i = 0; i < nactive; i++) {
		(void)Imx219StopStreaming(&(active[i]->Pipe->Iic));
	}
	xil_printf("  the sensors are stopped: nothing writes the DDR any more\r\n");
}

/*****************************************************************************/
/**
 * Publish the frozen frame addresses in DDR for a JTAG host - see remote.h.
 * Written last, magic first cleared and set at the end, so a host that reads
 * it while it is being written cannot see a half-filled block.
 */
static void publish_info(CamEntry *active[], int nactive, const u32 captured[])
{
	Frmbuf *fb0 = &(active[0]->Pipe->Frmbuf);
	u32 w = 0;

	Xil_Out32(APP_INFO_ADDR, 0);
	Xil_Out32(APP_INFO_ADDR + 4 * (++w), (u32)nactive);
	Xil_Out32(APP_INFO_ADDR + 4 * (++w), fb0->Width);
	Xil_Out32(APP_INFO_ADDR + 4 * (++w), fb0->Height);
	Xil_Out32(APP_INFO_ADDR + 4 * (++w), fb0->Stride);
	Xil_Out32(APP_INFO_ADDR + 4 * (++w), fb0->SizeBytes);
	for (int i = 0; i < nactive && w + 3 < APP_INFO_WORDS; i++) {
		Xil_Out32(APP_INFO_ADDR + 4 * (++w), active[i]->Pipe->Index);
		Xil_Out32(APP_INFO_ADDR + 4 * (++w),
			  (u32)active[i]->Pipe->Frmbuf.LastGoodAddr);
		Xil_Out32(APP_INFO_ADDR + 4 * (++w), captured[i]);
	}
	Xil_Out32(APP_INFO_ADDR, APP_INFO_MAGIC);
	Xil_DCacheFlushRange(APP_INFO_ADDR, APP_INFO_WORDS * 4);
}

static void report(CamEntry *active[], int nactive, const u32 captured[],
		   const CamTiming timing[], u32 elapsed_ms)
{
	xil_printf("\r\nResults after %u ms:\r\n", (unsigned)elapsed_ms);
	xil_printf("  cam  frames    fps   max gap  geometry    stride   "
		   "frame size   frozen frame\r\n");
	for (int i = 0; i < nactive; i++) {
		VideoPipe *p = active[i]->Pipe;
		Frmbuf *fb = &(p->Frmbuf);
		/* Timed from this camera's own first frame - see CamTiming. */
		u32 span    = timing[i].LastMs - timing[i].FirstMs;
		u32 fps_x10 = (span && captured[i] > 1)
			      ? ((captured[i] - 1) * 10000u) / span : 0;

		xil_printf("  %-3d  %-8u  %2u.%1u  %3u ms   %4ux%-5u  %-7u  %-11u  "
			   "0x%08X\r\n",
			   p->Index, (unsigned)captured[i],
			   (unsigned)(fps_x10 / 10), (unsigned)(fps_x10 % 10),
			   (unsigned)timing[i].MaxGapMs,
			   (unsigned)fb->Width, (unsigned)fb->Height,
			   (unsigned)fb->Stride, (unsigned)fb->SizeBytes,
			   (unsigned)fb->LastGoodAddr);
	}
	xil_printf("\r\n'max gap' is the longest interval between two consecutive\r\n");
	xil_printf("frames: one frame period means no frame was dropped.\r\n");
	xil_printf("\r\nThe frames are RGB8: 3 bytes per pixel, R first, no padding\r\n");
	xil_printf("between pixels; a line is 'stride' bytes. Dump one with\r\n");
	xil_printf("  mrd -bin -file cam0.bin 0x%08X %u\r\n",
		   (unsigned)active[0]->Pipe->Frmbuf.LastGoodAddr,
		   (unsigned)(active[0]->Pipe->Frmbuf.SizeBytes / 4));
	xil_printf("and convert it with scripts/rgb2png.py.\r\n");
}

int main(void)
{
	CamEntry *active[NUM_CAMS];
	CamTiming timing[NUM_CAMS];
	u32 captured[NUM_CAMS] = { 0 };
	int nactive = 0;
	u32 t_start, t_end;

	print_banner();

	/* ---------------------------------------------------------------
	 * 1. The link.  NOTHING in the 0xA000_0000 window may be touched
	 *    before this passes: an access with the link down never
	 *    completes and the A53 hangs until the board is power cycled.
	 * --------------------------------------------------------------- */
	LinkPrintStatus("Chip2Chip link status: ");
	if (!LinkIsUp(LINK_WAIT_MS)) {
		xil_printf("\r\nERROR: the AXI Chip2Chip link to the AUBoard is DOWN.\r\n");
		xil_printf("Nothing on the remote side can be accessed - an AXI access\r\n");
		xil_printf("into the 0xA000_0000 window would never complete and would\r\n");
		xil_printf("hang this CPU. Stopping here.\r\n\r\n");
		xil_printf("Check that:\r\n");
		xil_printf("  - the AUBoard is powered and programmed with the "
			   "'auboard' bitstream\r\n");
		xil_printf("  - the SFP+ cable is in SFP0 of the ZCU106 and the SFP "
			   "cage of the AUBoard\r\n");
		xil_printf("  - the PL of the ZCU106 was programmed and pl_resetn0 "
			   "released\r\n");
		for (;;) {
			sleep(1);
		}
	}
	xil_printf("Link is up.\r\n\r\n");

	/* ---------------------------------------------------------------
	 * 2. Probe the cameras.
	 * --------------------------------------------------------------- */
	xil_printf("Probing the cameras:\r\n");
	for (unsigned i = 0; i < NUM_CAMS; i++) {
		xil_printf("  CAM%d:\r\n", CamIndex[i]);
		if (pipe_probe(Cams[i].Pipe, CamIndex[i], Cams[i].Base) == XST_SUCCESS) {
			xil_printf("      IMX219 found (model id 0x%04X)\r\n",
				   Cams[i].Pipe->SensorModelId);
			active[nactive++] = &Cams[i];
		}
	}
	if (nactive == 0) {
		xil_printf("\r\nERROR: no camera answered. Check that the RPi Camera FMC\r\n");
		xil_printf("is fitted to the AUBoard and that a camera is connected to\r\n");
		xil_printf("CAM0 or CAM2 with the ribbon cable the right way round.\r\n");
		for (;;) {
			sleep(1);
		}
	}

	/* ---------------------------------------------------------------
	 * 3. Configure the pipelines.
	 * --------------------------------------------------------------- */
	xil_printf("\r\nConfiguring the video pipelines:\r\n");
	for (int i = 0; i < nactive; i++) {
		xil_printf("  CAM%d: ", active[i]->Pipe->Index);
		if (pipe_init(active[i]->Pipe, active[i]->Base) != XST_SUCCESS) {
			xil_printf("FAILED\r\n");
			active[i]->Pipe->IsConnected = FALSE;
		} else {
			xil_printf("ok\r\n");
		}
	}

	/* Drop the ones that failed. */
	{
		int n = 0;
		for (int i = 0; i < nactive; i++) {
			if (active[i]->Pipe->IsConnected) {
				active[n++] = active[i];
			}
		}
		nactive = n;
	}
	if (nactive == 0) {
		xil_printf("\r\nERROR: no pipeline could be configured.\r\n");
		for (;;) {
			sleep(1);
		}
	}

	/* ---------------------------------------------------------------
	 * 4. Start the sensors and capture.
	 * --------------------------------------------------------------- */
	xil_printf("\r\nStarting the cameras:\r\n");
	for (int i = 0; i < nactive; i++) {
		xil_printf("  CAM%d: ", active[i]->Pipe->Index);
		if (pipe_start_camera(active[i]->Pipe) != XST_SUCCESS) {
			xil_printf("FAILED\r\n");
		} else {
			xil_printf("streaming\r\n");
		}
	}
	xil_printf("\r\n");

	t_start = now_ms();
	capture(active, nactive, timing);
	t_end = now_ms();

	/* ---------------------------------------------------------------
	 * 5. Freeze and report.  A 6 MB JTAG dump takes seconds, during which
	 *    a running writer would go round its slots hundreds of times, so
	 *    the writers are stopped on a frame boundary and the sensors are
	 *    switched off before anything reads the DDR.  That path is not
	 *    coherent with the A53 caches (it comes in through S_AXI_HP0_FPD),
	 *    so FrmbufFreeze() also invalidates the frozen frame.
	 * --------------------------------------------------------------- */
	freeze(active, nactive, captured);
	publish_info(active, nactive, captured);
	report(active, nactive, captured, timing, t_end - t_start);

	LinkPrintStatus("\r\nChip2Chip link status: ");

	/* ---------------------------------------------------------------
	 * 6. Idle.  The frames are frozen in DDR; keep watching the link so
	 *    that it is obvious the system is still alive and that a dump
	 *    which fails is not failing because the link went away.
	 * --------------------------------------------------------------- */
	xil_printf("\r\nIdle - the frames are frozen in DDR. Dump them over JTAG now.\r\n\r\n");

	for (;;) {
		sleep(5);
		xil_printf("  alive: ");
		for (int i = 0; i < nactive; i++) {
			xil_printf("CAM%d %u frames frozen at 0x%08X  ",
				   active[i]->Pipe->Index, (unsigned)captured[i],
				   (unsigned)active[i]->Pipe->Frmbuf.LastGoodAddr);
		}
		LinkPrintStatus("link ");
	}

	return 0;
}
