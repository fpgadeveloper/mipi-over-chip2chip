/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * A small POLLED driver for the AXI IIC cores of the camera pipelines.
 *
 * Why not XIic: the standalone XIic driver is interrupt driven, and the cores
 * of this design sit behind an AXI INTC that is cascaded into the GIC - a
 * topology XSetupInterruptSystem() cannot wire up on a Cortex-A53 (see
 * docs/source/baremetal.md).  The register sequences below are the ones
 * scripts/jtag/auboard_cam.tcl uses, which are proven on this hardware,
 * including the end-of-read quirk of the AXI IIC.
 *
 * The BSP's XIic driver is still generated from the User DTS (that is the
 * point of the SDT flow) and the base addresses used here are the ones from
 * its config table - see iic_init().
 */

#ifndef I2C_H_
#define I2C_H_

#include "xil_types.h"

#define IIC_OK          0
#define IIC_ERR_NACK    (-1)
#define IIC_ERR_TIMEOUT (-2)
#define IIC_ERR_ARBLOST (-3)

typedef struct {
	UINTPTR BaseAddress;
} Iic;

/* Reset the core and leave it enabled as a master. */
int  IicInit(Iic *iic, UINTPTR BaseAddress);

/* Write len bytes to the 7 bit address dev. */
int  IicWrite(Iic *iic, u8 dev, const u8 *buf, u16 len);

/* Write txlen bytes, repeated start, then read rxlen bytes from dev. */
int  IicWriteRead(Iic *iic, u8 dev, const u8 *tx, u16 txlen, u8 *rx, u16 rxlen);

/* Is there a device at this 7 bit address? (a zero-length-ish probe write) */
int  IicProbe(Iic *iic, u8 dev);

const char *IicErrorString(int status);

#endif /* I2C_H_ */
