//========================================================================
// LoadStoreUnit.v
//========================================================================
// An execute unit for performing memory operations

`ifndef HW_EXECUTE_LOADSTOREUNIT_V
`define HW_EXECUTE_LOADSTOREUNIT_V

`include "defs/UArch.v"
`include "hw/common/Fifo.v"
`include "hw/util/TraceHeader.v"
`include "intf/D__XIntf.v"
`include "intf/X__WIntf.v"
`include "intf/MemIntf.v"

import UArch::*;

module LoadStoreUnit #(
  parameter p_opaq_bits         = 8,
  parameter p_num_in_flight     = 8,
  parameter p_d_intf_fifo_depth = 1
)(
  input  logic clk,
  input  logic rst,

  //----------------------------------------------------------------------
  // D <-> X Interface
  //----------------------------------------------------------------------

  D__XIntf.X_intf D,

  //----------------------------------------------------------------------
  // X <-> W Interface
  //----------------------------------------------------------------------

  X__WIntf.X_intf W,

  //----------------------------------------------------------------------
  // Memory Interface
  //----------------------------------------------------------------------

  MemIntf.client  mem
);

  localparam p_seq_num_bits      = D.p_seq_num_bits;
  localparam p_phys_addr_bits    = D.p_phys_addr_bits;
  localparam p_stage2_fifo_depth = 2**$clog2(p_num_in_flight);

  //----------------------------------------------------------------------
  // Types
  //----------------------------------------------------------------------

  typedef struct packed {
    logic                        val;
    logic                 [31:0] pc;
    logic   [p_seq_num_bits-1:0] seq_num;
    logic                 [31:0] op1;
    logic                 [31:0] op2;
    logic                  [4:0] waddr;
    logic [p_phys_addr_bits-1:0] preg;
    logic [p_phys_addr_bits-1:0] ppreg;
    logic                 [31:0] mem_data;
    rv_uop                       uop;
  } D_input;

  typedef struct packed {
    logic                        val;
    logic                 [31:0] pc;
    logic   [p_seq_num_bits-1:0] seq_num;
    logic                  [4:0] waddr;
    logic [p_phys_addr_bits-1:0] preg;
    logic [p_phys_addr_bits-1:0] ppreg;
    rv_uop                       uop;
    logic                  [1:0] offset;
  } stage2_msg;

  //----------------------------------------------------------------------
  // Stage 1: Request — Bypass FIFO for D interface
  //----------------------------------------------------------------------

  // verilator lint_off ENUMVALUE

  D_input fifo_in;
  assign fifo_in = '{
    val:      1'b1,
    pc:       D.pc,
    seq_num:  D.seq_num,
    op1:      D.op1,
    op2:      D.op2,
    waddr:    D.waddr,
    preg:     D.preg,
    ppreg:    D.ppreg,
    mem_data: D.op3.mem_data,
    uop:      D.uop
  };

  // verilator lint_on ENUMVALUE

  logic d_fifo_full, d_fifo_empty;
  logic d_fifo_push, d_fifo_pop;

  D_input D_curr;

  Fifo #(
    .p_entry_bits ($bits(D_input)),
    .p_depth      (p_d_intf_fifo_depth)
  ) d_fifo (
    .clk   (clk),
    .rst   (rst),
    .clear (1'b0),
    .push  (d_fifo_push),
    .pop   (d_fifo_pop),
    .empty (d_fifo_empty),
    .full  (d_fifo_full),
    .wdata (fifo_in),
    .rdata (D_curr)
  );

  logic      stage2_rdy;
  logic      stage2_push, stage2_pop, stage2_empty, stage2_full;

  assign d_fifo_push = D.val & (!d_fifo_full | d_fifo_pop);
  assign d_fifo_pop  = !d_fifo_empty & mem.req_rdy & stage2_rdy;

  assign D.rdy = !d_fifo_full | d_fifo_pop;

  //----------------------------------------------------------------------
  // Memory Operations
  //----------------------------------------------------------------------

  logic [31:0] op1, op2;
  assign op1 = D_curr.op1;
  assign op2 = D_curr.op2;

  logic [31:0] addr;
  assign addr = op1 + op2;

  rv_uop uop;
  assign uop = D_curr.uop;

  always_comb begin
    case( uop )
      OP_LB:   mem.req_msg.op = MEM_MSG_READ;
      OP_LH:   mem.req_msg.op = MEM_MSG_READ;
      OP_LW:   mem.req_msg.op = MEM_MSG_READ;
      OP_LBU:  mem.req_msg.op = MEM_MSG_READ;
      OP_LHU:  mem.req_msg.op = MEM_MSG_READ;
      OP_SB:   mem.req_msg.op = MEM_MSG_WRITE;
      OP_SH:   mem.req_msg.op = MEM_MSG_WRITE;
      OP_SW:   mem.req_msg.op = MEM_MSG_WRITE;
      default: mem.req_msg.op = MEM_MSG_READ;
    endcase
  end

  logic [3:0] base_strb;

  always_comb begin
    case( uop )
      OP_LB:   base_strb = 4'b0001;
      OP_LH:   base_strb = 4'b0011;
      OP_LW:   base_strb = 4'b1111;
      OP_LBU:  base_strb = 4'b0001;
      OP_LHU:  base_strb = 4'b0011;
      OP_SB:   base_strb = 4'b0001;
      OP_SH:   base_strb = 4'b0011;
      OP_SW:   base_strb = 4'b1111;
      default: base_strb = '0;
    endcase
  end

  // Decompose address
  logic [31:0] aligned_addr;
  logic  [1:0] stage1_addr_offset;

  assign aligned_addr        = { addr[31:2], 2'b00 };
  assign stage1_addr_offset  = addr[1:0];

  assign mem.req_msg.opaque = '0;
  assign mem.req_msg.strb   = base_strb << stage1_addr_offset;
  assign mem.req_msg.addr   = aligned_addr;
  assign mem.req_val        = !d_fifo_empty & stage2_rdy && !rst;

  always_comb begin
    case( stage1_addr_offset )
      2'd0: mem.req_msg.data = D_curr.mem_data;
      2'd1: mem.req_msg.data = D_curr.mem_data << 8;
      2'd2: mem.req_msg.data = D_curr.mem_data << 16;
      2'd3: mem.req_msg.data = D_curr.mem_data << 24;
    endcase
  end

  stage2_msg stage1_output;

  assign stage1_output.val     = 1'b1;
  assign stage1_output.pc      = D_curr.pc;
  assign stage1_output.seq_num = D_curr.seq_num;
  assign stage1_output.waddr   = D_curr.waddr;
  assign stage1_output.uop     = uop;
  assign stage1_output.offset  = stage1_addr_offset;
  assign stage1_output.preg    = D_curr.preg;
  assign stage1_output.ppreg   = D_curr.ppreg;

  assign stage2_push = d_fifo_pop;

  stage2_msg stage2_input;

  Fifo #(
    .p_entry_bits ($bits(stage2_msg)),
    .p_depth      (p_stage2_fifo_depth) // Round up to power of 2 (Fifo requirement)
  ) stage2_fifo (
    .clk   (clk),
    .rst   (rst),
    .clear (1'b0),
    .push  (stage2_push),
    .pop   (stage2_pop),
    .empty (stage2_empty),
    .full  (stage2_full),
    .wdata (stage1_output),
    .rdata (stage2_input)
  );

  assign stage2_rdy = !stage2_full;

  // Bypass: when stage2_fifo is empty and a push fires, route stage1_output
  // directly into stage2_reg next cycle instead of paying the extra fifo
  // register stage. Preserves multi-in-flight: if stage2_reg is busy or a
  // second request arrives before drain, traffic flows through the fifo
  // array as before.
  stage2_msg stage2_input_eff;
  logic      stage2_bypass;
  assign stage2_bypass    = stage2_empty & stage2_push;
  assign stage2_input_eff = stage2_bypass ? stage1_output : stage2_input;

  //----------------------------------------------------------------------
  // Stage 2: Response
  //----------------------------------------------------------------------

  stage2_msg stage2_reg;
  stage2_msg stage2_reg_next;
  logic W_xfer;

  // verilator lint_off ENUMVALUE
  always_ff @( posedge clk ) begin
    if ( rst )
      stage2_reg <= '{
        val:     1'b0,
        pc:      '0,
        seq_num: '0,
        waddr:   '0,
        preg:    '0,
        ppreg:   '0,
        uop:     rv_uop'('0),
        offset:  '0
      };
    else
      stage2_reg <= stage2_reg_next;
  end

  always_comb begin
    W_xfer = W.val & W.rdy;

    if ( stage2_pop )
      stage2_reg_next = stage2_input_eff;
    else if ( W_xfer )
      stage2_reg_next = '{
        val:     1'b0,
        pc:      '0,
        seq_num: '0,
        waddr:   '0,
        preg:    '0,
        ppreg:   '0,
        uop:     rv_uop'('0),
        offset:  '0
      };
    else
      stage2_reg_next = stage2_reg;
  end
  // verilator lint_on ENUMVALUE

  //----------------------------------------------------------------------
  // Determine correct data
  //----------------------------------------------------------------------

  logic [31:0] base_data, sext_data;
  always_comb begin
    case( stage2_reg.offset )
      2'd0: base_data = mem.resp_msg.data;
      2'd1: base_data = mem.resp_msg.data >> 8;
      2'd2: base_data = mem.resp_msg.data >> 16;
      2'd3: base_data = mem.resp_msg.data >> 24;
    endcase
  end

  always_comb begin
    case( stage2_reg.uop )
      OP_LB:   sext_data = { {24{base_data[7] }}, base_data[7:0]  };
      OP_LH:   sext_data = { {16{base_data[15]}}, base_data[15:0] };
      OP_LW:   sext_data = base_data;
      OP_LBU:  sext_data = { 24'b0, base_data[7:0]  };
      OP_LHU:  sext_data = { 16'b0, base_data[15:0] };
      OP_SB:   sext_data = '0;
      OP_SH:   sext_data = '0;
      OP_SW:   sext_data = '0;
      default: sext_data = '0;
    endcase
  end

  //----------------------------------------------------------------------
  // Memory Operations
  //----------------------------------------------------------------------

  t_op                    unused_resp_op;
  logic [p_opaq_bits-1:0] unused_resp_opaque;
  logic            [31:0] unused_resp_addr;
  logic             [3:0] unused_resp_strb;

  assign unused_resp_op     = mem.resp_msg.op;
  assign unused_resp_opaque = mem.resp_msg.opaque;
  assign unused_resp_addr   = mem.resp_msg.addr;
  assign unused_resp_strb   = mem.resp_msg.strb;
  assign W.wdata            = sext_data;

  assign W.pc               = stage2_reg.pc;
  assign W.waddr            = stage2_reg.waddr;
  assign W.seq_num          = stage2_reg.seq_num;
  assign W.preg             = stage2_reg.preg;
  assign W.ppreg                  = stage2_reg.ppreg;

  always_comb begin
    case( stage2_reg.uop )
      OP_LB:   W.wen = 1'b1;
      OP_LH:   W.wen = 1'b1;
      OP_LW:   W.wen = 1'b1;
      OP_LBU:  W.wen = 1'b1;
      OP_LHU:  W.wen = 1'b1;
      OP_SB:   W.wen = 1'b0;
      OP_SH:   W.wen = 1'b0;
      OP_SW:   W.wen = 1'b0;
      default: W.wen = 1'bx;
    endcase
  end

  assign mem.resp_rdy = stage2_reg.val & W.rdy;
  assign W.val        = stage2_reg.val & mem.resp_val;
  assign stage2_pop   = ((W.rdy & mem.resp_val) | 
                          !stage2_reg.val) & 
                          (!stage2_empty | stage2_push);

  //----------------------------------------------------------------------
  // Linetracing
  //----------------------------------------------------------------------

`ifndef SYNTHESIS
  function int ceil_div_4( int val );
    return (val / 4) + ((val % 4) > 0 ? 1 : 0);
  endfunction

  // Plain-net mirrors of interface signals read by trace(). See ALU for
  // rationale (VCS sensitivity workaround).
  logic         w_val_mir;
  logic         w_rdy_mir;
  logic         stage2_val_mir;
  logic         d_fifo_empty_mir;
  logic         d_fifo_pop_mir;
  assign w_val_mir         = W.val;
  assign w_rdy_mir         = W.rdy;
  assign stage2_val_mir    = stage2_reg.val;
  assign d_fifo_empty_mir  = d_fifo_empty;
  assign d_fifo_pop_mir    = d_fifo_pop;

  function int req_lane_w(
    // verilator lint_off UNUSEDSIGNAL
    int trace_level
    // verilator lint_on UNUSEDSIGNAL
  );
    int data_w;
    int hdr_w;
    data_w     = ceil_div_4( p_seq_num_bits ); // max(seq, "#") -- "#"==3 covered by hdr_w
    hdr_w      = 2; // "LQ" / "#"
    req_lane_w = (hdr_w > data_w) ? hdr_w : data_w;
  endfunction

  function int resp_lane_w(
    // verilator lint_off UNUSEDSIGNAL
    int trace_level
    // verilator lint_on UNUSEDSIGNAL
  );
    int data_w;
    int hdr_w;
    data_w      = ceil_div_4( p_seq_num_bits ); // max(seq, "#") -- "#"==3 covered by hdr_w
    hdr_w       = 2; // "LS" / "#"
    resp_lane_w = (hdr_w > data_w) ? hdr_w : data_w;
  endfunction

  function string trace(
    // verilator lint_off UNUSEDSIGNAL
    int trace_level
    // verilator lint_on UNUSEDSIGNAL
  );
    int    rqw;
    int    rsw;
    int    n;
    string body;
    string pad;
    rqw = req_lane_w( trace_level );
    rsw = resp_lane_w( trace_level );

    if( !d_fifo_empty_mir ) begin
      if( !d_fifo_pop_mir )
        body = "#";
      else
        body = $sformatf("%h", D_curr.seq_num);
    end else begin
      body = "";
    end
    pad = "";
    for( n = body.len(); n < rqw; n = n + 1 )
      pad = {pad, " "};
    trace = {body, pad, ">"};

    if( stage2_val_mir ) begin
      if( !(w_val_mir & w_rdy_mir) )
        body = "#";
      else
        body = $sformatf("%h", stage2_reg.seq_num);
    end else begin
      body = "";
    end
    pad = "";
    for( n = body.len(); n < rsw; n = n + 1 )
      pad = {pad, " "};
    trace = {trace, body, pad};
  endfunction

  `TRACE_HEADER_PAD_FN

  function string trace_header( int trace_level );
    trace_header = {th_pad( "MP", req_lane_w( trace_level ) ),
                    ">",
                    th_pad( "MQ", resp_lane_w( trace_level ) )};
  endfunction

  string tr, th;
  always_comb begin
    tr = trace(0);
    th = trace_header(0);
  end
`endif

endmodule

`endif // HW_EXECUTE_LOADSTOREUNIT_V
