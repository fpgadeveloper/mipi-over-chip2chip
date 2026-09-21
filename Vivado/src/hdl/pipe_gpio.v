// Opsero Electronic Design Inc. Copyright 2026
//
// Fan-out of the AXI GPIO of one video pipeline
//
// Every video pipeline has one AXI GPIO (all outputs) with the bit layout of the rpi-camera-fmc
// reference design:
//
//   bit 0  camera IO0 (camera enable of the Raspberry Pi cameras)
//   bit 1  camera IO1
//   bit 2  reset of the demosaic IP, active low
//   bit 3  reset of the video processing subsystem (scaler), active low
//   bit 4  reset of the gamma LUT IP, active low
//   bit 5  (reset of the frame buffer read IP of the reference design, not used here)
//   bit 6  reset of the frame buffer write IP, active low
//
// The register of the AXI GPIO is in the AXI4-Lite clock domain, the video IP is clocked by the
// video clock. The reference design wires the GPIO bits straight to the reset inputs; here every
// reset goes through a synchroniser in the video clock domain, followed by one ordinary flop
// that the tools may replicate (a reset has a high fan-out).
//
// The path into the first flop (sync0_reg) is asynchronous and is cut in the XDC of the target
// (see auboard.xdc). The camera IO bits go to pins and are passed through unchanged.
//
//*****************************************************************************************

`timescale 1ns / 1ps

module pipe_gpio (
  input  wire [31:0] gpio_o,            // gpio_io_o of the AXI GPIO (AXI4-Lite clock domain)

  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 video_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET demosaic_rst_n:vproc_rst_n:gamma_rst_n:frmbuf_wr_rst_n" *)
  input  wire        video_clk,

  output wire        cam_io0,
  output wire        cam_io1,

  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 demosaic_rst_n RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  output wire        demosaic_rst_n,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 vproc_rst_n RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  output wire        vproc_rst_n,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 gamma_rst_n RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  output wire        gamma_rst_n,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 frmbuf_wr_rst_n RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  output wire        frmbuf_wr_rst_n
);

  assign cam_io0 = gpio_o[0];
  assign cam_io1 = gpio_o[1];

  // {frmbuf_wr, gamma, vproc, demosaic}
  wire [3:0] rst_n_in = {gpio_o[6], gpio_o[4], gpio_o[3], gpio_o[2]};

  // All flops power up at 0 = reset asserted, the same as the reset value of the GPIO bits
  (* ASYNC_REG = "TRUE" *) reg [3:0] sync0 = 4'b0000;
  (* ASYNC_REG = "TRUE" *) reg [3:0] sync1 = 4'b0000;
  reg [3:0] rst_n_q = 4'b0000;

  always @(posedge video_clk) begin
    sync0   <= rst_n_in;
    sync1   <= sync0;
    rst_n_q <= sync1;
  end

  assign demosaic_rst_n  = rst_n_q[0];
  assign vproc_rst_n     = rst_n_q[1];
  assign gamma_rst_n     = rst_n_q[2];
  assign frmbuf_wr_rst_n = rst_n_q[3];

endmodule
