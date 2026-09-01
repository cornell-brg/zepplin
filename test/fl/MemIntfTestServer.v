//========================================================================
// MemIntfTestServer.v
//========================================================================
// A FL model of a memory server, to use in testing

`include "fl/fl_peripherals.v"
`include "hw/util/DelayStream.v"
`include "hw/util/TraceHeader.v"
`include "intf/MemIntf.v"
`include "types/MemMsg.v"

`ifndef TEST_FL_MEM_INTF_TEST_SERVER_V
`define TEST_FL_MEM_INTF_TEST_SERVER_V

module MemIntfTestServer #(
  parameter type t_req_msg  = logic,
  parameter type t_resp_msg = logic,
  parameter p_opaq_bits     = 8,
  parameter p_num_words     = 1,

  parameter p_send_intv_delay = 1,
  parameter p_recv_intv_delay = 1
)(
  input  logic clk,
  input  logic rst,
  
  
  MemIntf.server dut
);

  //----------------------------------------------------------------------
  // Store memory values in association array
  //----------------------------------------------------------------------

  logic [31:0] mem [logic [31:0]];

  always @( posedge clk ) begin
    if( rst )
      mem.delete();
  end

  // A function, not a task -- the body never consumes simulation time,
  // and it's called from Zeppelin_sim.v's init_mem, which is itself a
  // function (export "DPI-C" requires it).
  function void init_mem(
    input logic [31:0] addr,
    input logic [31:0] data
  );
    mem[addr] = data;
  endfunction

  //----------------------------------------------------------------------
  // Keep track of cycles since reset
  //----------------------------------------------------------------------

  localparam CYCLE_COUNT_ADDR = 32'hFFFFFF00;
  localparam INST_COUNT_ADDR  = 32'hFFFFFF04;

  logic [31:0] cycle_count;
  logic [31:0] inst_count;

`ifdef VTB_DUMP_SAIF
  logic saif_started = 0;
`endif

  always_ff @( posedge clk ) begin
    if( rst )
      cycle_count <= '0;
    else
      cycle_count <= cycle_count + 1;
  end

  function void notify_commit( int num_insts );
    inst_count = inst_count + num_insts;
  endfunction

  always @( posedge clk ) begin
    if( rst )
      inst_count = '0;
  end

  //----------------------------------------------------------------------
  // Have queues for sending and receiving memory messages
  //----------------------------------------------------------------------

  // verilator lint_off PINCONNECTEMPTY
  
  DelayStream #(
    .t_msg             (t_req_msg),
    .p_send_intv_delay (p_send_intv_delay)
  ) req_queue (
    .clk      (clk),
    .rst      (rst),

    .send_val (dut.req_val),
    .send_rdy (dut.req_rdy),
    .send_msg (dut.req_msg),

    .recv_val (),
    .recv_rdy (1'b0),
    .recv_msg ()
  );

  DelayStream #(
    .t_msg             (t_resp_msg),
    .p_recv_intv_delay (p_recv_intv_delay)
  ) resp_queue (
    .clk      (clk),
    .rst      (rst),

    .send_val (1'b0),
    .send_rdy (),
    .send_msg ('0),

    .recv_val (dut.resp_val),
    .recv_rdy (dut.resp_rdy),
    .recv_msg (dut.resp_msg)
  );

  // verilator lint_on PINCONNECTEMPTY

  //----------------------------------------------------------------------
  // Handle transactions
  //----------------------------------------------------------------------

  t_req_msg    curr_req;
  t_resp_msg   curr_resp;
  logic [31:0] _temp_write_data;

  initial begin
    foreach ( mem[addr] )
      mem[addr] = '0;
  end

  // verilator lint_off BLKSEQ
  always @( posedge clk ) begin
    if( req_queue.num_msgs() > 0 ) begin
      curr_req = req_queue.dequeue();

      // Execute the transaction
      case( curr_req.op )
        MEM_MSG_READ: begin
          for( int w = 0; w < p_num_words; w++ ) begin
            if( try_fl_read(curr_req.addr + (w << 2), _temp_write_data) )
              curr_resp.data[w*32 +: 32] = _temp_write_data;
            else if( (curr_req.addr + (w << 2)) == CYCLE_COUNT_ADDR ) begin
              curr_resp.data[w*32 +: 32] = cycle_count;
`ifdef VTB_DUMP_SAIF
              if( !saif_started ) begin
                $toggle_start;
                $display("[%0t] SAIF toggling enabled", $time);
                saif_started = 1;
              end else begin
                $toggle_stop;
                $display("[%0t] SAIF toggling disabled", $time);
                saif_started = 0;
              end
