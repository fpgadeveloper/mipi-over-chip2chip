/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * One camera pipeline of the AUBoard, as seen from the ZCU106:
 *
 *   IMX219 --CSI-2--> mipi_csi2_rx_subsystem -> axis_subset_converter (10->8)
 *     -> v_demosaic -> v_gamma_lut -> v_proc_ss (scaler) -> v_frmbuf_wr
 *     ==AXI4 over the Chip2Chip link==> DDR of the ZCU106
 *
 * The MIPI CSI-2 RX subsystem needs no register write to receive, so it is not
 * driven here (as in the rpi-camera-fmc reference application).  Its driver is
 * still pulled into the BSP by the User DTS, which is the point of the demo.
 */

#ifndef PIPE_H_
#define PIPE_H_

#include "xil_types.h"
#include "xgpio.h"
#include "xv_demosaic.h"
#include "xv_gamma_lut.h"
#include "xvprocss.h"
#include "i2c.h"
#include "frmbuf.h"

/* Bits of the per-pipeline axi_gpio (32 bit, all outputs, reset value 0x1). */
#define GPIO_CAM_IO0_MASK            (0x1u << 0)  /* camera enable, active HIGH */
#define GPIO_CAM_IO1_MASK            (0x1u << 1)  /* unused by the RPi camera v2 */
#define GPIO_CAM_DEMOSAIC_RST_N_MASK (0x1u << 2)  /* active low */
#define GPIO_CAM_VPROC_RST_N_MASK    (0x1u << 3)  /* active low */
#define GPIO_CAM_GAMMA_RST_N_MASK    (0x1u << 4)  /* active low */
/* bit 5 is the frame buffer READ reset of the reference design: not connected */
#define GPIO_CAM_FRMBUFWR_RST_N_MASK (0x1u << 6)  /* active low */

#define GPIO_ALL_RESETS_MASK  (GPIO_CAM_DEMOSAIC_RST_N_MASK | \
			       GPIO_CAM_VPROC_RST_N_MASK    | \
			       GPIO_CAM_GAMMA_RST_N_MASK    | \
			       GPIO_CAM_FRMBUFWR_RST_N_MASK)

/* Base addresses of one pipeline.  Filled in from the XPAR_* macros that the
 * User DTS produced - see main.c. */
typedef struct {
	UINTPTR Gpio;
	UINTPTR Iic;
	UINTPTR Demosaic;
	UINTPTR GammaLut;
	UINTPTR Vproc;
	UINTPTR FrmbufWr;
	UINTPTR FrmbufBufrBaseAddr;
} VideoPipeBaseAddr;

typedef struct {
	u8  Index;              /* camera number as the hardware names it: 0 or 2 */
	u8  IsConnected;        /* a sensor answered on I2C */
	XGpio        Gpio;
	Iic          Iic;
	XV_demosaic  Demosaic;
	XV_gamma_lut GammaLut;
	XVprocSs     Vproc;
	Frmbuf       Frmbuf;
	u16          SensorModelId;
} VideoPipe;

/* ---- reset helpers: ACTIVE LOW, so assert = 0, deassert = 1 ------------- */
static inline u32 pipe_gpio_read(VideoPipe *pipe)
{
	return XGpio_DiscreteRead(&(pipe->Gpio), 1);
}

static inline void pipe_gpio_write(VideoPipe *pipe, u32 v)
{
	XGpio_DiscreteWrite(&(pipe->Gpio), 1, v);
}

static inline void pipe_reset_assert(VideoPipe *pipe, u32 mask)
{
	pipe_gpio_write(pipe, pipe_gpio_read(pipe) & ~mask);
}

static inline void pipe_reset_deassert(VideoPipe *pipe, u32 mask)
{
	pipe_gpio_write(pipe, pipe_gpio_read(pipe) | mask);
}

int  pipe_probe(VideoPipe *pipe, u8 index, const VideoPipeBaseAddr *baseaddr);
int  pipe_init(VideoPipe *pipe, const VideoPipeBaseAddr *baseaddr);
int  pipe_start_camera(VideoPipe *pipe);
void pipe_stop(VideoPipe *pipe);

#endif /* PIPE_H_ */
