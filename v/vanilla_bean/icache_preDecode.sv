//==============================================================================
// DEC_LANE_1: Instructions that access Floating-Point Register File
// All other instructions default to INT RF (Lane 0)
//==============================================================================

`define DEC_LANE_1_OPCODES \
  7'b100??11, \        // 7'b10000/01/10/11 - FMADD, FMSUB, FNMSUB, FNMADD (reads/writes FP)
  `RV32_OP_FP          // 7'b1010011 - All FP ops: FADD, FSUB, FMUL, FDIV, FCVT, FMV, FEQ, etc.




// Instructions that never write to rd
`define NO_RD_WRITE_OPCODES \
  `RV32_STORE, \       // 7'b0100011 - SB, SH, SW (write to memory)
  `RV32_STORE_FP, \    // 7'b0100111 - FSW (write to memory)
  `RV32_BRANCH, \      // 7'b110001? - BEQ, BNE, BLT, BGE, BLTU, BGEU (only compare)
  `RV32_MISC_MEM       // 7'b0001111 - FENCE (memory ordering only)

// Instructions that never read rs1
`define NO_RS1_READ_OPCODES \
  `RV32_LUI_OP, \      // 7'b0110111 - LUI (immediate only)
  `RV32_AUIPC_OP, \    // 7'b0010111 - AUIPC (PC + immediate, no rs1)
  `RV32_JAL_OP         // 7'b1101111 - JAL (PC-relative, no rs1)

// Instructions that never read rs2
`define NO_RS2_READ_OPCODES \
  `RV32_LOAD, \        // 7'b0000011 - LB, LH, LW, LBU, LHU (only rs1)
  `RV32_LOAD_FP, \     // 7'b0000111 - FLW (only rs1)
  `RV32_OP_IMM, \      // 7'b0010011 - ADDI, SLTI, XORI, etc. (rs1 + immediate)
  `RV32_JALR_OP, \     // 7'b1100111 - JALR (only rs1)
  `RV32_LUI_OP, \      // 7'b0110111 - LUI (no registers)
  `RV32_AUIPC_OP, \    // 7'b0010111 - AUIPC (no registers)
  `RV32_JAL_OP, \      // 7'b1101111 - JAL (no registers)
  `RV32_SYSTEM         // 7'b1110011 - CSR ops (may read rs1 but not rs2)

//==============================================================================

module icache_preDecode (
    input  logic [RV32_instr_width_gp-1:0]    instruction_i,
    output logic                              inst_lane_o,
    output logic [RV32_reg_addr_width_gp-1:0] inst_rd_o,
    output logic                              inst_rd_valid_o,
    output logic [RV32_reg_addr_width_gp-1:0] inst_rs1_o,
    output logic                              inst_rs1_valid_o,
    output logic [RV32_reg_addr_width_gp-1:0] inst_rs2_o,
    output logic                              inst_rs2_valid_o
);

  instruction_s instr;
  assign instr = instruction_i;

  assign inst_rd_o  = instr.rd;
  assign inst_rs1_o = instr.rs1;
  assign inst_rs2_o = instr.rs2;

  always_comb begin
  
    //Lane Classification
    casez (instr.op)
      `DEC_LANE_1_OPCODES: inst_lane_o = 1'b1;
       default:            inst_lane_o = 1'b0;
    endcase

    //Valid RD Classification
    casez (instr.op)
    `NO_RD_WRITE_OPCODES: inst_rd_valid_o = 1'b0;
     default:             inst_rd_valid_o = 1'b1;
    endcase

    //Valid RS1 Classification
    casez (instr.op)
    `NO_RS1_READ_OPCODES : inst_rs1_valid_o = 1'b0;
     default:              inst_rs1_valid_o = 1'b1;
    endcase

    //Valid RS2 Classification
    casez (instr.op)
    `NO_RS2_READ_OPCODES: inst_rs2_valid_o = 1'b0;
     default:             inst_rs2_valid_o = 1'b1;
    endcase

  end

endmodule
