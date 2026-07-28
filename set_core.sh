#!/usr/bin/env bash
# Select which CPU core this SoC builds by repointing the src/z386 symlink.
# Everything (QSF, files.qip, verilator sim) resolves the core through
# src/z386, so this is the single switch point.
#
#   ./set_core.sh        show the current selection
#   ./set_core.sh 21     use 21.z386  (z386 0.5 mainline)
#   ./set_core.sh 24     use 24.z386x (hybrid 386+486, doc/z386x/design.md)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

case "${1:-}" in
    "")
        echo "src/z386 -> $(readlink src/z386)"
        exit 0
        ;;
    21) target=../../21.z386 ;;
    24) target=../../24.z386x ;;
    *)
        echo "usage: $0 [21|24]" >&2
        exit 1
        ;;
esac

ln -sfn "$target" src/z386
echo "src/z386 -> $target"
