Design Motivation and Philosophy
==========================================================================

Modern processor cores are highly monolithic, meaning their design is opaque to
anyone but the original designer and difficult to modify or extend past their
original specification. Zeppelin attacks this problem directly: it is a
fully-modular, superscalar, limited out-of-order RV32IM processor with
standardized latency-insensitive interfaces between functional units, broad
design parameterization, and swappable execute units. The superscalar, limited
out-of-order microarchitecture is itself implemented in a modular fashion so
the core is easier to understand and provides a stepping stone for future
improvements.

Zeppelin builds directly on
`Blimp <https://github.com/cornell-brg/blimp>`_, BRG's earlier single-issue,
in-order modular processor. Blimp established the modular methodology --
clean, latency-insensitive interfaces between pipeline stages and arbitrary
execute units -- and Zeppelin extends that methodology across the entire
pipeline to support multi-instruction throughput per cycle. The fetch unit,
decode-issue unit, and writeback-commit unit have all been redesigned from
the ground up to support superscalar execution, while the execute units
remain the swappable functional blocks they were in Blimp.

Design Principles
--------------------------------------------------------------------------

Several principles guide Zeppelin's implementation:

* **Modular units with standardized interfaces.** Each major pipeline stage
  is a self-contained unit (FU, DIU, XU, WCU, CFU) connected to its
  neighbors through small, well-defined SystemVerilog interfaces. Units can
  be modified, replaced, or extended without disturbing the rest of the
  pipeline as long as they continue to drive and accept the same interfaces.

* **Latency-insensitive forward dataflow.** All forward-moving interfaces
  use a standard ``val/rdy`` handshake, so any stage can stall any of its
  upstream stages without losing data. Execute units may take an arbitrary
  number of cycles to produce a result, and the rest of the pipeline
  adapts automatically.

* **Backward signals as notifications.** Latency-sensitive signals that flow
  backward in the pipeline (writebacks, commits, control-flow redirects) are
  modeled as ``val``-only notifications with no ``rdy`` line, ensuring no
  combinational loop or deadlock can form.

* **Parameterization over rewriting.** Frontend lane count, backend lane
  count, physical register count, sequence-number width, issue-queue depth,
  per-pipe FIFO depths, ALU/MUL counts, multiplier implementation,
  in-order/out-of-order issue queues, and branch-predictor configuration
  are all toplevel parameters. The same RTL can be instantiated from a
  minimal single-issue core to a wide multi-lane configuration.

* **Swappable execute units.** Execute units expose only the
  ``D__XIntf``/``X__WIntf`` interfaces and, where relevant, a
  ``ControlFlowNotif`` and a ``MemIntf``. Adding a floating-point unit or
  an accelerator interface is a matter of writing the new unit and routing
  it through the decode-issue instruction mapper.

This documentation describes the current implementation, including the
toplevel composition, the design of each microarchitectural unit, and the
supporting functional-level (FL) infrastructure used for verification.
