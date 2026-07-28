# Quartus build workflow for the z386 MiSTer project (revision z386_mister).
#
# Build profiles (base / debug / production) are applied to z386_mister.qsf by
# build_profile.py.  `build` runs a single full Quartus compile and the clk_sys
# top setup-paths report; `sweep` runs the fitter seed sweep (which requires the
# production profile).

REVISION   := z386_mister
SWEEP_ARGS := --start 1 --end 20 --jobs 5

.DEFAULT_GOAL := help
.PHONY: help base debug production build sweep core core21 core24

help:
	@echo 'z386 MiSTer Quartus targets:'
	@echo '  base        apply the base build profile'
	@echo '  debug       apply the debug build profile'
	@echo '  production  apply the production build profile'
	@echo '  build       single full Quartus compile + clk_sys top setup-paths report'
	@echo '  sweep       fitter seed sweep (needs the production profile)'
	@echo '              override seeds/jobs, e.g.:'
	@echo '                make sweep SWEEP_ARGS="--start 1 --end 5 --jobs 5"'
	@echo '  core        show the selected CPU core (src/z386 symlink)'
	@echo '  core21      select 21.z386'
	@echo '  core24      select 24.z386x'
	@echo '  help        this message (default target)'

# core selection: src/z386 is the single switch point (see set_core.sh).
core:
	@./set_core.sh

core21 core24:
	./set_core.sh $(patsubst core%,%,$@)

# base / debug / production: switch z386_mister.qsf to that profile.
base debug production:
	./build_profile.py $@

# build: one full compile, then the clk_sys top setup-paths report.
build:
	@./set_core.sh
	quartus_sh --flow compile $(REVISION)
	quartus_sta -t $(REVISION).clk_sys_top_setup.tcl
	@echo '==> top setup paths: output_files/$(REVISION).clk_sys_top_setup.rpt'

# sweep: fitter seed sweep (production profile required by seed_sweep.py).
sweep:
	./seed_sweep.py $(SWEEP_ARGS)
