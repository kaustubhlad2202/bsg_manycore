 `include "bsg_vanilla_defines.svh"

module issue_lane
  import bsg_vanilla_pkg::*;
  #(
     parameter pc_width_lp=0
  )
  (
    input instruction_s [1:0] inst_i,
    
    //input instruction pcs
    input [1:0][pc_width_lp-1:0]  inst_pc_i,

    //Is current cycle dual_issue?
    input logic dual_issue_i,

    // input instruction lanes
    input   logic  [1:0] inst_lane_i,  // 0->lane0, 1->lane1


    // lane allocated instructions
    output instruction_s  [1:0] lane_inst_o,

    // lane allocated pc's
    output [1:0][pc_width_lp-1:0]  lane_pc_o,

    // lane validity
    output    logic         [1:0]  lane_v_o,

    // older lane
    output    logic           lane0_is_older_o 
  );



  // raw valid for each input
  logic inst0_v, inst1_v;
  assign inst0_v = 1'b1;          // inst0 always considered present
  assign inst1_v = dual_issue_i;  // inst1 only present when dual_issue_i = 1

  // per-lane valid (OR of inputs that choose that lane)
  assign lane_v_o[0] =
      (inst0_v & (inst_lane_i[0] == 1'b0))
    | (inst1_v & (inst_lane_i[1] == 1'b0));

    assign lane_v_o[1] =
      (inst0_v & (inst_lane_i[0] == 1'b1))
    | (inst1_v & (inst_lane_i[1] == 1'b1));

  assign lane_inst_o[0] = (inst_lane_i[0] == 1'b0) ? inst_i[0] : inst_i[1];
  assign lane_pc_o[0]   = (inst_lane_i[0] == 1'b0) ? inst_pc_i[0] : inst_pc_i[1];
  assign lane_inst_o[1] = (inst_lane_i[0] == 1'b0) ? inst_i[1] : inst_i[0];
  assign lane_pc_o[1]   = (inst_lane_i[0] == 1'b0) ? inst_pc_i[1] : inst_pc_i[0];

  //Is lane0 older?
  assign lane0_is_older_o = ~inst_lane_i[0];

endmodule
