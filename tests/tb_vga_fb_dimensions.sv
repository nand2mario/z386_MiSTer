`timescale 1ns/1ps

module tb_vga_fb_dimensions;
    logic clk_sys = 0;
    logic clk_vga = 0;
    logic rst_n = 0;

    logic [3:0] io_address = 0;
    logic io_read = 0;
    wire [7:0] io_readdata;
    logic io_write = 0;
    logic [7:0] io_writedata = 0;
    logic io_b_cs = 0;
    logic io_c_cs = 0;
    logic io_d_cs = 0;
    logic [16:0] mem_address = 0;
    logic mem_read = 0;
    wire [7:0] mem_readdata;
    logic mem_write = 0;
    logic [7:0] mem_writedata = 0;
    wire irq;
    logic [27:0] clock_rate_vga = 28'd25_175_000;
    wire vga_ce;
    logic vga_f60 = 0;
    wire [2:0] vga_memmode;
    wire vga_blank_n;
    wire vga_off;
    wire vga_horiz_sync;
    wire vga_vert_sync;
    wire [7:0] vga_r;
    wire [7:0] vga_g;
    wire [7:0] vga_b;
    wire [17:0] vga_pal_d;
    wire [7:0] vga_pal_a;
    wire vga_pal_we;
    wire [19:0] vga_start_addr;
    wire [5:0] vga_wr_seg;
    wire [5:0] vga_rd_seg;
    wire [8:0] vga_width;
    wire [8:0] vga_stride;
    wire [10:0] vga_height;
    wire [3:0] vga_flags;
    wire vga_chain4;
    wire [3:0] vga_map_mask;
    wire [1:0] vga_read_plane;
    wire [1:0] vga_write_mode;
    logic vga_lores = 0;
    logic vga_border = 1;

    always #5 clk_sys = ~clk_sys;
    always #7 clk_vga = ~clk_vga;

    vga dut (.*);

    task automatic check_dimensions;
        @(posedge clk_sys);
        #1;
        if (vga_width != 9'd128)
            $fatal(1, "1024-pixel framebuffer width includes overscan: %0d groups", vga_width);
        if (vga_height != 11'd768)
            $fatal(1, "768-line framebuffer height includes overscan: %0d", vga_height);
    endtask

    initial begin
        repeat (3) @(posedge clk_sys);
        rst_n = 1;

        force dut.crtc_horizontal_display_size = 8'd127;
        force dut.crtc_horizontal_blanking_start = 9'd127;
        force dut.horiz_overscan_left = 9'd2;
        force dut.crtc_vertical_display_size = 11'd767;
        force dut.crtc_vertical_blanking_start = 11'd767;
        force dut.vert_overscan_top = 11'd8;

        vga_border = 1;
        check_dimensions();
        vga_border = 0;
        check_dimensions();

        $display("PASS: SVGA framebuffer dimensions exclude overscan");
        $finish;
    end
endmodule
