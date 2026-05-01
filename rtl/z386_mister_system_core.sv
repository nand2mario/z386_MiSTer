`timescale 1ns / 1ns

module z386_mister_system_core (
	input         clk_sys,
	input         reset,
	input         clk_audio,

	input  [63:0] status,
	input  [10:0] ps2_key,
	input         ps2_mouse_clk_out,
	input         ps2_mouse_data_out,
	output        ps2_mouse_clk_in,
	output        ps2_mouse_data_in,
	input   [7:0] sim_kbd_data,
	input         sim_kbd_data_valid,
	output  [8:0] sim_kbd_host_data,
	input         sim_kbd_host_data_clear,
	input         sim_soft_reset,

	input         ioctl_download,
	input  [15:0] ioctl_index,
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	output        ioctl_wait,

	inout  [15:0] sdram_dq,
	output [12:0] sdram_a,
	output  [1:0] sdram_ba,
	output  [1:0] sdram_dqm,
	output        sdram_nwe,
	output        sdram_nras,
	output        sdram_ncas,
	output        sdram_ncs,
	output        sdram_cke,

	input         ddram_busy,
	output  [7:0] ddram_burstcnt,
	output [28:0] ddram_addr,
	input  [63:0] ddram_dout,
	input         ddram_dout_ready,
	output        ddram_rd,
	output [63:0] ddram_din,
	output  [7:0] ddram_be,
	output        ddram_we,

	output        ce_pixel,
	output  [7:0] video_r,
	output  [7:0] video_g,
	output  [7:0] video_b,
	output        video_hs,
	output        video_vs,
	output        video_de,
	output [15:0] audio_l,
	output [15:0] audio_r,
	output        active,
	output        debug_bios_loaded_o,
	output        debug_first_instruction_o,

    input  [15:0] mgmt_address,
    input         mgmt_read,
    input         mgmt_write,
    input  [15:0] mgmt_writedata,
    output [15:0] mgmt_readdata,
    output [1:0]  fdd_request,
    output [2:0]  ide0_request,
    output [2:0]  ide1_request,

	output [15:0] dbg_cs,
	output [31:0] dbg_eip,
	output [31:0] dbg_cs_base,
	output        dbg_pe,
	output  [7:0] dbg_post_code,
	output  [7:0] dbg_uart_byte,
	output        dbg_uart_we,
	output        soft_reset_req
);

parameter [27:0] CLOCK_RATE_HZ = 28'd50_000_000;

wire        software_reset;
reg  [7:0]  software_reset_count;
wire        core_reset = reset | (software_reset_count != 8'd0);
assign soft_reset_req = software_reset;

wire  [7:0] syscfg;

reg   [7:0] kbd_data;
reg         kbd_data_valid;
reg   [7:0] mouse_data;
reg         mouse_data_valid;
wire  [8:0] kbd_host_data;
wire  [8:0] mouse_host_cmd;
wire        kbd_host_data_clear;
wire        mouse_host_cmd_clear = mouse_host_cmd[8];

reg         ps2_key_stb_r;
reg  [23:0] kbd_bytes_r;
reg   [1:0] kbd_count_r;
reg  [23:0] kbd_reply_bytes_r;
reg   [1:0] kbd_reply_count_r;
reg  [31:0] mouse_reply_bytes_r;
reg   [2:0] mouse_reply_count_r;
reg   [7:0] pending_mouse_cmd_r;
reg         pending_mouse_arg_r;

`ifndef VERILATOR
reg         kbd_host_data_clear_r;
reg         kbd_host_seen_r;
reg   [7:0] pending_kbd_cmd_r;
reg         pending_kbd_arg_r;
reg   [1:0] ps2_kbd_scan_set_r;
`endif

wire [15:0] sample_sb_l;
wire [15:0] sample_sb_r;
wire [15:0] sample_opl_l;
wire [15:0] sample_opl_r;
wire        speaker_out;
wire  [4:0] vol_l;
wire  [4:0] vol_r;
wire  [4:0] vol_cd_l;
wire  [4:0] vol_cd_r;
wire  [4:0] vol_midi_l;
wire  [4:0] vol_midi_r;
wire  [4:0] vol_line_l;
wire  [4:0] vol_line_r;
wire  [1:0] vol_spk;
wire  [4:0] vol_en;

wire [31:0] dbg_sd_avm_address;
wire [31:0] dbg_sd_avm_writedata;
wire        dbg_sd_avm_write;
wire        dbg_sd_avm_wait;
wire        dbg_sd_avm_accept;
wire [31:0] dbg_mm_addr;
wire [31:0] dbg_mm_din;
wire [31:0] dbg_mm_dout;
wire        dbg_mm_valid;
wire        dbg_mm_write;
wire        dbg_mm_ready;
wire        dbg_mm_resp_valid;
wire [31:0] dbg_mem_address;
wire [31:0] dbg_mem_din;
wire [31:0] dbg_mem_dout;
wire        dbg_mem_valid;
wire        dbg_mem_we;
wire        dbg_mem_ready;
wire        dbg_mem_resp_valid;
wire [31:0] dbg_avm_address;
wire [31:0] dbg_avm_readdata;
wire        dbg_avm_ready;
wire        dbg_avm_resp_valid;
wire [31:0] dbg_cpu_din_z;
wire  [2:0] debug_boot_stage;
wire        debug_sd_error;
wire        debug_bios_loaded;
wire        debug_vga_bios_sig_bad;
wire        debug_vga_bios_sig_checked;
wire        debug_first_instruction;
wire        debug_post_write;
wire  [7:0] dbg_uart_byte_w;
wire        dbg_uart_we_w;
wire        video_ce;
wire        video_blank_n;
wire        video_hsync;
wire        video_vsync;
wire  [7:0] video_r_w;
wire  [7:0] video_g_w;
wire  [7:0] video_b_w;
wire        dummy_sd_clk;
wire        dummy_sd_cmd;
wire  [3:0] dummy_sd_dat;

assign sim_kbd_host_data = kbd_host_data;
`ifdef VERILATOR
assign kbd_host_data_clear = sim_kbd_host_data_clear;
`else
assign kbd_host_data_clear = kbd_host_data_clear_r;
`endif

