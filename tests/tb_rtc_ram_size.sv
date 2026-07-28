`timescale 1ns / 1ns

module tb_rtc_ram_size;
    logic clk = 0;
    logic rst_n = 0;
    logic [1:0] ram_size = 0;
    logic io_address = 0;
    logic io_read = 0;
    logic io_write = 0;
    logic [7:0] io_writedata = 0;
    logic [7:0] io_readdata;
    logic irq;
    integer rtc_ticks;

    always #5 clk = ~clk;

    rtc dut (
        .clk(clk),
        .rst_n(rst_n),
        .irq(irq),
        .io_address(io_address),
        .io_read(io_read),
        .io_readdata(io_readdata),
        .io_write(io_write),
        .io_writedata(io_writedata),
        .bootcfg(6'd0),
        .ram_size(ram_size),
        .mgmt_address(8'd0),
        .mgmt_write(1'b0),
        .mgmt_writedata(8'd0),
        .clock_rate(28'd85_000_000)
    );

    task automatic select_cmos(input logic [6:0] address);
        begin
            @(negedge clk);
            io_address = 0;
            io_writedata = {1'b0, address};
            io_write = 1;
            @(negedge clk);
            io_write = 0;
        end
    endtask

    task automatic expect_cmos(input logic [6:0] address, input logic [7:0] expected);
        begin
            select_cmos(address);
            @(negedge clk);
            io_address = 1;
            io_read = 1;
            @(negedge clk);
            io_read = 0;
            if (io_readdata !== expected) begin
                $error("CMOS %02h: expected %02h, got %02h", address, expected, io_readdata);
                $fatal;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        expect_cmos(7'h17, 8'h00);
        expect_cmos(7'h18, 8'h3C);
        expect_cmos(7'h30, 8'h00);
        expect_cmos(7'h31, 8'h3C);
        expect_cmos(7'h34, 8'h00);
        expect_cmos(7'h35, 8'h00);
        expect_cmos(7'h2E, 8'h00);
        expect_cmos(7'h2F, 8'h00);

        ram_size = 1;
        expect_cmos(7'h17, 8'h00);
        expect_cmos(7'h18, 8'h7C);
        expect_cmos(7'h30, 8'h00);
        expect_cmos(7'h31, 8'h7C);
        expect_cmos(7'h34, 8'h00);
        expect_cmos(7'h35, 8'h01);
        expect_cmos(7'h2E, 8'h00);
        expect_cmos(7'h2F, 8'h40);

        ram_size = 2;
        expect_cmos(7'h17, 8'h00);
        expect_cmos(7'h18, 8'hFC);
        expect_cmos(7'h30, 8'h00);
        expect_cmos(7'h31, 8'hFC);
        expect_cmos(7'h34, 8'h00);
        expect_cmos(7'h35, 8'h03);
        expect_cmos(7'h2E, 8'h00);
        expect_cmos(7'h2F, 8'hC0);

        ram_size = 3;
        expect_cmos(7'h17, 8'hFF);
        expect_cmos(7'h18, 8'hFF);
        expect_cmos(7'h30, 8'hFF);
        expect_cmos(7'h31, 8'hFF);
        expect_cmos(7'h34, 8'h00);
        expect_cmos(7'h35, 8'h07);
        expect_cmos(7'h2E, 8'h01);
        expect_cmos(7'h2F, 8'hC2);

        // Ten milliseconds at 85 MHz must produce about 82 RTC base ticks.
        rtc_ticks = 0;
        repeat (850_000) begin
            @(negedge clk);
            if (dut.ce_8192hz)
                rtc_ticks = rtc_ticks + 1;
        end
        if (rtc_ticks < 81 || rtc_ticks > 83) begin
            $error("RTC base clock: expected 81-83 ticks, got %0d", rtc_ticks);
            $fatal;
        end

        $display("PASS: RTC memory sizes and 8192 Hz base clock (%0d ticks)", rtc_ticks);
        $finish;
    end
endmodule
