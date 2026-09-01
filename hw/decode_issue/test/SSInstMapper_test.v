//========================================================================
// SSInstMapper_test.v
//========================================================================
// A testbench for the SSInstMapper crossbar scheduler: age priority,
// slot-based accept, and iSLIP matching between front-end lanes and
// back-end pipes. Data muxing given an already-computed route is
// SSInstRouter's job, tested separately in SSInstRouter_test.v.
//
// No test case here ever commits, so oldest_seq_num stays at its reset
// value (0) throughout -- it's just tied there directly rather than
// wired up through CommitNotif/TestMPub/SSSeqAge.

`include "defs/UArch.v"
`include "hw/decode_issue/SSInstMapper.v"
`include "test/TestUtils.v"

import TestEnv::*;
import UArch::*;

//========================================================================
// SSInstMapperTestSuite
//========================================================================

module SSInstMapperTestSuite #(
  parameter p_suite_num        = 0,
  parameter p_num_pipes        = 4,
  parameter p_num_input_lanes  = 4,
  parameter p_input_lanes_bits = p_num_input_lanes > 1 ? $clog2(p_num_input_lanes) : 1,
  parameter p_iq_depth         = 8,
  parameter p_seq_num_bits     = 8,
  parameter p_num_iter         = 2
);

  // Define pipe subsets for testing
  // Pipe 0: ALU operations (ADD, SUB, AND, OR, XOR, SLT, SLTU, SRA, SRL, SLL, LUI, AUIPC)
  // Pipe 1: Memory operations (LB, LH, LW, LBU, LHU, SB, SH, SW)
  // Pipe 2: Control operations (JAL, JALR, BEQ, BNE, BLT, BGE, BLTU, BGEU)
  // Pipe 3: Multiply/Divide operations (MUL, MULH, MULHU, MULHSU, DIV, DIVU, REM, REMU)
  //
  // Built with explicit indexed assignment, not a positional '{...}
  // literal -- for a [p_num_pipes-1:0] (descending) array, a positional
  // literal silently assigns in reverse (index p_num_pipes-1 gets the
  // first element). Zeppelin.v's own gen_pipe_subsets() uses this same
  // indexed style for the real pipe_subsets config, for the same reason.
  function automatic rv_op_vec [p_num_pipes-1:0] gen_pipe_subsets;
    gen_pipe_subsets[0] = OP_ADD_VEC    | OP_SUB_VEC    | OP_AND_VEC    | OP_OR_VEC     |
                           OP_XOR_VEC    | OP_SLT_VEC    | OP_SLTU_VEC   | OP_SRA_VEC    |
                           OP_SRL_VEC    | OP_SLL_VEC    | OP_LUI_VEC    | OP_AUIPC_VEC;

    gen_pipe_subsets[1] = OP_LB_VEC     | OP_LH_VEC     | OP_LW_VEC     | OP_LBU_VEC    |
                           OP_LHU_VEC    | OP_SB_VEC     | OP_SH_VEC     | OP_SW_VEC;

    gen_pipe_subsets[2] = OP_JAL_VEC    | OP_JALR_VEC   | OP_BEQ_VEC    | OP_BNE_VEC    |
                           OP_BLT_VEC    | OP_BGE_VEC    | OP_BLTU_VEC   | OP_BGEU_VEC;

    gen_pipe_subsets[3] = OP_MUL_VEC    | OP_MULH_VEC   | OP_MULHU_VEC  | OP_MULHSU_VEC |
                           OP_DIV_VEC    | OP_DIVU_VEC   | OP_REM_VEC    | OP_REMU_VEC;
  endfunction

  localparam rv_op_vec [p_num_pipes-1:0] p_pipe_subsets = gen_pipe_subsets();

  string suite_name = $sformatf("%0d: SSInstMapperTestSuite_%0d_%0d_%0d_%0d_%0d",
                                p_suite_num, p_num_pipes, p_num_input_lanes,
                                p_iq_depth, p_seq_num_bits, p_num_iter);

  //----------------------------------------------------------------------
  // Setup
  //----------------------------------------------------------------------

  logic clk, rst;
  TestUtils t( .* );

  //----------------------------------------------------------------------
  // Instantiate design under test
  //----------------------------------------------------------------------

  typedef struct packed {
    rv_uop                     uop;
    logic [p_seq_num_bits-1:0] seq_num;
    logic                      src_pending0;
    logic                      src_pending1;
  } t_msg;

  t_msg dut_in_msg [p_num_input_lanes];
  logic dut_val    [p_num_input_lanes];

  logic                          dut_iq_rdy         [p_num_pipes];
  logic [$clog2(p_iq_depth):0]   dut_iq_avail_slots [p_num_pipes];

  // Never committed in any test case, so this stays at its reset value
  // throughout (matches what the original test actually exercised).
  logic [p_seq_num_bits-1:0] dut_oldest_seq_num;

  logic [p_input_lanes_bits-1:0] dut_route_idx [p_num_pipes];
  logic                          dut_iq_val    [p_num_pipes];
  logic                          dut_lane_val  [p_num_input_lanes];

  SSInstMapper #(
    .t_msg             (t_msg),
    .p_num_pipes       (p_num_pipes),
    .p_num_input_lanes (p_num_input_lanes),
    .p_iq_depth        (p_iq_depth),
    .p_seq_num_bits    (p_seq_num_bits),
    .p_num_iter        (p_num_iter),
    .p_pipe_subsets    (p_pipe_subsets)
  ) dut (
    .in_msg           (dut_in_msg),
    .val              (dut_val),
    .iq_rdy           (dut_iq_rdy),
    .iq_avail_slots   (dut_iq_avail_slots),
    .oldest_seq_num   (dut_oldest_seq_num),
    .route_idx        (dut_route_idx),
    .iq_val           (dut_iq_val),
    .lane_val         (dut_lane_val),
    .lane_to_pipe_map ()
  );

  initial dut_oldest_seq_num = '0;

  //----------------------------------------------------------------------
  // Helper tasks
  //----------------------------------------------------------------------

  task set_inputs(
    input rv_uop                     uop     [p_num_input_lanes],
    input logic [p_seq_num_bits-1:0] seq_num [p_num_input_lanes],
    input logic                      val     [p_num_input_lanes]
  );
    for (int i = 0; i < p_num_input_lanes; i++) begin
      dut_in_msg[i].uop          = uop[i];
      dut_in_msg[i].seq_num      = seq_num[i];
      dut_in_msg[i].src_pending0 = 1'b0;
      dut_in_msg[i].src_pending1 = 1'b0;
      dut_val[i]                 = val[i];
    end
  endtask

  task set_iq_state(
    input logic                        rdy         [p_num_pipes],
    input logic [$clog2(p_iq_depth):0] avail_slots [p_num_pipes]
  );
    for (int i = 0; i < p_num_pipes; i++) begin
      dut_iq_rdy[i]         = rdy[i];
      dut_iq_avail_slots[i] = avail_slots[i];
    end
  endtask

  task check_route(
    input logic [p_input_lanes_bits-1:0] exp_route_idx [p_num_pipes],
    input logic                          exp_iq_val    [p_num_pipes],
    input logic                          exp_lane_val  [p_num_input_lanes]
  );
    #1; // Let combinational logic settle
    for (int i = 0; i < p_num_pipes; i++) begin
      `CHECK_EQ(dut_iq_val[i], exp_iq_val[i]);
      if (exp_iq_val[i]) begin
        `CHECK_EQ(dut_route_idx[i], exp_route_idx[i]);
      end
    end
    for (int i = 0; i < p_num_input_lanes; i++) begin
      `CHECK_EQ(dut_lane_val[i], exp_lane_val[i]);
    end
  endtask

  //----------------------------------------------------------------------
  // test_case_single_instruction
  //----------------------------------------------------------------------
  // Test routing a single instruction to a compatible pipe

  task test_case_single_instruction();
    t.test_case_begin( "test_case_single_instruction" );
    if( !t.run_test ) return;

    // Test 1: Single ADD instruction -> should go to Pipe 0 (ALU)
    set_inputs(
      '{OP_ADD, OP_ADD, OP_ADD, OP_ADD},  // Only lane 0 valid
      '{p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0)},
      '{1'b1, 1'b0, 1'b0, 1'b0}
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );
    check_route(
      '{p_input_lanes_bits'(0), 'x, 'x, 'x},  // Pipe 0 gets lane 0
      '{1'b1, 1'b0, 1'b0, 1'b0},  // Only pipe 0 has instruction
      '{1'b1, 1'b0, 1'b0, 1'b0}   // Only lane 0 transferred
    );

    // Test 2: Single MUL instruction -> should go to Pipe 3 (MUL/DIV)
    set_inputs(
      '{OP_MUL, OP_MUL, OP_MUL, OP_MUL},
      '{p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0)},
      '{1'b0, 1'b1, 1'b0, 1'b0}  // Lane 1 valid
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );
    check_route(
      '{'x, 'x, 'x, p_input_lanes_bits'(1)},  // Pipe 3 gets lane 1
      '{1'b0, 1'b0, 1'b0, 1'b1},
      '{1'b0, 1'b1, 1'b0, 1'b0}
    );

    // Test 3: Single LW instruction -> should go to Pipe 1 (MEM)
    set_inputs(
      '{OP_LW, OP_LW, OP_LW, OP_LW},
      '{p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0)},
      '{1'b0, 1'b0, 1'b1, 1'b0}  // Lane 2 valid
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );
    check_route(
      '{'x, p_input_lanes_bits'(2), 'x, 'x},  // Pipe 1 gets lane 2
      '{1'b0, 1'b1, 1'b0, 1'b0},
      '{1'b0, 1'b0, 1'b1, 1'b0}
    );

    // Test 4: Single BNE instruction -> should go to Pipe 2 (CTRL)
    set_inputs(
      '{OP_BNE, OP_BNE, OP_BNE, OP_BNE},
      '{p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0)},
      '{1'b0, 1'b0, 1'b0, 1'b1}  // Lane 3 valid
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );
    check_route(
      '{'x, 'x, p_input_lanes_bits'(3), 'x},  // Pipe 2 gets lane 3
      '{1'b0, 1'b0, 1'b1, 1'b0},
      '{1'b0, 1'b0, 1'b0, 1'b1}
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_non_conflicting
  //----------------------------------------------------------------------
  // Test routing multiple non-conflicting instructions

  task test_case_non_conflicting();
    t.test_case_begin( "test_case_non_conflicting" );
    if( !t.run_test ) return;

    // All lanes have different instruction types
    set_inputs(
      '{OP_ADD, OP_LW, OP_BNE, OP_MUL},  // Different ops
      '{p_seq_num_bits'(0), p_seq_num_bits'(1), p_seq_num_bits'(2), p_seq_num_bits'(3)},
      '{1'b1, 1'b1, 1'b1, 1'b1}          // All valid
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );
    check_route(
      '{p_input_lanes_bits'(0), p_input_lanes_bits'(1), p_input_lanes_bits'(2), p_input_lanes_bits'(3)},  // Each pipe gets corresponding lane
      '{1'b1, 1'b1, 1'b1, 1'b1},  // All pipes receive instruction
      '{1'b1, 1'b1, 1'b1, 1'b1}   // All lanes transferred
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_age_priority
  //----------------------------------------------------------------------
  // Test that older instructions get priority when conflicting

  task test_case_age_priority();
    t.test_case_begin( "test_case_age_priority" );
    if( !t.run_test ) return;

    // Two ADD instructions competing for Pipe 0 (ALU)
    // Lane 0: seq_num = 5 (newer)
    // Lane 1: seq_num = 3 (older) <- should win
    set_inputs(
      '{OP_ADD, OP_ADD, OP_LW, OP_MUL},
      '{p_seq_num_bits'(5), p_seq_num_bits'(3), p_seq_num_bits'(4), p_seq_num_bits'(6)},
      '{1'b1, 1'b1, 1'b1, 1'b1}
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );

    // Expected behavior:
    // Iteration 1: Pipe 0 grants to lane 1 (older), pipe 1 grants to lane 2, pipe 3 grants to lane 3
    // After iteration 1, lane 0 is unmatched (lost contention to lane 1)
    // Iteration 2: No more matches (lane 0 wants pipe 0 which is already matched)
    check_route(
      '{p_input_lanes_bits'(1), p_input_lanes_bits'(2), 'x, p_input_lanes_bits'(3)},  // Pipe 0 gets lane 1, pipe 1 gets lane 2, pipe 3 gets lane 3
      '{1'b1, 1'b1, 1'b0, 1'b1},  // Pipes 0,1,3 receive instructions, pipe 2 does not
      '{1'b0, 1'b1, 1'b1, 1'b1}   // Lanes 1,2,3 transfer, lane 0 does not (lost contention)
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_slot_priority
  //----------------------------------------------------------------------
  // Test that pipes with more available slots get priority

  task test_case_slot_priority();
    t.test_case_begin( "test_case_slot_priority" );
    if( !t.run_test ) return;

    // One ADD instruction that could go to Pipe 0
    // But if we had multiple pipes supporting ADD, it should prefer
    // the one with more slots. For this test, we just verify routing works.
    set_inputs(
      '{OP_ADD, OP_ADD, OP_ADD, OP_ADD},
      '{p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0), p_seq_num_bits'(0)},
      '{1'b1, 1'b0, 1'b0, 1'b0}
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd2, 4'd8, 4'd5, 4'd3}  // Pipe 1 has most slots but doesn't support ADD
    );
    check_route(
      '{p_input_lanes_bits'(0), 'x, 'x, 'x},  // Still goes to Pipe 0 (only option)
      '{1'b1, 1'b0, 1'b0, 1'b0},
      '{1'b1, 1'b0, 1'b0, 1'b0}
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_pipe_not_ready
  //----------------------------------------------------------------------
  // Test that instructions aren't routed to non-ready pipes

  task test_case_pipe_not_ready();
    t.test_case_begin( "test_case_pipe_not_ready" );
    if( !t.run_test ) return;

    // ADD instruction, but Pipe 0 (ALU) is not ready
    set_inputs(
      '{OP_ADD, OP_LW, OP_BNE, OP_MUL},
      '{p_seq_num_bits'(0), p_seq_num_bits'(1), p_seq_num_bits'(2), p_seq_num_bits'(3)},
      '{1'b1, 1'b1, 1'b1, 1'b1}
    );
    set_iq_state(
      '{1'b0, 1'b1, 1'b1, 1'b1},  // Pipe 0 not ready
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );
    check_route(
      '{'x, p_input_lanes_bits'(1), p_input_lanes_bits'(2), p_input_lanes_bits'(3)},  // Pipe 0 gets nothing
      '{1'b0, 1'b1, 1'b1, 1'b1},  // Pipe 0 doesn't receive
      '{1'b0, 1'b1, 1'b1, 1'b1}   // Lane 0 not transferred
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_full_contention
  //----------------------------------------------------------------------
  // Test all lanes wanting the same pipe

  task test_case_full_contention();
    t.test_case_begin( "test_case_full_contention" );
    if( !t.run_test ) return;

    // All lanes have ADD instructions -> all want Pipe 0
    set_inputs(
      '{OP_ADD, OP_SUB, OP_AND, OP_OR},  // All ALU ops
      '{p_seq_num_bits'(10), p_seq_num_bits'(5), p_seq_num_bits'(15), p_seq_num_bits'(8)},       // Different ages
      '{1'b1, 1'b1, 1'b1, 1'b1}
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );

    // With p_num_iter=2, we should get 2 matches per cycle max
    // (limited by single pipe accepting)
    // Actually, with single output, only 1 can match per iteration
    // So with 2 iterations, we get 1 match total to Pipe 0
    // The oldest (seq_num=5, lane 1) should win in iteration 1
    check_route(
      '{p_input_lanes_bits'(1), 'x, 'x, 'x},  // Pipe 0 gets oldest (lane 1, seq=5)
      '{1'b1, 1'b0, 1'b0, 1'b0},
      '{1'b0, 1'b1, 1'b0, 1'b0}   // Only lane 1 transferred
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_invalid_instructions
  //----------------------------------------------------------------------
  // Test with invalid instructions

  task test_case_invalid_instructions();
    t.test_case_begin( "test_case_invalid_instructions" );
    if( !t.run_test ) return;

    // Mix of valid and invalid
    set_inputs(
      '{OP_ADD, OP_LW, OP_BNE, OP_MUL},
      '{p_seq_num_bits'(0), p_seq_num_bits'(1), p_seq_num_bits'(2), p_seq_num_bits'(3)},
      '{1'b1, 1'b0, 1'b1, 1'b0}  // Only lanes 0 and 2 valid
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd8, 4'd8, 4'd8, 4'd8}
    );
    check_route(
      '{p_input_lanes_bits'(0), 'x, p_input_lanes_bits'(2), 'x},
      '{1'b1, 1'b0, 1'b1, 1'b0},
      '{1'b1, 1'b0, 1'b1, 1'b0}   // Only valid lanes transferred
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_no_slots_available
  //----------------------------------------------------------------------
  // Test behavior when pipes have no available slots

  task test_case_no_slots_available();
    t.test_case_begin( "test_case_no_slots_available" );
    if( !t.run_test ) return;

    set_inputs(
      '{OP_ADD, OP_LW, OP_BNE, OP_MUL},
      '{p_seq_num_bits'(0), p_seq_num_bits'(1), p_seq_num_bits'(2), p_seq_num_bits'(3)},
      '{1'b1, 1'b1, 1'b1, 1'b1}
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd0, 4'd0, 4'd8, 4'd0}  // Only Pipe 2 has slots
    );
    check_route(
      '{'x, 'x, p_input_lanes_bits'(2), 'x},
      '{1'b0, 1'b0, 1'b1, 1'b0},  // Only pipe 2 matches (has slots)
      '{1'b0, 1'b0, 1'b1, 1'b0}   // Only lane 2 transferred
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_mixed_scenario
  //----------------------------------------------------------------------
  // Complex scenario with multiple conflicts and priorities

  task test_case_mixed_scenario();
    t.test_case_begin( "test_case_mixed_scenario" );
    if( !t.run_test ) return;

    // Lane 0: ADD (seq=20, newer) -> Pipe 0
    // Lane 1: SUB (seq=10, older) -> Pipe 0 (should win over lane 0)
    // Lane 2: LW (seq=15) -> Pipe 1
    // Lane 3: MUL (seq=12) -> Pipe 3
    set_inputs(
      '{OP_ADD, OP_SUB, OP_LW, OP_MUL},
      '{p_seq_num_bits'(20), p_seq_num_bits'(10), p_seq_num_bits'(15), p_seq_num_bits'(12)},
      '{1'b1, 1'b1, 1'b1, 1'b1}
    );
    set_iq_state(
      '{1'b1, 1'b1, 1'b1, 1'b1},
      '{4'd5, 4'd3, 4'd7, 4'd2}  // Different slot counts
    );

    // Expected: lane 1 wins pipe 0 (older), lanes 2,3 get their pipes
    // Lane 0 doesn't get matched (lost contention to lane 1)
    check_route(
      '{p_input_lanes_bits'(1), p_input_lanes_bits'(2), 'x, p_input_lanes_bits'(3)},  // Pipe 0 gets lane 1, pipe 1 gets lane 2, pipe 3 gets lane 3
      '{1'b1, 1'b1, 1'b0, 1'b1},  // Pipes 0,1,3 receive instructions, pipe 2 does not
      '{1'b0, 1'b1, 1'b1, 1'b1}   // Lanes 1,2,3 transfer, lane 0 does not (lost contention)
    );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // run_test_suite
  //----------------------------------------------------------------------

  task run_test_suite();
    t.test_suite_begin( suite_name );

    test_case_single_instruction();
    test_case_non_conflicting();
    test_case_age_priority();
    test_case_slot_priority();
    test_case_pipe_not_ready();
    test_case_full_contention();
    test_case_invalid_instructions();
    test_case_no_slots_available();
    test_case_mixed_scenario();
  endtask

  //----------------------------------------------------------------------
  // Linetracing
  //----------------------------------------------------------------------

  string trace;

  // verilator lint_off BLKSEQ
  always @( posedge clk ) begin
    #2;
    trace = "";
    t.trace( trace );
  end
  // verilator lint_on BLKSEQ

endmodule

//========================================================================
// SSInstMapper_test
//========================================================================

module SSInstMapper_test;

  // Default config: 4 pipes, 4 lanes, 8-depth IQ, 8-bit seq num, 2 iterations
  SSInstMapperTestSuite suite_1();

  int s;

  initial begin
    test_bench_begin( `__FILE__ );
    s = get_test_suite();

    if ((s <= 0) || (s == 1)) suite_1.run_test_suite();

    test_bench_end();
  end

endmodule
