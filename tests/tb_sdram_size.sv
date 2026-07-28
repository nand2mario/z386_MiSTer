`timescale 1ns / 1ns

module tb_sdram_size;
    logic clk = 0;
    logic resetn = 0;
    logic [1:0] sdram_size = 3;
    logic valid = 0;
    logic ready;
    logic [26:0] addr = 0;
    logic busy;
    wire [15:0] dq;
    wire [12:0] sdram_a;
    wire [1:0] sdram_ba;
    wire [1:0] sdram_dqm;
    wire sdram_nwe, sdram_nras, sdram_ncas, sdram_ncs, sdram_cke;

    always #5 clk = ~clk;

    sdram #(
        .FREQ(1_000_000),
        .HAS_DQM(1'b0)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .nce(1'b0),
        .refresh_allowed(1'b1),
        .busy(busy),
        .sdram_size(sdram_size),
        .valid0(valid),
        .ready0(ready),
        .wr0(1'b1),
        .addr0(addr),
        .din0(32'h1234_5678),
        .dout0(),
        .resp_valid0(),
        .be0(4'hF),
        .burst_cnt0(4'd1),
        .burst_done0(),
        .valid1(1'b0), .ready1(), .wr1(1'b0), .addr1(27'd0),
        .din1(32'd0), .dout1(), .be1(4'd0), .resp_valid1(),
        .burst_cnt1(4'd0), .burst_done1(),
        .valid2(1'b0), .ready2(), .wr2(1'b0), .addr2(27'd0),
        .din2(32'd0), .dout2(), .be2(4'd0), .resp_valid2(),
        .burst_cnt2(4'd0), .burst_done2(),
        .SDRAM_DQ(dq),
        .SDRAM_A(sdram_a),
        .SDRAM_DQM(sdram_dqm),
        .SDRAM_BA(sdram_ba),
        .SDRAM_nWE(sdram_nwe),
        .SDRAM_nRAS(sdram_nras),
        .SDRAM_nCAS(sdram_ncas),
        .SDRAM_nCS(sdram_ncs),
        .SDRAM_CKE(sdram_cke)
    );

    task automatic expect_activate(
        input logic [1:0] size,
        input logic [26:0] address,
        input logic expected_cs,
        input logic [1:0] expected_bank,
        input logic [12:0] expected_row,
        input logic [12:0] expected_column
    );
        begin
            while (busy) @(posedge clk);
            @(negedge clk);
            sdram_size = size;
            addr = address;
            valid = 1;
            do begin
                @(posedge clk);
                #1;
            end while (!ready);
            if ({sdram_nras, sdram_ncas, sdram_nwe} !== 3'b011 ||
                sdram_ncs !== expected_cs || sdram_ba !== expected_bank ||
                sdram_a !== expected_row || sdram_dqm !== expected_row[12:11]) begin
                $error("size=%0d addr=%08h: CMD/CS/BA/A=%b/%b/%b/%h expected 011/%b/%b/%h",
                       size, address, {sdram_nras, sdram_ncas, sdram_nwe}, sdram_ncs, sdram_ba, sdram_a,
                       expected_cs, expected_bank, expected_row);
                $fatal;
            end
            @(negedge clk);
            valid = 0;
            do begin
                @(posedge clk);
                #1;
            end while ({sdram_nras, sdram_ncas, sdram_nwe} != 3'b100);
            if (sdram_ncs !== expected_cs || sdram_ba !== expected_bank ||
                sdram_a !== expected_column) begin
                $error("size=%0d addr=%08h: write CS/BA/A=%b/%b/%h expected %b/%b/%h",
                       size, address, sdram_ncs, sdram_ba, sdram_a,
                       expected_cs, expected_bank, expected_column);
                $fatal;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        resetn = 1;
        while (busy) @(posedge clk);

        // 16MB maps to bank 2 under the 32MB module geometry.
        expect_activate(2'd1, 27'h100_0000, 1'b0, 2'b10, 13'd0, 13'd0);
        // The same address maps to bank 1 under 64MB geometry.
        expect_activate(2'd2, 27'h100_0000, 1'b0, 2'b01, 13'd0, 13'd0);
        // Upper row address bits are also mirrored onto the MiSTer DQM pins.
        expect_activate(2'd2, 27'h080_0000, 1'b0, 2'b00, 13'h1000, 13'd0);
        // A10 is a column bit on 64/128MB modules, not a row bit as on 32MB.
        expect_activate(2'd2, 27'h000_0400, 1'b0, 2'b00, 13'd0, 13'h0200);
        // The upper 64MB of a 128MB module selects its second chip.
        expect_activate(2'd3, 27'h400_0000, 1'b1, 2'b00, 13'd0, 13'd0);

        $display("PASS: SDRAM maps 32/64/128MB module geometries");
        $finish;
    end
endmodule
