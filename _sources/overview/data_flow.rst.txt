Data Flow in the Processor
==========================================================================

.. raw:: html

    <style> .zeppelin-blue {color:#2094F3; font-weight:bold; font-size:16px} </style>
    <style> .zeppelin-green {color:#97D077; font-weight:bold; font-size:16px} </style>

.. role:: zeppelin-blue

.. role:: zeppelin-green

Zeppelin is composed of several units connected by a small set of standardized
SystemVerilog interfaces. There are two classes of interface:

 - **Latency-Insensitive** interfaces carry information forward through the
   pipeline. They include both ``val`` and ``rdy`` signals, so a downstream
   unit can back-pressure its producer when it isn't ready to accept new
   data. Because the protocol is symmetric, latency-insensitive interfaces
   only flow forward (never from a later unit back to an earlier one),
   which avoids combinational deadlocks. Instructions follow these paths
   throughout their lifetime as they move between units. In Zeppelin's
   diagrams they appear as :zeppelin-blue:`blue arrows`, with bidirectional
   arrow heads indicating the ``val/rdy`` control flow.

 - **Latency-Sensitive** interfaces (also called **notifications**) carry
   information that may flow in any direction, including backward through
   the pipeline. They have only a ``val`` signal -- no ``rdy``, no
   back-pressure -- which is what makes them safe to wire backward without
   risking a combinational loop. Notifications are used for signals that
   must be acted on the same cycle they fire, such as writebacks, commits,
   and control-flow redirects. In Zeppelin's diagrams they appear as
   :zeppelin-green:`green arrows`, with unidirectional arrow heads
   indicating the one-way signal flow.

Latency-Insensitive Interfaces
--------------------------------------------------------------------------

Latency-insensitive interfaces are named ``<src>__<dest>Intf`` to indicate
which units they connect:

 - ``F__DIntf``: ``p_num_fe_lanes`` parallel interfaces from the fetch unit
   to the decode-issue unit, carrying the raw 32-bit instruction word, PC,
   sequence number, per-lane ``inst_status``, and (when branch prediction
   is enabled) a ``predicted_taken`` flag
 - ``D__XIntf``: ``p_num_pipes`` parallel interfaces from the decode-issue
   unit to the execute units, carrying the decoded micro-op, two source
   operand values, the destination physical register, the previous mapping
   of that architectural register, the immediate / third operand, the PC,
   sequence number, and prediction flag
 - ``X__WIntf``: ``p_num_pipes`` parallel interfaces from each execute unit
   to the writeback-commit unit, carrying the write data and address, the
   write-enable, the physical register specifiers, the PC, and sequence
   number
 - ``MemIntf``: the memory request/response interface used for the
   instruction memory (driven by the fetch unit) and the data memory
   (driven by the load-store execute unit). Reads are signaled by
   ``strb = 0``; sub-word stores are issued as word-aligned writes with
   the appropriate byte strobes; all transactions are tagged with an
   ``opaque`` field

All latency-insensitive interfaces in the toplevel pass through optional
simulation-only delay stages (``F__DDelay``, ``D__XDelay``, ``X__WDelay``)
that can inject periodic back-pressure, useful for stressing the
interfaces during unit testing.

Notifications
--------------------------------------------------------------------------

Notifications don't require a single source and/or destination, and are
therefore named according to their semantics. Zeppelin uses the following
notifications:

 - **Complete** notifications (``CompleteNotif``) communicate when an
   execute unit's result is selected by the WCU's arbiter and written
   into the register file. The WCU drives ``p_num_be_lanes`` instances
   of this notification to the DIU so that dependent instructions in
   the issue queues can be marked ready as early as possible -- before
   the completing instruction has even drained through the WCU's
   internal decoupling FIFO.

 - **Commit** notifications (``CommitNotif``) communicate when an
   instruction retires in program order. The WCU drives
   ``p_num_be_lanes`` of them to both the DIU (to free the previous
   physical register mapping and update the architectural state) and
   the fetch unit (to release the sequence number for reuse, advance
   the age tracker, and reclaim BTB entries on resolved branches).

 - **Control-flow** notifications (``ControlFlowNotif``) communicate
   redirects that must invalidate younger in-flight instructions. They
   can originate at either the DIU (for JAL/JALR) or the control-flow
   execute unit (for resolved conditional branches), and they carry the
   redirecting instruction's sequence number, source PC, target, taken
   bit, and a ``bp_update_val`` for the branch predictor. Because two
   different sources can fire in the same cycle, the **Control Flow
   Unit** (CFU) arbitrates between them using ``SSSeqAge`` and forwards
   the older redirect to the fetch unit and back to the DIU.

 - **Instruction trace** notifications (``InstTraceNotif``) drive
   external verification logic. They carry the same fields as
   ``CommitNotif`` and are used by the integration tests to compare
   committed instructions against the FL processor's golden reference.

 - **Instruction check** notifications (``InstCheckIntf``) thread the
   four cascaded ``InstCheck`` stages in the DIU; each stage takes a
   ``pass`` from its predecessor, performs its own check, and produces
   ``pass`` and ``invalidate`` outputs for the next stage.
