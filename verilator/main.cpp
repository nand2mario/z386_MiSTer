#include "Vz386_mister_system_core.h"
#include "Vz386_mister_system_core__Syms.h"
#include "Vz386_mister_system_core_z386_mister_system_core.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include <SDL.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <ctime>
#include <deque>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

#include "ide_hps.h"

using std::cerr;
using std::cout;
using std::deque;
using std::ifstream;
using std::ios;
using std::map;
using std::pair;
using std::string;
using std::vector;

#include "../../12.386tang/verilator/scancode.h"

static constexpr int H_RES = 1600;
static constexpr int V_RES = 900;

struct Pixel {
	uint8_t a;
	uint8_t b;
	uint8_t g;
	uint8_t r;
};

static Vz386_mister_system_core tb;
static VerilatedFstC* trace = nullptr;
static vluint64_t sim_time = 0;
static bool posedge = false;
static bool trace_toggle = false;
static bool trace_loop_started = false;
static uint64_t trace_start_cycle = 0;
static uint64_t current_cycle = 0;

static string disk_path = "../../sdcard/freedos.img";
static string boot0_path = "../../10.z386-sim/seabios/out/bios.bin";
static string boot1_path = "../../10.z386-sim/seabios/out/vgabios.bin";
static std::array<bool, 256> boot_pages_seen{};
static constexpr uint32_t DDR_SHMEM_BASE = 0x30000000;
static constexpr size_t DDR_SIZE = 16 * 1024 * 1024;
static std::vector<uint8_t> ddram_mem(DDR_SIZE);
static bool ddram_resp_valid = false;
static uint64_t ddram_resp_data = 0;

struct ScheduledPs2Bytes {
	uint64_t cycle;
	std::vector<uint8_t> bytes;
};

static std::vector<ScheduledPs2Bytes> ps2_events;
static size_t next_ps2_event = 0;
static deque<uint8_t> kbd_scancode_queue;
static uint64_t last_kbd_byte_time = 0;
static uint8_t ps2_kbd_scan_set = 2;
static uint8_t pending_kbd_cmd = 0;
static bool pending_kbd_arg = false;
static bool kbd_host_busy = false;
static bool kbd_host_clear_pending = false;
static std::vector<uint64_t> screen_check_cycles;
static size_t next_screen_check = 0;
static bool g_headless = false;
static bool g_ide_debug = true;
static Pixel screenbuffer[H_RES * V_RES]{};
static Pixel presentbuffer[H_RES * V_RES]{};

static constexpr std::array<uint32_t, 16> kVgaPalette = {{
	0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
	0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
	0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
	0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
}};

static inline Pixel palette_pixel(uint8_t idx) {
	uint32_t rgb = kVgaPalette[idx & 0x0f];
	return Pixel{
		0xff,
		static_cast<uint8_t>(rgb & 0xff),
		static_cast<uint8_t>((rgb >> 8) & 0xff),
		static_cast<uint8_t>((rgb >> 16) & 0xff),
	};
}

static vector<uint8_t> read_file(const string& path) {
	ifstream f(path, ios::binary);
	if (!f) throw std::runtime_error("failed to open " + path);
	f.seekg(0, ios::end);
	size_t size = static_cast<size_t>(f.tellg());
	f.seekg(0, ios::beg);
	vector<uint8_t> data(size);
	f.read(reinterpret_cast<char*>(data.data()), static_cast<std::streamsize>(size));
	if (!f) throw std::runtime_error("failed to read " + path);
	return data;
}

static void queue_ps2_bytes(const std::vector<uint8_t>& bytes) {
	kbd_scancode_queue.insert(kbd_scancode_queue.end(), bytes.begin(), bytes.end());
}

static inline uint32_t get_ticks_ms() {
	if (!g_headless) return SDL_GetTicks();
	return 0;
}

static void set_trace(bool toggle) {
	printf("Tracing %s\n", toggle ? "on" : "off");
	if (toggle && !trace) {
		trace = new VerilatedFstC();
		tb.trace(trace, 5);
		Verilated::traceEverOn(true);
		trace->open("waveform.fst");
	}
	trace_toggle = toggle;
}