assign active = debug_first_instruction | debug_post_write | kbd_data_valid;

always @(posedge clk_sys) begin
	if (reset) begin
		software_reset_count <= 8'd0;
`ifdef VERILATOR
	end else if (software_reset | sim_soft_reset) begin
`else
	end else if (sim_soft_reset) begin
`endif
		software_reset_count <= 8'hff;
	end else if (software_reset_count != 8'd0) begin
		software_reset_count <= software_reset_count - 8'd1;
	end
end

always @(posedge clk_sys) begin
	kbd_data_valid <= 1'b0;
	mouse_data_valid <= 1'b0;

	if (reset) begin
		ps2_key_stb_r <= ps2_key[10];
		kbd_bytes_r <= 24'd0;
		kbd_count_r <= 2'd0;
		kbd_reply_bytes_r <= 24'd0;
		kbd_reply_count_r <= 2'd0;
		kbd_data <= 8'd0;
		mouse_reply_bytes_r <= 32'd0;
		mouse_reply_count_r <= 3'd0;
		pending_mouse_cmd_r <= 8'd0;
		pending_mouse_arg_r <= 1'b0;
		mouse_data <= 8'd0;
`ifndef VERILATOR
		kbd_host_data_clear_r <= 1'b0;
		kbd_host_seen_r <= 1'b0;
		pending_kbd_cmd_r <= 8'd0;
		pending_kbd_arg_r <= 1'b0;
		ps2_kbd_scan_set_r <= 2'd2;
