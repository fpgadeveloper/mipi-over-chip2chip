/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * Bring one camera pipeline of the AUBoard up.  See pipe.h.
 *
 * ORDER MATTERS, and not only for the usual reasons: a video IP whose reset bit
 * in the GPIO of its pipeline is 0 does not answer on AXI4-Lite at all, and the
 * access never completes.  Every function below releases a reset, waits for the
 * synchroniser in the video clock domain, and only then touches the IP.
 */

#include "pipe.h"
#include "config.h"
#include "imx219.h"
#include "math.h"
#include "sleep.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xstatus.h"
#include "xvidc.h"

/* The reset bits cross into the video clock domain through a 3 stage
 * synchroniser; 1 ms is several orders of magnitude more than enough. */
#define RESET_SETTLE_US     1000

/* Offsets of the three 256 entry, 16 bit gamma tables inside v_gamma_lut. */
#define GAMMA_LUT_0_OFFSET  0x0800
#define GAMMA_LUT_1_OFFSET  0x1000
#define GAMMA_LUT_2_OFFSET  0x1800

/*****************************************************************************/
/**
 * Probe the sensor: bring the GPIO up, enable the camera, talk to the IMX219.
 * Nothing but the GPIO and the AXI IIC is touched, so this is safe to call on
 * a pipeline whose video IP are all still in reset.
 */
int pipe_probe(VideoPipe *pipe, u8 index, const VideoPipeBaseAddr *baseaddr)
{
	int status;

	pipe->Index = index;
	pipe->IsConnected = FALSE;
	pipe->SensorModelId = 0;

	status = XGpio_Initialize(&(pipe->Gpio), baseaddr->Gpio);
	if (status != XST_SUCCESS) {
		xil_printf("      GPIO initialization failed\r\n");
		return XST_FAILURE;
	}
	XGpio_SetDataDirection(&(pipe->Gpio), 1, 0x0);  /* all outputs */

	/* Camera on, every video IP held in reset (the power-up value). */
	pipe_gpio_write(pipe, GPIO_CAM_IO0_MASK);
	usleep(100000);                                 /* let the module boot */

	status = IicInit(&(pipe->Iic), baseaddr->Iic);
	if (status != IIC_OK) {
		xil_printf("      AXI IIC did not respond: %s\r\n",
			   IicErrorString(status));
		return XST_FAILURE;
	}

	status = Imx219Detect(&(pipe->Iic), &(pipe->SensorModelId));
	if (status != IIC_OK) {
		xil_printf("      no IMX219 at I2C 0x%02X (%s, model id 0x%04X)\r\n",
			   IMX219_I2C_SLAVE_ADDR, IicErrorString(status),
			   pipe->SensorModelId);
		return XST_FAILURE;
	}

	pipe->IsConnected = TRUE;
	return XST_SUCCESS;
}

/*****************************************************************************/
/**
 * Load a gamma curve into the three tables of v_gamma_lut.
 *
 * The LUT powers up LINEAR.  out = 255 * (in/255)^g with a different exponent
 * per channel, which is exactly what the Linux side of this design does with
 * its red/green/blue_gamma_correction controls: the curve brightens the
 * picture and the difference between the channels stands in for the automatic
 * white balance this pipeline does not have.  The values are in config.h.
 *
 * Table 0/1/2 drive memory bytes 0/1/2 = R/G/B - measured on this hardware,
 * see logs/mipi-over-chip2chip/phase6_baremetal.md.
 */
static void pipe_load_gamma(VideoPipe *pipe)
{
	static const u32 lut_offset[3] = {
		GAMMA_LUT_0_OFFSET, GAMMA_LUT_1_OFFSET, GAMMA_LUT_2_OFFSET
	};
	static const double gamma_exp[3] = {
		GAMMA_RED, GAMMA_GREEN, GAMMA_BLUE
	};
	UINTPTR base = pipe->GammaLut.Config.BaseAddress;

	for (int ch = 0; ch < 3; ch++) {
		for (u32 i = 0; i < GAMMA_TABLE_SIZE; i++) {
			double norm = (double)i / (double)GAMMA_TABLE_MAX;
			double out  = pow(norm, gamma_exp[ch]) * (double)GAMMA_TABLE_MAX;
			u32 value   = (u32)(out + 0.5);

			if (value > GAMMA_TABLE_MAX) {
				value = GAMMA_TABLE_MAX;
			}
			Xil_Out16(base + lut_offset[ch] + i * 2, (u16)value);
		}
	}
}

