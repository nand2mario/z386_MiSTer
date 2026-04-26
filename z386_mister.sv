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
	"-;",
	"S2,VHD,IDE 0-0;",
	"S3,VHD,IDE 0-1;",
	"-;",
	"S4,VHDISOCUECHD,IDE 1-0;",
	"S5,VHDISOCUECHD,IDE 1-1;",
	"-;",
	"R0,Reset;"
};

wire        clk_sys;
wire        clk_sdram;
wire        pll_locked;
wire        reset_async = RESET | ~pll_locked;
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
wire [35:0] ext_bus;
wire [21:0] gamma_bus;
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
    .ext_hotswap       (2'b00)
);

z386_mister_system_core #(
	.CLOCK_RATE_HZ(CLOCK_RATE_HZ)
) core (
	.clk_sys            (clk_sys),
	.reset              (reset_sync_r[2]),
	.clk_audio          (CLK_AUDIO),
	.status             (status[63:0]),
	.ps2_key            (ps2_key),
	.sim_kbd_data       (8'd0),
	.sim_kbd_data_valid (1'b0),
	.sim_kbd_host_data  (),
	.sim_kbd_host_data_clear(1'b0),
	.ioctl_download     (ioctl_download),
	.ioctl_index        (ioctl_index),
	.ioctl_wr           (ioctl_wr),
	.ioctl_addr         (ioctl_addr),
	.ioctl_dout         (ioctl_dout),
	.ioctl_wait         (ioctl_wait),
	.mgmt_address       (mgmt_addr),
	.mgmt_read          (mgmt_rd),
	.mgmt_write         (mgmt_wr),
	.mgmt_writedata     (mgmt_dout),
	.mgmt_readdata      (mgmt_din),
	.fdd_request        (mgmt_req[7:6]),
	.ide0_request       (mgmt_req[2:0]),
	.ide1_request       (mgmt_req[5:3]),
	.sdram_dq           (SDRAM_DQ),
	.sdram_a            (SDRAM_A),
	.sdram_ba           (SDRAM_BA),
	.sdram_dqm          ({SDRAM_DQMH, SDRAM_DQML}),
	.sdram_nwe          (SDRAM_nWE),
	.sdram_nras         (SDRAM_nRAS),
	.sdram_ncas         (SDRAM_nCAS),
	.sdram_ncs          (SDRAM_nCS),
	.sdram_cke          (SDRAM_CKE),

	.ddram_busy         (DDRAM_BUSY),
	.ddram_burstcnt     (DDRAM_BURSTCNT),
	.ddram_addr         (DDRAM_ADDR),
	.ddram_dout         (DDRAM_DOUT),
	.ddram_dout_ready   (DDRAM_DOUT_READY),
	.ddram_rd           (DDRAM_RD),
	.ddram_din          (DDRAM_DIN),
	.ddram_be           (DDRAM_BE),
	.ddram_we           (DDRAM_WE),

	.ce_pixel           (core_ce_pixel),
	.video_r            (core_r),
	.video_g            (core_g),
	.video_b            (core_b),
	.video_hs           (core_hs),
	.video_vs           (core_vs),
	.video_de           (core_de),
	.audio_l            (core_audio_l),
	.audio_r            (core_audio_r),
	.active             (core_active),
	.debug_bios_loaded_o(core_bios_loaded),
	.debug_first_instruction_o(core_first_instruction),
	.dbg_uart_byte      (core_dbg_uart_byte),
	.dbg_uart_we        (core_dbg_uart_we)
);

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

assign CLK_VIDEO     = clk_sys;
assign CE_PIXEL      = core_ce_pixel;
assign VIDEO_ARX     = 13'd4;
assign VIDEO_ARY     = 13'd3;
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
assign BUTTONS       = 2'b00;

assign AUDIO_L       = core_audio_l;
assign AUDIO_R       = core_audio_r;
assign AUDIO_S       = 1'b1;
assign AUDIO_MIX     = 2'b00;

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