`endif
	end else begin
`ifndef VERILATOR
		kbd_host_data_clear_r <= 1'b0;

		if (kbd_host_data[8] && !kbd_host_seen_r) begin
			kbd_host_seen_r <= 1'b1;
			kbd_host_data_clear_r <= 1'b1;

			if (!pending_kbd_arg_r) begin
				pending_kbd_cmd_r <= kbd_host_data[7:0];
				case (kbd_host_data[7:0])
					8'hFF: begin
						ps2_kbd_scan_set_r <= 2'd2;
						kbd_reply_bytes_r <= {8'h00, 8'hAA, 8'hFA};
						kbd_reply_count_r <= 2'd2;
						pending_kbd_cmd_r <= 8'd0;
					end
					8'hF2: begin
						kbd_reply_bytes_r <= {8'h83, 8'hAB, 8'hFA};
						kbd_reply_count_r <= 2'd3;
						pending_kbd_cmd_r <= 8'd0;
					end
					8'hF0,
					8'hF3,
					8'hED: begin
						kbd_reply_bytes_r <= {16'd0, 8'hFA};
						kbd_reply_count_r <= 2'd1;
						pending_kbd_arg_r <= 1'b1;
					end
					8'hF6: begin
						ps2_kbd_scan_set_r <= 2'd2;
						kbd_reply_bytes_r <= {16'd0, 8'hFA};
						kbd_reply_count_r <= 2'd1;
						pending_kbd_cmd_r <= 8'd0;
					end
					8'hF4,
					8'hF5,
					8'hFA: begin
						kbd_reply_bytes_r <= {16'd0, 8'hFA};
						kbd_reply_count_r <= 2'd1;
						pending_kbd_cmd_r <= 8'd0;
					end
					8'hEE: begin
						kbd_reply_bytes_r <= {16'd0, 8'hEE};
						kbd_reply_count_r <= 2'd1;
						pending_kbd_cmd_r <= 8'd0;
					end
					default: begin
						kbd_reply_bytes_r <= {16'd0, 8'hFE};
						kbd_reply_count_r <= 2'd1;
						pending_kbd_cmd_r <= 8'd0;
					end
				endcase
			end else begin
				case (pending_kbd_cmd_r)
					8'hED: begin
						kbd_reply_bytes_r <= {16'd0, 8'hFA};
						kbd_reply_count_r <= 2'd1;
					end
					8'hF0: begin
						if (kbd_host_data[7:0] <= 8'd3) begin
							if (kbd_host_data[7:0] == 8'd0) begin
								kbd_reply_bytes_r <= {8'd0, {6'd0, ps2_kbd_scan_set_r}, 8'hFA};
								kbd_reply_count_r <= 2'd2;
							end else begin
								ps2_kbd_scan_set_r <= kbd_host_data[1:0];
								kbd_reply_bytes_r <= {16'd0, 8'hFA};
								kbd_reply_count_r <= 2'd1;
							end
						end else begin
							kbd_reply_bytes_r <= {16'd0, 8'hFE};
							kbd_reply_count_r <= 2'd1;
						end
					end
					8'hF3: begin
						kbd_reply_bytes_r <= {16'd0, 8'hFA};
						kbd_reply_count_r <= 2'd1;
					end
					default: begin
						kbd_reply_bytes_r <= {16'd0, 8'hFE};
						kbd_reply_count_r <= 2'd1;
					end
				endcase
				pending_kbd_cmd_r <= 8'd0;
				pending_kbd_arg_r <= 1'b0;
			end
		end else if (!kbd_host_data[8]) begin
			kbd_host_seen_r <= 1'b0;
		end
`endif

		if (mouse_reply_count_r != 3'd0) begin
			mouse_data <= mouse_reply_bytes_r[7:0];
			mouse_data_valid <= 1'b1;
			mouse_reply_bytes_r <= {8'd0, mouse_reply_bytes_r[31:8]};
			mouse_reply_count_r <= mouse_reply_count_r - 3'd1;
		end else if (mouse_host_cmd[8]) begin
			if (pending_mouse_arg_r) begin
				mouse_reply_bytes_r <= {24'd0, 8'hFA};
				mouse_reply_count_r <= 3'd1;
				pending_mouse_cmd_r <= 8'd0;
				pending_mouse_arg_r <= 1'b0;
			end else begin
				pending_mouse_cmd_r <= mouse_host_cmd[7:0];
				case (mouse_host_cmd[7:0])
					8'hFF: begin
						// Reset: ACK, BAT OK, standard PS/2 mouse ID.
						mouse_reply_bytes_r <= {8'd0, 8'h00, 8'hAA, 8'hFA};
						mouse_reply_count_r <= 3'd3;
						pending_mouse_cmd_r <= 8'd0;
					end
					8'hF2: begin
						// Identify: ACK, standard PS/2 mouse ID.
						mouse_reply_bytes_r <= {16'd0, 8'h00, 8'hFA};
						mouse_reply_count_r <= 3'd2;
						pending_mouse_cmd_r <= 8'd0;
					end
					8'hE9: begin
						// Status request: ACK, status, resolution, sample rate.
						mouse_reply_bytes_r <= {8'h64, 8'h02, 8'h00, 8'hFA};
						mouse_reply_count_r <= 3'd4;
						pending_mouse_cmd_r <= 8'd0;
					end
					8'hEB: begin
						// Read data: ACK plus a neutral three-byte packet.
						mouse_reply_bytes_r <= {8'h00, 8'h00, 8'h08, 8'hFA};
						mouse_reply_count_r <= 3'd4;
						pending_mouse_cmd_r <= 8'd0;
					end
					8'hE8,
					8'hF3: begin
						// Resolution/sample-rate commands consume one parameter.
						mouse_reply_bytes_r <= {24'd0, 8'hFA};
						mouse_reply_count_r <= 3'd1;
						pending_mouse_arg_r <= 1'b1;
					end
					default: begin
						mouse_reply_bytes_r <= {24'd0, 8'hFA};
						mouse_reply_count_r <= 3'd1;
						pending_mouse_cmd_r <= 8'd0;
					end
				endcase
			end
		end

		if (sim_kbd_data_valid) begin
			kbd_data <= sim_kbd_data;
			kbd_data_valid <= 1'b1;
		end else if (kbd_reply_count_r != 2'd0) begin
			kbd_data <= kbd_reply_bytes_r[7:0];
			kbd_data_valid <= 1'b1;
			kbd_reply_bytes_r <= {8'd0, kbd_reply_bytes_r[23:8]};
			kbd_reply_count_r <= kbd_reply_count_r - 2'd1;
		end else if (kbd_count_r != 2'd0) begin
			kbd_data <= kbd_bytes_r[7:0];
			kbd_data_valid <= 1'b1;
			kbd_bytes_r <= {8'd0, kbd_bytes_r[23:8]};
			kbd_count_r <= kbd_count_r - 2'd1;
		end else if (ps2_key_stb_r != ps2_key[10]) begin
			ps2_key_stb_r <= ps2_key[10];

			if (ps2_key[8] && ps2_key[9]) begin
				kbd_bytes_r <= {8'd0, ps2_key[7:0], 8'hE0};
				kbd_count_r <= 2'd2;
			end else if (ps2_key[8] && !ps2_key[9]) begin
				kbd_bytes_r <= {ps2_key[7:0], 8'hF0, 8'hE0};
				kbd_count_r <= 2'd3;
			end else if (!ps2_key[8] && ps2_key[9]) begin
				kbd_bytes_r <= {16'd0, ps2_key[7:0]};
				kbd_count_r <= 2'd1;
			end else begin
				kbd_bytes_r <= {8'd0, ps2_key[7:0], 8'hF0};
				kbd_count_r <= 2'd2;
			end
		end
	end
end

system #(
	.SYS_FREQ(CLOCK_RATE_HZ),
	.SDRAM_HAS_DQM(1'b0),
	.SDRAM_FAST_GRADE(1'b1)
) system_i (
	.clk_sys             (clk_sys),
	.reset               (core_reset),
	.hps_apply_reset     (status[0]),
	.software_reset      (software_reset),
	.clock_rate          (CLOCK_RATE_HZ),

	.fdd_request         (fdd_request),
	.ide0_request        (ide0_request),
	.ide1_request        (ide1_request),
	.floppy_wp           (2'b00),

    .mgmt_address        (mgmt_address),
    .mgmt_read           (mgmt_read),
    .mgmt_readdata       (mgmt_readdata),
    .mgmt_write          (mgmt_write),
    .mgmt_writedata      (mgmt_writedata),

	.sdram_dq            (sdram_dq),
	.sdram_a             (sdram_a),
	.sdram_ba            (sdram_ba),
	.sdram_dqm           (sdram_dqm),
	.sdram_nwe           (sdram_nwe),
	.sdram_nras          (sdram_nras),
	.sdram_ncas          (sdram_ncas),
	.sdram_ncs           (sdram_ncs),
	.sdram_cke           (sdram_cke),

	.ddram_busy          (ddram_busy),
	.ddram_burstcnt      (ddram_burstcnt),
	.ddram_addr          (ddram_addr),
	.ddram_dout          (ddram_dout),
	.ddram_dout_ready    (ddram_dout_ready),
	.ddram_rd            (ddram_rd),
	.ddram_din           (ddram_din),
	.ddram_be            (ddram_be),
	.ddram_we            (ddram_we),

	.refresh_allowed     (1'b1),

	.sd_clk              (dummy_sd_clk),
	.sd_cmd              (dummy_sd_cmd),
	.sd_dat              (dummy_sd_dat),

	.ioctl_download      (ioctl_download),
	.ioctl_index         (ioctl_index),
	.ioctl_wr            (ioctl_wr),
	.ioctl_addr          (ioctl_addr),
	.ioctl_dout          (ioctl_dout),
	.ioctl_wait          (ioctl_wait),
	.img_mounted         (1'b0),
	.img_readonly        (1'b0),
	.img_size            (64'd0),
	.img_ack             (1'b0),
	.img_buff_din        (16'd0),

	.kbd_data            (kbd_data),
	.kbd_data_valid      (kbd_data_valid),
	.kbd_host_data       (kbd_host_data),
	.kbd_host_data_clear (kbd_host_data_clear),

	.ps2_mouseclk_in     (ps2_mouse_clk_out),
	.ps2_mousedat_in     (ps2_mouse_data_out),
	.ps2_mouseclk_out    (ps2_mouse_clk_in),
	.ps2_mousedat_out    (ps2_mouse_data_in),
	.mouse_data          (mouse_data),
	.mouse_data_valid    (mouse_data_valid),
	.mouse_host_cmd      (mouse_host_cmd),
	.mouse_host_cmd_clear(mouse_host_cmd_clear),

	.dbg_uart_byte       (dbg_uart_byte_w),
	.dbg_uart_we         (dbg_uart_we_w),

	.dbg_sd_avm_address  (dbg_sd_avm_address),
	.dbg_sd_avm_writedata(dbg_sd_avm_writedata),
	.dbg_sd_avm_write    (dbg_sd_avm_write),
	.dbg_sd_avm_wait     (dbg_sd_avm_wait),
	.dbg_sd_avm_accept   (dbg_sd_avm_accept),
	.dbg_mm_addr         (dbg_mm_addr),
	.dbg_mm_din          (dbg_mm_din),
	.dbg_mm_dout         (dbg_mm_dout),
	.dbg_mm_valid        (dbg_mm_valid),
	.dbg_mm_write        (dbg_mm_write),
	.dbg_mm_ready        (dbg_mm_ready),
	.dbg_mm_resp_valid   (dbg_mm_resp_valid),
	.dbg_mem_address     (dbg_mem_address),
	.dbg_mem_din         (dbg_mem_din),
	.dbg_mem_dout        (dbg_mem_dout),
	.dbg_mem_valid       (dbg_mem_valid),
	.dbg_mem_we          (dbg_mem_we),
	.dbg_mem_ready       (dbg_mem_ready),
	.dbg_mem_resp_valid  (dbg_mem_resp_valid),
	.dbg_avm_address     (dbg_avm_address),
	.dbg_avm_readdata    (dbg_avm_readdata),
	.dbg_avm_ready       (dbg_avm_ready),
	.dbg_avm_resp_valid  (dbg_avm_resp_valid),
	.dbg_cpu_din_z       (dbg_cpu_din_z),

	.bootcfg             ({4'd0, status[2:1]}),
	.uma_ram             (1'b0),
	.syscfg              (syscfg),

	.video_ce            (video_ce),
	.video_blank_n       (video_blank_n),
	.video_hsync         (video_hsync),
	.video_vsync         (video_vsync),
	.video_r             (video_r_w),
	.video_g             (video_g_w),
	.video_b             (video_b_w),

	.clk_audio           (clk_audio),
	.sample_sb_l         (sample_sb_l),
	.sample_sb_r         (sample_sb_r),
	.sample_opl_l        (sample_opl_l),
	.sample_opl_r        (sample_opl_r),
	.sound_fm_mode       (1'b1),
	.sound_cms_en        (1'b0),
	.speaker_out         (speaker_out),
	.vol_l               (vol_l),
	.vol_r               (vol_r),
	.vol_cd_l            (vol_cd_l),
	.vol_cd_r            (vol_cd_r),
	.vol_midi_l          (vol_midi_l),
	.vol_midi_r          (vol_midi_r),
	.vol_line_l          (vol_line_l),
	.vol_line_r          (vol_line_r),
	.vol_spk             (vol_spk),
	.vol_en              (vol_en),

	.debug_boot_stage    (debug_boot_stage),
	.debug_sd_error      (debug_sd_error),
	.debug_bios_loaded   (debug_bios_loaded),
	.debug_vga_bios_sig_bad(debug_vga_bios_sig_bad),
	.debug_vga_bios_sig_checked(debug_vga_bios_sig_checked),
	.debug_first_instruction(debug_first_instruction),
	.debug_post_code     (dbg_post_code),
	.debug_post_write    (debug_post_write),

	.cpu_pe              (dbg_pe),
	.cpu_cs              (dbg_cs),
	.cpu_eip             (dbg_eip),
	.cpu_cs_base         (dbg_cs_base)
);

reg [16:0] spk_mix;
reg [16:0] tmp_l;
reg [16:0] tmp_r;
reg [15:0] audio_l_r;
reg [15:0] audio_r_r;

always @(posedge clk_audio) begin
	spk_mix <= speaker_out ? 17'sh0400 : 17'sh0000;
	tmp_l <= {sample_opl_l[15], sample_opl_l} + {sample_sb_l[15], sample_sb_l} + spk_mix;
	tmp_r <= {sample_opl_r[15], sample_opl_r} + {sample_sb_r[15], sample_sb_r} + spk_mix;
	audio_l_r <= (^tmp_l[16:15]) ? {tmp_l[16], {15{tmp_l[15]}}} : tmp_l[15:0];
	audio_r_r <= (^tmp_r[16:15]) ? {tmp_r[16], {15{tmp_r[15]}}} : tmp_r[15:0];
end

assign audio_l = audio_l_r;
assign audio_r = audio_r_r;

assign ce_pixel = video_ce;
assign video_r = video_r_w;
assign video_g = video_g_w;
assign video_b = video_b_w;
assign video_hs = video_hsync;
assign video_vs = video_vsync;
assign video_de = video_blank_n;
assign dbg_uart_byte = dbg_uart_byte_w;
assign dbg_uart_we = dbg_uart_we_w;
assign debug_bios_loaded_o = debug_bios_loaded;
assign debug_first_instruction_o = debug_first_instruction;

endmodule
