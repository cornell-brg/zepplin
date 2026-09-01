Further Work
==========================================================================

Zeppelin has reached the point of running the full RV32IM ISA in a
parameterizable superscalar configuration with optional out-of-order issue
queues, but several known limitations remain. The items below capture the
main avenues for future work; the project report goes into more detail on
the motivation and tradeoff for each.

Fetch Block Alignment Requirement Removal
--------------------------------------------------------------------------

All instructions in a fetch block currently travel together through both
the fetch unit and the decode-issue unit. When some lanes can dispatch
while others cannot (e.g. a structural hazard on the iSLIP crossbar),
the dispatching lanes are marked ``DISPATCHED`` in the DIUFifo head and
the block remains parked until every lane has dispatched or been
invalidated. The "dead" slots that result are wasted decode-issue
bandwidth. A more advanced version would let the DIU pull in fresh
instructions from the fetch unit to refill those slots so that decode
issue can continue doing useful work without waiting for the slowest
lane in the current block. This is a substantial change because it
breaks the invariant that each fetch block has a single source PC and
contiguous sequence numbers.

Single-Cycle Branch Resolution Latency Requirement Removal
--------------------------------------------------------------------------

The control-flow execute pipe is forced into bypass-mode (its issue queue
is purely combinational) so that branches resolve in the cycle after
decode. This single-cycle latency requirement is what guarantees that no
speculatively-fetched instructions can move past the DIU before the
redirect arrives, which in turn means no XU or the WCU itself has to
listen for squashes.

The downside is that the control-flow pipe can never benefit from an issue
queue, and any younger instruction in the same fetch block as an
unresolved BRX is blocked at the DIU until the BRX dispatches. Removing
this requirement would require:

 - The XUs and the WCU all listening to ``ControlFlowNotif`` and squashing
   anything younger than the redirecting instruction
 - The memory XU keeping enough per-request state to drop squashed
   in-flight loads/stores (likely an LSQ in an out-of-order design)
 - Either a control-flow issue queue that can hold partial state, or a
   centralized issue queue (see "True Out-of-Order Issue" below)

In-Order Loads and Stores Requirement Removal
--------------------------------------------------------------------------

The load-store execute unit does not contain a load-store queue, so memory
ordering is enforced by forcing the memory pipe's issue queue to the
in-order variant. Adding a proper LSQ to the LSU would let memory
operations participate in out-of-order issue and would also be the natural
place to handle squashes of in-flight memory requests once the single-cycle
branch resolution requirement is lifted.

Support for True Out-of-Order Issue
--------------------------------------------------------------------------

Out-of-order issue queues exist (``IssueQueueOOO``) and demonstrably win
on synthetic benchmarks like the ``oooiq-demo``, but the per-pipe layout
limits how often reordering actually happens in real programs. Because
instructions are routed to a specific pipe's queue *before* their source
operands are known to be ready, one queue can fill up while another
identical pipe's queue is idle. To get true out-of-order issue out of the
hardware, the DIU likely needs to switch to a centralized issue queue
that is enqueued before pipe mapping and dispatches on dequeue. That
requires a more intelligent scheduler that can pull non-consecutive
ready instructions, and likely better compiler support so independent
instructions land close enough together to benefit.

Privileged ISA Support
--------------------------------------------------------------------------

The current ISA is RV32IM (no exceptions, no privilege modes). For
operating-system-style workloads, the privileged RISC-V ISA would need
to be implemented along with the CSRs and their semantics. A useful
target would be the CSRs needed to run
`EGOS-2000 <https://github.com/yhzhang0128/egos-2000>`_: at minimum
``mtvec``, ``mepc``, ``mcause``, ``mstatus``, ``mhartid``,
``mvendorid``, ``mscratch``, ``mip``, ``mie``, ``mtime``, ``mtimecmp``.

This work is tightly coupled to the squashing changes above, since
exceptions in the WCU break the "speculation never escapes the DIU"
invariant in the same way that multi-cycle branch resolution would.

Formal Verification
--------------------------------------------------------------------------

Zeppelin is verified through extensive unit and integration testing,
including ELF-based golden-reference checks against the FL processor and
randomized RISC-V instruction tests driven by
`riscv-dv <https://github.com/chipsalliance/riscv-dv>`_. The next step
in verification rigor would be replacing (or augmenting) the
``InstTraceNotif`` with the
`RVFI interface <https://github.com/SymbioticEDA/riscv-formal/blob/master/docs/rvfi.md>`_
so the design can be formally checked against the RISC-V formal model.

Sequence Number Generator Simplification
--------------------------------------------------------------------------

``SeqNumGen`` currently tracks in-flight sequence numbers with a bitmap
(``seq_num_list``) so that numbers can be freed in any order. In practice
numbers are freed on commit, which is in order with respect to the
sequence-number space, so a head/tail-pointer-based FIFO would suffice
and would scale as :math:`\log(N)` instead of :math:`N` for the number
of sequence numbers. The bitmap is a holdover from when the exact
semantics of sequence numbers were still being worked out and is worth
replacing.
