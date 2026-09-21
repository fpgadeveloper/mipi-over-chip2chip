// Opsero Electronic Design Inc. Copyright 2026
//
// Frequency counter
//
// Measures the frequency of "meas_clk" in Hz against the reference clock "ref_clk", whose
// frequency (REF_HZ) is known. The result is presented in the ref_clk domain, so that it
// can be read through an AXI GPIO that is clocked by ref_clk.
//
// How it works:
//
//   * ref_clk domain:  a gate counter toggles "gate_tgl" once every REF_HZ cycles (1 second).
//   * meas_clk domain: a free running counter counts meas_clk cycles. Every time a toggle of
//                      the gate is seen (through a synchroniser), the count is captured into
//                      "cap", the counter restarts, and "cap_tgl" is toggled.
//   * ref_clk domain:  when the toggle of "cap_tgl" arrives (through a synchroniser), "cap"
//                      has been stable for several cycles and is sampled into "freq_hz".
//
// The gate is exactly 1 second of ref_clk, so the captured count is the frequency in Hz. The
// resolution is +/-1 count; the accuracy is that of ref_clk. If meas_clk stops, no capture
// arrives within a gate period and "freq_hz" is forced to zero, so a dead clock reads as 0
// and not as a stale value. "update_cnt" counts the measurements (it increments once per
// second while meas_clk is running), which shows software that the value is live.
//
// Clock domain crossings (constrained in the XDC of the target, see auboard.xdc):
//
//   gate_tgl          -> gate_sync_reg[0]   single bit, 3 flop synchroniser
//   cap_tgl           -> cap_sync_reg[0]    single bit, 3 flop synchroniser
//   cap[31:0]         -> freq_hz[31:0]      multi-bit, quasi-static: only sampled several
//                                           ref_clk cycles after it last changed
//
//*****************************************************************************************

`timescale 1ns / 1ps

module freq_counter #(
  parameter integer REF_HZ = 100000000   // frequency of ref_clk in Hz
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ref_clk CLK" *)
  input  wire        ref_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 meas_clk CLK" *)
  input  wire        meas_clk,
  output reg  [31:0] freq_hz    = 32'd0,  // measured frequency of meas_clk in Hz (ref_clk domain)
  output reg  [31:0] update_cnt = 32'd0   // number of completed measurements (ref_clk domain)
);

  // ---------------------------------------------------------------------------------------
  // ref_clk domain: 1 second gate
  // ---------------------------------------------------------------------------------------
  reg [31:0] gate_cnt = 32'd0;
  reg        gate_tgl = 1'b0;
  wire       gate_tick = (gate_cnt == REF_HZ - 1);

  always @(posedge ref_clk) begin
    if (gate_tick) begin
      gate_cnt <= 32'd0;
      gate_tgl <= ~gate_tgl;
    end else begin
      gate_cnt <= gate_cnt + 32'd1;
    end
  end

  // ---------------------------------------------------------------------------------------
  // meas_clk domain: count the cycles between two toggles of the gate
  // ---------------------------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) reg [2:0] gate_sync = 3'b000;
  reg        gate_sync_d = 1'b0;
  reg [31:0] cnt     = 32'd0;
  reg [31:0] cap     = 32'd0;
  reg        cap_tgl = 1'b0;

  always @(posedge meas_clk) begin
    gate_sync   <= {gate_sync[1:0], gate_tgl};
    gate_sync_d <= gate_sync[2];
    if (gate_sync[2] ^ gate_sync_d) begin
      // "cnt" restarts at 0 on this cycle, so it holds N-1 when the next toggle is seen
      // N cycles later
      cap     <= cnt + 32'd1;
      cnt     <= 32'd0;
      cap_tgl <= ~cap_tgl;
    end else begin
      cnt <= cnt + 32'd1;
    end
  end

  // ---------------------------------------------------------------------------------------
  // ref_clk domain: take the captured count over
  // ---------------------------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) reg [2:0] cap_sync = 3'b000;
  reg cap_sync_d = 1'b0;
  reg seen       = 1'b0;
  wire cap_edge  = cap_sync[2] ^ cap_sync_d;

  always @(posedge ref_clk) begin
    cap_sync   <= {cap_sync[1:0], cap_tgl};
    cap_sync_d <= cap_sync[2];

    if (cap_edge) begin
      freq_hz    <= cap;
      update_cnt <= update_cnt + 32'd1;
    end

    // No capture during a whole gate period: meas_clk is not running
    if (gate_tick) begin
      seen <= cap_edge;
      if (!seen && !cap_edge) begin
        freq_hz <= 32'd0;
      end
    end else if (cap_edge) begin
      seen <= 1'b1;
    end
  end

endmodule
