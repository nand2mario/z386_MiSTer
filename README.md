# z386 MiSTer core

z386_MiSTer is an experimental PC core for MiSTer built around the
[z386x CPU](https://github.com/nand2mario/z386/tree/z386x). z386x combines the
original Intel 386 microcode with performance optimizations and architectural
extensions. Current optimizations include a faster frontend and hardwired fast
paths for common instructions.

The July 2026 build runs the Doom timedemo at 27.3 FPS, compared with 21.0 FPS
on ao486 using the same MiSTer system.

## Trying It

z386_MiSTer requires an SDRAM module. Unlike ao486_MiSTer, which uses DDR3,
this core uses MiSTer SDRAM. The SDRAM XS-D v2.5 module has been verified to
work.

Download the latest build from the
[releases page](https://github.com/nand2mario/z386_MiSTer/releases), then place
the files as follows:

- `MiSTer` in `/media/fat` after backing up the existing file
- `z386_*.rbf` in `/media/fat/_Computer`
- [boot0.rom](verilator/boot0.rom), [boot1.rom](verilator/boot1.rom), and disk
  images (`.vhd`) in `/media/fat/games/Z386`
