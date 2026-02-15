// ============================================================================
// issue_lane.sv - Single issue always sends inst to lane 0, dual issue sends int to 0 fp to 1
// ============================================================================

 `include "bsg_vanilla_defines.svh"

module issue_lane
import bsg_vanilla_pkg::*;
#(parameter pc_width_p = 32)
(
   input instruction_s [1:0] inst_i
  ,input logic [1:0][pc_width_p-1:0] inst_pc_i
  ,input logic [1:0] inst_lane_i           // Lane assignment per instruction
  ,input logic dual_issue_i                // Can dual-issue?
  
  ,output instruction_s [1:0] lane_inst_o  // [0]=lane0, [1]=lane1
  ,output logic [1:0][pc_width_p-1:0] lane_pc_o
  ,output logic [1:0] lane_v_o             // Valid per lane
  ,output logic lane0_is_older_o           // Age tracking
);

  // =========================================================================
  // Single-Issue Mode: Always route inst[0] to lane 0
  // Dual-Issue Mode: Route based on inst_lane_i
  // =========================================================================

  logic structural_hazard_detected;
  
  always_comb begin
    // Default: all invalid
    lane_inst_o = '0;
    lane_pc_o = '0;
    lane_v_o = '0;
    lane0_is_older_o = 1'b1;
    structural_hazard_detected = 1'b0;
    
    if (~dual_issue_i) begin
      // =====================================================================
      // SINGLE-ISSUE: Always put inst[0] in lane 0
      // =====================================================================
      lane_inst_o[0] = inst_i[0];
      lane_pc_o[0] = inst_pc_i[0];
      lane_v_o[0] = 1'b1;        // Lane 0 valid
      lane_v_o[1] = 1'b0;        // Lane 1 invalid (bubble)
      lane0_is_older_o = 1'b1;   // Lane 0 always older in single-issue
      
    end else begin
      // =====================================================================
      // DUAL-ISSUE: Route based on lane assignments
      // =====================================================================
      
      if (inst_lane_i[0] == 1'b0 && inst_lane_i[1] == 1'b1) begin
        // inst[0] → lane 0 (INT), inst[1] → lane 1 (FP)
        lane_inst_o[0] = inst_i[0];
        lane_inst_o[1] = inst_i[1];
        lane_pc_o[0] = inst_pc_i[0];
        lane_pc_o[1] = inst_pc_i[1];
        lane_v_o = 2'b11;          // Both valid
        lane0_is_older_o = 1'b1;   // inst[0] is older
        
      end else if (inst_lane_i[0] == 1'b1 && inst_lane_i[1] == 1'b0) begin
        // inst[0] → lane 1 (FP), inst[1] → lane 0 (INT) - SWAP!
        lane_inst_o[0] = inst_i[1];
        lane_inst_o[1] = inst_i[0];
        lane_pc_o[0] = inst_pc_i[1];
        lane_pc_o[1] = inst_pc_i[0];
        lane_v_o = 2'b11;          // Both valid
        lane0_is_older_o = 1'b0;   // inst[1] (now in lane0) is younger
        
      end else begin
        // Both want same lane - should not happen if dual_issue_i = 1
        // Safety: treat as single-issue, put inst[0] in lane 0
        lane_inst_o[0] = inst_i[0];
        lane_pc_o[0] = inst_pc_i[0];
        lane_v_o[0] = 1'b1;
        lane_v_o[1] = 1'b0;
        lane0_is_older_o = 1'b1;
        structural_hazard_detected = 'b1;
      end
    end
  end

endmodule

