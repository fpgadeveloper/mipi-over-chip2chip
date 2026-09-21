/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * Sony IMX219 (Raspberry Pi Camera v2) over the AXI IIC of a pipeline.
 * The register table is the one of the rpi-camera-fmc reference application.
 *
 * Credit to Greg Taylor https://github.com/gtaylormb/ultra96v2_imx219_to_displayport
 */

#ifndef IMX219_H_
#define IMX219_H_

#include "xil_types.h"
#include "i2c.h"

#define IMX219_I2C_SLAVE_ADDR       0x10

#define IMX219_REG_MODEL_ID_HI      0x0000
#define IMX219_REG_MODEL_ID_LO      0x0001
#define IMX219_REG_MODE_SELECT      0x0100
#define IMX219_REG_ANA_GAIN_GLOBAL  0x0157
#define IMX219_REG_COARSE_INT_TIME  0x015A

#define IMX219_MODEL_ID             0x0219

/* Bayer pattern of the sensor, as the v_demosaic BAYER_PHASE register wants it
 * (PG286): RGGB = 0. */
#define IMX219_BAYER_PHASE          0x00

typedef struct {
	u16 addr;
	u8  data;
} Imx219ConfigWord;

int  Imx219Detect(Iic *iic, u16 *model_id);
int  Imx219Config(Iic *iic);
int  Imx219StopStreaming(Iic *iic);
int  Imx219Read(Iic *iic, u16 addr, u8 *data);
int  Imx219Write(Iic *iic, u16 addr, u8 data);

#endif /* IMX219_H_ */
