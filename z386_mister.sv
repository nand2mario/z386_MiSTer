`timescale 1ns / 1ns

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

localparam CLOCK_RATE_HZ = 85_000_000;

localparam CONF_STR = {
	"Z386;UART115200;",
	"S0,IMGIMAVFD,Floppy A:;",
	"S1,IMGIMAVFD,Floppy B:;",
	"O12,Write Protect,None,A:,B:,A: & B:;",
	"-;",
	"S2,VHD,IDE 0-0;",
	"S3,VHD,IDE 0-1;",
	"-;",
	"S4,VHDISOCUECHD,IDE 1-0;",
	"S5,VHDISOCUECHD,IDE 1-1;",
	"-;",
	"P1,Audio & Video;",
	"P1-;",
	"P1OMN,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1-;",
	"P1O3,FM mode,OPL2,OPL3;",
	"P1OH,C/MS,Disable,Enable;",
	"P1OIJ,PC Speaker Volume,1,2,3,4;",
	"P1OKL,Audio Boost,No,2x,4x;",
	"P1oBC,Stereo Mix,none,25%,50%,100%;",
	"P1oO,SB Swap L/R,Off,On;",
	"-;",
	"P2,Hardware;",
	"P2o01,Boot 1st,Floppy/Hard Disk,Floppy,Hard Disk,CD-ROM;",
	"P2o23,Boot 2nd,NONE,Floppy,Hard Disk,CD-ROM;",
	"P2o45,Boot 3rd,NONE,Floppy,Hard Disk,CD-ROM;",
	"P2-;",
	"P2o6,IDE 1-0 CD Hot-Swap,Yes,No;",
	"P2o7,IDE 1-1 CD Hot-Swap,No,Yes;",
	"-;",
	"R0,Reset and apply HDD;"
};

wire        clk_sys;
wire        clk_sdram;
wire        pll_locked;
wire        reset_async = RESET | ~pll_locked;
wire        core_soft_reset_req;
wire        reset_req = buttons[1] | status[0];
reg  [2:0]  reset_sync_r = 3'b111;

wire [127:0] status;
wire  [1:0] buttons;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;
wire [15:0] ps2_mouse_ext;
wire        ps2_kbd_clk_out;
wire        ps2_kbd_data_out;
wire        ps2_kbd_clk_in;
wire        ps2_kbd_data_in;
wire        ps2_mouse_clk_out;
wire        ps2_mouse_data_out;
wire        ps2_mouse_clk_in;
wire        ps2_mouse_data_in;

wire        core_ce_pixel;
wire  [7:0] core_r;
wire  [7:0] core_g;
wire  [7:0] core_b;
wire        core_hs;
wire        core_vs;
wire        core_de;
wire  [7:0] clean_r;
wire  [7:0] clean_g;
wire  [7:0] clean_b;
wire        clean_hs;
wire        clean_vs;
wire        clean_de;
wire  [7:0] gamma_r;
wire  [7:0] gamma_g;
wire  [7:0] gamma_b;
wire        gamma_hs;
wire        gamma_vs;
wire        gamma_de;
wire [15:0] core_audio_l;
wire [15:0] core_audio_r;
wire        core_active;
wire        core_bios_loaded;
wire        core_first_instruction;
wire  [7:0] core_dbg_uart_byte;
wire        core_dbg_uart_we;
wire  [8:0] sample_cms_l;
wire  [8:0] sample_cms_r;
wire [15:0] sample_sb_l;
wire [15:0] sample_sb_r;
wire [15:0] sample_opl_l;
wire [15:0] sample_opl_r;
wire        speaker_out;
wire        speaker_out_audio;
wire        sbp;
wire  [4:0] vol_master_l;
wire  [4:0] vol_master_r;
wire  [4:0] vol_voice_l;
wire  [4:0] vol_voice_r;
wire  [4:0] vol_cd_l;
wire  [4:0] vol_cd_r;
wire  [4:0] vol_midi_l;
wire  [4:0] vol_midi_r;
wire  [4:0] vol_line_l;
wire  [4:0] vol_line_r;
wire  [1:0] vol_spk;
wire  [4:0] vol_en;
reg  [16:0] spk_out;
reg  [16:0] mix_tmp_l;
reg  [16:0] mix_tmp_r;
reg  [15:0] mix_dry_l;
reg  [15:0] mix_dry_r;
reg  [15:0] core_audio_l_r;
reg  [15:0] core_audio_r_r;
wire        dummy_sd_clk;
wire        dummy_sd_cmd;
wire  [3:0] dummy_sd_dat;
wire  [8:0] unused_mouse_host_cmd;
wire [35:0] ext_bus;
wire [21:0] gamma_bus;
wire [12:0] arx;
wire [12:0] ary;
wire [15:0] status_menumask = 16'd0;
wire [127:0] status_in = 128'd0;
wire        status_set = 1'b0;
wire        info_req = 1'b0;
wire [7:0]  info = 8'd0;
wire [2:0]  ps2_kbd_led_status = 3'b000;
wire [2:0]  ps2_kbd_led_use = 3'b000;
wire        video_rotated = 1'b0;
wire        new_vmode = status[4];
wire [31:0] joystick_0;
wire [31:0] joystick_1;
wire [31:0] joystick_2;
wire [31:0] joystick_3;
wire [31:0] joystick_4;
wire [31:0] joystick_5;
wire [15:0] joystick_l_analog_0;
wire [15:0] joystick_l_analog_1;
wire [15:0] joystick_l_analog_2;
wire [15:0] joystick_l_analog_3;
wire [15:0] joystick_l_analog_4;
wire [15:0] joystick_l_analog_5;
wire [15:0] joystick_r_analog_0;
wire [15:0] joystick_r_analog_1;
wire [15:0] joystick_r_analog_2;
wire [15:0] joystick_r_analog_3;
wire [15:0] joystick_r_analog_4;
wire [15:0] joystick_r_analog_5;
wire [7:0]  paddle_0;
wire [7:0]  paddle_1;
wire [7:0]  paddle_2;
wire [7:0]  paddle_3;
wire [7:0]  paddle_4;
wire [7:0]  paddle_5;
wire [8:0]  spinner_0;
wire [8:0]  spinner_1;
wire [8:0]  spinner_2;
wire [8:0]  spinner_3;
wire [8:0]  spinner_4;
wire [8:0]  spinner_5;
wire        forced_scandoubler;
wire        direct_video;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wait;
wire        ioctl_upload;
wire        ioctl_rd;
wire [31:0] ioctl_file_ext;
wire [15:0] sdram_sz;
wire [64:0] rtc;
wire [32:0] timestamp;
wire [7:0]  uart_mode;
wire [31:0] uart_speed;
wire        debug_uart_tx;
wire        debug_uart_busy;
reg   [7:0] debug_uart_data;
reg         debug_uart_wr;
reg   [7:0] debug_uart_fifo [0:255];
reg   [7:0] debug_uart_fifo_wr;
reg   [7:0] debug_uart_fifo_rd;
reg   [8:0] debug_uart_fifo_count;
reg         debug_uart_enqueue;
reg         debug_uart_dequeue;
reg         debug_uart_banner_active;
reg   [4:0] debug_uart_banner_index;
reg         debug_uart_reset_d;
wire [15:0] mgmt_din;
wire [15:0] mgmt_dout;
wire [15:0] mgmt_addr;
wire        mgmt_rd;
wire        mgmt_wr;
wire  [7:0] mgmt_req;

function [7:0] debug_banner_char;
	input [4:0] index;
	begin
		case(index)
			5'd0:  debug_banner_char = "Z";
			5'd1:  debug_banner_char = "3";
			5'd2:  debug_banner_char = "8";
			5'd3:  debug_banner_char = "6";
			5'd4:  debug_banner_char = " ";
			5'd5:  debug_banner_char = "s";
			5'd6:  debug_banner_char = "t";
			5'd7:  debug_banner_char = "a";
			5'd8:  debug_banner_char = "r";
			5'd9:  debug_banner_char = "t";
			5'd10: debug_banner_char = 8'h0D;
			default: debug_banner_char = 8'h0A;
		endcase
	end
endfunction

assign gamma_bus = 'z;
pll pll
(
	.refclk   (CLK_50M),
	.rst      (1'b0),
	.outclk_0 (clk_sys),
	.outclk_1 (clk_sdram),
	.locked   (pll_locked)
);

always @(posedge clk_sys or posedge reset_async) begin
	if (reset_async)
		reset_sync_r <= 3'b111;
	else if (reset_req)
		reset_sync_r <= 3'b111;
	else
		reset_sync_r <= {reset_sync_r[1:0], 1'b0};
end

hps_io #(
	.CONF_STR(CONF_STR),
	.CONF_STR_BRAM(0),
	.PS2DIV(2000),
	.PS2WE(1),
	.WIDE(1)
) hps_io
(
	.clk_sys           (clk_sys),
	.HPS_BUS           (HPS_BUS),
	.joystick_0        (joystick_0),
	.joystick_1        (joystick_1),
	.joystick_2        (joystick_2),
	.joystick_3        (joystick_3),
	.joystick_4        (joystick_4),
	.joystick_5        (joystick_5),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.joystick_l_analog_2(joystick_l_analog_2),
	.joystick_l_analog_3(joystick_l_analog_3),
	.joystick_l_analog_4(joystick_l_analog_4),
	.joystick_l_analog_5(joystick_l_analog_5),
	.joystick_r_analog_0(joystick_r_analog_0),
	.joystick_r_analog_1(joystick_r_analog_1),
	.joystick_r_analog_2(joystick_r_analog_2),
	.joystick_r_analog_3(joystick_r_analog_3),
	.joystick_r_analog_4(joystick_r_analog_4),
	.joystick_r_analog_5(joystick_r_analog_5),
	.joystick_0_rumble (16'd0),
	.joystick_1_rumble (16'd0),
	.joystick_2_rumble (16'd0),
	.joystick_3_rumble (16'd0),
	.joystick_4_rumble (16'd0),
	.joystick_5_rumble (16'd0),
	.paddle_0          (paddle_0),
	.paddle_1          (paddle_1),
	.paddle_2          (paddle_2),
	.paddle_3          (paddle_3),
	.paddle_4          (paddle_4),
	.paddle_5          (paddle_5),
	.spinner_0         (spinner_0),
	.spinner_1         (spinner_1),
	.spinner_2         (spinner_2),
	.spinner_3         (spinner_3),
	.spinner_4         (spinner_4),
	.spinner_5         (spinner_5),
	.status            (status),
	.buttons           (buttons),
	.ps2_key           (ps2_key),
	.ps2_kbd_clk_out   (ps2_kbd_clk_out),
	.ps2_kbd_data_out  (ps2_kbd_data_out),
	.ps2_kbd_clk_in    (ps2_kbd_clk_in),
	.ps2_kbd_data_in   (ps2_kbd_data_in),
	.ps2_kbd_led_status(ps2_kbd_led_status),
	.ps2_kbd_led_use   (ps2_kbd_led_use),
	.ps2_mouse_clk_out (ps2_mouse_clk_out),
	.ps2_mouse_data_out(ps2_mouse_data_out),
	.ps2_mouse_clk_in  (ps2_mouse_clk_in),
	.ps2_mouse_data_in (ps2_mouse_data_in),
	.ps2_mouse         (ps2_mouse),
	.ps2_mouse_ext     (ps2_mouse_ext),
	.forced_scandoubler(forced_scandoubler),
	.direct_video      (direct_video),
	.video_rotated     (video_rotated),
	.new_vmode         (new_vmode),
	.gamma_bus         (gamma_bus),
	.status_in         (status_in),
	.status_set        (status_set),
	.status_menumask   (status_menumask),
	.info_req          (info_req),
	.info              (info),
	.ioctl_download    (ioctl_download),
	.ioctl_index       (ioctl_index),
	.ioctl_wr          (ioctl_wr),
	.ioctl_addr        (ioctl_addr),
	.ioctl_dout        (ioctl_dout),
	.ioctl_upload      (ioctl_upload),
	.ioctl_upload_req  (1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din         (16'd0),
	.ioctl_rd          (ioctl_rd),
	.ioctl_file_ext    (ioctl_file_ext),
	.ioctl_wait        (ioctl_wait),
	.sdram_sz          (sdram_sz),
	.RTC               (rtc),
	.TIMESTAMP         (timestamp),
	.uart_mode         (uart_mode),
	.uart_speed        (uart_speed),
	.EXT_BUS           (ext_bus)
);

hps_ext hps_ext
(
    .clk_sys           (clk_sys),
    .EXT_BUS           (ext_bus),

    .ext_din           (mgmt_din),
    .ext_dout          (mgmt_dout),
    .ext_addr          (mgmt_addr),
    .ext_rd            (mgmt_rd),
    .ext_wr            (mgmt_wr),

    .cdda_req          (1'b0),
    .cdda_wr           (),
    .cdda_dout         (),

    .ext_midi          (),
    .ext_req           (mgmt_req),
    .ext_hotswap       (status[39:38])
);

system #(
	.SYS_FREQ(CLOCK_RATE_HZ),
	.SDRAM_HAS_DQM(1'b0),
	.SDRAM_FAST_GRADE(1'b1)
) core (
	.clk_sys             (clk_sys),
	.reset               (reset_sync_r[2]),
	.hps_apply_reset     (status[0]),
	.software_reset      (core_soft_reset_req),
	.clock_rate          (CLOCK_RATE_HZ),

	.fdd_request         (mgmt_req[7:6]),
	.ide0_request        (mgmt_req[2:0]),
	.ide1_request        (mgmt_req[5:3]),
	.floppy_wp           (status[2:1]),

	.mgmt_address        (mgmt_addr),
	.mgmt_read           (mgmt_rd),
	.mgmt_readdata       (mgmt_din),
	.mgmt_write          (mgmt_wr),
	.mgmt_writedata      (mgmt_dout),

	.sdram_dq            (SDRAM_DQ),
	.sdram_a             (SDRAM_A),
	.sdram_ba            (SDRAM_BA),
	.sdram_dqm           ({SDRAM_DQMH, SDRAM_DQML}),
	.sdram_nwe           (SDRAM_nWE),
	.sdram_nras          (SDRAM_nRAS),
	.sdram_ncas          (SDRAM_nCAS),
	.sdram_ncs           (SDRAM_nCS),
	.sdram_cke           (SDRAM_CKE),
	.refresh_allowed     (1'b1),

	.ddram_busy          (DDRAM_BUSY),
	.ddram_burstcnt      (DDRAM_BURSTCNT),
	.ddram_addr          (DDRAM_ADDR),
	.ddram_dout          (DDRAM_DOUT),
	.ddram_dout_ready    (DDRAM_DOUT_READY),
	.ddram_rd            (DDRAM_RD),
	.ddram_din           (DDRAM_DIN),
	.ddram_be            (DDRAM_BE),
	.ddram_we            (DDRAM_WE),

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
	.img_lba             (),
	.img_blk_cnt         (),
	.img_rd              (),
	.img_wr              (),
	.img_ack             (1'b0),
	.img_buff_addr       (),
	.img_buff_din        (16'd0),
	.img_buff_dout       (),
	.img_buff_wr         (),

	.ps2_mouseclk_in     (ps2_mouse_clk_out),
	.ps2_mousedat_in     (ps2_mouse_data_out),
	.ps2_mouseclk_out    (ps2_mouse_clk_in),
	.ps2_mousedat_out    (ps2_mouse_data_in),
	.ps2_kbclk_in        (ps2_kbd_clk_out),
	.ps2_kbdat_in        (ps2_kbd_data_out),
	.ps2_kbclk_out       (ps2_kbd_clk_in),
	.ps2_kbdat_out       (ps2_kbd_data_in),
	.mouse_data          (8'd0),
	.mouse_data_valid    (1'b0),
	.mouse_host_cmd      (unused_mouse_host_cmd),
	.mouse_host_cmd_clear(1'b0),

	.dbg_uart_byte       (core_dbg_uart_byte),
	.dbg_uart_we         (core_dbg_uart_we),
	.dbg_sd_avm_address  (),
	.dbg_sd_avm_writedata(),
	.dbg_sd_avm_write    (),
	.dbg_sd_avm_wait     (),
	.dbg_sd_avm_accept   (),
	.dbg_mm_addr         (),
	.dbg_mm_din          (),
	.dbg_mm_dout         (),
	.dbg_mm_valid        (),
	.dbg_mm_write        (),
	.dbg_mm_ready        (),
	.dbg_mm_resp_valid   (),
	.dbg_mem_address     (),
	.dbg_mem_din         (),
	.dbg_mem_dout        (),
	.dbg_mem_valid       (),
	.dbg_mem_we          (),
	.dbg_mem_ready       (),
	.dbg_mem_resp_valid  (),
	.dbg_avm_address     (),
	.dbg_avm_readdata    (),
	.dbg_avm_ready       (),
	.dbg_avm_resp_valid  (),
	.dbg_cpu_din_z       (),

	.bootcfg             (status[37:32]),
	.uma_ram             (1'b0),
	.syscfg              (),

	.video_ce            (core_ce_pixel),
	.video_blank_n       (core_de),
	.video_hsync         (core_hs),
	.video_vsync         (core_vs),
	.video_r             (core_r),
	.video_g             (core_g),
	.video_b             (core_b),

	.clk_audio           (CLK_AUDIO),
	.sample_cms_l        (sample_cms_l),
	.sample_cms_r        (sample_cms_r),
	.sample_sb_l         (sample_sb_l),
	.sample_sb_r         (sample_sb_r),
	.sample_opl_l        (sample_opl_l),
	.sample_opl_r        (sample_opl_r),
	.sound_fm_mode       (status[3]),
	.sound_cms_en        (status[17]),
	.speaker_out         (speaker_out),
	.sbp                 (sbp),
	.vol_master_l        (vol_master_l),
	.vol_master_r        (vol_master_r),
	.vol_voice_l         (vol_voice_l),
	.vol_voice_r         (vol_voice_r),
	.vol_cd_l            (vol_cd_l),
	.vol_cd_r            (vol_cd_r),
	.vol_midi_l          (vol_midi_l),
	.vol_midi_r          (vol_midi_r),
	.vol_line_l          (vol_line_l),
	.vol_line_r          (vol_line_r),
	.vol_spk             (vol_spk),
	.vol_en              (vol_en),

	.debug_boot_stage    (),
	.debug_sd_error      (),
	.debug_bios_loaded   (core_bios_loaded),
	.debug_vga_bios_sig_bad(),
	.debug_vga_bios_sig_checked(),
	.debug_first_instruction(core_first_instruction),
	.debug_post_code     (),
	.debug_post_write    (),

	.cpu_pe              (),
	.cpu_vm              (),
	.cpu_cs              (),
	.cpu_eip             (),
	.cpu_cs_base         ()
	);

synchronizer speaker_out_sync (
	.clk(CLK_AUDIO),
	.in(speaker_out),
	.out(speaker_out_audio)
);

always @(posedge CLK_AUDIO) begin
	reg [16:0] spk;
	spk <= {2'b00, {3'b000, speaker_out_audio} << status[19:18], 11'd0};
	spk_out <= spk >> ~vol_spk;
end

wire [15:0] master_l;
wire [15:0] master_r;
wire [15:0] sb_l;
wire [15:0] sb_r;
wire [15:0] opl_l;
wire [15:0] opl_r;
wire        sb_volume_valid;
wire [15:0] mix_cmp_l;
wire [15:0] mix_cmp_r;
wire [15:0] mix_pre_l = status[21:20] ? mix_cmp_l : mix_dry_l;
wire [15:0] mix_pre_r = status[21:20] ? mix_cmp_r : mix_dry_r;

acompr acompr_l(CLK_AUDIO, status[21], mix_dry_l, mix_cmp_l);
acompr acompr_r(CLK_AUDIO, status[21], mix_dry_r, mix_cmp_r);

sb_volume #(.NUM_CH(6), .SAMPLE_WIDTH(16)) sb_volume_inst (
	.clk(CLK_AUDIO),
	.sbp(sbp),
	.volumes_in({vol_master_l, vol_master_r,
	             vol_voice_l,  vol_voice_r,
	             vol_midi_l,   vol_midi_r}),
	.samples_in({mix_pre_l,    mix_pre_r,
	             sample_sb_l,  sample_sb_r,
	             sample_opl_l, sample_opl_r}),
	.samples_out({master_l, master_r,
	              sb_l,     sb_r,
	              opl_l,    opl_r}),
	.valid(sb_volume_valid)
);

wire [15:0] sb_l_swap = status[56] ? sb_r : sb_l;
wire [15:0] sb_r_swap = status[56] ? sb_l : sb_r;

always @(posedge CLK_AUDIO) begin
	if (sb_volume_valid) begin
		core_audio_l_r <= master_l;
		core_audio_r_r <= master_r;

		mix_tmp_l <= spk_out
		           + {2'b00, sample_cms_l, sample_cms_l[8:4]}
		           + {sb_l_swap[15], sb_l_swap}
		           + {opl_l[15], opl_l};
		mix_tmp_r <= spk_out
		           + {2'b00, sample_cms_r, sample_cms_r[8:4]}
		           + {sb_r_swap[15], sb_r_swap}
		           + {opl_r[15], opl_r};
	end

	mix_dry_l <= (^mix_tmp_l[16:15]) ? {mix_tmp_l[16], {15{mix_tmp_l[15]}}} : mix_tmp_l[15:0];
	mix_dry_r <= (^mix_tmp_r[16:15]) ? {mix_tmp_r[16], {15{mix_tmp_r[15]}}} : mix_tmp_r[15:0];
end

assign core_audio_l = core_audio_l_r;
assign core_audio_r = core_audio_r_r;

always @(*) begin
	debug_uart_enqueue = 1'b0;
	debug_uart_dequeue = 1'b0;

	if (debug_uart_banner_active && debug_uart_fifo_count != 9'd256)
		debug_uart_enqueue = 1'b1;
	else if (core_dbg_uart_we && debug_uart_fifo_count != 9'd256)
		debug_uart_enqueue = 1'b1;

	if (!debug_uart_busy && !debug_uart_wr && debug_uart_fifo_count != 9'd0)
		debug_uart_dequeue = 1'b1;
end

always @(posedge clk_sys) begin
	if (reset_sync_r[2]) begin
		debug_uart_data <= 8'd0;
		debug_uart_wr <= 1'b0;
		debug_uart_fifo_wr <= 8'd0;
		debug_uart_fifo_rd <= 8'd0;
		debug_uart_fifo_count <= 9'd0;
		debug_uart_banner_active <= 1'b0;
		debug_uart_banner_index <= 5'd0;
		debug_uart_reset_d <= 1'b1;
	end else begin
		debug_uart_wr <= 1'b0;
		debug_uart_reset_d <= 1'b0;

		if (debug_uart_reset_d) begin
			debug_uart_banner_active <= 1'b1;
			debug_uart_banner_index <= 5'd0;
		end

		if (debug_uart_dequeue) begin
			debug_uart_data <= debug_uart_fifo[debug_uart_fifo_rd];
			debug_uart_fifo_rd <= debug_uart_fifo_rd + 8'd1;
			debug_uart_wr <= 1'b1;
		end

		if (debug_uart_enqueue) begin
			debug_uart_fifo[debug_uart_fifo_wr] <= debug_uart_banner_active ? debug_banner_char(debug_uart_banner_index) : core_dbg_uart_byte;
			debug_uart_fifo_wr <= debug_uart_fifo_wr + 8'd1;
			if (debug_uart_banner_active) begin
				if (debug_uart_banner_index == 5'd11)
					debug_uart_banner_active <= 1'b0;
				debug_uart_banner_index <= debug_uart_banner_index + 5'd1;
			end
		end

		case ({debug_uart_enqueue, debug_uart_dequeue})
			2'b10: debug_uart_fifo_count <= debug_uart_fifo_count + 9'd1;
			2'b01: debug_uart_fifo_count <= debug_uart_fifo_count - 9'd1;
			default: debug_uart_fifo_count <= debug_uart_fifo_count;
		endcase
	end
end

uart_tx_V2 debug_uart_tx_i
(
	.clk                (clk_sys),
	.din                (debug_uart_data),
	.wr_en              (debug_uart_wr),
	.tx_busy            (debug_uart_busy),
	.tx_p               (debug_uart_tx)
);
defparam debug_uart_tx_i.clk_freq = CLOCK_RATE_HZ;
defparam debug_uart_tx_i.uart_freq = 115200;

// ao486 runs the raw VGA stream through the MiSTer helper blocks before handing
// it to sys_top. Do the same here instead of feeding raw sync/DE directly.
video_cleaner video_cleaner
(
	.clk_vid            (clk_sys),
	.ce_pix             (core_ce_pixel),

	.R                  (core_r),
	.G                  (core_g),
	.B                  (core_b),

	.HSync              (core_hs),
	.VSync              (core_vs),
	.DE_in              (core_de),

	.VGA_R              (clean_r),
	.VGA_G              (clean_g),
	.VGA_B              (clean_b),
	.VGA_VS             (clean_vs),
	.VGA_HS             (clean_hs),
	.DE_out             (clean_de)
);

gamma_fast gamma
(
	.clk_vid            (clk_sys),
	.ce_pix             (core_ce_pixel),

	.gamma_bus          (gamma_bus),

	.HSync              (clean_hs),
	.VSync              (clean_vs),
	.DE                 (clean_de),
	.RGB_in             ({clean_r, clean_g, clean_b}),

	.HSync_out          (gamma_hs),
	.VSync_out          (gamma_vs),
	.DE_out             (gamma_de),
	.RGB_out            ({gamma_r, gamma_g, gamma_b})
);

reg  [2:0] ar;
reg [11:0] arx_i;
reg [11:0] ary_i;
always @(posedge clk_sys) begin
	ar    <= status[23:22];
	arx_i <= (!ar) ? 12'd4 : (ar - 1'd1);
	ary_i <= (!ar) ? 12'd3 : 12'd0;
end

video_freak video_freak
(
	.CLK_VIDEO          (clk_sys),
	.CE_PIXEL           (core_ce_pixel),
	.VGA_VS             (gamma_vs),
	.HDMI_WIDTH         (HDMI_WIDTH),
	.HDMI_HEIGHT        (HDMI_HEIGHT),
	.VGA_DE             (),
	.VIDEO_ARX          (arx),
	.VIDEO_ARY          (ary),
	.VGA_DE_IN          (gamma_de),
	.ARX                (arx_i),
	.ARY                (ary_i),
	.CROP_SIZE          (12'd0),
	.CROP_OFF           (5'd0),
	.SCALE              (3'd0)
);

assign CLK_VIDEO     = clk_sys;
assign CE_PIXEL      = core_ce_pixel;
assign VIDEO_ARX     = arx;
assign VIDEO_ARY     = ary;
assign VGA_R         = gamma_r;
assign VGA_G         = gamma_g;
assign VGA_B         = gamma_b;
assign VGA_HS        = gamma_hs;
assign VGA_VS        = gamma_vs;
assign VGA_DE        = gamma_de;
assign VGA_F1        = 1'b0;
assign VGA_SL        = 2'b00;
assign VGA_SCALER    = 1'b1;
assign VGA_DISABLE   = 1'b0;
assign HDMI_FREEZE   = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;
`ifdef MISTER_FB
assign FB_EN         = 1'b0;
assign FB_FORMAT     = 5'd0;
assign FB_WIDTH      = 12'd0;
assign FB_HEIGHT     = 12'd0;
assign FB_BASE       = 32'd0;
assign FB_STRIDE     = 14'd0;
assign FB_FORCE_BLANK = 1'b0;
`ifdef MISTER_FB_PALETTE
assign FB_PAL_CLK    = 1'b0;
assign FB_PAL_ADDR   = 8'd0;
assign FB_PAL_DOUT   = 24'd0;
assign FB_PAL_WR     = 1'b0;
`endif
`endif

assign LED_USER      = pll_locked;
assign LED_POWER     = {1'b1, core_bios_loaded};
assign LED_DISK      = {1'b1, core_first_instruction};
assign BUTTONS       = {core_soft_reset_req, 1'b0};

assign AUDIO_L       = core_audio_l;
assign AUDIO_R       = core_audio_r;
assign AUDIO_S       = 1'b1;
assign AUDIO_MIX     = status[44:43];

assign ADC_BUS       = 4'bzzzz;

assign SD_SCK        = 1'bz;
assign SD_MOSI       = 1'bz;
assign SD_CS         = 1'bz;

assign DDRAM_CLK     = clk_sys;
assign SDRAM_CLK     = clk_sdram;

assign UART_RTS      = 1'b0;
assign UART_TXD      = debug_uart_tx;
assign UART_DTR      = 1'b0;
assign USER_OUT      = 7'h7F;

endmodule

module acompr
(
	input             clk,
	input             mode,
	input      [15:0] inp,
	output reg [15:0] out
);

localparam [3:0] comp_f1 = 4;
localparam [3:0] comp_a1 = 2;
localparam       comp_x1 = ((32767 * (comp_f1 - 1)) / ((comp_f1 * comp_a1) - 1)) + 1;
localparam       comp_b1 = comp_x1 * comp_a1;

localparam [3:0] comp_f2 = 8;
localparam [3:0] comp_a2 = 4;
localparam       comp_x2 = ((32767 * (comp_f2 - 1)) / ((comp_f2 * comp_a2) - 1)) + 1;
localparam       comp_b2 = comp_x2 * comp_a2;

always @(posedge clk) begin
	reg [15:0] v, v1, v2, v3;
	reg vs, vs1, vs3;

	v   <= inp[15] ? -inp : inp;
	vs  <= inp[15];

	v1  <= (v < comp_x1[15:0]) ? (v * comp_a1) : (((v - comp_x1[15:0])/comp_f1) + comp_b1[15:0]);
	v2  <= (v < comp_x2[15:0]) ? (v * comp_a2) : (((v - comp_x2[15:0])/comp_f2) + comp_b2[15:0]);
	vs1 <= vs;

	v3  <= mode ? v2 : v1;
	vs3 <= vs1;

	out <= vs3 ? -v3 : v3;
end

endmodule
