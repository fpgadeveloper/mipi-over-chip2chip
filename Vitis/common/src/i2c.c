/*
 * Opsero Electronic Design Inc. Copyright 2026
 *
 * Polled AXI IIC driver (PG090 dynamic controller logic).  See i2c.h for why
 * this exists instead of XIic, and scripts/jtag/auboard_cam.tcl for the same
 * sequences driven from the JTAG to AXI master.
 */

#include "i2c.h"
#include "sleep.h"
#include "xil_io.h"
#include "xil_printf.h"

/* ---- register map (PG090) ---------------------------------------------- */
#define IIC_GIE     0x01C
#define IIC_ISR     0x020
#define IIC_IER     0x028
#define IIC_SOFTR   0x040
#define IIC_CR      0x100
#define IIC_SR      0x104
#define IIC_TX_FIFO 0x108
#define IIC_RX_FIFO 0x10C
#define IIC_RX_PIRQ 0x120

/* Control register */
#define IIC_CR_EN       0x01    /* enable the core */
#define IIC_CR_TX_FIFO_RESET 0x02

/* Status register */
#define IIC_SR_BB       0x04    /* bus busy */
#define IIC_SR_RX_EMPTY 0x40
#define IIC_SR_TX_EMPTY 0x80

/* Interrupt status register (write 1 to a set bit to clear it) */
#define IIC_ISR_ARB_LOST 0x01
#define IIC_ISR_TX_ERR   0x02   /* NACK - see the note in IicWriteRead() */

/* TX FIFO data word: bit 8 = START, bit 9 = STOP */
#define IIC_TX_START    0x100
#define IIC_TX_STOP     0x200

/* Polling: the bus runs at 100 kHz, so a 3 byte transfer takes about 300 us. */
#define IIC_POLL_STEP_US    50
#define IIC_POLL_TRIES      2000    /* 100 ms */

static inline u32 iic_rd(Iic *iic, u32 off)
{
	return Xil_In32(iic->BaseAddress + off);
}

static inline void iic_wr(Iic *iic, u32 off, u32 val)
{
	Xil_Out32(iic->BaseAddress + off, val);
}

/* The ISR toggles the bits that are written as 1: write back what we read. */
static void iic_clear_isr(Iic *iic)
{
	iic_wr(iic, IIC_ISR, iic_rd(iic, IIC_ISR));
}

int IicInit(Iic *iic, UINTPTR BaseAddress)
{
	iic->BaseAddress = BaseAddress;

	iic_wr(iic, IIC_SOFTR, 0xA);            /* soft reset key */
	usleep(1000);
	iic_wr(iic, IIC_RX_PIRQ, 0x0F);
	iic_wr(iic, IIC_CR, IIC_CR_TX_FIFO_RESET);
	iic_wr(iic, IIC_CR, IIC_CR_EN);
	iic_clear_isr(iic);
	iic_wr(iic, IIC_GIE, 0);                /* no interrupts: we poll */
	iic_wr(iic, IIC_IER, 0);

	/* A core that answers has TX_EMPTY set and the bus idle after a reset. */
	if ((iic_rd(iic, IIC_SR) & (IIC_SR_BB | IIC_SR_TX_EMPTY)) != IIC_SR_TX_EMPTY) {
		return IIC_ERR_TIMEOUT;
	}
	return IIC_OK;
}

/* Wait until (SR & mask) == value.  Returns IIC_OK or IIC_ERR_TIMEOUT. */
static int iic_wait_sr(Iic *iic, u32 mask, u32 value, u32 tries)
{
	for (u32 i = 0; i < tries; i++) {
		if ((iic_rd(iic, IIC_SR) & mask) == value) {
			return IIC_OK;
		}
		usleep(IIC_POLL_STEP_US);
	}
	return IIC_ERR_TIMEOUT;
}

/* Start of a transaction: the bus must be free and the TX FIFO empty. */
static void iic_begin(Iic *iic)
{
	if (iic_wait_sr(iic, IIC_SR_BB | IIC_SR_TX_EMPTY, IIC_SR_TX_EMPTY, 50) != IIC_OK) {
		IicInit(iic, iic->BaseAddress);
	}
	iic_clear_isr(iic);
}

/*
 * End of a WRITE: wait until the TX FIFO has drained and the bus is free.  A
 * slave that does not acknowledge its address or a data byte raises the
 * transmit-error interrupt; the rest of the FIFO is then never sent, so the
 * core has to be reset to empty it.
 */