static void queue_sdl_key(SDL_Keycode key, bool pressed) {
	auto it = ps2scancodes.find(key);
	if (it == ps2scancodes.end()) return;
	const auto& seq = pressed ? it->second.first : it->second.second;
	if (seq.empty()) return;
	queue_ps2_bytes(seq);
}

static void handle_kbd_host_cmd(uint8_t cmd) {
	auto reply = [](uint8_t code) {
		kbd_scancode_queue.push_back(code);
	};

	if (!pending_kbd_arg) {
		pending_kbd_cmd = cmd;
		switch (cmd) {
		case 0xFF:
			ps2_kbd_scan_set = 2;
			reply(0xFA);
			reply(0xAA);
			pending_kbd_cmd = 0;
			break;
		case 0xF2:
			reply(0xFA);
			reply(0xAB);
			reply(0x83);
			pending_kbd_cmd = 0;
			break;
		case 0xF0:
		case 0xF3:
		case 0xED:
			reply(0xFA);
			pending_kbd_arg = true;
			break;
		case 0xF6:
			ps2_kbd_scan_set = 2;
			reply(0xFA);
			pending_kbd_cmd = 0;
			break;
		case 0xF4:
		case 0xF5:
		case 0xFA:
			reply(0xFA);
			pending_kbd_cmd = 0;
			break;
		case 0xEE:
			reply(0xEE);
			pending_kbd_cmd = 0;
			break;
		default:
			reply(0xFE);
			pending_kbd_cmd = 0;
			break;
		}
	} else {
		switch (pending_kbd_cmd) {
		case 0xED:
			reply(0xFA);
			break;
		case 0xF0:
			if (cmd <= 3) {
				reply(0xFA);
				if (cmd == 0) reply(ps2_kbd_scan_set);
				else ps2_kbd_scan_set = cmd;
			} else {
				reply(0xFE);
			}
			break;
		case 0xF3:
			reply(0xFA);
			break;
		default:
			break;
		}
		pending_kbd_cmd = 0;
		pending_kbd_arg = false;
	}
}

static std::string current_text_screen() {
	auto* sys = tb.z386_mister_system_core->system_i;
	std::string text;
	text.reserve(25 * 81);
	uint16_t start = static_cast<uint16_t>(sys->__PVT__vga_inst__DOT__crtc_address_start);
	uint16_t byte_panning = static_cast<uint16_t>(sys->__PVT__vga_inst__DOT__crtc_address_byte_panning);
	uint16_t stride = static_cast<uint16_t>(sys->__PVT__vga_inst__DOT__crtc_address_offset) << 1;
	uint16_t cols = static_cast<uint16_t>(sys->__PVT__vga_inst__DOT__crtc_horizontal_display_size) + 1;
	if (cols == 0 || cols > 160) cols = 80;
	if (stride == 0 || stride > 4096) stride = cols;
	uint16_t row_addr = start + byte_panning;
	for (int row = 0; row < 25; ++row) {
		for (uint16_t col = 0; col < cols; ++col) {
			uint8_t ch = sys->__PVT__vga_inst__DOT__plane_ram_0__DOT__mem[static_cast<uint16_t>(row_addr + col)];
			if (ch < 0x20 || ch > 0x7e) ch = ' ';
			text.push_back(static_cast<char>(ch));
		}
		text.push_back('\n');
		row_addr = static_cast<uint16_t>(row_addr + stride);
	}
	return text;
}

static std::string row_for_match(const std::string& screen, const std::string& needle) {
	size_t pos = screen.find(needle);
	if (pos == std::string::npos) return {};
	size_t line_start = screen.rfind('\n', pos);
	if (line_start == std::string::npos) line_start = 0;
	else line_start += 1;
	size_t line_end = screen.find('\n', pos);
	if (line_end == std::string::npos) line_end = screen.size();
	return screen.substr(line_start, line_end - line_start);
}

static void dump_nonempty_rows(const std::string& screen) {
	size_t line_start = 0;
	unsigned row = 0;
	while (line_start < screen.size()) {
		size_t line_end = screen.find('\n', line_start);
		if (line_end == std::string::npos) line_end = screen.size();
		std::string row_text = screen.substr(line_start, line_end - line_start);
		size_t first = row_text.find_first_not_of(' ');
		if (first != std::string::npos) {
			size_t last = row_text.find_last_not_of(' ');
			cout << "screen row " << row << ": [" << row_text.substr(first, last - first + 1) << "]\n";
		}
		if (line_end == screen.size()) break;
		line_start = line_end + 1;
		row++;
	}
}