`endif
            end
            else if( (curr_req.addr + (w << 2)) == INST_COUNT_ADDR )
              curr_resp.data[w*32 +: 32] = inst_count;
            else if( mem.exists( curr_req.addr + (w << 2) ) == 1 )
              curr_resp.data[w*32 +: 32] = mem[curr_req.addr + (w << 2)];
            else
              curr_resp.data[w*32 +: 32] = '0;
          end
          curr_resp.strb  = curr_req.strb;
        end
        MEM_MSG_WRITE: begin
          for( int i = 0; i < p_num_words; i++ ) begin
            if( mem.exists( curr_req.addr + (i << 2) ) == 1 )
              _temp_write_data = mem[curr_req.addr + (i << 2)];
            else
              _temp_write_data = '0;
            if( ( curr_req.strb[i*4 +: 4] & 4'b0001 ) > 0 )
              _temp_write_data[7:0] = curr_req.data[i*32 +: 8];
            if( ( curr_req.strb[i*4 +: 4] & 4'b0010 ) > 0 )
              _temp_write_data[15:8] = curr_req.data[i*32+8 +: 8];
            if( ( curr_req.strb[i*4 +: 4] & 4'b0100 ) > 0 )
              _temp_write_data[23:16] = curr_req.data[i*32+16 +: 8];
            if( ( curr_req.strb[i*4 +: 4] & 4'b1000 ) > 0 )
              _temp_write_data[31:24] = curr_req.data[i*32+24 +: 8];
            if( curr_req.strb[i*4 +: 4] == 4'b1111 ) begin
              if( try_fl_write(curr_req.addr + (i << 2), _temp_write_data) ) begin
                if( fl_exit_requested() ) $finish;
              end else
                mem[curr_req.addr + (i << 2)] = _temp_write_data;
            end else begin
              mem[curr_req.addr + (i << 2)] = _temp_write_data;
            end
          end

          curr_resp.data = '0;
          curr_resp.strb  = curr_req.strb;
        end
      endcase

      curr_resp.op     = curr_req.op;
      curr_resp.addr   = curr_req.addr;
      curr_resp.opaque = curr_req.opaque;

      // Store the result to be sent back
      resp_queue.enqueue( curr_resp );
    end
  end
  // verilator lint_on BLKSEQ

  //----------------------------------------------------------------------
  // Linetracing
  //----------------------------------------------------------------------

  function int ceil_div_4( int val );
    return (val / 4) + ((val % 4) > 0 ? 1 : 0);
  endfunction

  `TRACE_HEADER_PAD_FN

  function string trace_header( int trace_level );
    int str_len;
    int side_w;
    str_len = 2 + 1 +
              ceil_div_4(p_opaq_bits) + 1 +
              8                       + 1 +
              ceil_div_4(p_num_words * 32);
    side_w = (trace_level > 0) ? str_len : 2;
    trace_header = {th_pad("RQ", side_w), " > ", th_pad("RS", side_w)};
  endfunction

  function string trace(int trace_level);
    string req_linetrace, resp_linetrace;
    int str_len;

    str_len = 2 + 1 +                       // op
              ceil_div_4(p_opaq_bits) + 1 + // opaque
              8                       + 1 + // addr
              ceil_div_4(p_num_words * 32); // data

    if( dut.req_val & dut.req_rdy ) begin
      case( dut.req_msg.op )
        MEM_MSG_READ:  req_linetrace = "rd";
        MEM_MSG_WRITE: req_linetrace = "wr";
        default:       req_linetrace = "??";
      endcase

      if( trace_level > 0 ) begin
        req_linetrace = {req_linetrace, ":", $sformatf("%h:%h:%h", 
                         dut.req_msg.opaque, dut.req_msg.addr,
                         dut.req_msg.data)};
      end
    end else begin
      if( trace_level > 0 )
        req_linetrace = {str_len{" "}};
      else
        req_linetrace = {2{" "}};
    end

    if( dut.resp_val & dut.resp_rdy ) begin
      case( dut.resp_msg.op )
        MEM_MSG_READ:  resp_linetrace = "rd";
        MEM_MSG_WRITE: resp_linetrace = "wr";
        default:       resp_linetrace = "??";
      endcase

      if( trace_level > 0 ) begin
        resp_linetrace = {resp_linetrace, ":", $sformatf("%h:%h:%h", 
                         dut.resp_msg.opaque, dut.resp_msg.addr,
                         dut.resp_msg.data)};
      end
    end else begin
      if( trace_level > 0 )
        resp_linetrace = {str_len{" "}};
      else
        resp_linetrace = {2{" "}};
    end

    trace = $sformatf("%s > %s", req_linetrace, resp_linetrace);
  endfunction
endmodule

`endif // TEST_FL_MEM_INTF_TEST_SERVER_V