/*****************************************************************************/
/**
 * Configure the whole pipeline.  Call pipe_probe() first; this function
 * assumes there is a sensor.
 */
int pipe_init(VideoPipe *pipe, const VideoPipeBaseAddr *baseaddr)
{
	XVprocSs_Config *VprocSsConfigPtr;
	XVidC_VideoStream StreamIn, StreamOut;
	XVidC_VideoTiming const *TimingPtr;
	XVidC_VideoMode resId;
	int status;

	/* The camera is switched off while the pipeline is set up; it is
	 * powered back on (and reset) by pipe_start_camera(). */
	XGpio_DiscreteClear(&(pipe->Gpio), 1, GPIO_CAM_IO0_MASK);

	/* ---- frame buffer write ---------------------------------------- */
	pipe_reset_deassert(pipe, GPIO_CAM_FRMBUFWR_RST_N_MASK);
	usleep(RESET_SETTLE_US);
	status = FrmbufInit(&(pipe->Frmbuf), baseaddr->FrmbufWr,
			    baseaddr->FrmbufBufrBaseAddr);
	if (status != XST_SUCCESS) {
		return XST_FAILURE;
	}

	/* ---- video processing subsystem (scaler) ----------------------- */
	pipe_reset_deassert(pipe, GPIO_CAM_VPROC_RST_N_MASK);
	usleep(RESET_SETTLE_US);
	VprocSsConfigPtr = XVprocSs_LookupConfig(baseaddr->Vproc);
	if (VprocSsConfigPtr == NULL) {
		xil_printf("      video processing subsystem not found at 0x%08X\r\n",
			   (unsigned)baseaddr->Vproc);
		return XST_FAILURE;
	}
	XVprocSs_LogReset(&(pipe->Vproc));
	status = XVprocSs_CfgInitialize(&(pipe->Vproc), VprocSsConfigPtr,
					VprocSsConfigPtr->BaseAddress);
	if (status != XST_SUCCESS) {
		xil_printf("      video processing subsystem init failed\r\n");
		return XST_FAILURE;
	}

	resId = XVidC_GetVideoModeId(VMODE_WIDTH, VMODE_HEIGHT, VMODE_FRAMERATE, FALSE);
	TimingPtr = XVidC_GetTimingInfo(resId);
	if (TimingPtr == NULL) {
		xil_printf("      no video timing for %dx%d\r\n",
			   VMODE_WIDTH, VMODE_HEIGHT);
		return XST_FAILURE;
	}
	StreamIn.VmId          = resId;
	StreamIn.Timing        = *TimingPtr;
	StreamIn.ColorFormatId = COLOR_FORMAT_ID;
	StreamIn.ColorDepth    = pipe->Vproc.Config.ColorDepth;
	StreamIn.PixPerClk     = pipe->Vproc.Config.PixPerClock;
	StreamIn.FrameRate     = XVidC_GetFrameRate(resId);
	StreamIn.IsInterlaced  = XVidC_IsInterlaced(resId);
	XVprocSs_SetVidStreamIn(&(pipe->Vproc), &StreamIn);

	resId = XVidC_GetVideoModeId(VPROC_WIDTH_OUT, VPROC_HEIGHT_OUT,
				     VPROC_FRAMERATE_OUT, FALSE);
	TimingPtr = XVidC_GetTimingInfo(resId);
	if (TimingPtr == NULL) {
		xil_printf("      no video timing for %dx%d\r\n",
			   VPROC_WIDTH_OUT, VPROC_HEIGHT_OUT);
		return XST_FAILURE;
	}
	StreamOut.VmId          = resId;
	StreamOut.Timing        = *TimingPtr;
	StreamOut.ColorFormatId = COLOR_FORMAT_ID;
	StreamOut.ColorDepth    = pipe->Vproc.Config.ColorDepth;
	StreamOut.PixPerClk     = pipe->Vproc.Config.PixPerClock;
	StreamOut.FrameRate     = XVidC_GetFrameRate(resId);
	StreamOut.IsInterlaced  = XVidC_IsInterlaced(resId);
	XVprocSs_SetVidStreamOut(&(pipe->Vproc), &StreamOut);

	status = XVprocSs_SetSubsystemConfig(&(pipe->Vproc));
	if (status != XST_SUCCESS) {
		xil_printf("      video processing subsystem configuration failed\r\n");
		return XST_FAILURE;
	}
	XVprocSs_Start(&(pipe->Vproc));

	/* ---- demosaic --------------------------------------------------- */
	pipe_reset_deassert(pipe, GPIO_CAM_DEMOSAIC_RST_N_MASK);
	usleep(RESET_SETTLE_US);
	status = XV_demosaic_Initialize(&(pipe->Demosaic), baseaddr->Demosaic);
	if (status != XST_SUCCESS) {
		xil_printf("      demosaic init failed\r\n");
		return XST_FAILURE;
	}
	XV_demosaic_Set_HwReg_width(&(pipe->Demosaic), VMODE_WIDTH);
	XV_demosaic_Set_HwReg_height(&(pipe->Demosaic), VMODE_HEIGHT);
	XV_demosaic_Set_HwReg_bayer_phase(&(pipe->Demosaic), IMX219_BAYER_PHASE);
	XV_demosaic_EnableAutoRestart(&(pipe->Demosaic));
	XV_demosaic_Start(&(pipe->Demosaic));

	/* ---- gamma LUT -------------------------------------------------- */
	pipe_reset_deassert(pipe, GPIO_CAM_GAMMA_RST_N_MASK);
	usleep(RESET_SETTLE_US);
	status = XV_gamma_lut_Initialize(&(pipe->GammaLut), baseaddr->GammaLut);
	if (status != XST_SUCCESS) {
		xil_printf("      gamma LUT init failed\r\n");
		return XST_FAILURE;
	}
	XV_gamma_lut_Set_HwReg_width(&(pipe->GammaLut), VMODE_WIDTH);
	XV_gamma_lut_Set_HwReg_height(&(pipe->GammaLut), VMODE_HEIGHT);
	XV_gamma_lut_Set_HwReg_video_format(&(pipe->GammaLut), 0);
	pipe_load_gamma(pipe);
	XV_gamma_lut_EnableAutoRestart(&(pipe->GammaLut));
	XV_gamma_lut_Start(&(pipe->GammaLut));

	return XST_SUCCESS;
}