static void step() {
	tb.ddram_busy = 0;
	tb.ddram_dout_ready = ddram_resp_valid ? 1 : 0;
	tb.ddram_dout = ddram_resp_data;

	tb.clk_sys = !tb.clk_sys;
	tb.clk_audio = tb.clk_sys;
	posedge = tb.clk_sys;
	tb.eval();
	if (posedge) {
		bool read_accepted = tb.ddram_rd && !tb.ddram_busy;
		if (read_accepted) {
			uint64_t byte_addr = static_cast<uint64_t>(tb.ddram_addr) << 3;
			uint64_t offset = (byte_addr >= DDR_SHMEM_BASE) ? byte_addr - DDR_SHMEM_BASE : UINT64_MAX;
			uint64_t data = 0;
			if (offset != UINT64_MAX) {
				for (int i = 0; i < 8; i++) {
					if (offset + static_cast<uint64_t>(i) < ddram_mem.size())
						data |= static_cast<uint64_t>(ddram_mem[offset + i]) << (8 * i);
				}
			}
			ddram_resp_data = data;
			ddram_resp_valid = true;
		} else if (ddram_resp_valid) {
			ddram_resp_valid = false;
		}
	}
	if (trace && trace_toggle && trace_loop_started && current_cycle >= trace_start_cycle) trace->dump(sim_time);
	sim_time++;
}

static void full_step() {
	step();
	step();
}

static void pulse_mgmt_write(uint16_t addr, uint16_t data) {
	tb.mgmt_address = addr;
	tb.mgmt_writedata = data;
	tb.mgmt_write = 1;
	tb.mgmt_read = 0;
	full_step();
	tb.mgmt_write = 0;
	full_step();
}

static void ddr_write(uint32_t offset, const vector<uint8_t>& data) {
	if (offset >= ddram_mem.size()) return;
	size_t count = std::min(data.size(), ddram_mem.size() - static_cast<size_t>(offset));
	std::copy_n(data.begin(), count, ddram_mem.begin() + offset);
}

static void stage_roms_to_ddr(const vector<uint8_t>& boot0, const vector<uint8_t>& boot1) {
	uint32_t boot0_offset = (boot0.size() > 65536) ? 0xE0000 : 0xF0000;

	std::fill(ddram_mem.begin(), ddram_mem.end(), 0);
	std::fill(ddram_mem.begin() + 0xA0000, ddram_mem.begin() + 0x100000, 0xFF);
	std::fill(ddram_mem.begin() + 0xA0000, ddram_mem.begin() + 0xC0000, 0x00);
	std::fill(ddram_mem.begin() + 0xCE000, ddram_mem.begin() + 0xD0000, 0x00);
	ddr_write(0xC0000, boot1);
	ddr_write(boot0_offset, boot0);
	cout << "Staged ROMs in DDR: boot1 @ 0xC0000, boot0 @ 0x"
	     << std::hex << boot0_offset << std::dec << "\n";
}

static uint8_t bin2bcd(unsigned val) {
	return static_cast<uint8_t>(((val / 10) << 4) | (val % 10));
}

static void configure_floppy_slot(unsigned slot, bool present) {
	uint16_t base = static_cast<uint16_t>(0xF200 + (slot << 7));
	pulse_mgmt_write(base + 0x0, present ? 1 : 0);
	pulse_mgmt_write(base + 0x1, 1);
	pulse_mgmt_write(base + 0x2, 0);
	pulse_mgmt_write(base + 0x3, 0);
	pulse_mgmt_write(base + 0x4, 0);
	pulse_mgmt_write(base + 0x5, 0);
	pulse_mgmt_write(base + 0xC, 0);
}

