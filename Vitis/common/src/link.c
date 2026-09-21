/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * See link.h.
 */

#include "link.h"
#include "remote.h"
#include "sleep.h"
#include "xil_io.h"
#include "xil_printf.h"

u32 LinkStatus(void)
{
	return Xil_In32(LINK_GPIO_BASEADDR + LINK_STATUS_OFFSET) & 0x3FF;
}

int LinkIsUp(u32 timeout_ms)
{
	u32 elapsed = 0;

	for (;;) {
		if ((LinkStatus() & LINK_ST_READY_MASK) == LINK_ST_READY_MASK) {
			return TRUE;
		}
		if (elapsed >= timeout_ms) {
			return FALSE;
		}
		usleep(100000);
		elapsed += 100;
	}
}

void LinkPrintStatus(const char *prefix)
{
	u32 st = LinkStatus();

	xil_printf("%s0x%03X  [", prefix, st);
	xil_printf("%s", (st & LINK_ST_CHANNEL_UP)    ? " channel_up"   : "");
	xil_printf("%s", (st & LINK_ST_LANE_UP)       ? " lane_up"      : "");
	xil_printf("%s", (st & LINK_ST_PLL_LOCKED)    ? " pll_locked"   : "");
	xil_printf("%s", (st & LINK_ST_C2C_LINK)      ? " c2c_link"     : "");
	xil_printf("%s", (st & LINK_ST_MULTI_BIT_ERR) ? " multi_bit_error" : "");
	xil_printf("%s", (st & LINK_ST_CONFIG_ERROR)  ? " config_error" : "");
	xil_printf("%s", (st & LINK_ST_HARD_ERR)      ? " hard_error"   : "");
	xil_printf("%s", (st & LINK_ST_SOFT_ERR)      ? " soft_error"   : "");
	xil_printf("%s", (st & LINK_ST_FRAME_ERR)     ? " frame_error"  : "");
	xil_printf(" ]\r\n");
}
