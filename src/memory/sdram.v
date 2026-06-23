// Simple SDRAM controller for Tang and MiSTer SDRAM module
// nand2mario
//
// 2024.10: initial version.
// 2025.08: convert to 32-bit with burst read support.
// 2026.04: derive SDRAM timing from FREQ up to 133MHz
//
// This is a 32-bit, low-latency and non-bursting controller for accessing the SDRAM module
// on Tang boards and DE10-Nano. The SDRAM is 4 banks x 8192 rows x 512 columns x 16 bits (32MB in total).
//
// Read timings (burst_cnt=2):
//   clk        /‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___/
//   host       |  req  |       |       |       |       |       |       |  ack  |
//   sdram              |  RAS  |  CAS1 |  CAS2 |  CAS2 |  CAS3 |
//   dq                                         |lo word|hi word|lo word|hi word|
//   ready                                              | ready |       | ready |
//   burst_done                                                         | done  |
//   cycle          0       1       2       3       4       5       6       7
//
// Under the legacy <=66MHz settings (CL2):
// - Read latency is T_RCD + CAS + 2*burst_cnt - 1 cycles from ACT to last data.
// - Write latency: ACT at t0, low-half write at t=T_RCD, high-half write at t=T_RCD+2
//   (auto-precharge on the high half), ack after T_WR+T_RP from the high half.
// - Read burst of at most 15 32-bit dwords. Bursts must not cross a row boundary.
// - Write is always a single 32-bit word with byte-enable support. No burst write.
// - Refresh is done automatically every ~7.8us when idle and refresh_allowed==1.

module sdram
#(
    parameter         FREQ = 64_800_000,
    parameter         HAS_DQM = 1'b1,     // Set to 0 for MiSTer modules. They do not have DQM pins.
    parameter         FAST_GRADE = 1'b1   // 1: Alliance -6 speed grade, 0: -7 speed grade
)
(
    // SDRAM side interface (16-bit data bus)
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output reg [1:0]  SDRAM_DQM,
    output reg [1:0]  SDRAM_BA,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_nCS,    // always 0
    output            SDRAM_CKE,    // always 1

    // Logic side interface (32-bit)
    input             clk,
    input             resetn,
    input             nce,            // for x2 wrapper, 1: do not accept new request or auto-refresh 
    input             refresh_allowed,      // set to 1 to allow auto-refresh
    output            busy,

    // 3 requesters, 0 has highest priority (valid/ready handshake)
    input             valid0,       // request valid (held until ready)
    output            ready0,       // 1-cycle pulse: request accepted
    input             wr0,          // 1: write (single dword), 0: read
    input      [24:0] addr0,        // dword address (bits [1:0] ignored)
    input      [31:0] din0,         // 32-bit write data
    output     [31:0] dout0,        // 32-bit read data
    input       [3:0] be0,          // byte enable
    output            resp_valid0,  // pulses when a 32-bit read word is ready
    input       [3:0] burst_cnt0,   // read burst dwords (max 15)
    output            burst_done0,  // pulses when read burst completes

    input             valid1,
    output            ready1,
    input             wr1,
    input      [24:0] addr1,
    input      [31:0] din1,
    output     [31:0] dout1,
    input       [3:0] be1,
    output            resp_valid1,
    input       [3:0] burst_cnt1,
    output            burst_done1,

    input             valid2,
    output            ready2,
    input             wr2,
    input      [24:0] addr2,
    input      [31:0] din2,
    output     [31:0] dout2,
    input       [3:0] be2,
    output            resp_valid2,
    input       [3:0] burst_cnt2,
    output            burst_done2
);

function integer ns_to_cycles;
    input integer ns;
    integer prod;
    begin
        prod = ns * ((FREQ + 999) / 1000);
        ns_to_cycles = (prod + 1_000_000 - 1) / 1_000_000;
        if (ns_to_cycles < 1)
            ns_to_cycles = 1;
    end
endfunction

// localparam integer FREQ66 = 66_000_000;
localparam integer FREQ66 = 75_000_000;   // pushing the edge
localparam integer T_RP_NS = FAST_GRADE ? 18 : 21;
localparam integer T_RCD_NS = FAST_GRADE ? 18 : 21;
localparam integer T_RC_NS = FAST_GRADE ? 60 : 63;
localparam integer T_WR_NS = FAST_GRADE ? 12 : 14;

