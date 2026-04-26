// sdram_x2_wrapper: run SDRAM core at 2x clk_sys
//
// Notes
// - This wrapper assumes clk_2x = 2 * clk_sys and both clocks are phase-aligned
//   from the same PLL, so a clk_sys rising edge coincides with every other clk_2x edge.
// - Inputs from clk_sys domain are sampled by the 2x core on clk_sys edges for safety. 
// - Outputs that are pulses in the 2x domain are stretched to at least one clk_sys cycle.
module sdram_x2_wrapper #(
    parameter FREQ_SYS = 20_000_000
) (
    // Clocks/reset
    input             clk_sys,       // main logic clock (e.g. 20 MHz)
    input             clk_2x,        // SDRAM engine clock (e.g. 40 MHz)
    input             resetn,
    input             refresh_allowed,

    // Expose busy to system domain (sampled on clk_sys)
    output reg        busy,

    // 3 requesters (system domain, valid/ready handshake)
    input             valid0,
    output reg        ready0,
    input             wr0,
    input      [24:0] addr0,
    input      [31:0] din0,
    output reg [31:0] dout0,
    input       [3:0] be0,
    output reg        resp_valid0,
    input       [3:0] burst_cnt0,
    output reg        burst_done0,

    input             valid1,
    output reg        ready1,
    input             wr1,
    input      [24:0] addr1,
    input      [31:0] din1,
    output reg [31:0] dout1,
    input       [3:0] be1,
    output reg        resp_valid1,
    input       [3:0] burst_cnt1,
    output reg        burst_done1,

    input             valid2,
    output reg        ready2,
    input             wr2,
    input      [24:0] addr2,
    input      [31:0] din2,
    output reg [31:0] dout2,
    input       [3:0] be2,
    output reg        resp_valid2,
    input       [3:0] burst_cnt2,
    output reg        burst_done2,

    // SDRAM side pins
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output     [1:0]  SDRAM_DQM,
    output     [1:0]  SDRAM_BA,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_nCS,
    output            SDRAM_CKE
);

localparam FREQ_2X = 2 * FREQ_SYS;

// phase=0 when clk_sys is high, 1 when clk_sys is low
reg phase;
always @(negedge clk_2x) begin
    phase <= ~clk_sys;         
end

// Inner SDRAM core at 2x clock
wire        core_busy;
wire        core_req0, core_req1, core_req2;
wire        core_resp_valid0, core_resp_valid1, core_resp_valid2;
wire        core_bdone0, core_bdone1, core_bdone2;
wire [31:0] core_dout0, core_dout1, core_dout2;
wire        core_ready0, core_ready1, core_ready2;

// Instantiate the actual SDRAM core at 2x frequency
sdram #(.FREQ(FREQ_2X)) u_sdram (
    .SDRAM_DQ   (SDRAM_DQ),
    .SDRAM_A    (SDRAM_A),
    .SDRAM_DQM  (SDRAM_DQM),
    .SDRAM_BA   (SDRAM_BA),
    .SDRAM_nWE  (SDRAM_nWE),
    .SDRAM_nRAS (SDRAM_nRAS),
    .SDRAM_nCAS (SDRAM_nCAS),
    .SDRAM_nCS  (SDRAM_nCS),
    .SDRAM_CKE  (SDRAM_CKE),

    .clk              (clk_2x),
    .resetn           (resetn),
    .nce              (~phase),   // no new requests or refreshes on 1st phase (when phase == 0)
    .refresh_allowed  (refresh_allowed),
    .busy             (core_busy),

    .valid0      (valid0),          // only sample when phase == 1
    .ready0      (core_ready0),
    .wr0         (wr0),
    .addr0       (addr0),
    .din0        (din0),
    .dout0       (core_dout0),
    .be0         (be0),
    .resp_valid0 (core_resp_valid0),
    .burst_cnt0  (burst_cnt0),
    .burst_done0 (core_bdone0),

    .valid1      (valid1),
    .ready1      (core_ready1),
    .wr1         (wr1),
    .addr1       (addr1),
    .din1        (din1),
    .dout1       (core_dout1),
    .be1         (be1),
    .resp_valid1 (core_resp_valid1),
    .burst_cnt1  (burst_cnt1),
    .burst_done1 (core_bdone1),

    .valid2      (valid2),
    .ready2      (core_ready2),
    .wr2         (wr2),
    .addr2       (addr2),
    .din2        (din2),
    .dout2       (core_dout2),
    .be2         (be2),
    .resp_valid2 (core_resp_valid2),
    .burst_cnt2  (burst_cnt2),
    .burst_done2 (core_bdone2)
);

// Pending flags across a clk_sys cycle
reg pend_resp0, pend_resp1, pend_resp2;
reg pend_bdone0, pend_bdone1, pend_bdone2;
reg [31:0] pend_dout0, pend_dout1, pend_dout2;

assign busy = core_busy;

always @(posedge clk_2x or negedge resetn) begin
    if (!resetn) begin
        pend_resp0 <= 1'b0; pend_resp1 <= 1'b0; pend_resp2 <= 1'b0;
        pend_bdone0 <= 1'b0; pend_bdone1 <= 1'b0; pend_bdone2 <= 1'b0;
        resp_valid0 <= 1'b0;
        resp_valid1 <= 1'b0;
        resp_valid2 <= 1'b0;
    end else begin
        // Capture core events as they happen (2x domain)
        pend_resp0 <= core_resp_valid0;
        pend_resp1 <= core_resp_valid1;
        pend_resp2 <= core_resp_valid2;
        pend_dout0 <= core_dout0;
        pend_dout1 <= core_dout1;
        pend_dout2 <= core_dout2;
        pend_bdone0 <= core_bdone0;
        pend_bdone1 <= core_bdone1;
        pend_bdone2 <= core_bdone2;

        // On phase==1, update outputs once per clk_sys
        if (phase) begin
            ready0 <= core_ready0;
            ready1 <= core_ready1;
            ready2 <= core_ready2;

            resp_valid0 <= core_resp_valid0 | pend_resp0;
            resp_valid1 <= core_resp_valid1 | pend_resp1;
            resp_valid2 <= core_resp_valid2 | pend_resp2;

            if (pend_resp0) dout0 <= pend_dout0;
            if (core_resp_valid0) dout0 <= core_dout0;
            if (pend_resp1) dout1 <= pend_dout1;
            if (core_resp_valid1) dout1 <= core_dout1;
            if (pend_resp2) dout2 <= pend_dout2;
            if (core_resp_valid2) dout2 <= core_dout2;

            burst_done0 <= core_bdone0 | pend_bdone0;
            burst_done1 <= core_bdone1 | pend_bdone1;
            burst_done2 <= core_bdone2 | pend_bdone2;
        end
    end
end

endmodule