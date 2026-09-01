//========================================================================
// SSInstRouter_test.v
//========================================================================
// A testbench for the SSInstRouter data mux.
//
// SSInstRouter is a pure combinational mux -- given a
// route_idx/lane_to_pipe_map already computed elsewhere (by
// SSInstMapper; see SSInstMapper_test.v), it just wires data through.
// This test checks that it muxes the right message to the right pipe,
// and correctly gates iq_ins_try/dispatch_go on
// chk_pass/iq_val/iq_rdy.

`include "hw/decode_issue/SSInstRouter.v"
`include "test/TestUtils.v"

import TestEnv::*;

//========================================================================
// SSInstRouterTestSuite
//========================================================================

module SSInstRouterTestSuite #(
  parameter p_suite_num        = 0,
  parameter p_num_pipes        = 4,
  parameter p_num_input_lanes  = 4,
  parameter p_input_lanes_bits = p_num_input_lanes > 1 ? $clog2(p_num_input_lanes) : 1,
  parameter p_pipe_bits        = p_num_pipes > 1 ? $clog2(p_num_pipes) : 1
);

  string suite_name = $sformatf("%0d: SSInstRouterTestSuite_%0d_%0d",
                                p_suite_num, p_num_pipes, p_num_input_lanes);

  //----------------------------------------------------------------------
  // Setup
  //----------------------------------------------------------------------

  logic clk, rst;
  TestUtils t( .* );

  //----------------------------------------------------------------------
  // Instantiate design under test
  //----------------------------------------------------------------------
  // A tag field lets checks confirm the right lane's message actually
  // reached the right pipe, not just that some message did.

  typedef struct packed {
    logic [3:0] tag;
  } t_msg;

  t_msg dut_in_msg   [p_num_input_lanes];
  logic dut_chk_pass [p_num_input_lanes];
  logic dut_iq_rdy   [p_num_pipes];

  logic [p_input_lanes_bits-1:0] dut_route_idx        [p_num_pipes];
  logic                          dut_iq_val           [p_num_pipes];
  logic [p_pipe_bits-1:0]        dut_lane_to_pipe_map [p_num_input_lanes];

  t_msg dut_iq_msg      [p_num_pipes];
  logic dut_iq_ins_try  [p_num_pipes];
  logic dut_dispatch_go [p_num_input_lanes];

  SSInstRouter #(
    .t_msg             (t_msg),
    .p_num_pipes       (p_num_pipes),
    .p_num_input_lanes (p_num_input_lanes)
  ) dut (
    .in_msg           (dut_in_msg),
    .chk_pass         (dut_chk_pass),
    .iq_rdy           (dut_iq_rdy),
    .route_idx        (dut_route_idx),
    .iq_val           (dut_iq_val),
    .lane_to_pipe_map (dut_lane_to_pipe_map),
    .iq_msg           (dut_iq_msg),
    .iq_ins_try       (dut_iq_ins_try),
    .dispatch_go      (dut_dispatch_go)
  );

  //----------------------------------------------------------------------
  // Helper tasks
  //----------------------------------------------------------------------

  // Sets up a 1:1 route (pipe i <- lane i, lane i -> pipe i), which is
  // all that matters for exercising the mux -- the actual matching
  // policy is SSInstMapper's job, not this module's.
  task set_identity_route();
    for (int i = 0; i < p_num_input_lanes; i++)
      dut_in_msg[i].tag = 4'(i);
    for (int i = 0; i < p_num_pipes; i++)
      dut_route_idx[i] = p_input_lanes_bits'(i % p_num_input_lanes);
    for (int i = 0; i < p_num_input_lanes; i++)
      dut_lane_to_pipe_map[i] = p_pipe_bits'(i % p_num_pipes);
  endtask

  task check(
    input logic exp_iq_val      [p_num_pipes],
    input logic exp_iq_ins_try  [p_num_pipes],
    input logic exp_dispatch_go [p_num_input_lanes]
  );
    #1; // Let combinational logic settle
    for (int i = 0; i < p_num_pipes; i++) begin
      `CHECK_EQ(dut_iq_ins_try[i], exp_iq_ins_try[i]);
      if (exp_iq_val[i]) begin
        `CHECK_EQ(dut_iq_msg[i].tag, dut_in_msg[dut_route_idx[i]].tag);
      end
    end
    for (int i = 0; i < p_num_input_lanes; i++) begin
      `CHECK_EQ(dut_dispatch_go[i], exp_dispatch_go[i]);
    end
  endtask

  //----------------------------------------------------------------------
  // test_case_mux
  //----------------------------------------------------------------------
  // The routed message at each pipe is the input message from whatever
  // lane route_idx points at, regardless of chk_pass/iq_val/iq_rdy.

  task test_case_mux();
    t.test_case_begin( "test_case_mux" );
    if( !t.run_test ) return;

    set_identity_route();
    for (int i = 0; i < p_num_input_lanes; i++) dut_chk_pass[i] = 1'b1;
    for (int i = 0; i < p_num_pipes; i++)       dut_iq_rdy[i]   = 1'b1;
    for (int i = 0; i < p_num_pipes; i++)       dut_iq_val[i]   = 1'b1;

    #1;
    for (int i = 0; i < p_num_pipes; i++) begin
      `CHECK_EQ(dut_iq_msg[i].tag, dut_in_msg[dut_route_idx[i]].tag);
    end

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_ins_try_gating
  //----------------------------------------------------------------------
  // iq_ins_try[pipe] = chk_pass[routed lane] & iq_val[pipe]

  task test_case_ins_try_gating();
    logic exp_iq_val      [p_num_pipes];
    logic exp_iq_ins_try  [p_num_pipes];
    logic exp_dispatch_go [p_num_input_lanes];

    t.test_case_begin( "test_case_ins_try_gating" );
    if( !t.run_test ) return;

    set_identity_route();
    for (int i = 0; i < p_num_input_lanes; i++) dut_chk_pass[i] = 1'b1;
    for (int i = 0; i < p_num_pipes; i++)       dut_iq_rdy[i]   = 1'b1;

    // iq_val low on pipe 0 blocks its iq_ins_try even though chk_pass
    // is high on the lane it's routed from.
    for (int i = 0; i < p_num_pipes; i++)
      dut_iq_val[i] = (i != 0);

    for (int i = 0; i < p_num_pipes; i++)       exp_iq_val[i]      = (i != 0);
    for (int i = 0; i < p_num_pipes; i++)       exp_iq_ins_try[i]  = (i != 0);
    for (int i = 0; i < p_num_input_lanes; i++) exp_dispatch_go[i] = 1'b1;
    check( exp_iq_val, exp_iq_ins_try, exp_dispatch_go );

    // chk_pass low on lane 0 blocks iq_ins_try on whichever pipe it's
    // routed to (pipe 0, under the identity route).
    for (int i = 0; i < p_num_pipes; i++) dut_iq_val[i] = 1'b1;
    for (int i = 0; i < p_num_input_lanes; i++)
      dut_chk_pass[i] = (i != 0);

    for (int i = 0; i < p_num_pipes; i++)       exp_iq_val[i]      = 1'b1;
    for (int i = 0; i < p_num_pipes; i++)       exp_iq_ins_try[i]  = (i != 0);
    for (int i = 0; i < p_num_input_lanes; i++) exp_dispatch_go[i] = (i != 0);
    check( exp_iq_val, exp_iq_ins_try, exp_dispatch_go );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // test_case_dispatch_go_gating
  //----------------------------------------------------------------------
  // dispatch_go[lane] = chk_pass[lane] & iq_rdy[lane's matched pipe]

  task test_case_dispatch_go_gating();
    logic exp_iq_val      [p_num_pipes];
    logic exp_iq_ins_try  [p_num_pipes];
    logic exp_dispatch_go [p_num_input_lanes];

    t.test_case_begin( "test_case_dispatch_go_gating" );
    if( !t.run_test ) return;

    set_identity_route();
    for (int i = 0; i < p_num_input_lanes; i++) dut_chk_pass[i] = 1'b1;
    for (int i = 0; i < p_num_pipes; i++)       dut_iq_val[i]   = 1'b1;

    // iq_rdy low on pipe 0 blocks dispatch_go on whichever lane maps to
    // it (lane 0, under the identity map).
    for (int i = 0; i < p_num_pipes; i++)
      dut_iq_rdy[i] = (i != 0);

    for (int i = 0; i < p_num_pipes; i++)       exp_iq_val[i]      = 1'b1;
    for (int i = 0; i < p_num_pipes; i++)       exp_iq_ins_try[i]  = 1'b1;
    for (int i = 0; i < p_num_input_lanes; i++) exp_dispatch_go[i] = (i != 0);
    check( exp_iq_val, exp_iq_ins_try, exp_dispatch_go );

    t.test_case_end();
  endtask

  //----------------------------------------------------------------------
  // run_test_suite
  //----------------------------------------------------------------------

  task run_test_suite();
    t.test_suite_begin( suite_name );

    test_case_mux();
    test_case_ins_try_gating();
    test_case_dispatch_go_gating();
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
// SSInstRouter_test
//========================================================================

module SSInstRouter_test;

  SSInstRouterTestSuite suite_1();

  int s;

  initial begin
    test_bench_begin( `__FILE__ );
    s = get_test_suite();

    if ((s <= 0) || (s == 1)) suite_1.run_test_suite();

    test_bench_end();
  end

endmodule
