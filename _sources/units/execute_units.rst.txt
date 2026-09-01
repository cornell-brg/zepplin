Execute Units (XU)
==========================================================================

Execute units sit between the decode-issue unit and the writeback-commit
unit, connected via the ``D__XIntf`` (input) and ``X__WIntf`` (output)
interfaces. Each execute unit receives decoded instructions with resolved
operands from an issue queue, performs its computation, and drives the
result to the writeback stage. Execute units are specialized by function:
arithmetic/logic, control flow, memory, and multiply/divide/remainder.

Most execute units include a small input bypass FIFO at the ``D__XIntf``
input (parameterized by ``p_d_intf_fifo_depth``) that decouples the issue
queue from the execute datapath. The FIFO pops when the downstream
``X__WIntf`` is ready and pushes when a valid instruction arrives from the
issue queue. Each unit also carries physical register specifiers (``preg``,
``ppreg``) through the pipeline for the writeback-commit unit to use during
commit and free-list reclamation.

.. _xu-alu:

Arithmetic/Logic Unit: ALU
--------------------------------------------------------------------------

The ALU is a single-cycle combinational execute unit that handles all
integer arithmetic and logic operations: ``ADD``, ``SUB``, ``AND``,
``OR``, ``XOR``, ``SLT``, ``SLTU``, ``SRA``, ``SRL``, ``SLL``, ``LUI``,
and ``AUIPC``. The input bypass FIFO buffers instructions from the issue
queue; on each cycle that the FIFO is non-empty and the writeback
interface is ready, the head instruction's operands are fed into a
combinational case-select that produces the result. ``AUIPC`` adds the PC
to the immediate; ``LUI`` passes the immediate directly. The write-enable
(``wen``) is always asserted since all ALU instructions write a
destination register.

Zeppelin instantiates ``p_num_alus`` copies of the ALU in parallel; each
gets its own pipe slot in the decode-issue crossbar and its own
``D__XIntf``/``X__WIntf``.

.. _xu-ctrl:

Control Flow Execute Unit: ControlFlowUnit
--------------------------------------------------------------------------

The control-flow execute unit resolves conditional branch instructions
(``BEQ``, ``BNE``, ``BLT``, ``BGE``, ``BLTU``, ``BGEU``) and publishes
redirect notifications via the ``ControlFlowNotif`` interface. JAL and
JALR are handled in the decode-issue unit (by the ``DIUCtrlFlowPublisher``),
so they never reach this unit.

The unit includes a bypass FIFO at the ``D__XIntf`` input and full support
for branch prediction. It evaluates the branch condition by comparing
``op1`` and ``op2``, then uses the ``predicted_taken`` field (propagated
from the fetch unit through the issue queue) to detect mispredictions. A
redirect is published only when the actual outcome differs from the
prediction (``should_branch != predicted_taken``). The unit also asserts
``bp_update_val`` on every conditional branch (regardless of whether it
mispredicted) so that the branch predictor can update its state. The
``taken`` signal carries the actual branch direction, and ``target``
carries ``PC + imm`` (the branch destination); the redirect consumer uses
``taken`` to determine whether to redirect to the target or the
fall-through address.

The control-flow pipe is always configured in bypass-mode at the issue
queue stage (the issue queue is purely combinational), so a branch
resolves on the cycle after decode. This single-cycle latency is what
guarantees no speculatively-fetched instructions can get past the DIU
before the redirect arrives, simplifying the rest of the pipeline (no
XU/WCU squashing required).

.. _xu-lsu:

Load-Store Unit: LoadStoreUnit
--------------------------------------------------------------------------

The load-store unit (``LoadStoreUnit``) is a two-stage pipelined execute
unit that handles all memory operations (``LB``, ``LH``, ``LW``, ``LBU``,
``LHU``, ``SB``, ``SH``, ``SW``) via the ``MemIntf`` interface.

**Stage 1 (Request):** The input bypass FIFO holds decoded memory
instructions. When the head instruction is valid, the memory interface is
ready, and the stage-2 FIFO has space, the unit computes the effective
address (``op1 + op2``), word-aligns it, and issues the memory request.
For sub-word operations, the byte offset within the word is used to shift
the store data and compute the appropriate byte strobe mask (``strb``).
The byte offset and instruction metadata (sequence number, write address,
micro-op, physical registers) are pushed into a stage-2 FIFO to accompany
the memory response when it returns.

