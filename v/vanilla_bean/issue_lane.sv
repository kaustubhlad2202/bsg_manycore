module issue_lane
  import bsg_vanilla_pkg::*;
  #(parameter INST_WIDTH_P = 32)
  (
    // control
    input    logic     dual_issue_i,  //Decides if the current cycle is dual_issue

    // input instructions
    input instruction_s  inst0_i,
    input instruction_s  inst1_i,

    // input instruction lanes
    input   logic   inst0_lane_i,  // 0->lane0, 1->lane1
    input   logic   inst1_lane_i,  // 0->lane0, 1->lane1

    // lane allocated instructions
    output instruction_s   lane0_inst_o,
    output instruction_s   lane1_inst_o,

    // lane validity
    output    logic           lane0_v_o,
    output    logic           lane1_v_o
  );



  // raw valid for each input
  logic inst0_v, inst1_v;
  assign inst0_v = 1'b1;          // inst0 always considered present
  assign inst1_v = dual_issue_i;  // inst1 only present when dual_issue_i = 1

  // per-lane valid (OR of inputs that choose that lane)
  assign lane0_v_o =
      (inst0_v & (inst0_lane_i == 1'b0))
    | (inst1_v & (inst1_lane_i == 1'b0));

  assign lane1_v_o =
      (inst0_v & (inst0_lane_i == 1'b1))
    | (inst1_v & (inst1_lane_i == 1'b1));

  //inst0 is always valid and decides where both instructions go; use valid qualifiers to disqualify output inst1's lane if single issue
  assign lane0_inst_o = (inst0_lane_i == 1'b0) ? inst0_i : inst1_i;
  assign lane1_inst_o = (inst0_lane_i == 1'b0) ? inst1_i : inst0_i;

endmodule
