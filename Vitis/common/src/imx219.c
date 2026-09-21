/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * See imx219.h.  The register table below is the one of the rpi-camera-fmc
 * reference application, unchanged: 1920x1080, 2 lanes, RAW10, frame length
 * 1113, line length 3448 (about 47.5 frames/s).  The last entry starts the
 * stream.
 */

#include "imx219.h"
#include "sleep.h"
#include "xil_printf.h"

/* 1920x1080P48, from
 * https://android.googlesource.com/kernel/bcm/+/android-bcm-tetra-3.10-lollipop-wear-release/drivers/media/video/imx219.c
 */
static const Imx219ConfigWord imx219_cfg[] = {
	{0x30EB, 0x05},
	{0x30EB, 0x0C},
	{0x300A, 0xFF},
	{0x300B, 0xFF},
	{0x30EB, 0x05},
	{0x30EB, 0x09},
	{0x0114, 0x01}, /* 2-wire csi */
	{0x0128, 0x00}, /* auto MIPI global timing */
	{0x012A, 0x18}, /* INCK freq: 24.0 MHz */
	{0x012B, 0x00},
	{0x0160, 0x04}, /* frame length lines = 1113 */
	{0x0161, 0x59},
	{0x0162, 0x0D}, /* line length pixels = 3448 */
	{0x0163, 0x78},
	{0x0164, 0x02}, /* x-start address = 680 */
	{0x0165, 0xA8},
	{0x0166, 0x0A}, /* x-end address = 2599 */
	{0x0167, 0x27},
	{0x0168, 0x02}, /* y-start address = 692 */
	{0x0169, 0xB4},
	{0x016A, 0x06}, /* y-end address = 1771 */
	{0x016B, 0xEB},
	{0x016C, 0x07}, /* x-output size = 1920 */
	{0x016D, 0x80},
	{0x016E, 0x04}, /* y-output size = 1080 */
	{0x016F, 0x38},
	{0x0170, 0x01},
	{0x0171, 0x01},
	{0x0174, 0x00},
	{0x0175, 0x00},
	{0x018C, 0x0A},
	{0x018D, 0x0A},
	{0x0301, 0x05}, /* video timing pixel clock divider value = 5 */
	{0x0303, 0x01}, /* video timing system clock divider value = 1 */
	{0x0304, 0x03}, /* external clock 24-27 MHz */
	{0x0305, 0x03},
	{0x0306, 0x00}, /* PLL video timing system multiplier value = 57 */
	{0x0307, 0x39},
	{0x0309, 0x0A}, /* output pixel clock divider value = 10 */
	{0x030B, 0x01}, /* output system clock divider value = 1 */
	{0x030C, 0x00}, /* PLL output system multiplier value = 114 */
	{0x030D, 0x72},
	{0x455E, 0x00},
	{0x471E, 0x4B},
	{0x4767, 0x0F},
	{0x4750, 0x14},
	{0x4540, 0x00},
	{0x47B4, 0x14},
	{0x4713, 0x30},
	{0x478B, 0x10},
	{0x478F, 0x10},
	{0x4793, 0x10},
	{0x4797, 0x0E},
	{0x479B, 0x0E},
	{0x0100, 0x01}  /* stream on */
};

int Imx219Write(Iic *iic, u16 addr, u8 data)
{
	u8 buf[3];
	buf[0] = (u8)(addr >> 8);
	buf[1] = (u8)(addr & 0xFF);
	buf[2] = data;
	return IicWrite(iic, IMX219_I2C_SLAVE_ADDR, buf, 3);
}

int Imx219Read(Iic *iic, u16 addr, u8 *data)
{
	u8 tx[2];
	tx[0] = (u8)(addr >> 8);
	tx[1] = (u8)(addr & 0xFF);
	return IicWriteRead(iic, IMX219_I2C_SLAVE_ADDR, tx, 2, data, 1);
}

int Imx219Detect(Iic *iic, u16 *model_id)
{
	u8 hi = 0, lo = 0;
	int status;

	status = Imx219Read(iic, IMX219_REG_MODEL_ID_HI, &hi);
	if (status != IIC_OK) {
		return status;
	}
	status = Imx219Read(iic, IMX219_REG_MODEL_ID_LO, &lo);
	if (status != IIC_OK) {
		return status;
	}
	if (model_id) {
		*model_id = (u16)((hi << 8) | lo);
	}
	return ((u16)((hi << 8) | lo) == IMX219_MODEL_ID) ? IIC_OK : IIC_ERR_NACK;
}

int Imx219StopStreaming(Iic *iic)
{
	return Imx219Write(iic, IMX219_REG_MODE_SELECT, 0x00);
}

int Imx219Config(Iic *iic)
{
	int status;

	/* Stop streaming before the sensor is reprogrammed. */
	status = Imx219StopStreaming(iic);
	if (status != IIC_OK) {
		return status;
	}
	usleep(1000);

	for (unsigned i = 0; i < sizeof(imx219_cfg) / sizeof(imx219_cfg[0]); i++) {
		status = Imx219Write(iic, imx219_cfg[i].addr, imx219_cfg[i].data);
		if (status != IIC_OK) {
			xil_printf("      IMX219: write of 0x%04X failed: %s\r\n",
				   imx219_cfg[i].addr, IicErrorString(status));
			return status;
		}
	}

	/* Analogue gain, as in the reference application. */
	return Imx219Write(iic, IMX219_REG_ANA_GAIN_GLOBAL, 232);
}
