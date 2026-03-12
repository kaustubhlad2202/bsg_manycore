//==============================================================================
// Instruction Pre-Decode for Dual-Issue Classification
//==============================================================================

`include "bsg_vanilla_defines.svh"

//====================================================================================
// Hybrid instruction detection macros --> These instructions can never be dual issued
//====================================================================================
`define FCVT_W_FUNCT7    7'b1100000  // FCVT.W.S, FCVT.WU.S  (FP→INT)
`define FCVT_S_FUNCT7    7'b1101000  // FCVT.S.W, FCVT.S.WU  (INT→FP)
`define FMV_X_W_FUNCT7   7'b1110000  // FMV.X.W, FCLASS.S    (FP→INT)
`define FMV_W_X_FUNCT7   7'b1111000  // FMV.W.X              (INT→FP)
`define FCMP_FUNCT7      7'b1010000  // FEQ.S, FLT.S, FLE.S  (FP→INT)

//==========================================================================================================
// Instructions that never write to rd --> These instructions should never cause dual issue RAW (same cycle)
//==========================================================================================================
`define NO_RD_WRITE_OPCODES \
  `RV32_STORE, \
  `RV32_STORE_FP, \
  `RV32_BRANCH, \
  `RV32_MISC_MEM

//===========================================================================================================
// Instructions that never read rs1 --> These instructions should face  cause dual issue rs1 RAW (same cycle)
//===========================================================================================================
`define NO_RS1_READ_OPCODES \
  `RV32_LUI_OP, \
  `RV32_AUIPC_OP, \
  `RV32_JAL_OP

//===========================================================================================================
// Instructions that never read rs2 --> These instructions should face  cause dual issue rs3 RAW (same cycle)
//===========================================================================================================
`define NO_RS2_READ_OPCODES \
  `RV32_LOAD, \
  `RV32_LOAD_FP, \
  `RV32_OP_IMM, \
  `RV32_JALR_OP, \
  `RV32_LUI_OP, \
  `RV32_AUIPC_OP, \
  `RV32_JAL_OP, \
  `RV32_SYSTEM
//==============================================================================

module icache_preDecode
    import bsg_vanilla_pkg::*;
    (
    input  logic [RV32_instr_width_gp-1:0]    instruction_i,
    
    // Lane assignment (0=EXE/INT, 1=FP_EXE/FP)
    output logic                               inst_lane_o,
    
    // Register operand information
    output logic [RV32_reg_addr_width_gp-1:0]  inst_rd_o,
    output logic                                inst_rd_valid_o,
    output logic [RV32_reg_addr_width_gp-1:0]  inst_rs1_o,
    output logic                                inst_rs1_valid_o,
    output logic [RV32_reg_addr_width_gp-1:0]  inst_rs2_o,
    output logic                                inst_rs2_valid_o,
    
    // Instruction classification flags
    output logic                                inst_is_hybrid_o,
    output logic                                inst_is_flw_o,
    output logic                                inst_is_fsw_o
);

  //============================================================================
  // Instruction decode
  //============================================================================
  instruction_s instr;
  assign instr = instruction_i;

  assign inst_rd_o  = instr.rd;
  assign inst_rs1_o = instr.rs1;
  assign inst_rs2_o = instr.rs2;

  //============================================================================
  // FP Memory Operations Detection
  //============================================================================
  assign inst_is_flw_o = (instr.op == `RV32_LOAD_FP);
  assign inst_is_fsw_o = (instr.op == `RV32_STORE_FP);

  //============================================================================
  // Group 1: Pure INT instructions (Lane 0 / EXE stage)
  //============================================================================
  logic is_pure_int;
  
  assign is_pure_int = (instr.op == `RV32_OP)       ||  // ALU ops + IMUL/IDIV
                       (instr.op == `RV32_OP_IMM)   ||  // ALU immediate ops
                       (instr.op == `RV32_LOAD)     ||  // Integer loads
                       (instr.op == `RV32_STORE)    ||  // Integer stores
                       (instr.op == `RV32_LOAD_FP)  ||  // FLW (uses LSU)
                       //(instr.op == `RV32_STORE_FP) ||  // FSW (uses LSU) TODO (Logic): FSW should be treated as hybrid, only single issue
                       (instr.op == `RV32_JAL_OP)   ||  // JAL
                       (instr.op == `RV32_JALR_OP)  ||  // JALR
                       (instr.op == `RV32_LUI_OP)   ||  // LUI
                       (instr.op == `RV32_AUIPC_OP) ||  // AUIPC
                       (instr.op == `RV32_MISC_MEM) ||  // FENCE
                       (instr.op == `RV32_SYSTEM);      // CSR, ECALL, EBREAK

  //============================================================================
  // Group 3: Hybrid instructions (must single-issue)
  //============================================================================
  logic is_hybrid;
  
  always_comb begin
    is_hybrid = (instr.op == `RV32_STORE_FP);
    
    // Only check FP opcodes for hybrid operations
      case (instr.funct7)
        `FCVT_W_FUNCT7:   is_hybrid = 1'b1;  // FCVT.W.S, FCVT.WU.S (FP→INT)
        `FCVT_S_FUNCT7:   is_hybrid = 1'b1;  // FCVT.S.W, FCVT.S.WU (INT→FP)
        `FMV_X_W_FUNCT7:  is_hybrid = 1'b1;  // FMV.X.W, FCLASS.S (FP→INT)
        `FMV_W_X_FUNCT7:  is_hybrid = 1'b1;  // FMV.W.X (INT→FP)
        `FCMP_FUNCT7: begin
          // FEQ.S (010), FLT.S (001), FLE.S (000)
          if (instr.funct3 inside {3'b000, 3'b001, 3'b010}) begin
            is_hybrid = 1'b1;
          end
        end
      endcase
  end

  assign inst_is_hybrid_o = is_hybrid;

  //============================================================================
  // Group 2: Pure FP instructions (Lane 1 / FP_EXE stage)
  //============================================================================
  logic is_pure_fp;
  logic is_fp_opcode;
  
  // FP opcodes: FMA (100??11) and OP_FP (1010011)
  assign is_fp_opcode = (instr.op ==? 7'b100??11) | (instr.op == `RV32_OP_FP);
  
  // Pure FP = FP opcode but NOT hybrid
  assign is_pure_fp = is_fp_opcode && !is_hybrid;

  //============================================================================
  // Lane Assignment
  //============================================================================
  always_comb begin
    if (is_pure_fp) begin
      inst_lane_o = 1'b1;  // FP_EXE lane and FSW
    end else begin
      inst_lane_o = 1'b0;  // EXE lane (INT + FLW)
    end
  end

  //============================================================================
  // Register Valid Signals
  //============================================================================
  always_comb begin
    
    // Valid RD: All instructions except stores, branches, and fence
    casez (instr.op)
      `NO_RD_WRITE_OPCODES: inst_rd_valid_o = 1'b0;
      default:              inst_rd_valid_o = 1'b1;
    endcase

    // Valid RS1: All instructions except LUI, AUIPC, JAL
    casez (instr.op)
      `NO_RS1_READ_OPCODES: inst_rs1_valid_o = 1'b0;
      default:              inst_rs1_valid_o = 1'b1;
    endcase

    // Valid RS2: Only R-type, branches, and stores
    casez (instr.op)
      `NO_RS2_READ_OPCODES: inst_rs2_valid_o = 1'b0;
      default:              inst_rs2_valid_o = 1'b1;
    endcase

  end

endmodule

