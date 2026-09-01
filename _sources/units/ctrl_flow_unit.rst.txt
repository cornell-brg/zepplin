Control Flow Unit (CFU)
==========================================================================

The Control Flow Unit (``CtrlFlowUnit``) arbitrates between control-flow
redirect notifications from multiple sources -- the decode-issue unit
(for JAL/JALR) and the control-flow execute unit (for resolved
conditional branches) -- and selects a single winner each cycle. The
winning redirect is broadcast to the fetch unit (to restart instruction
fetching at the correct target) and back to the decode-issue unit (to
flush the current instruction window). In configurations with branch
prediction, the unit also forwards branch-predictor update signals
(``bp_update_val``, ``taken``, ``pc``, ``target``) from the winning
source so the fetch unit's branch predictor can learn from resolved
branches and jumps.

The CFU operates on the ``ControlFlowNotif`` interface, which carries
``redirect_val`` (fetch must redirect), ``bp_update_val`` (branch/JAL
resolution data is valid for BP update), ``seq_num``, ``pc``, ``target``,
and ``taken``.

Arbitration
--------------------------------------------------------------------------

``CtrlFlowUnit`` arbitrates between ``p_num_arb`` redirect sources using
a binary-tree structure of pairwise ``CtrlFlowUnitHelper`` arbiters.
Each helper selects the older of two notifications based on their
sequence numbers, using the ``oldest_seq_num`` from a single shared
``SSSeqAge`` instance for wrap-around-safe age comparison across the
``p_num_be_lanes`` commit lanes (see :doc:`/uarch/seq_nums`). The
binary tree is built at elaboration time: leaf nodes connect to the
``arb`` interface array, and each level halves the number of candidates
until a single winner emerges at the root.

When only one source is valid, it wins unconditionally. When both
sources are valid, the older notification (the one with the earlier
sequence number) is selected. Unused leaf slots (when ``p_num_arb`` is
not a power of two) are zero-filled with ``redirect_val = 0``. For the
trivial ``p_num_arb == 1`` case, the single source passes through
directly with no arbitration hardware.

Helper modules pass through the full ``ControlFlowNotif`` payload
(``pc``, ``target``, ``taken``, ``bp_update_val``) from the winning
source, so the branch predictor receives update information through the
arbitrated grant.

Decoupled Grant for the DIU
--------------------------------------------------------------------------

The CFU produces two grant outputs:

- **``gnt``:** The full arbitration result across all ``p_num_arb``
  sources, broadcast to the fetch unit and other subscribers.

- **``gnt_excl``:** The arbitration result *excluding* the DIU source
  (identified by ``p_diu_idx``), connected to the DIU's own
  ``ctrl_flow_sub`` input.

The decoupled grant breaks the combinational loop that would otherwise
form: the DIU publishes a redirect combinationally on its
``ctrl_flow_pub`` interface, the CFU arbitrates it into ``gnt``, and
``gnt`` would feed back into the DIU. By stripping the DIU's own
redirect out of the path that returns to the DIU, the loop is broken
without needing a sequential break in the fetch-redirect path. Both
grants use the same ``SSSeqAge`` instance for age tracking. The full
grant uses a binary tree of arbiters across all sources; the excluded
grant uses a second binary tree that omits the DIU source. When
``p_num_arb == 2`` (the common case with one XU source and one DIU
source), ``gnt_excl`` is a zero-cost passthrough of the single non-DIU
source, requiring no additional arbitration hardware.