static void configure_cmos(bool hdd0_present, bool floppy0_present, bool boot_from_floppy = false) {
	std::time_t now = std::time(nullptr);
	std::tm tm{};
	localtime_r(&now, &tm);

	uint8_t cmos[128] = {};

	// Match the 386tang default: 4MB total, so 3MB extended.
	const uint16_t ext_mem_kb = 3 * 1024;

	cmos[0x00] = bin2bcd(tm.tm_sec);
	cmos[0x02] = bin2bcd(tm.tm_min);
	cmos[0x04] = bin2bcd(tm.tm_hour);
	cmos[0x05] = 0x12;
	cmos[0x06] = static_cast<uint8_t>(tm.tm_wday + 1);
	cmos[0x07] = bin2bcd(tm.tm_mday);
	cmos[0x08] = bin2bcd(tm.tm_mon + 1);
	cmos[0x09] = bin2bcd((tm.tm_year < 117) ? 17 : tm.tm_year - 100);
	cmos[0x0A] = 0x26;
	cmos[0x0B] = 0x02;
	cmos[0x0D] = 0x80;

	cmos[0x10] = 0x00;
	cmos[0x12] = static_cast<uint8_t>((hdd0_present ? 0xF : 0x0) << 4);
	cmos[0x14] = 0x4D;
	cmos[0x15] = 0x80;
	cmos[0x16] = 0x02;
	cmos[0x17] = ext_mem_kb & 0xFF;
	cmos[0x18] = ext_mem_kb >> 8;
	cmos[0x19] = static_cast<uint8_t>(hdd0_present ? 0x2F : 0x00);

	cmos[0x2D] = static_cast<uint8_t>((floppy0_present && boot_from_floppy) ? 0x20 : 0x00);
	cmos[0x30] = ext_mem_kb & 0xFF;
	cmos[0x31] = ext_mem_kb >> 8;
	cmos[0x32] = 0x20;
	cmos[0x34] = 0x00;
	cmos[0x35] = 0x00;
	cmos[0x37] = 0x20;
	cmos[0x39] = 0x02;

	unsigned short sum = 0;
	for (int i = 0x10; i <= 0x2D; ++i) sum += cmos[i];
	cmos[0x2E] = sum >> 8;
	cmos[0x2F] = sum & 0xFF;

	for (unsigned i = 0; i < sizeof(cmos); ++i) {
		pulse_mgmt_write(static_cast<uint16_t>(0xF400 + i), cmos[i]);
	}
}

static void configure_x86_management(bool hdd0_present) {
	configure_floppy_slot(0, false);
	configure_floppy_slot(1, false);
	configure_cmos(hdd0_present, false, false);
}

