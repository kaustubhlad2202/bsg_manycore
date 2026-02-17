/**
 *  scoreboard.v
 *
 *  2020-05-08:  Tommy J - adding FMA support.
 *  2026-02-16:  Dual-issue support added
 */

`include "bsg_defines.sv"

module scoreboard
  import bsg_vanilla_pkg::*;
  #(els_p = RV32_reg_els_gp
    , `BSG_INV_PARAM(num_src_port_p)
    , num_clear_port_p=1
    , num_score_port_p=1          // ADDED: number of score ports
    , dual_issue_enable_p=0       // ADDED: enable dual-issue hardware
    , x0_tied_to_zero_p = 0
    , localparam id_width_lp = `BSG_SAFE_CLOG2(els_p)
    // ADDED: Compute number of destination ports based on dual-issue
    , localparam num_dest_port_lp = dual_issue_enable_p ? 2 : 1
  )
  (
    input clk_i
    , input reset_i

    // MODIFIED: Source ports remain same size (Lane 0 only reads rs)
    , input [num_src_port_p-1:0][id_width_lp-1:0] src_id_i
    
    // MODIFIED: Destination ports - array if dual-issue enabled
    , input [num_dest_port_lp-1:0][id_width_lp-1:0] dest_id_i

    , input [num_src_port_p-1:0] op_reads_rf_i
    
    // MODIFIED: Write RF signal - array if dual-issue enabled
    // op_writes_rf_i[0] = lane 0 rd valid (always checked)
    // op_writes_rf_i[1] = lane 1 rd valid (dual-issue indicator)
    , input [num_dest_port_lp-1:0] op_writes_rf_i

    // MODIFIED: Score signals - array for multiple ports
    , input [num_score_port_p-1:0] score_i
    , input [num_score_port_p-1:0][id_width_lp-1:0] score_id_i

    , input [num_clear_port_p-1:0] clear_i
    , input [num_clear_port_p-1:0][id_width_lp-1:0] clear_id_i

    // MODIFIED: Dependency output - array if dual-issue enabled
    , output logic [num_dest_port_lp-1:0] dependency_o
  );

  logic [els_p-1:0] scoreboard_r;

  // ========================================================================
  // Multi-port clear logic (unchanged)
  // ========================================================================
  logic [num_clear_port_p-1:0][els_p-1:0] clear_by_port;
  logic [els_p-1:0][num_clear_port_p-1:0] clear_by_port_t; // transposed
  logic [els_p-1:0] clear_combined;

  bsg_transpose #(
    .els_p(num_clear_port_p)
    ,.width_p(els_p)
  ) tranposer (
    .i(clear_by_port)
    ,.o(clear_by_port_t)
  );

  for (genvar j = 0 ; j < num_clear_port_p; j++) begin: clr_dcode_v
    bsg_decode_with_v #(
      .num_out_p(els_p)
    ) clear_decode_v (
      .i(clear_id_i[j])
      ,.v_i(clear_i[j])
      ,.o(clear_by_port[j])
    );
  end

  always_comb begin
    for (integer i = 0; i < els_p; i++) begin
      clear_combined[i] = |clear_by_port_t[i];
    end
  end

  // synopsys translate_off
  always_ff @ (negedge clk_i) begin
    if (~reset_i) begin
      for (integer i = 0; i < els_p; i++) begin
        assert($countones(clear_by_port_t[i]) <= 1) else
          $error("[ERROR][SCOREBOARD] multiple clear on the same id. t=%0t", $time);
      end
    end
  end
  // synopsys translate_on

  // ========================================================================
  // Multi-port score logic (MODIFIED for multiple score ports)
  // ========================================================================
  logic [num_score_port_p-1:0] allow_zero;
  logic [num_score_port_p-1:0][els_p-1:0] score_bits;
  logic [els_p-1:0] score_combined;

  for (genvar j = 0; j < num_score_port_p; j++) begin: score_dcode_v
    assign allow_zero[j] = (x0_tied_to_zero_p == 0) | (score_id_i[j] != '0);
    
    bsg_decode_with_v #(
      .num_out_p(els_p)
    ) score_demux (
      .i(score_id_i[j])
      ,.v_i(score_i[j] & allow_zero[j])
      ,.o(score_bits[j])
    );
  end

  // Combine all score bits with OR
  always_comb begin
    score_combined = '0;
    for (integer j = 0; j < num_score_port_p; j++) begin
      score_combined |= score_bits[j];
    end
  end

  // ========================================================================
  // Scoreboard state update
  // ========================================================================
  always_ff @ (posedge clk_i) begin
    for (integer i = 0; i < els_p; i++) begin
      if(reset_i) begin
        scoreboard_r[i] <= 1'b0;
      end
      else begin
        // "score" takes priority over "clear" in case of 
        // simultaneous score and clear. But this
        // condition should not occur in general, as 
        // the pipeline should not allow a new dependency
        // on a register until the old dependency on that 
        // register is cleared.
        if(score_combined[i]) begin
          scoreboard_r[i] <= 1'b1;
        end
        else if (clear_combined[i]) begin
          scoreboard_r[i] <= 1'b0;
        end
      end
    end
  end

  // ========================================================================
  // Dependency logic (MODIFIED for dual-issue)
  // ========================================================================
  // As the register is scored (in EXE), the instruction in ID that has 
  // WAW or RAW dependency on this register stalls.
  // The register that is being cleared does not stall ID.
  //
  // NOTE: op_writes_rf_i[1] acts as the dual-issue valid signal.
  //       When op_writes_rf_i[1]=0, lane 1 is not issuing (single-issue mode)
  //       When op_writes_rf_i[1]=1, lane 1 is issuing (dual-issue mode)

  // Find dependency on scoreboard
  logic [num_src_port_p-1:0] rs_depend_on_sb;
  logic [num_dest_port_lp-1:0] rd_depend_on_sb;

  for (genvar i = 0; i < num_src_port_p; i++) begin
    assign rs_depend_on_sb[i] = scoreboard_r[src_id_i[i]] & op_reads_rf_i[i];
  end
  
  for (genvar i = 0; i < num_dest_port_lp; i++) begin
    // op_writes_rf_i[i] acts as valid - if 0, no dependency
    assign rd_depend_on_sb[i] = scoreboard_r[dest_id_i[i]] & op_writes_rf_i[i];
  end

  // Find which matches on clear_id
  logic [num_clear_port_p-1:0][num_src_port_p-1:0] rs_on_clear;
  logic [num_src_port_p-1:0][num_clear_port_p-1:0] rs_on_clear_t;
  logic [num_clear_port_p-1:0][num_dest_port_lp-1:0] rd_on_clear;
  
  for (genvar i = 0; i < num_clear_port_p; i++) begin
    for (genvar j = 0; j < num_src_port_p; j++) begin
      assign rs_on_clear[i][j] = clear_i[i] && (clear_id_i[i] == src_id_i[j]);
    end

    for (genvar j = 0; j < num_dest_port_lp; j++) begin
      assign rd_on_clear[i][j] = clear_i[i] && (clear_id_i[i] == dest_id_i[j]);
    end
  end

  bsg_transpose #(
    .els_p(num_clear_port_p)
    ,.width_p(num_src_port_p)
  ) trans1 (
    .i(rs_on_clear)
    ,.o(rs_on_clear_t)
  );

  logic [num_src_port_p-1:0] rs_on_clear_combined;
  logic [num_dest_port_lp-1:0] rd_on_clear_combined;

  for (genvar i = 0; i < num_src_port_p; i++) begin
    assign rs_on_clear_combined[i] = |rs_on_clear_t[i];
  end

  for (genvar i = 0; i < num_dest_port_lp; i++) begin
    logic [num_clear_port_p-1:0] rd_clear_vec;
    for (genvar j = 0; j < num_clear_port_p; j++) begin
      assign rd_clear_vec[j] = rd_on_clear[j][i];
    end
    assign rd_on_clear_combined[i] = |rd_clear_vec;
  end

  // Find which could depend on score (MODIFIED for multiple score ports)
  logic [num_src_port_p-1:0] rs_depend_on_score;
  logic [num_dest_port_lp-1:0] rd_depend_on_score;

  for (genvar i = 0; i < num_src_port_p; i++) begin
    logic [num_score_port_p-1:0] rs_score_match;
    for (genvar j = 0; j < num_score_port_p; j++) begin
      assign rs_score_match[j] = (src_id_i[i] == score_id_i[j]) && score_i[j] && allow_zero[j];
    end
    assign rs_depend_on_score[i] = (|rs_score_match) && op_reads_rf_i[i];
  end

  for (genvar i = 0; i < num_dest_port_lp; i++) begin
    logic [num_score_port_p-1:0] rd_score_match;
    for (genvar j = 0; j < num_score_port_p; j++) begin
      assign rd_score_match[j] = (dest_id_i[i] == score_id_i[j]) && score_i[j] && allow_zero[j];
    end
    // op_writes_rf_i[i] acts as valid
    assign rd_depend_on_score[i] = (|rd_score_match) && op_writes_rf_i[i];
  end

  // ========================================================================
  // Generate dependency outputs based on dual-issue mode
  // ========================================================================
  if (dual_issue_enable_p == 0) begin: single_issue
    // Single-issue mode: original behavior
    wire depend_on_sb = |({rd_depend_on_sb[0], rs_depend_on_sb} & ~{rd_on_clear_combined[0], rs_on_clear_combined});
    wire depend_on_score = |{rd_depend_on_score[0], rs_depend_on_score};
    
    assign dependency_o[0] = depend_on_sb | depend_on_score;
  end
  else begin: dual_issue
    // Dual-issue mode
    
    // Lane 0 (lower instruction): checks both rs and rd
    wire lane0_rs_depend_on_sb = |(rs_depend_on_sb & ~rs_on_clear_combined);
    wire lane0_rd_depend_on_sb = rd_depend_on_sb[0] & ~rd_on_clear_combined[0];
    wire lane0_depend_on_sb = lane0_rs_depend_on_sb | lane0_rd_depend_on_sb;
    
    wire lane0_rs_depend_on_score = |rs_depend_on_score;
    wire lane0_rd_depend_on_score = rd_depend_on_score[0];
    wire lane0_depend_on_score = lane0_rs_depend_on_score | lane0_rd_depend_on_score;
    
    assign dependency_o[0] = lane0_depend_on_sb | lane0_depend_on_score;
    
    // Lane 1 (upper instruction): only checks rd (no rs dependencies)
    // When op_writes_rf_i[1]=0 (not dual-issuing), dependency_o[1] will be 0
    // When op_writes_rf_i[1]=1 (dual-issuing), check for rd dependencies
    wire lane1_rd_depend_on_sb = rd_depend_on_sb[1] & ~rd_on_clear_combined[1];
    wire lane1_rd_depend_on_score = rd_depend_on_score[1];
    
    assign dependency_o[1] = lane1_rd_depend_on_sb | lane1_rd_depend_on_score;
  end

  // ========================================================================
  // Assertions
  // ========================================================================
  // synopsys translate_off
  always_ff @ (negedge clk_i) begin
    if (~reset_i) begin
      assert((score_combined & clear_combined) == '0)
        else $error("[BSG_ERROR] score and clear on the same id cannot happen. t=%0t", $time);
      
      // ADDED: Check for multiple score ports writing same register
      if (num_score_port_p > 1) begin
        for (integer i = 0; i < els_p; i++) begin
          logic [num_score_port_p-1:0] score_vec;
          for (integer j = 0; j < num_score_port_p; j++) begin
            score_vec[j] = score_bits[j][i];
          end
          assert($countones(score_vec) <= 1)
            else $error("[BSG_ERROR] multiple score ports writing to same register %0d. t=%0t", i, $time);
        end
      end
    end
  end
  // synopsys translate_on

endmodule

`BSG_ABSTRACT_MODULE(scoreboard)
