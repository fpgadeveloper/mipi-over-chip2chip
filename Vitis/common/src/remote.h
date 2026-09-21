/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * The hardware that is NOT in the ZCU106 XSA.
 *
 * Everything below lives in the FPGA of the AUBoard and is reached through the
 * AXI Chip2Chip window.  The base addresses are the XPAR_* macros that the
 * standalone BSP generated from the User DTS (Vitis/common/dts/
 * remote_pipeline.dtsi) - that is the whole point of the System Device Tree
 * flow, and referencing them here (rather than writing the numbers out) is the
 * proof that the platform really picked the remote IP up.  If one of these
 * macros does not exist, the User DTS did not reach the platform build.
 */

#ifndef REMOTE_H_
#define REMOTE_H_

#include "xparameters.h"

/* ---- the link, on the ZCU106 side (this IS in the XSA) ------------------ */
/* axi_gpio_link channel 1 (in): status of the Aurora / AXI Chip2Chip link. */
#define LINK_GPIO_BASEADDR      XPAR_AXI_GPIO_LINK_BASEADDR
#define LINK_STATUS_OFFSET      0x0000      /* channel 1 data register */
#define LINK_CONTROL_OFFSET     0x0008      /* channel 2 data register */

/*
 * Link status bits (docs/link_contract_deviations.md).  Bit 4 is always 0 on
 * this side: a Chip2Chip slave with an Aurora PHY has no link_error pin.
 */
#define LINK_ST_CHANNEL_UP      (1u << 0)   /* Aurora channel up */
#define LINK_ST_LANE_UP         (1u << 1)   /* Aurora lane up */
#define LINK_ST_PLL_LOCKED      (1u << 2)   /* GT PLL locked */
#define LINK_ST_C2C_LINK        (1u << 3)   /* AXI Chip2Chip link status */
#define LINK_ST_LINK_ERROR      (1u << 4)   /* always 0 here, see above */
#define LINK_ST_MULTI_BIT_ERR   (1u << 5)
#define LINK_ST_CONFIG_ERROR    (1u << 6)
#define LINK_ST_HARD_ERR        (1u << 7)   /* Aurora hard error */
#define LINK_ST_SOFT_ERR        (1u << 8)   /* Aurora soft error */
#define LINK_ST_FRAME_ERR       (1u << 9)   /* Aurora frame error */

/* The bits that must ALL be set before a remote register may be touched. */
#define LINK_ST_READY_MASK      (LINK_ST_CHANNEL_UP | LINK_ST_LANE_UP | \
                                 LINK_ST_PLL_LOCKED | LINK_ST_C2C_LINK)
/* Bits that mean "something went wrong since the last reset of the AUBoard". */
#define LINK_ST_ERROR_MASK      (LINK_ST_MULTI_BIT_ERR | LINK_ST_CONFIG_ERROR | \
                                 LINK_ST_HARD_ERR | LINK_ST_SOFT_ERR | \
                                 LINK_ST_FRAME_ERR)

/* ---- the remote interrupt controller ----------------------------------- */
#define REMOTE_INTC_BASEADDR    XPAR_C2C_INTC_BASEADDR

/* ---- frame buffers in the DDR of the ZCU106 ----------------------------- *
 * The frame buffer writers of the AUBoard are 32-bit AXI masters and the AXI
 * MMU of the ZCU106 design only passes 0x0000_0000 - 0x7FFF_FFFF (DDR low,
 * 1:1, through S_AXI_HP0_FPD).  Anything above 0x8000_0000 gets a DECERR, so
 * the buffers MUST be in DDR low.  0x2000_0000 is well clear of the
 * application, which the linker puts at the bottom of DDR.
 *
 * 3 slots x 1920 x 1080 x 3 bytes = 18 662 400 bytes, rounded up to 32 MB per
 * camera.  That path is NOT cache coherent (S_AXI_HP0_FPD does not go through
 * the CCI), so the application flushes before and invalidates after - see
 * frmbuf.c.
 */
#define FRMBUF_SLOTS            3
#define FRMBUF_REGION_SIZE      0x02000000u     /* 32 MB per camera */
#define CAM0_FRMBUF_BASEADDR    0x20000000u
#define CAM2_FRMBUF_BASEADDR    0x22000000u

/* ---- where the application tells a JTAG host what it did ---------------- *
 * Which slot a frame ends up frozen in depends on how many frames were
 * captured, so the addresses are not known in advance.  The application
 * publishes them in DDR (well clear of the application at the bottom and of
 * the frame buffers above) and scripts/jtag/zcu106_baremetal.tcl reads them,
 * so "run+dump" needs no one to read the UART.  Layout, u32 words:
 *
 *   0 magic   1 ncams   2 width   3 height   4 stride   5 frame size
 *   6 cam index   7 frozen frame address   8 frames captured   (per camera)
 */
#define APP_INFO_ADDR           0x1FFF0000u
#define APP_INFO_MAGIC          0x43324331u     /* "C2C1" */
#define APP_INFO_WORDS          12

#endif /* REMOTE_H_ */
