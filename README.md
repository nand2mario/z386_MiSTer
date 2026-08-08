# z386 MiSTer core

z386_MiSTer is an experimental PC-compatible core for MiSTer, built around the
[z386x CPU](https://github.com/nand2mario/z386/tree/z386x). z386x executes the
original Intel 80386 microcode while adding pipelining, a faster frontend,
hardwired fast paths for common instructions, and selected architectural
extensions.

In Doom timedemo testing, the core reaches 29.7 FPS at maximum detail, compared
with 21.0 FPS on ao486 using the same MiSTer system. It supports 16, 32, 64, or
128 MB of RAM and ET4000-compatible SVGA modes.

## Trying It

z386_MiSTer requires a MiSTer SDRAM module; unlike ao486_MiSTer, it does not use
the DE10-Nano's DDR3 memory. The SDRAM XS-D v2.5 module has been verified to
work.

Download the latest build from the
[releases page](https://github.com/nand2mario/z386_MiSTer/releases), then install
the files as follows:

- Back up the existing `/media/fat/MiSTer`, then replace it with the released
  `MiSTer` file.
- `z386_*.rbf` in `/media/fat/_Computer`
- [boot0.rom](verilator/boot0.rom), [boot1.rom](verilator/boot1.rom), and disk
  images (`.vhd`) in `/media/fat/games/Z386`

For discussion, compatibility reports, and feedback, see the
[z386 forum thread](https://misterfpga.org/viewtopic.php?t=10400).
