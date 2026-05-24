
# z386 MiSTer core

z386_MiSTer is an unofficial PC core for MiSTer built around z386, a new 80386-compatible CPU design. It currently behaves like a smaller ao486_MiSTer: 16 MB of RAM and roughly 75% of ao486_MiSTer's performance. The core is still experimental, but the goal is to keep improving it.

## Trying It

z386_MiSTer requires an SDRAM module. Unlike ao486_MiSTer, which uses DDR3, this core uses MiSTer SDRAM. The SDRAM XS-D v2.5 module is verified to work.

Download a build from the [release page](https://github.com/nand2mario/z386_MiSTer/releases). Put `MiSTer` file in /media/fat (after backing up your existing `MiSTer`), z386_*.rbf in /media/fat/_Computer and [boot0.rom](verilator/boot0.rom), [boot1.rom](verilator/boot1.rom), game disk images (.vhd files) in `/media/fat/games/Z386`.

.
