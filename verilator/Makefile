VERILATOR = verilator
VERILATOR_BUILD_JOBS ?= 8
SDL_CFLAGS=$(shell sdl2-config --cflags)
SDL_LIBS=$(shell sdl2-config --libs)
VERILATOR_FLAGS = +1800-2017ext+sv --trace-fst --trace-structs --savable --top-module z386_mister_sim --cc --exe --build -j $(VERILATOR_BUILD_JOBS) -CFLAGS "$(SDL_CFLAGS) -O2 -std=c++17" -LDFLAGS "$(SDL_LIBS)" -Wno-WIDTH -Wno-PINMISSING -Wno-COMBDLY -Wno-TIMESCALEMOD -Wno-IMPLICITSTATIC -Wno-CASEOVERLAP -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-REALCVT -Wno-ASCRANGE -Wno-MULTIDRIVEN -Wno-LATCH -DZ386_ALTERA_ALU=1
VERILATOR_INCLUDE = -I../src -I../src/z386

D=../src
DZ=../src/z386

SOURCES = ../z386_mister_sim.sv \
		  $(D)/system.sv \
		  $(DZ)/z386_pkg.sv $(DZ)/ucode_rom.sv $(DZ)/z386.sv $(DZ)/decoder.sv \
		  $(DZ)/alu.sv $(DZ)/alu_alt.sv $(DZ)/biu.sv $(DZ)/prefetch.sv $(DZ)/segmentation_unit.sv \
		  $(DZ)/paging_unit.sv $(DZ)/paging_tlb.sv $(DZ)/paging_walker.sv \
		  $(DZ)/dsp_mul.sv $(DZ)/protection.sv \
		  $(D)/iobus_adapter.sv $(D)/pic_inta_bridge.sv \
		  $(D)/memory/main_memory.sv $(D)/z386/l1_cache.sv $(D)/z386/l1_icache.sv $(D)/memory/sdram_sim.v \
		  $(D)/soc/dma.v $(D)/soc/floppy.v $(D)/soc/ide.v $(D)/soc/pic.v $(D)/soc/pit_counter.v \
		  $(D)/soc/pit.v $(D)/soc/ps2.v $(D)/soc/rtc.v $(D)/soc/vga.v \
		  $(D)/common/dpram.v $(D)/common/simple_ram.v $(D)/common/simple_fifo.v $(D)/common/async_fifo.v \
		  $(D)/common/ps2_device.v $(D)/common/simple_mult.v $(D)/common/uart_tx_V2.v $(D)/common/synchronizer.sv \
		  $(D)/common/cdc_vector_handshake_continuous.sv \
		  $(D)/soc/sound/sound.v $(D)/soc/sound/sound_dsp.v $(D)/soc/sound/saa1099.sv \
		  $(D)/soc/sound/opl3/afifo.v $(D)/soc/sound/opl3/opl3_pkg.sv \
		  $(D)/soc/sound/opl3/phase_generator.sv $(D)/soc/sound/opl3/mem_simple_dual_port.sv $(D)/soc/sound/opl3/calc_envelope_shift.sv \
		  $(D)/soc/sound/opl3/operator.sv $(D)/soc/sound/opl3/calc_phase_inc.sv $(D)/soc/sound/opl3/opl3_exp_lut.sv \
		  $(D)/soc/sound/opl3/calc_rhythm_phase.sv $(D)/soc/sound/opl3/opl3_log_sine_lut.sv $(D)/soc/sound/opl3/channels.sv \
		  $(D)/soc/sound/opl3/clk_div.sv $(D)/soc/sound/opl3/control_operators.sv $(D)/soc/sound/opl3/dac_prep.sv \
		  $(D)/soc/sound/opl3/edge_detector.sv $(D)/soc/sound/opl3/envelope_generator.sv $(D)/soc/sound/opl3/host_if.sv \
		  $(D)/soc/sound/opl3/ksl_add_rom.sv $(D)/soc/sound/opl3/leds.sv $(D)/soc/sound/opl3/mem_multi_bank_reset.sv \
		  $(D)/soc/sound/opl3/mem_multi_bank.sv $(D)/soc/sound/opl3/mem_simple_dual_port_async_read.sv \
		  $(D)/soc/sound/opl3/pipeline_sr.sv $(D)/soc/sound/opl3/reset_sync.sv $(D)/soc/sound/opl3/timer.sv \
		  $(D)/soc/sound/opl3/timers.sv $(D)/soc/sound/opl3/tremolo.sv $(D)/soc/sound/opl3/trick_sw_detection.sv \
		  $(D)/soc/sound/opl3/vibrato.sv $(D)/soc/sound/opl3/opl3.sv

CPP_SOURCES = main.cpp ide_hps.cpp

all: obj_dir/Vz386_mister_sim

obj_dir/Vz386_mister_sim: $(SOURCES) $(CPP_SOURCES) ../src/z386/ucode.hex
	ln -sf ../src/z386/ucode.hex .
	$(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_INCLUDE) $(SOURCES) $(CPP_SOURCES)

run: obj_dir/Vz386_mister_sim
	./obj_dir/Vz386_mister_sim --enter-at 10000000

trace: obj_dir/Vz386_mister_sim
	./obj_dir/Vz386_mister_sim --trace

clean:
	rm -rf obj_dir
	rm -f ucode.hex waveform.fst

.PHONY: all run trace clean
