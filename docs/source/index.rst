.. MIPI over Chip2Chip reference design documentation master file.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

MIPI over Chip2Chip Reference Design
====================================

This is the documentation for the MIPI over Chip2Chip reference design: MIPI CSI-2 cameras
on a processor-less FPGA board (Tria AUBoard 15P with the Opsero `RPi Camera FMC`_),
controlled by a Zynq UltraScale+ host (AMD ZCU106) over AXI Chip2Chip and an Aurora 64B/66B
link on an SFP+ cable.

It is a two-board system: the two target designs of this repository are not alternatives to
choose from, they are the two halves of one system and both must be built.


.. toctree::
   :maxdepth: 2
   :caption: User Guide

   description
   requirements
   supported_carriers
   build_instructions
   yocto
   deploy
   flash
   linux_cameras
   display
   baremetal
   advanced
   troubleshooting
   revision_history


.. _RPi Camera FMC: https://docs.opsero.com/op068/datasheet/overview/
