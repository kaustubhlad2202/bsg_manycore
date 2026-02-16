/**
 *  icache.v
 *
 *  Instruction cache for manycore. 
 *
 *  05/11/2018, shawnless.xie@gmail.com
 *
 *  Diagram on branch target pre-computation logic:
 *  https://docs.google.com/presentation/d/1ZeRHYhqMHJQ0mRgDTilLuWQrZF7On-Be_KNNosgeW0c/edit#slide=id.g10d2e6febb9_1_0
 */

`include "bsg_vanilla_defines.svh"

module icache
  import bsg_vanilla_pkg::*;
  #(`BSG_INV_PARAM(icache_tag_width_p)
    , `BSG_INV_PARAM(icache_entries_p)
    , `BSG_INV_PARAM(icache_block_size_in_words_p) // block size is power of 2.
    , localparam icache_addr_width_lp=`BSG_SAFE_CLOG2(icache_entries_p/icache_block_size_in_words_p)
    , pc_width_lp=(icache_tag_width_p+`BSG_SAFE_CLOG2(icache_entries_p))
    , icache_block_offset_width_lp=`BSG_SAFE_CLOG2(icache_block_size_in_words_p)
    , parameter bit icache_dual_issue_p=0
  )
  (
    input clk_i
    , input network_reset_i
    , input reset_i

    // ctrl signal
    , input v_i
    , input w_i
    , input flush_i
    , input read_pc_plus4_i

    // icache write
    , input [pc_width_lp-1:0] w_pc_i
    , input [RV32_instr_width_gp-1:0] w_instr_i

    // icache read (by processor)
    , input [pc_width_lp-1:0] pc_i
    , input [pc_width_lp-1:0] jalr_prediction_i
    , output [1:0][RV32_instr_width_gp-1:0] instr_o
    , output [pc_width_lp-1:0] pred_or_jump_addr_o
    , output [1:0][pc_width_lp-1:0] pc_r_o
    , output dual_issue_eligible_o
    , output [1:0] instr_lane_o
    , output icache_miss_o
    , output icache_flush_r_o
    , output logic branch_predicted_taken_o
  );

  // localparam
  //
  localparam branch_pc_low_width_lp = (RV32_Bimm_width_gp+1);
  localparam jal_pc_low_width_lp    = (RV32_Jimm_width_gp+1);

  localparam branch_pc_high_width_lp = (pc_width_lp+2) - branch_pc_low_width_lp; 
  localparam jal_pc_high_width_lp    = (pc_width_lp+2) - jal_pc_low_width_lp;

  localparam icache_format_width_lp = `icache_format_width(icache_tag_width_p, icache_block_size_in_words_p, icache_dual_issue_p);

  //
  `declare_icache_format_s(icache_tag_width_p, icache_block_size_in_words_p);

  // address decode
  //
  logic [icache_tag_width_p-1:0] w_tag;
  logic [icache_addr_width_lp-1:0] w_addr;
  logic [icache_block_offset_width_lp-1:0] w_block_offset;
  assign {w_tag, w_addr, w_block_offset} = w_pc_i;
  

  // Instantiate icache memory 
  //
  logic v_li;
  icache_format_s icache_data_li, icache_data_lo;
  logic [icache_addr_width_lp-1:0] icache_addr_li;

  bsg_mem_1rw_sync #(
    .width_p(icache_format_width_lp)
    ,.els_p(icache_entries_p/icache_block_size_in_words_p)
    ,.latch_last_read_p(1)
  ) imem_0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.v_i(v_li)
    ,.w_i(w_i)
    ,.addr_i(icache_addr_li)
    ,.data_i(icache_data_li)
    ,.data_o(icache_data_lo)
  );

  assign icache_addr_li = w_i
    ? w_addr
    : pc_i[icache_block_offset_width_lp+:icache_addr_width_lp];


  //  Pre-compute the lower part of the jump address for JAL and BRANCH
  //  instruction
  //
  //  The width of the adder is defined by the Imm width +1.
  //
  //  For the branch op, we are saving the sign of an imm13 value, in the LSB
  //  of instruction opcode, to use it later when making branch prediction.
  //
  instruction_s w_instr;
  assign w_instr = w_instr_i;
  wire write_branch_instr = w_instr.op ==? `RV32_BRANCH;
  wire write_jal_instr    = w_instr.op ==? `RV32_JAL_OP;
  
  // BYTE address computation
  wire [branch_pc_low_width_lp-1:0] branch_imm_val = `RV32_Bimm_13extract(w_instr);
  wire [branch_pc_low_width_lp-1:0] branch_pc_val = branch_pc_low_width_lp'({w_pc_i, 2'b0}); 
  
  wire [jal_pc_low_width_lp-1:0] jal_imm_val = `RV32_Jimm_21extract(w_instr);
  wire [jal_pc_low_width_lp-1:0] jal_pc_val = jal_pc_low_width_lp'({w_pc_i, 2'b0}); 
  
  logic [branch_pc_low_width_lp-1:0] branch_pc_lower_res;
  logic branch_pc_lower_cout;
  logic [jal_pc_low_width_lp-1:0] jal_pc_lower_res;
  logic jal_pc_lower_cout;
  
  assign {branch_pc_lower_cout, branch_pc_lower_res} = {1'b0, branch_imm_val} + {1'b0, branch_pc_val};
  assign {jal_pc_lower_cout,    jal_pc_lower_res   } = {1'b0, jal_imm_val}    + {1'b0, jal_pc_val   };
  
  
  // Inject the 2-BYTE (half) address, the LSB is ignored.
  wire [RV32_instr_width_gp-1:0] injected_instr = write_branch_instr
    ? `RV32_Bimm_12inject1(w_instr, branch_pc_lower_res)
    : (write_jal_instr
      ? `RV32_Jimm_20inject1(w_instr, jal_pc_lower_res)
      : w_instr);

  wire imm_sign = write_branch_instr
    ? branch_imm_val[RV32_Bimm_width_gp] 
    : jal_imm_val[RV32_Jimm_width_gp];

  wire pc_lower_cout = write_branch_instr
    ? branch_pc_lower_cout
    : jal_pc_lower_cout;




//==============================================================================
// DUAL-ISSUE PREDECODE AND DEPENDENCY TRACKING
//==============================================================================

// Buffered overhead for multi-word writes
dual_issue_instr_cache_overhead_s [icache_block_size_in_words_p-2:0] dual_issue_overhead_r;
dual_issue_instr_cache_overhead_s dual_issue_overhead;

// Logic to decide if previous instruction is dual-issue eligible
logic du_is_eligible;

generate
  if (icache_dual_issue_p) begin : gen_dual_issue_predecode
    
    // Predecode output signals
    logic predecode_lane_lo;
    logic [RV32_reg_addr_width_gp-1:0] predecode_rd_lo;
    logic                              predecode_rd_valid_lo;
    logic [RV32_reg_addr_width_gp-1:0] predecode_rs1_lo;
    logic                              predecode_rs1_valid_lo;
    logic [RV32_reg_addr_width_gp-1:0] predecode_rs2_lo;
    logic                              predecode_rs2_valid_lo;
    
    // Predecode output signals for current instruction
    logic                              predecode_lane_lo;
    logic [RV32_reg_addr_width_gp-1:0] predecode_rd_lo;
    logic                              predecode_rd_valid_lo;
    logic [RV32_reg_addr_width_gp-1:0] predecode_rs1_lo;
    logic                              predecode_rs1_valid_lo;
    logic [RV32_reg_addr_width_gp-1:0] predecode_rs2_lo;
    logic                              predecode_rs2_valid_lo;
    logic                              predecode_is_hybrid_lo;
    logic                              predecode_is_flw_lo;
    logic                              predecode_is_fsw_lo;
    
    // Instantiate predecode module
    icache_preDecode preDecUnit (
       .instruction_i(w_instr)
      ,.inst_lane_o(predecode_lane_lo)
      ,.inst_rd_o(predecode_rd_lo)
      ,.inst_rd_valid_o(predecode_rd_valid_lo)
      ,.inst_rs1_o(predecode_rs1_lo)
      ,.inst_rs1_valid_o(predecode_rs1_valid_lo)
      ,.inst_rs2_o(predecode_rs2_lo)
      ,.inst_rs2_valid_o(predecode_rs2_valid_lo)
      ,.inst_is_hybrid_o(predecode_is_hybrid_lo)
      ,.inst_is_flw_o(predecode_is_flw_lo)
      ,.inst_is_fsw_o(predecode_is_fsw_lo)
    );
    
    // FSM to store previous instruction data
    logic                              prev_inst_lane_r;
    logic [RV32_reg_addr_width_gp-1:0] prev_inst_rd_r;
    logic                              prev_inst_rd_valid_r;
    logic                              prev_inst_is_branch_r;
    logic                              prev_inst_is_hybrid_r;
    logic                              prev_inst_is_flw_r;
    logic                              prev_inst_is_fsw_r;
    
    always_ff @ (posedge clk_i) begin
      if (v_i & w_i) begin
        prev_inst_lane_r      <= predecode_lane_lo;
        prev_inst_rd_r        <= predecode_rd_lo;
        prev_inst_rd_valid_r  <= predecode_rd_valid_lo;
        prev_inst_is_branch_r <= write_branch_instr | write_jal_instr; 
        prev_inst_is_hybrid_r <= predecode_is_hybrid_lo;
        prev_inst_is_flw_r    <= predecode_is_flw_lo;
        prev_inst_is_fsw_r    <= predecode_is_fsw_lo;
      end
    end
    
    //==========================================================================
    // RAW Hazard Detection for FLW and FP instruction pairs
    // FLW writes to FP RF, so check if current FP instruction reads that register
    //==========================================================================
    logic fl_raw_hazard;
    
    always_comb begin
      fl_raw_hazard = 1'b0;
      
      // Previous is FLW, current is pure FP (Lane 1, not FLW/FSW, not hybrid)
      if (prev_inst_is_flw_r && 
          (predecode_lane_lo == 1'b1) && 
          !predecode_is_flw_lo && 
          !predecode_is_fsw_lo && 
          !predecode_is_hybrid_lo) begin
        
        // Check if FLW's destination (FP rd) matches current FP instruction's sources or destination
        // RAW: FLW.rd vs FP.rs1 or FP.rs2
        if (prev_inst_rd_valid_r && predecode_rs1_valid_lo && (prev_inst_rd_r == predecode_rs1_lo)) begin
          fl_raw_hazard = 1'b1;
        end
        if (prev_inst_rd_valid_r && predecode_rs2_valid_lo && (prev_inst_rd_r == predecode_rs2_lo)) begin
          fl_raw_hazard = 1'b1;
        end
        // WAW: FLW.rd vs FP.rd
        if (prev_inst_rd_valid_r && predecode_rd_valid_lo && (prev_inst_rd_r == predecode_rd_lo)) begin
          fl_raw_hazard = 1'b1;
        end
      end
      
      // Previous is pure FP, current is FSW or FLW
      if ((prev_inst_lane_r == 1'b1) && 
          !prev_inst_is_flw_r && 
          !prev_inst_is_fsw_r && 
          !prev_inst_is_hybrid_r) begin
        
        // Current is FSW: RAW check (prev FP.rd vs FSW.rs2)
        if (predecode_is_fsw_lo && 
            prev_inst_rd_valid_r && 
            predecode_rs2_valid_lo && 
            (prev_inst_rd_r == predecode_rs2_lo)) begin
          fl_raw_hazard = 1'b1;
        end
        
        // Current is FLW: WAW check (prev FP.rd vs FLW.rd)
        if (predecode_is_flw_lo && 
            prev_inst_rd_valid_r && 
            predecode_rd_valid_lo && 
            (prev_inst_rd_r == predecode_rd_lo)) begin
          fl_raw_hazard = 1'b1;
        end
      end
    end
    
    //==========================================================================
    // Dual-Issue Eligibility
    //==========================================================================
    logic instructions_belong_to_different_lanes;
    
    assign instructions_belong_to_different_lanes = (prev_inst_lane_r != predecode_lane_lo);
    
    assign du_is_eligible = 
      instructions_belong_to_different_lanes &&  // Different lanes (Lane 0 vs Lane 1)
      !prev_inst_is_branch_r &&                  // Previous not branch/jump
      !prev_inst_is_hybrid_r &&                  // Previous instruction not hybrid
      !predecode_is_hybrid_lo &&                 // Current instruction not hybrid
      !fl_raw_hazard;                           // No FP register conflicts




    assign dual_issue_overhead = '{
      prev_inst_du_is_eligible: du_is_eligible,
      curr_decode_lane: predecode_lane_lo
    };
    

    
  end else begin : gen_no_dual_issue_predecode
    // When disabled, create dummy signals to avoid undefined references
    localparam dual_issue_overhead_width_c = 0;
    
  end
endgenerate



//Control signals for instruction buffer
logic [icache_block_size_in_words_p-2:0] imm_sign_r;
logic [icache_block_size_in_words_p-2:0] pc_lower_cout_r;
logic [icache_block_size_in_words_p-2:0][RV32_instr_width_gp-1:0] buffered_instr_r;

//==============================================================================
// DATA WRITE GROUP FORMATION
//==============================================================================

//Dual_Issue_Overhead //TODO: Optimize, only used in dual issue mode
logic [icache_block_size_in_words_p-1:0] du_is_eligible_packed;
logic [icache_block_size_in_words_p-1:0] dec_lane_packed;

generate
  if (icache_dual_issue_p) begin : gen_dual_issue_overhead
    
    assign du_is_eligible_packed = {
      1'b0,  // Entry 0 unused
      dual_issue_overhead.prev_inst_du_is_eligible,
      //TODO: Parameterize below code
      dual_issue_overhead_r[2].prev_inst_du_is_eligible,
      dual_issue_overhead_r[1].prev_inst_du_is_eligible
    };
    
    assign dec_lane_packed = {
      dual_issue_overhead.curr_decode_lane,
      //TODO: Parameterize below code
      dual_issue_overhead_r[2].curr_decode_lane,
      dual_issue_overhead_r[1].curr_decode_lane,
      dual_issue_overhead_r[0].curr_decode_lane
    };
    
    
  end else begin : gen_single_issue_no_overhead
    
    // Assign without dual-issue fields (0-width field gets optimized away); Tie-off
    assign duis_eligible_packed = 'b0;
    assign decode_lane_packed = 'b0;

    
  end
endgenerate

// Assign with dual-issue fields
assign icache_data_li = '{
      du_is_eligible: du_is_eligible_packed,
      dec_lane:       dec_lane_packed,
      lower_sign: {imm_sign, imm_sign_r},
      lower_cout: {pc_lower_cout, pc_lower_cout_r},
      tag: w_tag,
      instr: {injected_instr, buffered_instr_r}
    };




//==============================================================================
// BUFFERED WRITES AND CACHE/BUFFER ENABLE LOGIC
//==============================================================================

// icache write counter
logic [icache_block_offset_width_lp-1:0] write_count_r;
always_ff @ (posedge clk_i) begin
  if (network_reset_i) begin
    write_count_r <= '0;
  end
  else begin
    if (v_i & w_i) begin
      write_count_r <= write_count_r + 1'b1;
    end
  end
end


logic write_en_buffer;
logic write_en_icache;

always_ff @ (posedge clk_i) begin
  if (write_en_buffer) begin
    imm_sign_r[write_count_r]       <= imm_sign;
    pc_lower_cout_r[write_count_r]  <= pc_lower_cout;
    buffered_instr_r[write_count_r] <= injected_instr;
  end
end

// Dual-issue overhead buffering (conditional)
generate
  if (icache_dual_issue_p) begin : gen_dual_issue_buffer
    always_ff @ (posedge clk_i) begin
      if (write_en_buffer) begin
        dual_issue_overhead_r[write_count_r] <= dual_issue_overhead;
      end
    end
  end
endgenerate


always_comb begin
  if (write_count_r == icache_block_size_in_words_p-1) begin
    write_en_buffer = 1'b0;
    write_en_icache = v_i & w_i;
  end
  else begin
    write_en_buffer = v_i & w_i;
    write_en_icache = 1'b0;
  end
end







  // synopsys translate_off
  always_ff @ (negedge clk_i) begin
    if ((network_reset_i === 1'b0) & v_i & w_i) begin
      assert(write_count_r == w_block_offset) else $error("icache being written not in sequence.");
    end
  end
  // synopsys translate_on



  // Program counter
  logic [pc_width_lp-1:0] pc_r; 
  logic [pc_width_lp-1:0] pc_next_inst_r; //FIXME (Optimize): Used only for Dual Issue

  logic icache_flush_r;
  // Since imem has one cycle delay and we send next cycle's address, pc_n,
  // if the PC is not written, the instruction must not change.

  always_ff @ (posedge clk_i) begin
    if (reset_i) begin
      pc_r <= '0;
      pc_next_inst_r <= 'b1; //FIXME (Optimize): Used only for Dual Issue
      icache_flush_r <= 1'b0;
    end
    else begin

      if (v_i & ~w_i) begin
        pc_r <= pc_i;
        pc_next_inst_r <= pc_i + 'b1; //FIXME (Optimize): Used only for Dual Issue
        icache_flush_r <= 1'b0;
      end
      else begin
        icache_flush_r <= flush_i;
      end
    end
  end

  assign icache_flush_r_o = icache_flush_r;

  // TODO: Update the energy saving logic to account for dual-Issue
  // Energy-saving logic
  // - Don't read the icache if the current pc is not at the last word of the block, and 
  //   there is a hint from the next-pc logic that it is reading pc+4 next (no branch or jump).
  assign v_li = w_i
    ? write_en_icache
    : (v_i & ((&pc_r[0+:icache_block_offset_width_lp]) | ~read_pc_plus4_i));


  // Merge the PC lower part and high part
  // BYTE operations

  logic [icache_block_offset_width_lp-1:0] idx;
  logic [icache_block_offset_width_lp-1:0] idx_next_inst; //FIXME (Optimize): Used only for Dual Issue

  assign idx = pc_r[0+:icache_block_offset_width_lp];
  assign idx_next_inst = pc_next_inst_r[0+:icache_block_offset_width_lp]; //FIXME (Optimize): Used only for Dual Issue

  instruction_s [1:0] instr_out;
  logic [1:0] lower_sign_out; //FIXME (Optimize): Use upper bit only for Dual Issue
  logic [1:0] lower_cout_out; //FIXME (Optimize): Use upper bit only for Dual Issue
  logic dual_issue; //FIXME (Optimize): Used only for Dual Issue
  logic [1:0] decode_lane; //FIXME (Optimize): Used only for Dual Issue

  assign instr_out[0] = icache_data_lo.instr[idx];
  assign lower_sign_out[0] = icache_data_lo.lower_sign[idx];
  assign lower_cout_out[0] = icache_data_lo.lower_cout[idx];

  logic lower_sign_out_final, lower_cout_out_final;

  generate
    if(icache_dual_issue_p) begin: dual_read_logic

      //Dual issue eligible in current cycle?
      assign dual_issue = icache_data_lo.du_is_eligible[idx];

      //Decode lane for both instructions
      assign decode_lane[0] = icache_data_lo.dec_lane[idx];
      assign decode_lane[1] = icache_data_lo.dec_lane[idx_next_inst];

      //Get data for the next instruction
      assign instr_out[1] = icache_data_lo.instr[idx_next_inst];  
      assign lower_sign_out[1] = icache_data_lo.lower_sign[idx_next_inst];
      assign lower_cout_out[1] = icache_data_lo.lower_cout[idx_next_inst];
      
      //If dual issue, only second instruction can be a branch
      assign lower_sign_out_final = (dual_issue) ? lower_sign_out[1] : lower_sign_out[0];
      assign lower_cout_out_final = (dual_issue) ? lower_cout_out[1] : lower_cout_out[0];

    end

    else begin: no_dual_read_logic
      //Tied off
      assign dual_issue = 'b0;

      //Tied off
      assign decode_lane = 'b0;

      //Tied off
      assign instr_out[1] = 'b0;
      assign lower_sign_out[1] = 'b0;
      assign lower_cout_out[1] = 'b0;

      assign lower_sign_out_final = lower_sign_out[0];
      assign lower_cout_out_final = lower_cout_out[0];  

    end

  endgenerate

  wire sel_pc    = ~(lower_sign_out_final ^ lower_cout_out_final); 
  wire sel_pc_p1 = (~lower_sign_out_final) & lower_cout_out_final;


  
  logic [branch_pc_high_width_lp-1:0] branch_pc_high;
  logic [jal_pc_high_width_lp-1:0] jal_pc_high;

  generate

    if(icache_dual_issue_p) begin: dual_issue_branch

      assign branch_pc_high = (dual_issue) ?  pc_next_inst_r[(branch_pc_low_width_lp-2)+:branch_pc_high_width_lp] : pc_r[(branch_pc_low_width_lp-2)+:branch_pc_high_width_lp];
      assign jal_pc_high = (dual_issue) ? pc_next_inst_r[(branch_pc_low_width_lp-2)+:branch_pc_high_width_lp] : pc_r[(jal_pc_low_width_lp-2)+:jal_pc_high_width_lp];
    
    end

    else begin: single_issue_branch

      assign branch_pc_high = pc_r[(branch_pc_low_width_lp-2)+:branch_pc_high_width_lp];
      assign jal_pc_high = pc_r[(jal_pc_low_width_lp-2)+:jal_pc_high_width_lp];

    end

  endgenerate



  // We are saving the carry-out when we are partially computing the
  // lower-portion jump addr, as we write to the icache.
  // When we are calculating the full jump addr, as we read back from the icache,
  // we decide how to propagate the carry to the upper portion of the jump
  // addr, using this table.
  // -------------------------------------------------------------
  // pc_lower_sign  pc_lower_cout  | pc_high-1  pc_high  pc_high+1
  // ------------------------------+------------------------------
  //   0              0            |            1                   
  //   0              1            |                     1
  //   1              0            | 1                                     
  //   1              1            |            1 
  // ------------------------------+------------------------------
  //



  logic [branch_pc_high_width_lp-1:0] branch_pc_high_out;
  logic [jal_pc_high_width_lp-1:0] jal_pc_high_out;

  always_comb begin
    if (sel_pc) begin
      branch_pc_high_out = branch_pc_high;
      jal_pc_high_out = jal_pc_high;
    end
    else if (sel_pc_p1) begin
      branch_pc_high_out = branch_pc_high + 1'b1;
      jal_pc_high_out = jal_pc_high + 1'b1;
    end
    else begin // sel_pc_n1
      branch_pc_high_out = branch_pc_high - 1'b1;
      jal_pc_high_out = jal_pc_high - 1'b1;
    end
  end
  

  logic is_jal_instr;
  logic is_jalr_instr;

  generate

    if (icache_dual_issue_p) begin: dual_issue_JAL

      assign is_jal_instr  =  instr_out[dual_issue].op == `RV32_JAL_OP;
      assign is_jalr_instr =  instr_out[dual_issue].op == `RV32_JALR_OP;

    end

    else begin: single_issue_JAL

      assign is_jal_instr =  instr_out[0].op == `RV32_JAL_OP;
      assign is_jalr_instr = instr_out[0].op == `RV32_JALR_OP;

    end

  endgenerate


  logic [pc_width_lp+2-1:0] jal_pc;
  logic [pc_width_lp+2-1:0] branch_pc;

  generate

    if (icache_dual_issue_p) begin: dual_issue_BR_J_PC

      assign branch_pc = {branch_pc_high_out, `RV32_Bimm_13extract(instr_out[dual_issue])};
      assign jal_pc = {jal_pc_high_out, `RV32_Jimm_21extract(instr_out[dual_issue])};

    end

    else begin: single_issue_BR_JAL_PC

      assign branch_pc = {branch_pc_high_out, `RV32_Bimm_13extract(instr_out[0])};
      assign jal_pc = {jal_pc_high_out, `RV32_Jimm_21extract(instr_out[0])};

    end

  endgenerate
   

//==============================================================================
// OUTPUT ASSIGNMENTS
//==============================================================================

//Instructions and corresponding PC
assign instr_o = instr_out;
assign pc_r_o = {pc_next_inst_r, pc_r};

//Decode lane out
assign instr_lane_o = decode_lane;

//Can we dual_issue?
assign dual_issue_eligible_o = dual_issue;

// this is word addr.
assign pred_or_jump_addr_o = is_jal_instr
  ? jal_pc[2+:pc_width_lp]
  : (is_jalr_instr
    ? jalr_prediction_i  //FIXME: Check for uArch consistency of jalr_prediction_i when we dual issue
    : branch_pc[2+:pc_width_lp]);

// branch imm sign
assign branch_predicted_taken_o = lower_sign_out_final;

// the icache miss logic
assign icache_miss_o = icache_data_lo.tag != pc_r[icache_block_offset_width_lp+icache_addr_width_lp+:icache_tag_width_p]; //FIXME: Check for uArch consistency of  when we dual issue

assign icache_flush_r_o = icache_flush_r;






//==============================================================================
// DUAL-ISSUE ELIGIBILITY STATISTICS TRACKER
// Samples dual-issue potential at each cache line fill
//==============================================================================

generate
  if (icache_dual_issue_p) begin : gen_dual_issue_stats
    
    // Counters for tracking dual-issue opportunities
    integer total_cache_fills;
    integer total_eligible_pairs;
    integer histogram [0:icache_block_size_in_words_p];  // histogram[i] = fills with i eligible pairs
    
    // Count eligible instructions in current fill
    logic [icache_block_size_in_words_p-1:0] du_eligible_vector;
    integer eligible_count;
    

    // Count population (number of 1s)
    always_comb begin
      eligible_count = 0;
      for (int i = 0; i < icache_block_size_in_words_p; i++) begin
        eligible_count += du_is_eligible_packed[i];
      end
    end
    
    // Sample at icache write enable (when cache line fill completes)
    always_ff @ (posedge clk_i) begin
      if (network_reset_i) begin
        total_cache_fills <= 0;
        total_eligible_pairs <= 0;
        for (int i = 0; i <= icache_block_size_in_words_p; i++) begin
          histogram[i] <= 0;
        end
      end
      else if (write_en_icache) begin
        total_cache_fills <= total_cache_fills + 1;
        total_eligible_pairs <= total_eligible_pairs + eligible_count;
        histogram[eligible_count] <= histogram[eligible_count] + 1;
      end
    end
    
    // Dump statistics at end of simulation
    // synopsys translate_off
    final begin
      $display("==============================================================================");
      $display("ICACHE DUAL-ISSUE FILL TIME ELIGIBILITY STATISTICS");
      $display("==============================================================================");
      $display("Total cache fills: %0d", total_cache_fills);
      $display("Total eligible dual-issue pairs: %0d", total_eligible_pairs);
      if (total_cache_fills > 0) begin
        $display("Average eligible pairs per fill: %.2f", 
                 real'(total_eligible_pairs) / real'(total_cache_fills));
        $display("Dual-issue utilization: %.2f%%", 
                 100.0 * real'(total_eligible_pairs) / real'(total_cache_fills * icache_block_size_in_words_p));
      end
      $display("");
      $display("Histogram (eligible pairs per cache line fill):");
      for (int i = 0; i <= icache_block_size_in_words_p; i++) begin
        if (histogram[i] > 0) begin
          $display("  %0d eligible: %0d fills (%.2f%%)", 
                   i, histogram[i], 
                   100.0 * real'(histogram[i]) / real'(total_cache_fills));
        end
      end
      $display("==============================================================================");
    end
    // synopsys translate_on
    
  end
endgenerate



 
endmodule

`BSG_ABSTRACT_MODULE(icache)
