
# z386 MiSTer core

z386_MiSTer is an unofficial PC core for MiSTer built around the extended
`z386x` CPU branch. The core retains the original Intel 386 microcode engine
and adds a faster frontend and bounded hardwired instruction paths. The July
2026 build runs the Doom timedemo at 27.3 FPS versus 21.0 FPS on ao486 using
the same MiSTer system.

## Trying It

z386_MiSTer requires an SDRAM module. Unlike ao486_MiSTer, which uses DDR3, this core uses MiSTer SDRAM. The SDRAM XS-D v2.5 module is verified to work.

Download a build from the [release page](https://github.com/nand2mario/z386_MiSTer/releases). Put `MiSTer` file in /media/fat (after backing up your existing `MiSTer`), z386_*.rbf in /media/fat/_Computer and [boot0.rom](verilator/boot0.rom), [boot1.rom](verilator/boot1.rom), game disk images (.vhd files) in `/media/fat/games/Z386`.

.
