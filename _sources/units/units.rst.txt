Microarchitectural Units
==========================================================================

Zeppelin's pipeline is composed of the following first-class
microarchitectural units, each connected to its neighbors through the
standardized interfaces described in :doc:`/overview/data_flow`:

.. toctree::
   :maxdepth: 1

   Fetch Unit (FU) <fetch_unit>
   Decode Issue Unit (DIU) <decode_issue_unit>
   Execute Units (XU) <execute_units>
   Writeback Commit Unit (WCU) <writeback_commit_unit>
   Control Flow Unit (CFU) <ctrl_flow_unit>

Each unit is implemented as a single parameterizable SystemVerilog module
under the corresponding ``hw/<name>/`` directory. The toplevel
``hw/top/Zeppelin.v`` is what wires them together; see
:doc:`/overview/overview` for the toplevel composition and the most
important configuration parameters.
