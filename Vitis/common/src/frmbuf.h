/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * Frame Buffer Write of one camera pipeline, plus the frame accounting.
 *
 * Unlike the rpi-camera-fmc reference application there is no Frame Buffer
 * Read here: this design has no display half.  The writer cycles through
 * FRMBUF_SLOTS buffers in the DDR of the ZCU106 so that it is not hammering
 * one address; FrmbufFreeze() then stops it on a frame boundary so that a host
 * can dump a whole, static frame over JTAG.
 *
 * POLLED, not interrupt driven - see docs/source/baremetal.md ("Interrupts").
 * FrmbufPoll() takes the place of the DONE interrupt handler.
 *
 * WHILE THE WRITER RUNS, NO SLOT IS SAFE TO READ.  The IP runs with
 * auto-restart, so it re-latches its buffer address register the instant it
 * restarts - within a clock of DONE, long before software that polls (or even
 * software that takes an interrupt) can write a new address.  A buffer address
 * written after DONE therefore takes effect one frame later than the naive
 * reading suggests, and "the slot that has just finished" is in general the
 * slot the IP is filling right now.  FrmbufFreeze() is what makes a frame
 * readable: it stops the rotation, lets the IP settle on ONE slot, and flushes
 * the core in the vertical blanking gap right after a DONE.  Only then does
 * LastGoodAddr point at a whole, static frame.
 *
 * CACHES: the writer comes into the PS through S_AXI_HP0_FPD, which does NOT
 * go through the cache coherent interconnect.  The application therefore
 * invalidates a buffer before it reads it and flushes it before it hands it to
 * the writer - FrmbufInvalidateLast() does the former.
 */

#ifndef FRMBUF_H_
#define FRMBUF_H_

#include "xil_types.h"
#include "xv_frmbufwr_l2.h"

typedef struct {
	XV_FrmbufWr_l2 FrmbufWr;

	UINTPTR BufrBaseAddr;   /* first slot */
	UINTPTR WrAddr;         /* what is in the buffer address register now */
	UINTPTR LastGoodAddr;   /* a whole, static frame - valid after FrmbufFreeze() */

	u32 Stride;             /* bytes per line */
	u32 Width;
	u32 Height;
	u32 SizeBytes;          /* Stride * Height, one slot */

	u32 FrameCount;         /* completed frames since FrmbufStart() */
	u8  Rotate;             /* FrmbufPoll() advances the slot while this is set */
	u8  Frozen;             /* the IP is stopped and LastGoodAddr is a whole frame */
} Frmbuf;

int  FrmbufInit(Frmbuf *fb, UINTPTR BaseAddr, UINTPTR BufrBaseAddr);
int  FrmbufStart(Frmbuf *fb);
void FrmbufStop(Frmbuf *fb);

/*
 * Check the DONE flag of the IP.  If a frame has completed, count it and (while
 * rotating) point the IP at the next slot.  Returns the number of frames
 * completed in this call (0 or 1).
 */
int  FrmbufPoll(Frmbuf *fb);

/*
 * Stop the writer leaving a WHOLE frame behind at LastGoodAddr, and leave the
 * DDR static so that a JTAG dump cannot race the hardware.  Call it with the
 * camera still streaming.  Returns XST_SUCCESS, or XST_FAILURE on a timeout
 * (the IP is stopped either way, but LastGoodAddr may then be a torn frame).
 */
int  FrmbufFreeze(Frmbuf *fb);

/* Invalidate the cache lines of the last completed frame before reading it. */
void FrmbufInvalidateLast(Frmbuf *fb);

#endif /* FRMBUF_H_ */