static int iic_write_done(Iic *iic)
{
	int status = IIC_ERR_TIMEOUT;

	for (u32 i = 0; i < IIC_POLL_TRIES; i++) {
		u32 isr = iic_rd(iic, IIC_ISR);
		if (isr & IIC_ISR_ARB_LOST) { status = IIC_ERR_ARBLOST; break; }
		if (isr & IIC_ISR_TX_ERR)   { status = IIC_ERR_NACK;    break; }
		if ((iic_rd(iic, IIC_SR) & (IIC_SR_BB | IIC_SR_TX_EMPTY)) == IIC_SR_TX_EMPTY) {
			status = IIC_OK;
			break;
		}
		usleep(IIC_POLL_STEP_US);
	}
	if (status != IIC_OK) {
		IicInit(iic, iic->BaseAddress);
	}
	return status;
}

int IicWrite(Iic *iic, u8 dev, const u8 *buf, u16 len)
{
	if (len == 0) {
		return IIC_OK;
	}
	iic_begin(iic);
	iic_wr(iic, IIC_TX_FIFO, IIC_TX_START | ((u32)dev << 1));
	for (u16 i = 0; i < len; i++) {
		u32 word = buf[i];
		if (i == len - 1) {
			word |= IIC_TX_STOP;
		}
		iic_wr(iic, IIC_TX_FIFO, word);
	}
	return iic_write_done(iic);
}

int IicWriteRead(Iic *iic, u8 dev, const u8 *tx, u16 txlen, u8 *rx, u16 rxlen)
{
	u16 got = 0;
	int status = IIC_OK;

	if (rxlen == 0) {
		return IicWrite(iic, dev, tx, txlen);
	}

	iic_begin(iic);
	iic_wr(iic, IIC_TX_FIFO, IIC_TX_START | ((u32)dev << 1));
	for (u16 i = 0; i < txlen; i++) {
		iic_wr(iic, IIC_TX_FIFO, tx[i]);
	}
	/* repeated start, read address, then the byte count with a stop */
	iic_wr(iic, IIC_TX_FIFO, IIC_TX_START | ((u32)dev << 1) | 1u);
	iic_wr(iic, IIC_TX_FIFO, IIC_TX_STOP | rxlen);

	for (u32 i = 0; i < IIC_POLL_TRIES && got < rxlen; i++) {
		if (!(iic_rd(iic, IIC_SR) & IIC_SR_RX_EMPTY)) {
			rx[got++] = (u8)(iic_rd(iic, IIC_RX_FIFO) & 0xFF);
			continue;
		}
		u32 isr = iic_rd(iic, IIC_ISR);
		if (isr & IIC_ISR_ARB_LOST) { status = IIC_ERR_ARBLOST; break; }
		/*
		 * The AXI IIC raises its transmit-error interrupt at the END of
		 * every master read as well (the master does not acknowledge the
		 * last byte), so the flag only means NACK while the RX FIFO is
		 * still empty.
		 */
		if ((isr & IIC_ISR_TX_ERR) && (iic_rd(iic, IIC_SR) & IIC_SR_RX_EMPTY)) {
			status = IIC_ERR_NACK;
			break;
		}
		usleep(IIC_POLL_STEP_US);
	}
	if (status == IIC_OK && got < rxlen) {
		status = IIC_ERR_TIMEOUT;
	}
	if (status != IIC_OK) {
		IicInit(iic, iic->BaseAddress);
		return status;
	}

	/* wait for the stop condition, then drop the expected transmit error */
	iic_wait_sr(iic, IIC_SR_BB, 0, 100);
	iic_clear_isr(iic);
	return IIC_OK;
}

int IicProbe(Iic *iic, u8 dev)
{
	u8 reg = 0;
	/* One address byte and one data byte read back: enough to see the ACK. */
	u8 rx = 0;
	return IicWriteRead(iic, dev, &reg, 1, &rx, 1);
}

const char *IicErrorString(int status)
{
	switch (status) {
	case IIC_OK:            return "ok";
	case IIC_ERR_NACK:      return "no acknowledge (NACK)";
	case IIC_ERR_TIMEOUT:   return "timeout";
	case IIC_ERR_ARBLOST:   return "arbitration lost";
	default:                return "unknown error";
	}
}