static void usage() {
	cout << "Usage: Vz386_mister_system_core [--trace] [--trace-start cycle] [--headless] [--cycles N] [--disk path] [--boot0 path] [--boot1 path] [--enter-at cycle] [--screen-at cycle] [--no-ide]\n";
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	setvbuf(stdout, nullptr, _IOLBF, 0);
	setvbuf(stderr, nullptr, _IONBF, 0);

	bool enable_trace = false;
	uint64_t max_cycles = std::numeric_limits<uint64_t>::max();
	vector<uint64_t> enter_cycles;

	for (int i = 1; i < argc; ++i) {
		string arg = argv[i];
		if (arg == "--trace") {
			enable_trace = true;
		} else if (arg == "--trace-start" && i + 1 < argc) {
			trace_start_cycle = std::stoull(argv[++i]);
		} else if (arg == "--headless") {
			g_headless = true;
		} else if (arg == "--cycles" && i + 1 < argc) {
			max_cycles = std::stoull(argv[++i]);
		} else if (arg == "--disk" && i + 1 < argc) {
			disk_path = argv[++i];
		} else if (arg == "--boot0" && i + 1 < argc) {
			boot0_path = argv[++i];
		} else if (arg == "--boot1" && i + 1 < argc) {
			boot1_path = argv[++i];
		} else if (arg == "--enter-at" && i + 1 < argc) {
			enter_cycles.push_back(std::stoull(argv[++i]));
		} else if (arg == "--screen-at" && i + 1 < argc) {
			screen_check_cycles.push_back(std::stoull(argv[++i]));
		} else if (arg == "--ide") {
			g_ide_debug = true;
		} else if (arg == "--no-ide") {
			g_ide_debug = false;
		} else {
			usage();
			return 1;
		}
	}

	for (uint64_t cycle : enter_cycles) {
		auto it = ps2scancodes.find(SDLK_RETURN);
		if (it != ps2scancodes.end()) {
			std::vector<uint8_t> bytes;
			bytes.insert(bytes.end(), it->second.first.begin(), it->second.first.end());
			bytes.insert(bytes.end(), it->second.second.begin(), it->second.second.end());
			ps2_events.push_back({cycle, bytes});
		}
	}
	std::sort(ps2_events.begin(), ps2_events.end(),
		[](const ScheduledPs2Bytes& a, const ScheduledPs2Bytes& b) { return a.cycle < b.cycle; });
	std::sort(screen_check_cycles.begin(), screen_check_cycles.end());

	vector<uint8_t> boot0;
	vector<uint8_t> boot1;
	try {
		boot0 = read_file(boot0_path);
		boot1 = read_file(boot1_path);
	} catch (const std::exception& e) {
		cerr << e.what() << "\n";
		return 1;
	}

	HpsIde ide0(0, 0xF000);
	HpsIde ide1(1, 0xF100);
	ide0.set_debug(g_ide_debug);
	ide1.set_debug(g_ide_debug);
	if (!ide0.open(disk_path)) {
		cerr << "failed to open disk image " << disk_path << "\n";
		return 1;
	}

	SDL_Window* sdl_window = nullptr;
	SDL_Renderer* sdl_renderer = nullptr;
	SDL_Texture* sdl_texture = nullptr;
	uint32_t last_render_ms = 0;
	uint32_t last_title_ms = 0;
	vluint64_t last_title_sim_time = 0;
	int resolution_x = 720;
	int resolution_y = 400;
	int scan_x = 0;
	int scan_y = 0;
	int frame_pix_cnt = 0;
	int frame_x_max = 0;
	int frame_line_max = 0;
	uint64_t next_console_text_check = 0;
	std::string last_console_text;

	if (!g_headless) {
		if (SDL_Init(SDL_INIT_VIDEO) < 0) {
			cerr << "SDL init failed: " << SDL_GetError() << "\n";
			return 1;
		}
		sdl_window = SDL_CreateWindow("z386 MiSTer sim", SDL_WINDOWPOS_CENTERED,
			SDL_WINDOWPOS_CENTERED, resolution_x * 2, resolution_y * 2,
			SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
		if (!sdl_window) {
			cerr << "SDL window creation failed: " << SDL_GetError() << "\n";
			SDL_Quit();
			return 1;
		}
		SDL_SetWindowMinimumSize(sdl_window, resolution_x, resolution_y);
		sdl_renderer = SDL_CreateRenderer(sdl_window, -1, SDL_RENDERER_ACCELERATED);
		if (!sdl_renderer) sdl_renderer = SDL_CreateRenderer(sdl_window, -1, SDL_RENDERER_SOFTWARE);
		if (!sdl_renderer) {
			cerr << "SDL renderer creation failed: " << SDL_GetError() << "\n";
			SDL_DestroyWindow(sdl_window);
			SDL_Quit();
			return 1;
		}
		SDL_RenderSetLogicalSize(sdl_renderer, resolution_x, resolution_y);
		sdl_texture = SDL_CreateTexture(sdl_renderer, SDL_PIXELFORMAT_RGBA8888,
			SDL_TEXTUREACCESS_STREAMING, H_RES, V_RES);
		if (!sdl_texture) {
			cerr << "SDL texture creation failed: " << SDL_GetError() << "\n";
			SDL_DestroyRenderer(sdl_renderer);
			SDL_DestroyWindow(sdl_window);
			SDL_Quit();
			return 1;
		}
		SDL_StopTextInput();
	}

	tb.clk_sys = 0;
	tb.clk_audio = 0;
	tb.reset = 1;
	tb.status = 0;
	tb.ps2_key = 0;
	tb.ioctl_download = 0;
	tb.ioctl_index = 0;
	tb.ioctl_wr = 0;
	tb.ioctl_addr = 0;
	tb.ioctl_dout = 0;
	tb.ddram_busy = 0;
	tb.ddram_dout = 0;
	tb.ddram_dout_ready = 0;
	tb.mgmt_address = 0;
	tb.mgmt_read = 0;
	tb.mgmt_write = 0;
	tb.mgmt_writedata = 0;
	tb.ps2_key = 0;

	if (enable_trace) set_trace(true);

	stage_roms_to_ddr(boot0, boot1);
	full_step();
	tb.reset = 0;
	full_step();
	configure_x86_management(ide0.present());
	trace_loop_started = true;

	bool saw_first_instruction = false;
	bool saw_post = false;
	bool saw_video_sync = false;
	bool saw_boot_sector = false;
	bool saw_post_boot_exec = false;
	bool saw_boot_menu_text = false;
	bool saw_nonblack_pixel = false;
	unsigned boot_page_logs = 0;
	bool prev_vs = false;
	bool prev_hs = false;
	bool prev_de = false;
	bool bios_dbg_wr_prev = false;
	uint8_t last_post = 0;
	bool have_post = false;
	bool running = true;
	auto* core = tb.z386_mister_system_core;
	auto* sys = core->system_i;

	tb.sim_kbd_data = 0;
	tb.sim_kbd_data_valid = 0;
	tb.sim_kbd_host_data_clear = 0;

	auto keyboard_send_pre = [&](uint64_t cycle) {
		tb.sim_kbd_host_data_clear = kbd_host_clear_pending;

		while (next_ps2_event < ps2_events.size() && ps2_events[next_ps2_event].cycle <= cycle) {
			queue_ps2_bytes(ps2_events[next_ps2_event].bytes);
			next_ps2_event++;
		}

		if (!kbd_host_busy && cycle - last_kbd_byte_time > 100000 && !kbd_scancode_queue.empty()) {
			uint8_t byte = kbd_scancode_queue.front();
			kbd_scancode_queue.pop_front();
			tb.sim_kbd_data = byte;
			tb.sim_kbd_data_valid = 1;
			last_kbd_byte_time = cycle;
			printf("%8llu: Sending scancode 0x%02X\n",
			       (unsigned long long)cycle, byte);
		} else {
			tb.sim_kbd_data_valid = 0;
		}
	};

	auto keyboard_observe_post = [&](uint64_t cycle) {
		if (!posedge) return;

		uint16_t kbd_host_data = tb.sim_kbd_host_data;
		bool kbd_host_valid = (kbd_host_data & 0x100) != 0;
		if (kbd_host_valid && !kbd_host_busy) {
			uint8_t cmd = static_cast<uint8_t>(kbd_host_data & 0xFF);
			printf("%8llu: Received keyboard command 0x%02X\n",
			       (unsigned long long)cycle, cmd);
			handle_kbd_host_cmd(cmd);
			kbd_host_busy = true;
			kbd_host_clear_pending = true;
		} else if (!kbd_host_valid && kbd_host_busy) {
			kbd_host_busy = false;
			kbd_host_clear_pending = false;
		}
		tb.sim_kbd_data_valid = 0;
	};

	auto consume_video = [&](uint64_t cycle) {
		if (!posedge) return;

		if (tb.video_vs && !prev_vs) {
			scan_x = 0;
			scan_y = 0;
		}

		if (tb.ce_pixel) {
			if (tb.video_de && !prev_de) {
				scan_x = 0;
				if (frame_line_max != 0 && scan_y + 1 < V_RES) scan_y++;
				if (scan_y + 1 > frame_line_max) frame_line_max = scan_y + 1;
			}
			if (tb.video_de) {
				if (scan_x < H_RES && scan_y < V_RES) {
					Pixel* p = &screenbuffer[scan_y * H_RES + scan_x];
					p->a = 0xff;
					p->r = tb.video_r;
					p->g = tb.video_g;
					p->b = tb.video_b;
					if (p->r || p->g || p->b) frame_pix_cnt++;
					if (!saw_nonblack_pixel && (p->r || p->g || p->b)) {
						saw_nonblack_pixel = true;
						cout << cycle << ": first non-black VGA pixel at x=" << scan_x
						     << " y=" << scan_y << "\n";
					}
				}
				scan_x++;
				if (scan_x > frame_x_max) frame_x_max = scan_x;
			}
		}

		if (tb.video_vs && !prev_vs) {
			saw_video_sync = true;
			if (frame_x_max >= 640) resolution_x = std::min(frame_x_max, H_RES);
			if (frame_line_max >= 300) resolution_y = std::min(frame_line_max, V_RES);
			cout << cycle << ": FRAME: PE=" << static_cast<int>(tb.dbg_pe)
			     << " CS:EIP=" << std::hex << tb.dbg_cs << ":" << tb.dbg_eip
			     << std::dec << " pix=" << frame_pix_cnt
			     << " lines=" << frame_line_max
			     << " xmax=" << frame_x_max << "\n";
			std::copy(std::begin(screenbuffer), std::end(screenbuffer), std::begin(presentbuffer));
			std::fill(std::begin(screenbuffer), std::end(screenbuffer), Pixel{0xff, 0x00, 0x00, 0x00});
			frame_pix_cnt = 0;
			frame_x_max = 0;
			frame_line_max = 0;
			if (saw_post_boot_exec && cycle >= next_console_text_check) {
				std::string screen = current_text_screen();
				if (screen != last_console_text) {
					cout << cycle << ": VGA text update\n";
					dump_nonempty_rows(screen);
					last_console_text = screen;
				}
				next_console_text_check = cycle + 1000000ull;
			}
			if (!saw_boot_menu_text && saw_boot_sector &&
			    next_screen_check < screen_check_cycles.size() &&
			    cycle >= screen_check_cycles[next_screen_check]) {
				std::string screen = current_text_screen();
				std::string row = row_for_match(screen, "Press ESC for boot menu");
				cout << cycle << ": screen checkpoint\n";
				if (!row.empty()) {
					saw_boot_menu_text = true;
					cout << cycle << ": boot menu text: [" << row << "]\n";
				} else {
					dump_nonempty_rows(screen);
				}
				next_screen_check++;
			}
		}
		prev_vs = tb.video_vs;
		prev_hs = tb.video_hs;
		prev_de = tb.video_de;
	};

	for (uint64_t cycle = 0; cycle < max_cycles && running; ++cycle) {
		current_cycle = cycle;
		tb.mgmt_read = 0;
		tb.mgmt_write = 0;
		ide0.tick(tb);
		if (!tb.mgmt_read && !tb.mgmt_write) ide1.tick(tb);

		if (!tb.clk_sys) keyboard_send_pre(cycle);
		step();
		keyboard_observe_post(cycle);
		consume_video(cycle);

		if (!tb.clk_sys) keyboard_send_pre(cycle);
		step();
		keyboard_observe_post(cycle);
		consume_video(cycle);

		bool bios_dbg_wr = tb.dbg_uart_we;
		if (bios_dbg_wr && !bios_dbg_wr_prev) {
			uint8_t ch = tb.dbg_uart_byte;
			printf("\033[33m");
			putchar(ch);
			printf("\033[0m");
			fflush(stdout);
		}
		bios_dbg_wr_prev = bios_dbg_wr;

		if (!g_headless) {
			uint32_t now = get_ticks_ms();
			SDL_Event e;
			while (SDL_PollEvent(&e)) {
				if (e.type == SDL_QUIT) running = false;
				else if (e.type == SDL_WINDOWEVENT &&
				         e.window.event == SDL_WINDOWEVENT_CLOSE &&
				         e.window.windowID == SDL_GetWindowID(sdl_window)) running = false;
				else if (e.type == SDL_KEYDOWN && !e.key.repeat) {
					SDL_Keymod mods = SDL_GetModState();
					bool trace_hotkey =
						(e.key.keysym.scancode == SDL_SCANCODE_T) &&
						(mods & (KMOD_GUI | KMOD_CTRL));
					if (trace_hotkey) {
						set_trace(!trace_toggle);
					} else {
						queue_sdl_key(e.key.keysym.sym, true);
					}
				} else if (e.type == SDL_KEYUP) {
					SDL_Keymod mods = SDL_GetModState();
					bool trace_hotkey =
						(e.key.keysym.scancode == SDL_SCANCODE_T) &&
						(mods & (KMOD_GUI | KMOD_CTRL));
					if (!trace_hotkey) {
						queue_sdl_key(e.key.keysym.sym, false);
					}
				}
			}

			if (now - last_render_ms >= 33) {
				SDL_UpdateTexture(sdl_texture, nullptr, presentbuffer, H_RES * sizeof(Pixel));
				const SDL_Rect src_rect = {0, 0, resolution_x, resolution_y};
				SDL_RenderClear(sdl_renderer);
				SDL_RenderCopy(sdl_renderer, sdl_texture, &src_rect, nullptr);
				SDL_RenderPresent(sdl_renderer);
				last_render_ms = now;

				if (now - last_title_ms >= 1000) {
					uint64_t delta_cycles = (sim_time - last_title_sim_time) / 2;
					char title[128];
					snprintf(title, sizeof(title), "z386 MiSTer - %.1f MHz%s",
						delta_cycles / 1000000.0,
						trace_toggle ? " [TRACE]" : "");
					SDL_SetWindowTitle(sdl_window, title);
					last_title_ms = now;
					last_title_sim_time = sim_time;
				}
			}
		}

		uint32_t linear_ip = tb.dbg_cs_base + tb.dbg_eip;
		if (!saw_boot_sector && linear_ip >= 0x7C00 && linear_ip < 0x7E00) {
			saw_boot_sector = true;
			cout << cycle << ": boot sector execution at " << std::hex
			     << tb.dbg_cs << ":" << tb.dbg_eip
			     << " linear=0x" << linear_ip << std::dec << "\n";
		}
		if (saw_boot_sector && !saw_post_boot_exec &&
		    linear_ip < 0xA0000 &&
		    !(linear_ip >= 0x7C00 && linear_ip < 0x7E00)) {
			saw_post_boot_exec = true;
			cout << cycle << ": post-boot execution at " << std::hex
			     << tb.dbg_cs << ":" << tb.dbg_eip
			     << " linear=0x" << linear_ip << std::dec << "\n";
		}
		if (saw_boot_sector && linear_ip < 0x100000) {
			uint32_t page = linear_ip >> 12;
			if (page < boot_pages_seen.size() && !boot_pages_seen[page]) {
				boot_pages_seen[page] = true;
				if (boot_page_logs < 32) {
					boot_page_logs++;
					cout << cycle << ": exec page 0x" << std::hex << page
					     << " CS:EIP=" << tb.dbg_cs << ":" << tb.dbg_eip
					     << " linear=0x" << linear_ip
					     << " PE=" << static_cast<int>(tb.dbg_pe)
					     << std::dec << "\n";
				}
			}
		}

		if (!have_post || tb.dbg_post_code != last_post) {
			if (tb.dbg_post_code != 0) {
				last_post = tb.dbg_post_code;
				have_post = true;
				saw_post = true;
				cout << cycle << ": POST " << std::hex << static_cast<int>(last_post)
				     << " CS:EIP=" << tb.dbg_cs << ":" << tb.dbg_eip << std::dec << "\n";
			}
		}

		if (tb.active && !saw_first_instruction) {
			saw_first_instruction = true;
			cout << cycle << ": core active at " << std::hex << tb.dbg_cs << ":" << tb.dbg_eip << std::dec << "\n";
		}
	}

	if (trace) {
		trace->close();
		delete trace;
		trace = nullptr;
	}
	if (sdl_texture) SDL_DestroyTexture(sdl_texture);
	if (sdl_renderer) SDL_DestroyRenderer(sdl_renderer);
	if (sdl_window) SDL_DestroyWindow(sdl_window);
	if (!g_headless) SDL_Quit();

	if (!saw_first_instruction || !saw_post || !saw_video_sync) {
		cerr << "wrapper boot milestone not reached"
		     << " first_instruction=" << saw_first_instruction
		     << " post=" << saw_post
		     << " video_sync=" << saw_video_sync << "\n";
		return 2;
	}

	cout << "MiSTer wrapper harness reached POST " << std::hex
	     << static_cast<int>(last_post) << std::dec
	     << " with active video sync";
	if (saw_boot_menu_text) cout << " and boot menu text";
	if (saw_boot_sector) cout << " and boot sector fetch";
	if (saw_post_boot_exec) cout << " and post-boot execution";
	cout << "\n";
	if (saw_post_boot_exec && !saw_boot_menu_text) {
		dump_nonempty_rows(current_text_screen());
	}
	return 0;
}