**Stage 2 (Response):** A ``stage2_fifo`` (depth rounded to the next
power of 2 from ``p_num_in_flight``) buffers the metadata for all
in-flight requests. A stage-2 register holds the metadata for the
currently-awaited response. When the memory response arrives, the unit
uses the stored byte offset to extract and shift the correct bytes from
the response data, then applies sign- or zero-extension based on the
micro-op (sign-extend for LB/LH, zero-extend for LBU/LHU, full word for
LW). Store operations drive ``wen = 0`` since they do not write a
destination register.

The stage-2 FIFO supports a bypass path: when the FIFO is empty and a
push fires simultaneously, the metadata is routed directly into the
stage-2 register on the next cycle, avoiding the extra latency of writing
to and reading from the FIFO array. This preserves low latency for the
common single-in-flight case while still supporting multiple outstanding
requests via the FIFO when traffic backs up.

Because there is no load-store queue in this unit, the memory pipe's
issue queue is forced to the in-order variant so that memory ordering is
preserved at issue.

.. _xu-muldivrem:

Multiply/Divide/Remainder Units
--------------------------------------------------------------------------

The RV32M extension operations (``MUL``, ``MULH``, ``MULHSU``, ``MULHU``,
``DIV``, ``DIVU``, ``REM``, ``REMU``) are handled by one of three
interchangeable units, all sharing the same ``D__XIntf``/``X__WIntf``
interface. Which variant is instantiated is selected by the toplevel
``p_muldivrem_sel`` parameter, and ``p_num_muls`` copies are instantiated
in parallel.

IterativeMulDivRem (``p_muldivrem_sel = 0``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The fully iterative unit uses a multi-cycle state machine with five
states: ``IDLE``, ``SWAP_SIGN``, ``CALC``, ``RESTORE_SIGN``, and
``DONE``. On each ``CALC`` cycle, the ``IterativeMulDivRemStep`` submodule
advances the computation by one iteration:

- **Multiplication:** Shift-and-add algorithm. ``a`` shifts left, ``b``
  shifts right; when the LSB of ``b`` is set, ``a`` is accumulated into
  the result. Completes when ``b`` reaches zero.

- **Division/Remainder:** Restoring division. On each step, if
  ``|a| >= b`` the divisor is subtracted and the quotient bit is
  accumulated. The ``b_shift`` register tracks the current quotient bit
  position, shifting right each cycle until zero. For remainder, the
  result is simply the final value of ``a``.

Signed operations use a ``SWAP_SIGN`` state to negate ``op2`` when it is
negative (for DIV/REM), and a ``RESTORE_SIGN`` state to correct the
result sign afterward. The unit handles divide-by-zero (returns
all-ones for DIV/DIVU, dividend for REM/REMU) and signed overflow
(``-2^31 / -1``) as special cases. The ``D.rdy`` signal deasserts while
the computation is in progress, stalling the issue queue.

SingleCycleMulIterativeDivRem (``p_muldivrem_sel = 1``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The hybrid unit combines a single-cycle multiplier for
MUL/MULH/MULHSU/MULHU with an iterative divider (``IterativeDivRemStep``)
for DIV/DIVU/REM/REMU. Multiplications complete in one cycle with full
throughput, while divisions iterate over multiple cycles using the same
restoring-division algorithm as the fully iterative variant. This
provides the best area/timing trade-off: the critical multiplier path is
short, and the slower division operations (which are less frequent in
typical code) amortize over multiple cycles. This is the default
selection for the configurations evaluated in the project report.

SingleCycleMulDivRem (``p_muldivrem_sel = 2``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The fully single-cycle unit computes all MUL/DIV/REM operations in one
cycle using a combinational datapath. It shares a single hardware
multiplier between multiplication and remainder computation: for MUL
variants, the multiplier computes ``op1 * op2`` directly with appropriate
sign extension; for REM variants, the multiplier computes
``quotient * divisor`` so that the remainder can be derived as
``dividend - product``. Division uses a combinational ``/`` operator. The
same divide-by-zero and overflow edge cases are handled. This variant has
the highest throughput (one result per cycle) but the longest
combinational path and thus the strictest timing constraint.