/*****************************************************************************/
/**
 * Power-cycle the sensor, program it and start the frame buffer writer.
 */
int pipe_start_camera(VideoPipe *pipe)
{
	int status;

	/* Reset the IMX219 with its enable pin, as the reference application. */
	XGpio_DiscreteClear(&(pipe->Gpio), 1, GPIO_CAM_IO0_MASK);
	usleep(100000);
	XGpio_DiscreteSet(&(pipe->Gpio), 1, GPIO_CAM_IO0_MASK);
	usleep(100000);

	/* The core has to be re-synchronised after the bus went quiet. */
	(void)IicInit(&(pipe->Iic), pipe->Iic.BaseAddress);

	status = Imx219Config(&(pipe->Iic));
	if (status != IIC_OK) {
		xil_printf("      IMX219 configuration failed: %s\r\n",
			   IicErrorString(status));
		return XST_FAILURE;
	}

	return FrmbufStart(&(pipe->Frmbuf));
}

/*****************************************************************************/
/**
 * Stop the sensor and leave the pipeline in its power-up state (camera on,
 * every video IP in reset) so that the next run starts from a known place.
 */
void pipe_stop(VideoPipe *pipe)
{
	if (pipe->IsConnected) {
		(void)Imx219StopStreaming(&(pipe->Iic));
	}
	FrmbufStop(&(pipe->Frmbuf));
	pipe_gpio_write(pipe, GPIO_CAM_IO0_MASK);
}
