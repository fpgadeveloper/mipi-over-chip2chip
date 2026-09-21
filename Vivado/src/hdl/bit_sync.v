// Opsero Electronic Design Inc. Copyright 2026
//
// Synchroniser for independent, slowly changing status bits
//
// Brings WIDTH status bits from any clock domain (or from no clock at all) into the domain of
// "clk" through a 3 flop synchroniser per bit. Every bit is synchronised on its own, so the
// bits of the vector are NOT kept coherent with each other: only use this for flags such as
// "channel up" or "PLL locked", never for a multi-bit value.
//
// The path into the first flop (sync0_reg) is asynchronous and is cut in the XDC of the
// target (see auboard.xdc).
//
//*****************************************************************************************

`timescale 1ns / 1ps

module bit_sync #(
  parameter integer WIDTH = 1
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  input  wire             clk,
  input  wire [WIDTH-1:0] din,    // asynchronous inputs
  output wire [WIDTH-1:0] dout    // synchronised to clk
);

  (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync0 = {WIDTH{1'b0}};
  (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync1 = {WIDTH{1'b0}};
  (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync2 = {WIDTH{1'b0}};

  always @(posedge clk) begin
    sync0 <= din;
    sync1 <= sync0;
    sync2 <= sync1;
  end

  assign dout = sync2;

endmodule
