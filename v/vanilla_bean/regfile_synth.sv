/**
 *    regfile_synth.v
 *
 *    synthesized register file
 *
 *    @author tommy
 */

`include "bsg_defines.sv"

module regfile_synth
  #(`BSG_INV_PARAM(width_p)
    , `BSG_INV_PARAM(els_p)
    , `BSG_INV_PARAM(num_rs_p)
    , num_rd_p=1                                    // ADDED: number of write ports (default 1)
    , `BSG_INV_PARAM(x0_tied_to_zero_p)

    , localparam addr_width_lp=`BSG_SAFE_CLOG2(els_p)
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

  wire unused = reset_i;
  
  logic [num_rs_p-1:0][addr_width_lp-1:0] r_addr_r;


  always_ff @ (posedge clk_i)
    for (integer i = 0; i < num_rs_p; i++)
      if (r_v_i[i]) r_addr_r[i] <= r_addr_i[i];



  if (x0_tied_to_zero_p) begin: xz
    // x0 is tied to zero.
    logic [width_p-1:0] mem_r [els_p-1:1];
    
    for (genvar i = 0; i < num_rs_p; i++)
      assign r_data_o[i] = (r_addr_r[i] == '0)? '0 : mem_r[r_addr_r[i]];

    // MODIFIED: Support multiple write ports
    always_ff @ (posedge clk_i)
      for (integer i = 0; i < num_rd_p; i++)           // ADDED: loop over write ports
        if (w_v_i[i] & (w_addr_i[i] != '0))            // MODIFIED: indexed access
          mem_r[w_addr_i[i]] <= w_data_i[i];           // MODIFIED: indexed access


  end
  else begin: xnz
    // x0 is not tied to zero.
    logic [width_p-1:0] mem_r [els_p-1:0];
   
    for (genvar i = 0; i < num_rs_p; i++)
      assign r_data_o[i] = mem_r[r_addr_r[i]];

    // MODIFIED: Support multiple write ports
    always_ff @ (posedge clk_i)
      for (integer i = 0; i < num_rd_p; i++)           // ADDED: loop over write ports
        if (w_v_i[i])                                  // MODIFIED: indexed access
          mem_r[w_addr_i[i]] <= w_data_i[i];           // MODIFIED: indexed access
    
  end

  // ADDED: Assertion to detect write port collisions
  // synopsys translate_off
  always_ff @(posedge clk_i) begin
    if (!reset_i) begin
      for (integer i = 0; i < num_rd_p; i++) begin
        for (integer j = i+1; j < num_rd_p; j++) begin
          if (w_v_i[i] & w_v_i[j]) begin
            // Check collision, but allow writes to x0/f0 (always ignored)
            if (x0_tied_to_zero_p) begin
              assert (w_addr_i[i] != w_addr_i[j] || w_addr_i[i] == '0)
                else $error("[%m] Write collision: port[%0d] and port[%0d] both writing to addr %0d", 
                            i, j, w_addr_i[i]);
            end
            else begin
              assert (w_addr_i[i] != w_addr_i[j])
                else $error("[%m] Write collision: port[%0d] and port[%0d] both writing to addr %0d", 
                            i, j, w_addr_i[i]);
            end
          end
        end
      end
    end
  end
  // synopsys translate_on

endmodule

`BSG_ABSTRACT_MODULE(regfile_synth)
