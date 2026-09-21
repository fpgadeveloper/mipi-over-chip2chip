/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * The AXI Chip2Chip / Aurora link to the AUBoard.
 *
 * THE MOST IMPORTANT FUNCTION IN THIS APPLICATION IS LinkIsUp().
 *
 * There is no timeout anywhere in the register path: an AXI4-Lite access into
 * the remote window while the link is down never completes, and the A53 hangs
 * with no way out but a power cycle.  Nothing in the application may touch an
 * address in the 0xA000_0000 window before LinkIsUp() has returned TRUE.
 *
 * The status register itself is on the ZCU106 side (axi_gpio_link, in the
 * ZCU106 XSA) and is always safe to read.
 */

#ifndef LINK_H_
#define LINK_H_

#include "xil_types.h"

/* Raw contents of the link status register (bits: see remote.h). */
u32  LinkStatus(void);

/* TRUE when channel up + lane up + PLL locked + Chip2Chip link status are all
 * set.  Waits up to timeout_ms for that; 0 = check once. */
int  LinkIsUp(u32 timeout_ms);

/* Print the status register, decoded, on the UART. */
void LinkPrintStatus(const char *prefix);

#endif /* LINK_H_ */
