`timescale 1ns / 1ps

module tb_main_memory_svga;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic [31:0] cpu_addr = 0;
    logic [31:0] cpu_din = 0;
    logic [31:0] cpu_dout;
    logic cpu_resp_valid;
    logic [3:0] cpu_be = 0;
    logic [7:0] cpu_burstcount = 1;
    logic cpu_ready;
    logic cpu_valid = 0;
    logic cpu_write = 0;
    logic [1:0] ram_size = 0;
    logic [31:0] mem_addr;
    logic [31:0] mem_din;
    logic [31:0] mem_dout = 0;
    logic mem_resp_valid = 0;
    logic [3:0] mem_be;
    logic [7:0] mem_burstcount;
    logic mem_ready = 0;
    logic mem_valid;
    logic mem_write;
    logic [16:0] vga_address;
    logic [7:0] vga_readdata = 0;
    logic [7:0] vga_writedata;
    logic [2:0] vga_memmode = 3'b100;
    logic vga_read;
    logic vga_write;
    logic [5:0] vga_wr_seg = 0;
    logic [5:0] vga_rd_seg = 6'h12;
    logic vga_fb_en = 1;
    logic vga_chain4 = 1;
    logic [3:0] vga_map_mask = 4'hF;
    logic [1:0] vga_read_plane = 0;
    logic [1:0] vga_write_mode = 0;
    logic vga_wr_done;
    logic [28:0] fb_ddram_addr;
    logic [63:0] fb_ddram_din;
    logic [7:0] fb_ddram_be;
    logic fb_ddram_we;
    logic fb_ddram_rd;
    logic [63:0] fb_ddram_dout = 0;
    logic fb_ddram_dout_ready = 0;
    logic [7:0] fb_ddram_burstcnt;
    logic fb_ddram_busy = 0;

    main_memory dut (.*);

    always @(posedge clk) begin
        fb_ddram_dout_ready <= 0;
        if (fb_ddram_rd) begin
            fb_ddram_dout <= 64'h8877_6655_4433_2211;
            fb_ddram_dout_ready <= 1;
        end
    end

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;

        // Read the upper dword of bank 0x12, then change the CPU address as soon
        // as the request is accepted. The DDR response must use the accepted
        // request's half-select rather than the now-live CPU address.
        @(negedge clk);
        cpu_addr = 32'h000A_0004;
        cpu_be = 4'hF;
        cpu_valid = 1;
        do begin
            @(posedge clk);
            #1;
        end while (!cpu_ready);

        if (fb_ddram_addr !== 29'h07F2_4000)
            $fatal(1, "SVGA read address mismatch: %08x", fb_ddram_addr);

        @(negedge clk);
        cpu_valid = 0;
        cpu_addr = 32'h000A_0000;

        do begin
            @(posedge clk);
            #1;
        end while (!cpu_resp_valid);

        if (cpu_dout !== 32'h8877_6655)
            $fatal(1, "SVGA read used live address half-select: got %08x", cpu_dout);

        $display("PASS: SVGA read preserves the accepted dword half-select");

        // Windows' ET4000 driver disables chain-4 for screen-to-screen blits.
        // Each aperture byte then addresses four adjacent framebuffer pixels;
        // a read loads all plane latches and write mode 1 copies those latches.
        @(negedge clk);
        vga_chain4 = 0;
        vga_rd_seg = 6'h01;
        vga_read_plane = 2;
        cpu_addr = 32'h000A_0010;
        cpu_be = 4'h1;
        cpu_valid = 1;
        cpu_write = 0;
        do begin
            @(posedge clk);
            #1;
        end while (!cpu_ready);

        if (fb_ddram_addr !== 29'h07F0_8008)
            $fatal(1, "planar SVGA read address mismatch: %08x", fb_ddram_addr);

        @(negedge clk);
        cpu_valid = 0;
        do begin
            @(posedge clk);
            #1;
        end while (!cpu_resp_valid);

        if (cpu_dout !== 32'h3333_3333)
            $fatal(1, "planar SVGA selected-plane read mismatch: %08x", cpu_dout);

        @(negedge clk);
        vga_wr_seg = 6'h02;
        vga_map_mask = 4'hA;
        vga_write_mode = 1;
        cpu_addr = 32'h000A_0020;
        cpu_be = 4'h2;
        cpu_din = 32'h0000_A500;
        cpu_valid = 1;
        cpu_write = 1;
        do begin
            @(posedge clk);
            #1;
        end while (!cpu_ready);

        if (fb_ddram_addr !== 29'h07F1_0010)
            $fatal(1, "planar SVGA write address mismatch: %08x", fb_ddram_addr);
        if (fb_ddram_be !== 8'hA0)
            $fatal(1, "planar SVGA map mask mismatch: %02x", fb_ddram_be);
        if (fb_ddram_din !== 64'h4433_2211_0000_0000)
            $fatal(1, "planar SVGA latch data mismatch: %016x", fb_ddram_din);

        @(negedge clk);
        cpu_valid = 0;
        $display("PASS: planar SVGA write mode 1 copies all four VGA latches");

        // A larger physical SDRAM module must not leak past the guest RAM
        // size. Cache-line reads still need one response per requested beat.
        @(negedge clk);
        vga_chain4 = 1;
        cpu_addr = 32'h0100_0000;
        cpu_be = 4'hF;
        cpu_burstcount = 3;
        cpu_valid = 1;
        cpu_write = 0;
        #1;
        if (!cpu_ready || mem_valid)
            $fatal(1, "16MB boundary read was sent to physical SDRAM");
        @(negedge clk);
        cpu_valid = 0;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF)
                $fatal(1, "missing open-bus burst response above 16MB");
        end
        @(posedge clk);
        #1;
        if (cpu_resp_valid)
            $fatal(1, "extra open-bus burst response above 16MB");

        @(negedge clk);
        cpu_addr = 32'h0100_0000;
        cpu_burstcount = 1;
        cpu_valid = 1;
        cpu_write = 1;
        #1;
        if (!cpu_ready || mem_valid)
            $fatal(1, "write above 16MB was not ignored locally");
        @(negedge clk);
        cpu_valid = 0;

        ram_size = 1;
        cpu_addr = 32'h0100_0000;
        cpu_valid = 1;
        cpu_write = 0;
        #1;
        if (cpu_ready || !mem_valid)
            $fatal(1, "32MB configuration rejected an in-range access");
        @(negedge clk);
        cpu_valid = 0;

        ram_size = 3;
        cpu_addr = 32'h0800_0000;
        cpu_valid = 1;
        #1;
        if (!cpu_ready || mem_valid)
            $fatal(1, "address above 128MB aliased into physical SDRAM");
        @(negedge clk);
        cpu_valid = 0;
        $display("PASS: configured RAM size is enforced as a physical decode limit");
        $finish;
    end
endmodule
