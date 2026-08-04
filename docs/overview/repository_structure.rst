Repository Structure
==========================================================================

Zeppelin's repository is organized in the following structure:

 - ``CMakeLists.txt``: The top-level build system for the repository
 - ``README.md``: Quickstart instructions
 - ``app/``: Application code to be run on the processor. Each
   subdirectory is a different program, plus shared runtime in
   ``app/utils/`` and microbenchmarks in ``app/ubmark/``
 - ``asm/``: A C++ RISC-V assembler/disassembler shared by the FL
   processor, test harnesses, and tools
 - ``cmake/``: Helper code for the CMake build system, including the
   Verilog-as-a-language support files
 - ``defs/``: Common SystemVerilog definitions used across the processor
   (``ISA.v`` for opcodes, ``UArch.v`` for default parameters and types)
 - ``docs/``: Zeppelin's documentation (this site)
 - ``fl/``: Functional-level (FL) utilities, including the C++ FL
   processor implementation, a wrapper (``fl-sim``) to run code on it,
   the FL peripherals, and the Verilog DPI shim used to drive RTL
   testbenches from C++
 - ``hw/``: All hardware designs for the processor. The directory is
   split into several subdirectories, each with an associated ``test/``
   subdirectory for unit tests:

    - ``common/``: Common hardware modules (FIFOs, priority encoders,
      the iSLIP matching core)
    - ``ctrl_flow/``: Control Flow Unit (CFU) and its helpers
    - ``decode_issue/``: DIU and supporting designs (rename table,
      issue queues, instruction mapper/router, decoder, instruction
      checks, register file)
    - ``execute/``: Execute unit implementations (ALU, control-flow
      execute, load-store, multiple multiply/divide/remainder variants)
    - ``fetch/``: Fetch unit and supporting designs (address generator,
      squash tracker, branch predictor, sequence-number generator)
    - ``top/``: The top-level processor (``Zeppelin.v``) and integration
      tests:

      - ``sim/``: ``Zeppelin_sim.v`` simulator wrapper and supporting
        ``SimUtils.v`` / ``FLPeripherals.v`` shims for running ELFs
      - ``test/``: ``ZeppelinTestHarness.v``, the ELF-based
        ``Zeppelin_elf_test.v``, and the directed and golden test
        suites under ``test_cases/``
    - ``util/``: Utility modules (``SSSeqAge`` age tracker, the
      simulation-only stage delay modules, trace-header helpers)
    - ``writeback_commit/``: WCU and supporting designs (multi-ROB
      ``SSROB``, age-based arbiter ``SSWCUArb``, decoupling FIFO
      ``WCUFifo``)

 - ``intf/``: The hardware interfaces used to connect Zeppelin's units
   (``F__DIntf``, ``D__XIntf``, ``X__WIntf``, ``MemIntf``,
   ``CompleteNotif``, ``CommitNotif``, ``ControlFlowNotif``,
   ``InstTraceNotif``, ``InstCheckIntf``)
 - ``lint/``: Linting configuration and waivers for the Verilog sources
 - ``test/``: Shared testing infrastructure (``TestUtils.v``,
   ``FLTestUtils.v``, the ``MemIntfTestServer`` model, and the C++
   ``sim.cpp`` testbench entry point)
 - ``tools/``: Tools used to support Zeppelin's development:

    - ``rvelfdump.cpp``: A program to turn a compiled RISC-V program
      into a text-based ``address: data`` mapping
    - ``spi_flash/``: A Python program to communicate a text-based
      ``address: data`` mapping to an FPGA emulation of Zeppelin
      over SPI
    - ``verif_riscv_dv_batch.py``, ``verif_elf_suites.yaml``:
      Helpers for generating ELF-based test suites and driving the
      `riscv-dv <https://github.com/chipsalliance/riscv-dv>`_
      random-instruction framework
 - ``types/``: Common SystemVerilog types (``MemMsg``)
 - ``verilator_waivers.vlt``: Project-wide Verilator lint waivers