localparam integer CAS_I   = (FREQ <= 100_000_000) ? 2 : 3;
localparam integer T_WR_I  = (FREQ <= FREQ66) ? 1 : ns_to_cycles(T_WR_NS);
localparam integer T_MRD_I = 2;
localparam integer T_RP_I  = (FREQ <= FREQ66) ? 1 : ns_to_cycles(T_RP_NS);
localparam integer T_RCD_I = (FREQ <= FREQ66) ? 1 : ns_to_cycles(T_RCD_NS);
localparam integer T_RC_I  = (FREQ <= FREQ66) ? 4 : ns_to_cycles(T_RC_NS);
localparam integer T_DAL_I = T_WR_I + T_RP_I;

localparam [3:0] CAS   = CAS_I[3:0];
localparam [3:0] T_WR  = T_WR_I[3:0];
localparam [3:0] T_MRD = T_MRD_I[3:0];
localparam [3:0] T_RP  = T_RP_I[3:0];
localparam [3:0] T_RCD = T_RCD_I[3:0];
localparam [3:0] T_RC  = T_RC_I[3:0];

generate
if (FREQ > 133_000_000) begin : gen_freq_check
    initial
        $error("ERROR: This timing table is only characterized up to 133MHz.");
end
endgenerate

reg busy_buf = 1'b1;
reg nce_r;
always @(posedge clk) nce_r <= nce;
reg busy_r;
always @(posedge clk) busy_r <= busy;
assign busy = ~nce_r ? busy_buf : busy_r;    // use busy_buf value the next cycle of CE

