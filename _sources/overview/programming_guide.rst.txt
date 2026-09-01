Configuration and Programming Guide
==========================================================================

This guide explains how to (1) reconfigure Zeppelin's microarchitectural
parameters, (2) add or remove execute units at the toplevel, and (3) write
new programs that run on Zeppelin using the runtime in ``app/``.

Configuring Zeppelin Parameters
--------------------------------------------------------------------------

All toplevel parameters live in three places:

- **Defaults:** ``hw/top/Zeppelin_defaults.vh`` defines a ``P_*`` macro for
  every toplevel parameter, each guarded by ``\`ifndef`` so the value can
  be overridden externally.
- **Toplevel module:** ``hw/top/Zeppelin.v`` declares the parameters with
  the corresponding ``\`P_*`` macro as the default, and propagates them
  into the FU, DIU, XUs, WCU, and CFU.
- **Common types:** ``defs/UArch.v`` defines the ``rv_uop`` opcode enum,
  the ``rv_op_vec`` one-hot subset type, and helper subsets used to
  describe which instructions each pipe can execute.

There are two ways to change a parameter value, depending on whether the
change applies globally or to a single instantiation.

Setting Parameters Globally (via ``-D`` Macro Overrides)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Each macro in ``Zeppelin_defaults.vh`` can be overridden from the build
system by passing a ``-D<NAME>=<VALUE>`` flag to the Verilog compiler.
This is the recommended way to sweep configurations without editing
source. To do it from a CMake build, edit
``hw/top/sim/sims.cmake`` (or the corresponding ``tests.cmake`` entry for
test targets) and add the override to the simulator's compile options, or
configure CMake with extra Verilog flags:

.. code-block:: bash

   cmake .. -DCMAKE_Verilog_FLAGS="-DP_NUM_FE_LANES=4 -DP_NUM_BE_LANES=4"

The most commonly tweaked macros and what they control:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Macro
     - Effect
   * - ``P_NUM_FE_LANES``
     - Width of the frontend fetch block; number of instructions decoded
       and renamed per cycle
   * - ``P_NUM_BE_LANES``
     - Commit lanes out of the WCU per cycle (also the ROB write/read
       width); must be ``<= 2**P_SEQ_NUM_BITS``
   * - ``P_NUM_ALUS``, ``P_NUM_MULS``
     - Number of replicated ALU and MUL/DIV/REM execute units
   * - ``P_SEQ_NUM_BITS``
     - Width of the sequence-number space (also bounds the ROB depth)
   * - ``P_NUM_PHYS_REGS``
     - Size of the physical register file. Must be at least
       ``31 + max_in_flight_writers``
   * - ``P_IQ_DEPTH``
     - Depth of each per-pipe issue queue
   * - ``P_PIPE_BYPASS``
     - ``0``: only the control pipe is in bypass mode (everything else
       gets a real issue queue); ``1``: every pipe is bypass-only (no
       buffering)
   * - ``P_ALL_IQ_IN_ORDER``
     - Force every issue queue to the in-order variant (disable
       ``IssueQueueOOO``)
   * - ``P_MULDIVREM_SEL``
     - ``0``: iterative MUL/DIV/REM; ``1``: single-cycle MUL with
       iterative DIV/REM; ``2``: fully single-cycle MUL/DIV/REM
   * - ``P_ENABLE_BRANCH_PRED``
     - Instantiate the BTB-based branch predictor in the FU
   * - ``P_BTB_ENTRIES``, ``P_BTB_WAYS``
     - BTB size and associativity
   * - ``P_MAX_IN_FLIGHT``
     - Maximum in-flight instruction-memory requests
   * - ``P_*_D_INTF_FIFO_DEPTH``
     - Per-XU input-FIFO depths (one for ALU, MUL, MEM, CTRL pipes)
   * - ``P_F_INTF_FIFO_DEPTH``, ``P_X_INTF_FIFO_DEPTH``
     - DIUFifo and WCUFifo depth, respectively

Setting Parameters per Instantiation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

If a test or simulator wrapper needs a different configuration than the
defaults, instantiate ``Zeppelin`` with an explicit parameter override
rather than redefining the macro:

.. code-block:: systemverilog

   Zeppelin #(
     .p_num_fe_lanes (4),
     .p_num_be_lanes (4),
     .p_num_alus     (4),
     .p_num_muls     (4)
   ) DUT ( ... );

Use this when (1) you want one test target to differ from the rest, (2)
you're writing a sweep harness that re-instantiates Zeppelin multiple
times with different parameters in the same simulation, or (3) you need
the value to depend on an upstream parameter rather than a fixed macro.

Constraint checklist when picking parameters:

- ``p_num_be_lanes <= 2**p_seq_num_bits`` (ROB depth bound)
- ``p_num_phys_regs >= 31 + (maximum writers in-flight)``; the defaults
  in ``Zeppelin_defaults.vh`` are calibrated to the corresponding lane
  count and should be re-checked when changing ``P_NUM_BE_LANES``
- ``p_ctrl_d_intf_fifo_depth`` must remain at ``1``; the control-flow
  pipe assumes a single-cycle branch resolution latency
- Memory-issuing pipes are automatically forced to in-order issue queues
  regardless of ``p_all_iq_in_order``

Adding and Removing Execute Units
--------------------------------------------------------------------------

Execute units (XUs) are the swappable functional blocks at the back of
the pipeline. There are two qualitatively different changes you might
want to make: changing the *count* of an existing XU type, or adding a
*new* XU type entirely.

Changing the Count of an Existing XU
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

For ALUs and MUL/DIV/REM units, this is a one-parameter change:

- Set ``P_NUM_ALUS`` (or ``p_num_alus`` at instantiation) to the desired
  count, including ``0`` to remove ALUs entirely (only useful for tests
  that don't issue any ALU ops)
- Set ``P_NUM_MULS`` to the desired count of MUL/DIV/REM units, or ``0``
  to drop M-extension support

The toplevel's generate loops (``ALU_XU_GEN``, ``MUL_XU_GEN``) automatically
replicate the units and the decode-issue crossbar and writeback arbiter
re-derive ``p_num_pipes = p_num_alus + p_num_muls + 2`` from those
counts. The MEM and CTRL pipes are always present at the fixed pipe
indices ``p_num_alus + p_num_muls`` and ``p_num_alus + p_num_muls + 1``.

When changing these counts, also tune the related parameters:

- ``p_num_be_lanes`` should usually scale with the total pipe count
  enough to absorb the additional concurrent completions
- ``p_iq_depth`` may need to grow to keep instructions ready when more
  pipes compete for the same operand-producing instruction
- ``p_num_phys_regs`` should grow with both ``p_num_fe_lanes`` and the
  pipe count, since wider configurations have more in-flight writes

Adding a New XU Type (e.g. an Accelerator)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The minimal recipe for plumbing a new XU into the toplevel:

1. **Implement the XU module.** It must accept a ``D__XIntf.sub`` and
   drive an ``X__WIntf.pub``. If the XU resolves control flow, it also
   needs to drive a ``ControlFlowNotif.pub``; if it accesses memory, it
   needs a ``MemIntf.client``. Use ``ALU.v`` (single-cycle combinational)
   or ``IterativeMulDivRem.v`` (multi-cycle state machine) as a starting
   template. Match the existing ``trace`` / ``trace_header`` convention
   so the linetrace integrates cleanly.

2. **Extend the opcode set if needed.** If the XU implements new
   instructions, add the corresponding entries to the ``rv_uop`` enum
   in ``defs/UArch.v``, bump ``num_ops``, define the matching
   ``OP_<NAME>_VEC`` one-hot localparams, and update the assembler/
   disassembler/FL processor in ``asm/`` and ``fl/`` to recognize them.
   Existing instructions can be reused without any opcode changes.

3. **Define the new pipe's ISA subset in the toplevel.** Add a new
   ``localparam p_<name>_subset`` in ``hw/top/Zeppelin.v`` next to the
   existing ``p_alu_subset``/``p_m_subset`` definitions, OR-combining
   the ``OP_*_VEC`` constants for the operations the XU handles.

4. **Update the pipe layout.** Bump ``p_num_pipes`` (currently derived
   as ``p_num_alus + p_num_muls + 2``; either change that derivation or
   introduce a new ``p_num_<xu>`` parameter that participates in it).
   Update ``gen_pipe_subsets`` to assign the new subset to the new pipe
   index, and shift the MEM/CTRL pipe indices accordingly. Allocate the
   matching slot in ``d__x_intfs[]``, ``d__x_del[]``, and
   ``x__w_intfs[]``.

5. **Instantiate the XU.** Add a ``generate`` block (or direct
   instantiation if only one copy) that hooks up ``D``, ``W``, and any
   notification or memory interfaces just like the existing XUs.

6. **Wire any new notifications into the CFU/SU.** If the XU publishes
   ``ControlFlowNotif``, extend ``ctrl_flow_arb_notif[]`` and increase
   ``p_num_arb`` on the ``CtrlFlowUnit`` instantiation so the new source
   participates in age-based arbitration.

7. **Decide on the issue-queue policy.** By default a new pipe gets the
   out-of-order ``IssueQueueOOO``. If the XU has memory-ordering
   constraints (like the LSU) or otherwise needs in-order issue, add its
   subset to the check inside the DIU that forces an in-order queue for
   pipes that intersect ``p_mem_subset`` (and consider whether the XU
   really wants a similar carve-out parameter).

8. **Update tests and the linetrace.** Add the new XU's trace column to
   ``Zeppelin.v``'s ``trace``/``trace_header`` functions and the
   ``Zeppelin_linetrace.md`` reference. Add unit tests under
   ``hw/execute/test/`` and integration test cases under
   ``hw/top/test/test_cases/``.

To remove an entire XU type (e.g. drop the MUL pipe in a minimal
configuration), it is usually enough to set ``P_NUM_MULS`` (or the
analogous count parameter) to ``0`` and avoid emitting the corresponding
opcodes from the compiler -- the generate loop becomes empty and the
crossbar contracts automatically.

Writing Programs for Zeppelin
--------------------------------------------------------------------------

Programs live under ``app/<program>/`` and are built into RISC-V ELF
binaries that the simulator loads at boot. Each program also gets a
"native" build (using the host compiler with the same source) so it can
be exercised quickly on a workstation before being run on the simulator.

Program Layout
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A minimal program is just two files. The C++ source:

.. code-block:: cpp

   // app/myprog/myprog.cpp
   #include "utils/zeppelin_wprintf.h"

   int main()
   {
     zeppelin_wprintf( L"Hello from myprog\n" );
     return 0;
   }

and a small CMakeLists that lists which files are the entry points and
which are supporting sources:

.. code-block:: cmake

   # app/myprog/CMakeLists.txt
   set(APP_FILES
     myprog.cpp
     PARENT_SCOPE
   )

   set(SRC_FILES
     PARENT_SCOPE
   )

``APP_FILES`` is the list of files that each contain a ``main`` -- one
RISC-V target ``app-<name>`` and one native target ``app-<name>-native``
are generated per entry. ``SRC_FILES`` is any shared code that should be
linked into every entry point in the directory (leave it empty when each
``.cpp`` is self-contained, as for ``hello`` and ``echo``; see ``ubmark``
for an example that uses it).

Finally, register the new directory by appending its name to
``APP_SUBDIRS`` in ``app/CMakeLists.txt``:

.. code-block:: cmake

   set(APP_SUBDIRS
     adventure
     echo
     hello
     myprog   # added
     sqrt
     ubmark
   )

After reconfiguring CMake the targets ``app-myprog`` (RISC-V ELF) and
``app-myprog-native`` (host binary) become available.

The Zeppelin Runtime
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Because Zeppelin doesn't yet have an OS or libc, programs talk directly
to memory-mapped peripherals through the small runtime in ``app/utils/``.
Every header uses the same ``_RISCV`` switch so the same source compiles
to a real host binary natively. The runtime functions provided are:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Header
     - Provides
   * - ``zeppelin_wprintf.h``
     - ``zeppelin_wprintf(L"...")`` -- wide-character ``printf`` against
       ``0xF0000000``. Word-aligned stores; integers print in hex. Use
       this when you only need to output text and want minimal code size.
   * - ``zeppelin_stdio.h``
     - ``zeppelin_printf``, ``zeppelin_sscanf``, ``zeppelin_putchar``,
       ``zeppelin_getchar``, ``zeppelin_fputs``, ``zeppelin_fgets``,
       ``zeppelin_fflush``. Full ``char*`` IO via ``%d %s %c %%`` against
       the terminal MMIO; reads from ``0xF0000004``.
   * - ``zeppelin_string.h``
     - ``strlen``-style helpers shared by the printf/scanf machinery
   * - ``zeppelin_misc.h``
     - ``zeppelin_atol``
   * - ``zeppelin_exit.h``
     - ``zeppelin_exit(int code)`` -- terminates the simulation by
       writing ``code`` to ``0xFFFFFFFC``
   * - ``zeppelin_stats.h``
     - ``zeppelin_cycle_count()`` and ``zeppelin_inst_count()`` -- reads
       from ``0xFFFFFF00`` and ``0xFFFFFF04`` respectively. Useful for
       computing CPI:
       ``cpi = (end_cycles - start_cycles) / (end_insts - start_insts)``
   * - ``zeppelin_rand.h``
     - ``rand``/``srand``-equivalents for deterministic stimulus
   * - ``zeppelin_stdlib.h``
     - Small libc-like helpers that don't need a separate ``.cpp``

The runtime objects are linked into every entry point automatically via
the ``UTILS`` static library defined in ``app/CMakeLists.txt``; ``#include``-ing
the header is the only thing a program needs to do.

Memory Map and Exit Convention
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The MMIO peripherals exposed by the simulator and the FL processor are:

.. list-table::
   :header-rows: 1
   :widths: 20 80

   * - Address
     - Meaning
   * - ``0xF0000000``
     - Terminal output (writes print a character)
   * - ``0xF0000004``
     - Terminal input (reads consume a character)
   * - ``0xFFFFFF00``
     - Cycle counter (read-only)
   * - ``0xFFFFFF04``
     - Instruction counter (read-only)
   * - ``0xFFFFFFFC``
     - Exit register (writes terminate the simulation with the written
       exit code)

Everything below ``0xF0000000`` is normal memory; the ELF is loaded
starting at ``0x00000200`` per ``app/scripts/zeppelin.ld``. The
``app/scripts/crt0.S`` boot stub sets up the stack, zeros ``.bss``, calls
``main``, and then writes the return value into the exit register so a
plain ``return 0;`` from ``main`` will cleanly halt the simulator.

Building and Running
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

From a configured ``build/`` directory:

.. code-block:: bash

   # Cross-compile for Zeppelin
   make app-myprog -j
   # Build the RTL simulator (only needs to happen once per RTL change)
   make zeppelin-sim -j
   # Run the ELF on the RTL simulator
   ./zeppelin-sim +elf=app/myprog

To debug a program before running it on RTL, build and run the native
target:

.. code-block:: bash

   make app-myprog-native -j
   ./app/myprog-native

To verify against the FL processor (the golden reference used by all
integration tests):

.. code-block:: bash

   make fl-sim -j
   ./fl-sim app/myprog

The runtime macros switch transparently between MMIO writes (on RV32)
and stdio (on the host), so the same program produces the same output
on all three.

Performance Tips
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The microbenchmarks under ``app/ubmark/`` are written specifically to
stress different parts of the pipeline, and are a useful reference when
writing your own:

- Wrap the timed region with ``zeppelin_cycle_count()`` and
  ``zeppelin_inst_count()`` reads, not around the whole ``main`` -- this
  excludes startup overhead.
- Independent computations expose ILP and benefit from wider frontend
  configurations. Pairs of benchmarks like ``depchain-serial`` vs
  ``depchain-multi`` and ``fir-naive`` vs ``fir-unrolled`` illustrate the
  effect.
- Branches that are not data-dependent benefit from enabling the branch
  predictor and growing ``P_BTB_ENTRIES``; data-dependent branches
  (``branchloop-branchy``, ``bsearch``) saturate the simple BTB and need
  a smarter predictor to improve.
- Mixed compute/memory loops (``memcopy-compheavy``) benefit most from
  growing both ``P_NUM_FE_LANES`` and an out-of-order issue queue
  (``P_ALL_IQ_IN_ORDER=0`` with ``P_IQ_DEPTH>=2``), since long-latency
  loads no longer block independent ALU work.
