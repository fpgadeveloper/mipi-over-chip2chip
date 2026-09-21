/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * A millisecond clock for the A53, read straight from the ARM generic timer.
 *
 * XTime_GetTime() is not used: the standalone BSP of the SDT flow does not
 * export xtime_l.h (and with it COUNTS_PER_SECOND) into the platform's include
 * directory, and which timer xiltimer picks up depends on the BSP
 * configuration.  CNTPCT_EL0 and CNTFRQ_EL0 are architectural and always there
 * - they are what XTime_GetTime() reads on this core anyway.
 */

#ifndef TIMER_H_
#define TIMER_H_

#include "xil_types.h"

static inline u64 TimerTicks(void)
{
	u64 v;

	__asm__ __volatile__("mrs %0, CNTPCT_EL0" : "=r"(v));
	return v;
}

static inline u64 TimerHz(void)
{
	u64 v;

	__asm__ __volatile__("mrs %0, CNTFRQ_EL0" : "=r"(v));
	return v ? v : 100000000ULL;   /* ZCU106 default, should never be needed */
}

static inline u32 TimerNowMs(void)
{
	return (u32)((TimerTicks() * 1000ULL) / TimerHz());
}

#endif /* TIMER_H_ */
