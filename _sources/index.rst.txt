.. Zeppelin documentation master file, created by
   sphinx-quickstart on Tue Nov 26 23:07:46 2024.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

Zeppelin Documentation
==========================================================================

This is the home for Zeppelin's documentation, including the overall framework,
microarchitecture, and how users can use and/or modify the implementation.

.. toctree::
   :maxdepth: 1
   :caption: Overview

   overview/motivation
   overview/data_flow
   overview/overview
   overview/repository_structure
   overview/build_system
   overview/dependencies
   overview/programming_guide
   overview/todo

.. toctree::
   :maxdepth: 2
   :caption: Microarchitectural Units

   units/units

.. toctree::
   :maxdepth: 1
   :caption: Microarchitectural Details

   uarch/seq_nums.rst

.. toctree::
   :maxdepth: 1
   :caption: Functional Level (FL) Utilities

   fl/assembler
   fl/proc
