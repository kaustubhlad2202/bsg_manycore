//====================================================================
// regfile_hard.v
// 11/02/2016, shawnless.xie@gmail.com
// 05/08/2020, Tommy J - Adding FMA support
//====================================================================

// This module instantiate a 2r1w (or 3r1w) sync memory file and add a bypass
// register. When there is a write and read and the same time, it output
// the newly written value, which is "write through"

`include "bsg_defines.sv"

module regfile_hard
  #(`BSG_INV_PARAM(width_p )
    , `BSG_INV_PARAM(els_p )
    , `BSG_INV_PARAM(num_rs_p ) // number of read ports. only supports 2 and 3.
    , num_rd_p=1                 // ADDED: number of write ports (default 1)
    , x0_tied_to_zero_p=0
    , localparam addr_width_lp = `BSG_SAFE_CLOG2(els_p)
  )
  ( 
    input clk_i
    , input reset_i

    , input [num_rd_p-1:0] w_v_i                           // MODIFIED: array of write enables
    , input [num_rd_p-1:0][addr_width_lp-1:0] w_addr_i    // MODIFIED: array of write addresses
    , input [num_rd_p-1:0][width_p-1:0] w_data_i          // MODIFIED: array of write data

    , input [num_rs_p-1:0] r_v_i
    , input [num_rs_p-1:0][addr_width_lp-1:0] r_addr_i
    , output logic [num_rs_p-1:0][width_p-1:0] r_data_o
  );

  // synopsys translate_off
  initial begin
    assert(num_rs_p == 2 || num_rs_p == 3)
      else $error("num_rs_p can be either 2 or 3 only.");
    assert(num_rd_p == 1 || num_rd_p == 2)          // ADDED: check num_rd_p
      else $error("num_rd_p can be either 1 or 2 only.");
  end
  // synopsys translate_on


  // if we are reading and writing to the same register, we want to read the
  // value being written and prevent reading from rf_mem..
  // if we are reading or writing x0, then we don't want to do anything.

  logic [num_rs_p-1:0][num_rd_p-1:0] rw_same_addr;      // MODIFIED: track per write port
  logic [num_rs_p-1:0] r_v_li;
  logic [num_rs_p-1:0][width_p-1:0] r_data_lo;
  logic [num_rd_p-1:0] w_v_li;                          // MODIFIED: array

  // MODIFIED: Check read-write hazards for each write port
  for (genvar i = 0; i < num_rs_p; i++) begin
    for (genvar j = 0; j < num_rd_p; j++) begin
      assign rw_same_addr[i][j] = w_v_i[j] & r_v_i[i] & (w_addr_i[j] == r_addr_i[i]);
    end
    // Suppress read if any write port matches
    assign r_v_li[i] = (|rw_same_addr[i])
      ? 1'b0
      : r_v_i[i] & ((x0_tied_to_zero_p == 0) | r_addr_i[i] != '0);
  end

  // MODIFIED: Suppress writes to x0 for each write port
  for (genvar j = 0; j < num_rd_p; j++) begin
    assign w_v_li[j] = w_v_i[j] & ((x0_tied_to_zero_p == 0) | w_addr_i[j] != '0);
  end

  if (num_rs_p == 2) begin: rf2
    // MODIFIED: Support both 2R1W and 2R2W based on num_rd_p
    if (num_rd_p == 1) begin: single_wr
      bsg_mem_2r1w_sync #(
        .width_p(width_p)
        ,.els_p(els_p)
      ) rf_mem2 (
        .clk_i(clk_i)
        ,.reset_i(reset_i)

        ,.w_v_i(w_v_li[0])
        ,.w_addr_i(w_addr_i[0])
        ,.w_data_i(w_data_i[0])

        ,.r0_v_i(r_v_li[0])
        ,.r0_addr_i(r_addr_i[0])
        ,.r0_data_o(r_data_lo[0])

        ,.r1_v_i(r_v_li[1])
        ,.r1_addr_i(r_addr_i[1])
        ,.r1_data_o(r_data_lo[1])
      );
    end
    else if (num_rd_p == 2) begin: dual_wr
      // ADDED: Instantiate 2R2W for dual-write support
      bsg_mem_2r2w_sync #(
        .width_p(width_p)
        ,.els_p(els_p)
      ) rf_mem2 (
        .clk_i(clk_i)
        ,.reset_i(reset_i)

        // Write port 0
        ,.w0_v_i(w_v_li[0])
        ,.w0_addr_i(w_addr_i[0])
        ,.w0_data_i(w_data_i[0])

        // Write port 1
        ,.w1_v_i(w_v_li[1])
        ,.w1_addr_i(w_addr_i[1])
        ,.w1_data_i(w_data_i[1])

        // Read port 0
        ,.r0_v_i(r_v_li[0])
        ,.r0_addr_i(r_addr_i[0])
        ,.r0_data_o(r_data_lo[0])

        // Read port 1
        ,.r1_v_i(r_v_li[1])
        ,.r1_addr_i(r_addr_i[1])
        ,.r1_data_o(r_data_lo[1])
      );
    end
  end
  else if (num_rs_p == 3) begin: rf3
    // MODIFIED: Support both 3R1W and 3R2W based on num_rd_p
    if (num_rd_p == 1) begin: single_wr
      bsg_mem_3r1w_sync #(
        .width_p(width_p)
        ,.els_p(els_p)
      ) rf_mem3 (
        .clk_i(clk_i)
        ,.reset_i(reset_i)

        ,.w_v_i(w_v_li[0])
        ,.w_addr_i(w_addr_i[0])
        ,.w_data_i(w_data_i[0])

        ,.r0_v_i(r_v_li[0])
        ,.r0_addr_i(r_addr_i[0])
        ,.r0_data_o(r_data_lo[0])

        ,.r1_v_i(r_v_li[1])
        ,.r1_addr_i(r_addr_i[1])
        ,.r1_data_o(r_data_lo[1])

        ,.r2_v_i(r_v_li[2])
        ,.r2_addr_i(r_addr_i[2])
        ,.r2_data_o(r_data_lo[2])
      );
    end
    else if (num_rd_p == 2) begin: dual_wr
      // ADDED: Instantiate 3R2W for dual-write support
      bsg_mem_3r2w_sync #(
        .width_p(width_p)
        ,.els_p(els_p)
      ) rf_mem3 (
        .clk_i(clk_i)
        ,.reset_i(reset_i)

        // Write port 0
        ,.w0_v_i(w_v_li[0])
        ,.w0_addr_i(w_addr_i[0])
        ,.w0_data_i(w_data_i[0])

        // Write port 1
        ,.w1_v_i(w_v_li[1])
        ,.w1_addr_i(w_addr_i[1])
        ,.w1_data_i(w_data_i[1])

        // Read port 0
        ,.r0_v_i(r_v_li[0])
        ,.r0_addr_i(r_addr_i[0])
        ,.r0_data_o(r_data_lo[0])

        // Read port 1
        ,.r1_v_i(r_v_li[1])
        ,.r1_addr_i(r_addr_i[1])
        ,.r1_data_o(r_data_lo[1])

        // Read port 2
        ,.r2_v_i(r_v_li[2])
        ,.r2_addr_i(r_addr_i[2])
        ,.r2_data_o(r_data_lo[2])
      );
    end
  end

  // we want to remember which registers we read last time, and we want to
  // hold the last read value until the new location is read, or the new value is
  // written to that location.

  logic [num_rd_p-1:0][width_p-1:0] w_data_r, w_data_n;
  logic [num_rs_p-1:0][width_p-1:0] r_data_r, r_data_n;
  logic [num_rs_p-1:0][addr_width_lp-1:0] r_addr_r, r_addr_n;
  logic [num_rs_p-1:0][num_rd_p-1:0] rw_same_addr_r;
  logic [num_rs_p-1:0] r_v_r;
  logic [num_rs_p-1:0][width_p-1:0] r_safe_data;
  
  // ADDED: Declare bypass logic signals outside generate loop (FIXED)
  logic [num_rs_p-1:0] any_wr_match;
  logic [num_rs_p-1:0][width_p-1:0] matching_wr_data;

  // combinational logic
  //
  for (genvar i = 0; i < num_rs_p; i++) begin
    // MODIFIED: Priority mux - check both write ports, port 1 has priority if both match
    assign r_safe_data[i] = rw_same_addr_r[i][1] ? w_data_r[1]
                          : rw_same_addr_r[i][0] ? w_data_r[0]
                          : r_data_lo[i];

    assign r_addr_n[i] = r_v_i[i]
      ? r_addr_i[i]
      : r_addr_r[i];

    // MODIFIED: Check if any write port matches current read address (FIXED)
    assign any_wr_match[i] = w_v_i[1] & (r_addr_r[i] == w_addr_i[1])
                           | w_v_i[0] & (r_addr_r[i] == w_addr_i[0]);
    assign matching_wr_data[i] = (w_v_i[1] & (r_addr_r[i] == w_addr_i[1])) ? w_data_i[1]
                                : (w_v_i[0] & (r_addr_r[i] == w_addr_i[0])) ? w_data_i[0]
                                : '0;
    
    assign r_data_n[i] = any_wr_match[i]
      ? matching_wr_data[i]
      : (r_v_r[i] ? r_safe_data[i] : r_data_r[i]);

    assign r_data_o[i] = ((r_addr_r[i] == '0) & (x0_tied_to_zero_p == 1))
      ? '0
      : (r_v_r[i] ? r_safe_data[i] : r_data_r[i]);
  end

  // MODIFIED: Update w_data_n for each write port (FIXED)
  for (genvar j = 0; j < num_rd_p; j++) begin
    // FIXED: Create vector of all read ports that match this write port
    logic [num_rs_p-1:0] rw_match_vec;
    for (genvar k = 0; k < num_rs_p; k++) begin
      assign rw_match_vec[k] = rw_same_addr[k][j];
    end
    assign w_data_n[j] = (|rw_match_vec) ? w_data_i[j] : w_data_r[j];
  end

  // sequential logic
  //
  always_ff @ (posedge clk_i) begin
    if (reset_i) begin
       rw_same_addr_r <= '0;
       r_v_r <= '0;

       // MBT: added to be more reset conservative
       w_data_r  <= '0;
       r_data_r <= '0;
       r_addr_r <= '0;
    end
    else begin
      rw_same_addr_r <= rw_same_addr;
      r_v_r <= r_v_i;
      w_data_r <= w_data_n;
      r_data_r <= r_data_n;
      r_addr_r <= r_addr_n;
    end
  end

  // ADDED: Assertion to detect write port collisions
  // synopsys translate_off
  always_ff @(posedge clk_i) begin
    if (!reset_i && num_rd_p == 2) begin
      if (w_v_i[0] & w_v_i[1]) begin
        if (x0_tied_to_zero_p) begin
          assert (w_addr_i[0] != w_addr_i[1] || w_addr_i[0] == '0)
            else $error("[%m] Write collision: port[0] and port[1] both writing to addr %0d", w_addr_i[0]);
        end
        else begin
          assert (w_addr_i[0] != w_addr_i[1])
            else $error("[%m] Write collision: port[0] and port[1] both writing to addr %0d", w_addr_i[0]);
        end
      end
    end
  end
  // synopsys translate_on

endmodule

`BSG_ABSTRACT_MODULE(regfile_hard)
