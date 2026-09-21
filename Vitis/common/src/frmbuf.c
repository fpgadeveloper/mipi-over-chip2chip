/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * See frmbuf.h.
 */

#include "frmbuf.h"
#include "remote.h"
#include "config.h"
#include "timer.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xvidc.h"

/* The IP has HAS_RGB8 and nothing else: 3 bytes per pixel in memory. */
#define FRMBUF_MEM_FORMAT   XVIDC_CSF_MEM_RGB8
#define FRMBUF_STREAM_FORMAT XVIDC_CSF_RGB
#define FRMBUF_BYTES_PER_PIXEL 3

/*****************************************************************************/
/**
 * Stride in bytes: the line length rounded up to a whole number of AXI4 data
 * beats.  The master is 64 bit wide here, so the stride is a multiple of 8
 * (xlnx,dma-align in the device tree).
 */
static u32 CalcStride(u32 width, u16 AXIMMDataWidth)
{
	u32 MMWidthBytes = AXIMMDataWidth / 8;
	u32 line = width * FRMBUF_BYTES_PER_PIXEL;

	return ((line + MMWidthBytes - 1) / MMWidthBytes) * MMWidthBytes;
}

int FrmbufInit(Frmbuf *fb, UINTPTR BaseAddr, UINTPTR BufrBaseAddr)
{
	XVidC_VideoStream stream;
	XVidC_VideoTiming const *timing;
	int status;

	status = XVFrmbufWr_Initialize(&(fb->FrmbufWr), BaseAddr);
	if (status != XST_SUCCESS) {
		xil_printf("      frame buffer write: initialization failed\r\n");
		return XST_FAILURE;
	}

	stream.PixPerClk     = fb->FrmbufWr.FrmbufWr.Config.PixPerClk;
	stream.ColorDepth    = fb->FrmbufWr.FrmbufWr.Config.MaxDataWidth;
	stream.ColorFormatId = FRMBUF_STREAM_FORMAT;
	stream.VmId = XVidC_GetVideoModeId(VPROC_WIDTH_OUT, VPROC_HEIGHT_OUT,
					   VPROC_FRAMERATE_OUT, FALSE);
	timing = XVidC_GetTimingInfo(stream.VmId);
	if (timing == NULL) {
		xil_printf("      frame buffer write: no timing for %dx%d\r\n",
			   VPROC_WIDTH_OUT, VPROC_HEIGHT_OUT);
		return XST_FAILURE;
	}
	stream.Timing    = *timing;
	stream.FrameRate = XVidC_GetFrameRate(stream.VmId);

	fb->Width     = stream.Timing.HActive;
	fb->Height    = stream.Timing.VActive;
	fb->Stride    = CalcStride(fb->Width,
				   fb->FrmbufWr.FrmbufWr.Config.AXIMMDataWidth);
	fb->SizeBytes = fb->Stride * fb->Height;

	if ((fb->SizeBytes * FRMBUF_SLOTS) > FRMBUF_REGION_SIZE) {
		xil_printf("      frame buffer write: %u slots of %u bytes do not fit "
			   "in the %u byte region\r\n",
			   (unsigned)FRMBUF_SLOTS, (unsigned)fb->SizeBytes,
			   (unsigned)FRMBUF_REGION_SIZE);
		return XST_FAILURE;
	}

	status = XVFrmbufWr_SetMemFormat(&(fb->FrmbufWr), fb->Stride,
					 FRMBUF_MEM_FORMAT, &stream);
	if (status != XST_SUCCESS) {
		xil_printf("      frame buffer write: SetMemFormat failed\r\n");
		return XST_FAILURE;
	}

	fb->BufrBaseAddr = BufrBaseAddr;
	fb->WrAddr       = BufrBaseAddr;
	fb->LastGoodAddr = 0;
	fb->FrameCount   = 0;
	fb->Rotate       = TRUE;
	fb->Frozen       = FALSE;

	status = XVFrmbufWr_SetBufferAddr(&(fb->FrmbufWr), fb->WrAddr);
	if (status != XST_SUCCESS) {
		xil_printf("      frame buffer write: SetBufferAddr failed\r\n");
		return XST_FAILURE;
	}

	/*
	 * Clear the whole region and push it out of the caches: the writer is
	 * not coherent, so a dirty cache line written back later would corrupt
	 * a captured frame.
	 */
	Xil_DCacheFlushRange(fb->BufrBaseAddr, FRMBUF_SLOTS * fb->SizeBytes);

	/*
	 * Latch DONE in the interrupt status register so that FrmbufPoll() can
	 * see it.  The IER is what makes the HLS control interface latch a
	 * status bit; GIE, which drives the interrupt output, stays off - this
	 * application polls (docs/source/baremetal.md).
	 */
	XV_frmbufwr_InterruptGlobalDisable(&(fb->FrmbufWr.FrmbufWr));
	XV_frmbufwr_InterruptClear(&(fb->FrmbufWr.FrmbufWr),
				   XVFRMBUFWR_IRQ_DONE_MASK | XVFRMBUFWR_IRQ_READY_MASK);
	XV_frmbufwr_InterruptEnable(&(fb->FrmbufWr.FrmbufWr),
				    XVFRMBUFWR_IRQ_DONE_MASK);

	XV_frmbufwr_EnableAutoRestart(&(fb->FrmbufWr.FrmbufWr));
	return XST_SUCCESS;
}