// Tri-state DQ
reg        dq_oen;          // 0: drive dq_out, 1: Hi-Z
reg [15:0] dq_out;
assign SDRAM_DQ = dq_oen ? {16{1'bZ}} : dq_out;
wire [15:0] dq_in = SDRAM_DQ;

// Single registered DQ capture.  This is the ONLY register that reads the DQ
// pins, so FAST_INPUT_REGISTER packs it into the IOB input cell -> deterministic,
// placement-independent read timing (previously rd_lo16/dout_word/dout_buf each
// read the raw pin, so only one could pack into the IOB and the rest captured
// through placement-dependent fabric routing).  dq_r lags dq_in by one cycle, so
// the READ/RMW_READ capture thresholds below are pushed out by 1.
reg  [15:0] dq_r;
always @(posedge clk) dq_r <= dq_in;

// Command/address
reg [2:0]  cmd;
reg [12:0] a;
assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
assign SDRAM_A  = a;
assign SDRAM_CKE= 1'b1;
assign SDRAM_nCS= 1'b0;

// Per-port ready pulse (1 cycle, request accepted)
reg [2:0] ready_pulse;
assign ready0 = ready_pulse[0];
assign ready1 = ready_pulse[1];
assign ready2 = ready_pulse[2];

// Read data path
reg  [31:0] dout_buf0;             // holds last completed word per port
reg  [31:0] dout_buf1;
reg  [31:0] dout_buf2;
reg  [31:0] dout_word;             // most recent completed word (active port)
reg         data_resp_pulse;       // 1-cycle pulse when a 32-bit word completes

assign resp_valid0 = (req_id_buf == 2'd0) ? data_resp_pulse : 1'b0;
assign resp_valid1 = (req_id_buf == 2'd1) ? data_resp_pulse : 1'b0;
assign resp_valid2 = (req_id_buf == 2'd2) ? data_resp_pulse : 1'b0;

assign dout0  = resp_valid0 ? dout_word : dout_buf0;
assign dout1  = resp_valid1 ? dout_word : dout_buf1;
assign dout2  = resp_valid2 ? dout_word : dout_buf2;

// Burst-done pulse (on final word of a read burst)
reg burst_done_pulse;
assign burst_done0 = (req_id_buf == 2'd0) ? burst_done_pulse : 1'b0;
assign burst_done1 = (req_id_buf == 2'd1) ? burst_done_pulse : 1'b0;
assign burst_done2 = (req_id_buf == 2'd2) ? burst_done_pulse : 1'b0;

// FSM
reg [2:0] state;
localparam INIT     = 3'd0;
localparam CONFIG   = 3'd1;
localparam IDLE     = 3'd2;
localparam READ     = 3'd3;
localparam RMW_READ = 3'd4;
localparam WRITE    = 3'd5;
localparam REFRESH  = 3'd6;
localparam RMW_ACT  = 3'd7;

// RAS# CAS# WE#
localparam CMD_SetModeReg  = 3'b000;
localparam CMD_AutoRefresh = 3'b001;
localparam CMD_PreCharge   = 3'b010;
localparam CMD_BankActivate= 3'b011;
localparam CMD_Write       = 3'b100;
localparam CMD_Read        = 3'b101;
localparam CMD_NOP         = 3'b111;

// Mode register: burst length = 1, sequential
localparam [2:0] BURST_LEN   = 3'b000;   // 1
localparam       BURST_MODE  = 1'b0;     // sequential
localparam [10:0] MODE_REG   = {4'b0000, CAS[2:0], BURST_MODE, BURST_LEN};

// Refresh period (~7.8us per row over 64ms total)
localparam REFRESH_CYCLES = (FREQ/1000) * 64 / 8192;
localparam integer REFRESH_CNT_W = (REFRESH_CYCLES < 2) ? 1 : $clog2(REFRESH_CYCLES + 1);

reg cfg_now;

reg [4:0]  cycle;             // small scheduler counter (saturates)
reg [24:0] addr_buf;
reg [31:0] din_buf;
reg [3:0]  be_buf;
reg [1:0]  req_id_buf;

reg [REFRESH_CNT_W-1:0] refresh_cnt;
reg        need_refresh;

// READ pipeline counters (16-bit halfwords)
reg [4:0]  rd_total_halfs;    // = 2 * effective dword count (<= 30)
reg [4:0]  rd_issued;         // # of CAS commands already issued
reg [4:0]  rd_received;       // # of 16-bit words captured from dq
reg [7:0]  rd_col_base;       // starting dword column (0..255)
reg [15:0] rd_lo16;           // latch low-half before composing 32-bit
reg [1:0]  rmw_issued;
reg [1:0]  rmw_received;
reg [1:0]  rmw_total_reads;
reg [1:0]  rmw_read_halfs;
reg [31:0] rmw_old_data;
reg [1:0]  wr_halfs;          // bit0=write low 16-bit half, bit1=write high 16-bit half

function [31:0] byte_merge(input [31:0] old_data, input [31:0] new_data, input [3:0] be);
    byte_merge = {be[3] ? new_data[31:24] : old_data[31:24],
                  be[2] ? new_data[23:16] : old_data[23:16],
                  be[1] ? new_data[15:8]  : old_data[15:8],
                  be[0] ? new_data[7:0]   : old_data[7:0]};
endfunction

// simple refresh request
always @(posedge clk) begin
    if (!resetn) begin
        need_refresh<= 1'b0;
    end else begin
        if (refresh_cnt == 0)
            need_refresh <= 1'b0;
        else if (refresh_cnt == REFRESH_CYCLES)
            need_refresh <= 1'b1;
    end
end

// Main FSM
always @(posedge clk) begin
    automatic reg new_req;
    reg [1:0] req_id;
    reg [24:0] req_addr;
    reg [31:0] req_din;
    reg [3:0] req_be;
    reg req_wr;
    reg [3:0] req_burst;

    // defaults each cycle
    cmd               <= CMD_NOP;
    SDRAM_DQM         <= 2'b00;
    data_resp_pulse  <= 1'b0;
    burst_done_pulse  <= 1'b0;
    ready_pulse    <= 3'b000;

    // saturating cycle counter
    cycle <= (cycle == 5'd31) ? cycle : (cycle + 5'd1);
    refresh_cnt <= refresh_cnt + 1'b1;

    // Request arbiter (valid-based priority)
    new_req = valid0 | valid1 | valid2;
    req_id  = valid0 ? 2'd0 :
              valid1 ? 2'd1 : 2'd2;
    case (req_id)
    2'd0: begin
        req_addr = addr0;
        req_din = din0;
        req_be = be0;
        req_wr = wr0;
        req_burst = burst_cnt0;
    end
    2'd1: begin
        req_addr = addr1;
        req_din = din1;
        req_be = be1;
        req_wr = wr1;
        req_burst = burst_cnt1;
    end
    default: begin
        req_addr = addr2;
        req_din = din2;
        req_be = be2;
        req_wr = wr2;
        req_burst = burst_cnt2;
    end
    endcase;

    case (state)
    // Power-on wait → CONFIG sequence
    INIT: begin
        if (cfg_now) begin
            state  <= CONFIG;
            cycle  <= 5'd0;
        end
        busy_buf <= 1'b1;
        dq_oen   <= 1'b1;     // tri-state DQ during init
    end

    CONFIG: begin
        // t=0: PRECHG ALL
        if (cycle == 5'd0) begin
            cmd   <= CMD_PreCharge;
            a[10] <= 1'b1;                // precharge all
        end
        // t=T_RP: AutoRefresh #1
        if (cycle == T_RP) begin
            cmd <= CMD_AutoRefresh;
        end
        // t=T_RP+T_RC: AutoRefresh #2
        if (cycle == (T_RP+T_RC)) begin
            cmd <= CMD_AutoRefresh;
        end
        // t=T_RP+2*T_RC: Set Mode Register
        if (cycle == (T_RP+T_RC+T_RC)) begin
            cmd     <= CMD_SetModeReg;
            a[10:0] <= MODE_REG;
        end
        // t=...+T_MRD: done
        if (cycle == (T_RP+T_RC+T_RC+T_MRD)) begin
            state      <= IDLE;
            busy_buf   <= 1'b0;
            refresh_cnt<= 0;
        end
    end

    IDLE: if (~nce) begin     // change state on when nce == 0
        busy_buf <= 1'b0;
        if (need_refresh && refresh_allowed) begin
            // Refresh takes priority over new requests to prevent starvation
            cmd         <= CMD_AutoRefresh;
            refresh_cnt <= 0;
            busy_buf    <= 1'b1;
            cycle       <= 5'd1;
            state       <= REFRESH;
        end else if (new_req) begin
            // Latch request and pulse accepted
            addr_buf       <= req_addr;
            din_buf        <= req_din;
            be_buf         <= req_be;
            req_id_buf     <= req_id;
            ready_pulse[req_id] <= 1'b1;

            // ACT to selected bank/row
            cmd       <= CMD_BankActivate;
            SDRAM_BA  <= req_addr[24:23];
            a         <= req_addr[22:10];     // row
            busy_buf  <= 1'b1;
            cycle     <= 5'd1;

            if (req_wr) begin
                if (!HAS_DQM && (req_be == 4'b0011)) begin
                    wr_halfs <= 2'b01;
                    state    <= WRITE;
                end else if (!HAS_DQM && (req_be == 4'b1100)) begin
                    wr_halfs <= 2'b10;
                    state    <= WRITE;
                end else if (!HAS_DQM && (req_be != 4'b1111)) begin
                    rmw_issued   <= 2'd0;
                    rmw_received <= 2'd0;
                    rmw_old_data <= 32'd0;
                    if (req_be[1:0] != 2'b00 && req_be[3:2] == 2'b00) begin
                        rmw_read_halfs  <= 2'b01;
                        rmw_total_reads <= 2'd1;
                        wr_halfs        <= 2'b01;
                    end else if (req_be[3:2] != 2'b00 && req_be[1:0] == 2'b00) begin
                        rmw_read_halfs  <= 2'b10;
                        rmw_total_reads <= 2'd1;
                        wr_halfs        <= 2'b10;
                    end else begin
                        rmw_read_halfs  <= 2'b11;
                        rmw_total_reads <= 2'd2;
                        wr_halfs        <= 2'b11;
                    end
                    state        <= RMW_READ;
                end else begin
                    wr_halfs <= 2'b11;
                    state <= WRITE;
                end
            end else begin
                automatic reg [3:0] eff_burst;
                // Compute effective burst length clamped to row end (256 dword columns per row)
                rd_col_base     <= req_addr[9:2];     // dword column
                eff_burst       = (req_burst == 0) ? 1 : req_burst;
                rd_total_halfs  <= {eff_burst,1'b0};     // *2
                rd_issued       <= 5'd0;
                rd_received     <= 5'd0;
                state           <= READ;
            end
        end
    end

    // Issue length-1 READ commands every cycle after T_RCD.
    // Each READ returns one 16-bit half. We compose 32-bit words from pairs.
    READ: begin
        // Issue CAS READ one per cycle once T_RCD reached
        if ((cycle >= T_RCD) && (rd_issued < rd_total_halfs)) begin
            automatic reg [8:0] col16;
            cmd      <= CMD_Read;
            SDRAM_BA <= addr_buf[24:23];
            // Column: {dword_col + (rd_issued>>1), half_bit}
            // A[12:0] = {A12..A11=0, A10=auto-pre(last half), A9=0, A8..A0=column[8:0]}
            col16     = { (rd_col_base + (rd_issued[4:1])), rd_issued[0] };
            a         <= {2'b00, (rd_issued == rd_total_halfs-1), 1'b0, col16};
            rd_issued <= rd_issued + 5'd1;
        end

        // Capture returning 16-bit data after CAS latency (+1 for the dq_r stage)
        if ((cycle >= (T_RCD + CAS + 2)) && (rd_received < rd_issued)) begin
            if (!rd_received[0]) begin
                rd_lo16 <= dq_r;                  // low half
            end else begin
                dout_word <= {dq_r, rd_lo16};     // high half completes a 32-bit word
                data_resp_pulse <= 1'b1;
                // Update per-port holding register so dout* remains valid after the pulse
                case (req_id_buf)
                2'd0: dout_buf0 <= {dq_r, rd_lo16};
                2'd1: dout_buf1 <= {dq_r, rd_lo16};
                default: dout_buf2 <= {dq_r, rd_lo16};
                endcase

                // If that was the last half in the burst, signal burst_done and go idle
                if (rd_received + 5'd1 == rd_total_halfs) begin
                    burst_done_pulse <= 1'b1;
                    busy_buf <= 1'b0;
                    state    <= IDLE;
                end
            end
            rd_received <= rd_received + 5'd1;
        end
    end

    // Boards without DQM must read the original dword and merge bytes locally.
    RMW_READ: begin
        if ((cycle >= T_RCD) && (rmw_issued < rmw_total_reads)) begin
            automatic reg [8:0] col16;
            automatic reg       half_sel;
            half_sel = (rmw_read_halfs == 2'b10) ? 1'b1 :
                       (rmw_read_halfs == 2'b01) ? 1'b0 :
                       rmw_issued[0];
            cmd      <= CMD_Read;
            SDRAM_BA <= addr_buf[24:23];
            col16    = {addr_buf[9:2], half_sel};
            a        <= {2'b00, (rmw_issued == rmw_total_reads-1), 1'b0, col16};
            rmw_issued <= rmw_issued + 2'd1;
        end

        if ((cycle >= (T_RCD + CAS + 2)) && (rmw_received < rmw_issued)) begin
            automatic reg       half_sel;
            automatic reg [31:0] old_word;
            half_sel = (rmw_read_halfs == 2'b10) ? 1'b1 :
                       (rmw_read_halfs == 2'b01) ? 1'b0 :
                       rmw_received[0];
            old_word = rmw_old_data;

            if (!half_sel) begin
                old_word[15:0] = dq_r;
            end else begin
                old_word[31:16] = dq_r;
            end

            rmw_old_data <= old_word;

            if (rmw_received + 2'd1 == rmw_total_reads) begin
                din_buf <= byte_merge(old_word, din_buf, be_buf);
                be_buf  <= (wr_halfs == 2'b01) ? 4'b0011 :
                           (wr_halfs == 2'b10) ? 4'b1100 : 4'b1111;
                state   <= RMW_ACT;
                cycle   <= 5'd0;
            end
            rmw_received <= rmw_received + 2'd1;
        end
    end

    // Re-open the row after the auto-precharged RMW read, then do a full-word write.
    RMW_ACT: begin
        if (cycle == 5'd0) begin
            cmd      <= CMD_BankActivate;
            SDRAM_BA <= addr_buf[24:23];
            a        <= addr_buf[22:10];
            cycle    <= 5'd1;
            state    <= WRITE;
        end
    end

    // Write selected 16-bit halves. MiSTer SDRAM modules have no DQM, so
    // partial byte writes are converted to the smallest safe half-word write.
    WRITE: begin
        // low half at T_RCD
        if (cycle == T_RCD && wr_halfs[0]) begin
            cmd      <= CMD_Write;
            SDRAM_BA <= addr_buf[24:23];
            a        <= {2'b00, !wr_halfs[1]/*AP if final*/, 1'b0, {addr_buf[9:2], 1'b0}};
            SDRAM_DQM<= HAS_DQM ? {~be_buf[1], ~be_buf[0]} : 2'b00;
            dq_out   <= din_buf[15:0];
            dq_oen   <= 1'b0;
        end

        // high half can immediately follow the low half; no idle bubble needed.
        if ((cycle == T_RCD && !wr_halfs[0] && wr_halfs[1]) ||
            (cycle == (T_RCD+1) && wr_halfs == 2'b11)) begin
            cmd      <= CMD_Write;
            SDRAM_BA <= addr_buf[24:23];
            a        <= {2'b00, 1'b1/*AP*/, 1'b0, {addr_buf[9:2], 1'b1}};
            SDRAM_DQM<= HAS_DQM ? {~be_buf[3], ~be_buf[2]} : 2'b00;
            dq_out   <= din_buf[31:16];
            dq_oen   <= 1'b0;
        end

        if ((cycle == (T_RCD+1) && wr_halfs != 2'b11) ||
            (cycle == (T_RCD+2) && wr_halfs == 2'b11)) begin
            dq_oen <= 1'b1;
        end

        // Auto-precharged write must satisfy tDAL = tWR + tRP before the next ACT.
        if ((wr_halfs == 2'b11 && cycle == (T_RCD + T_DAL_I)) ||
            (wr_halfs != 2'b11 && cycle == (T_RCD + T_DAL_I - 1))) begin
            busy_buf <= 1'b0;
            state    <= IDLE;
        end
    end

    REFRESH: begin
        if (cycle == T_RC) begin
            state    <= IDLE;
            busy_buf <= 1'b0;
        end
    end

    default: state <= IDLE;
    endcase

    // Reset
    if (!resetn) begin
        state      <= INIT;
        busy_buf   <= 1'b1;
        dq_oen     <= 1'b1;
        SDRAM_DQM  <= 2'b00;
        SDRAM_BA   <= 2'b00;
        a          <= 13'd0;
        cmd        <= CMD_NOP;

        cycle      <= 5'd0;
        refresh_cnt<= {REFRESH_CNT_W{1'b0}};
        rmw_issued <= 2'd0;
        rmw_received <= 2'd0;
        rmw_total_reads <= 2'd0;
        rmw_read_halfs <= 2'b00;
        rmw_old_data <= 32'd0;
        wr_halfs <= 2'b11;

        ready_pulse <= 3'b000;

        dout_buf0 <= 32'd0;
        dout_buf1 <= 32'd0;
        dout_buf2 <= 32'd0;

        rd_total_halfs <= 5'd0;
        rd_issued      <= 5'd0;
        rd_received    <= 5'd0;

        data_resp_pulse <= 1'b0;
        burst_done_pulse <= 1'b0;
    end
end

// Generate cfg_now pulse after initialization delay (normally 200us)
reg  [23:0]   rst_cnt;        // enough for 200us at ~65MHz
reg           rst_done, rst_done_p1;

always @(posedge clk) begin
    rst_done_p1 <= rst_done;
    cfg_now     <= rst_done & ~rst_done_p1;     // rising edge

    if (rst_cnt != (FREQ/1000)*200/1000) begin  // count to 200us
        rst_cnt  <= rst_cnt + 24'd1;
        rst_done <= 1'b0;
    end else begin
        rst_done <= 1'b1;
    end

    if (!resetn) begin
        rst_cnt  <= 24'd0;
        rst_done <= 1'b0;
    end
end

endmodule