int FrmbufStart(Frmbuf *fb)
{
	fb->FrameCount   = 0;
	fb->LastGoodAddr = 0;
	fb->Rotate       = TRUE;
	fb->Frozen       = FALSE;
	XV_frmbufwr_InterruptClear(&(fb->FrmbufWr.FrmbufWr),
				   XVFRMBUFWR_IRQ_DONE_MASK);
	XVFrmbufWr_Start(&(fb->FrmbufWr));
	return XST_SUCCESS;
}

void FrmbufStop(Frmbuf *fb)
{
	(void)XVFrmbufWr_Stop(&(fb->FrmbufWr));
}

int FrmbufPoll(Frmbuf *fb)
{
	UINTPTR next;

	if (!(XV_frmbufwr_InterruptGetStatus(&(fb->FrmbufWr.FrmbufWr)) &
	      XVFRMBUFWR_IRQ_DONE_MASK)) {
		return 0;
	}
	XV_frmbufwr_InterruptClear(&(fb->FrmbufWr.FrmbufWr),
				   XVFRMBUFWR_IRQ_DONE_MASK);
	fb->FrameCount++;

	/*
	 * Rotating spreads the frames over the slots so that the writer is not
	 * hammering one address; it does NOT make any slot safe to read, because
	 * the IP has already re-latched its address register by the time we get
	 * here (see frmbuf.h).  FrmbufFreeze() stops the rotation for exactly
	 * that reason.
	 */
	if (!fb->Rotate) {
		return 1;
	}

	next = fb->WrAddr + fb->SizeBytes;
	if (next >= fb->BufrBaseAddr + (UINTPTR)FRMBUF_SLOTS * fb->SizeBytes) {
		next = fb->BufrBaseAddr;
	}
	fb->WrAddr = next;
	if (XVFrmbufWr_SetBufferAddr(&(fb->FrmbufWr), fb->WrAddr) != XST_SUCCESS) {
		xil_printf("      frame buffer write: SetBufferAddr(0x%08X) failed\r\n",
			   (unsigned)fb->WrAddr);
	}
	return 1;
}

/*****************************************************************************/
/**
 * Stop the writer with a WHOLE frame in DDR.
 *
 * The problem this solves: the IP runs with auto-restart and re-latches its
 * buffer address register within a clock of DONE, so software can never know
 * for certain which slot the IP is filling at a given moment - "the slot that
 * just finished" may well be the slot being overwritten right now.  A JTAG dump
 * of 6 MB takes seconds, during which the writer goes round all the slots
 * hundreds of times.
 *
 * Rather than guess at the latch instant, this stops rotating: the IP then
 * re-latches the SAME address frame after frame, so after a couple of
 * completions that one slot certainly holds a whole frame no matter when the
 * register is sampled.  The core is then flushed immediately after a DONE,
 * inside the vertical blanking gap - at 1113 total lines for 1080 active ones
 * that is about 600 us, thousands of times the couple of register accesses
 * below - so the frame that had just restarted has not put a pixel into the
 * slot yet.  Nothing writes that memory afterwards.
 */
int FrmbufFreeze(Frmbuf *fb)
{
	u32 deadline = TimerNowMs() + FREEZE_TIMEOUT_MS;
	u32 seen = 0;

	/* Settle on whatever slot the address register points at now. */
	fb->Rotate = FALSE;

	while (seen < FREEZE_FRAMES) {
		if (FrmbufPoll(fb)) {
			seen++;
			continue;
		}
		if (TimerNowMs() > deadline) {
			break;
		}
	}

	/* Stop now, in the blanking gap that has just opened. */
	(void)XVFrmbufWr_Stop(&(fb->FrmbufWr));

	fb->LastGoodAddr = fb->WrAddr;
	fb->Frozen       = (seen >= FREEZE_FRAMES);

	/* Not coherent with the A53 caches: drop anything stale before a read. */
	Xil_DCacheInvalidateRange(fb->LastGoodAddr, fb->SizeBytes);

	return fb->Frozen ? XST_SUCCESS : XST_FAILURE;
}

void FrmbufInvalidateLast(Frmbuf *fb)
{
	if (fb->LastGoodAddr) {
		Xil_DCacheInvalidateRange(fb->LastGoodAddr, fb->SizeBytes);
	}
}
