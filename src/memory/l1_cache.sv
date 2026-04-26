// L1 cache with write buffer
// nand2mario, April 2026
//
// 4-way set-associative, PLRU replacement, default 256 sets (SET_BITS=8),
// 4-DWORD (16-byte) lines = 16KB total
// Read-allocate, write-through, Burst line fill from SDRAM (burstcount=4), early restart
// 2-entry write buffer absorbs write latency.
//
// VIPT 0-wait-state design:
//   1. lookup + lookup_addr → tag + data BRAM pre-read (cycle N)
//   2. cpu_valid + cpu_addr → tag compare (vs registered tags) + response (cycle N+1)
//   lookup fires 1 cycle before cpu_valid for both reads and writes.
//
// Data and tag accesses are synchronous (registered read at lookup time). This enables
// the cache to return result in 1 cycle after request arrives from BIU.
//
// PLRU tree (3 bits): bit[2]=top (0→left{0,1}, 1→right{2,3}),
//   bit[1]=left (0→way0, 1→way1), bit[0]=right (0→way2, 1→way3)
//
// Address decomposition (byte address, max 32MB, default SET_BITS=8):
//   [24:12] = tag (13 bits)
//   [11:4]  = set index (8 bits, 256 sets)
//   [3:2]   = offset (2 bits, selects DWORD in line)
//   [1:0]   = byte (handled by byte enables)
module l1_cache #(
    parameter integer SET_BITS = 8
) (
    input         clk,
    input         reset,

    // CPU side — physical address from BIU (valid/ready protocol)
    input  [31:0] cpu_addr,       // physical byte address
    input  [31:0] cpu_din,        // write data
    output [31:0] cpu_dout,       // read data
    input   [3:0] cpu_be,         // byte enables
    input         cpu_valid,      // request valid
    input         cpu_write,      // 1=write, 0=read
    output        cpu_ready,      // acceptance pulse
    output        cpu_resp_valid, // read data valid pulse

    // VIPT early cache lookup handshake (fires 1 cycle before cpu_valid)
    input  [31:0] lookup_addr,    // linear address for cache indexing
    input         lookup,         // valid: request tag+data pre-read this cycle
    input         lookup_cancel,  // drop preread when upstream abandons this launch
    output        lookup_ready,   // cache can accept a new pre-read

    // Memory side
    output [31:0] mem_addr,
    output [31:0] mem_din,
    input  [31:0] mem_dout,
    output  [3:0] mem_be,
    output  [7:0] mem_burstcount,
    input         mem_busy,
    output        mem_valid,
    output        mem_write,
    input         mem_ready,
    input         mem_resp_valid,

    // DMA snoop
    input  [31:0] snoop_addr,
    input         snoop_valid,

    input         cache_enable
);

localparam integer WORD_OFFSET_BITS = 2;
localparam integer BYTE_OFFSET_BITS = 2;
localparam integer LINE_OFFSET_BITS = WORD_OFFSET_BITS + BYTE_OFFSET_BITS;
localparam integer PAGE_OFFSET_BITS = 12;
localparam integer MAX_VIPT_SET_BITS = PAGE_OFFSET_BITS - LINE_OFFSET_BITS;
localparam integer NUM_SETS = 1 << SET_BITS;
localparam integer BRAM_ADDR_BITS = SET_BITS + WORD_OFFSET_BITS;
localparam integer TAG_BITS = 25 - LINE_OFFSET_BITS - SET_BITS;
localparam integer SET_LSB = LINE_OFFSET_BITS;
localparam integer SET_MSB = SET_LSB + SET_BITS - 1;
localparam integer TAG_LSB = SET_MSB + 1;
localparam integer TAG_MSB = 24;
localparam integer TAG_RAM_BITS = (TAG_BITS < 16) ? 16 : TAG_BITS;
localparam integer META_RAM_BITS = 16;
localparam integer META_VALID0_BIT = 0;
localparam integer META_VALID1_BIT = 1;
localparam integer META_VALID2_BIT = 2;
localparam integer META_VALID3_BIT = 3;
localparam integer SNOOP_Q_DEPTH = 4;
localparam integer SNOOP_Q_IDX_BITS = (SNOOP_Q_DEPTH <= 1) ? 1 : $clog2(SNOOP_Q_DEPTH);
localparam [META_RAM_BITS-1:0] META_CLEAR = {META_RAM_BITS{1'b0}};

function [META_RAM_BITS-1:0] meta_pack(input valid0, input valid1, input valid2, input valid3);
begin
    meta_pack = {{(META_RAM_BITS-4){1'b0}}, valid3, valid2, valid1, valid0};
end
endfunction

function [3:0] way_hit_vec(
    input        lookup_valid_i,
    input  [3:0] valid_vec_i,
    input        set_invalid_i,
    input  [TAG_BITS-1:0] req_tag_i,
    input  [TAG_BITS-1:0] tag0_i,
    input  [TAG_BITS-1:0] tag1_i,
    input  [TAG_BITS-1:0] tag2_i,
    input  [TAG_BITS-1:0] tag3_i
);
begin
    if (!lookup_valid_i || set_invalid_i) begin
        way_hit_vec = 4'b0000;
    end else begin
        way_hit_vec[0] = valid_vec_i[0] && (tag0_i == req_tag_i);
        way_hit_vec[1] = valid_vec_i[1] && (tag1_i == req_tag_i);
        way_hit_vec[2] = valid_vec_i[2] && (tag2_i == req_tag_i);
        way_hit_vec[3] = valid_vec_i[3] && (tag3_i == req_tag_i);
    end
end
endfunction

function [1:0] way_encode(input [3:0] hit_vec_i);
begin
    way_encode = hit_vec_i[0] ? 2'd0 :
                 hit_vec_i[1] ? 2'd1 :
                 hit_vec_i[2] ? 2'd2 : 2'd3;
end
endfunction

function [31:0] way_data_mux(
    input [1:0]  way_i,
    input [31:0] data0_i,
    input [31:0] data1_i,
    input [31:0] data2_i,
    input [31:0] data3_i
);
begin
    case (way_i)
        2'd0: way_data_mux = data0_i;
        2'd1: way_data_mux = data1_i;
        2'd2: way_data_mux = data2_i;
        default: way_data_mux = data3_i;
    endcase
end
endfunction

// PLRU bits: plru[0]=top (0→left, 1→right), plru[1]=left (0→way0, 1→way1),
//            plru[2]=right (0→way2, 1→way3)
// After access, bits point AWAY from accessed way (toward victim).

// PLRU update: after accessing hit_way, point tree away from it
function [2:0] plru_update(input [2:0] plru, input [1:0] hit_way);
begin
    case (hit_way)
        2'd0: plru_update = {plru[2], 1'b1, 1'b1};   // top→right, left→way1
        2'd1: plru_update = {plru[2], 1'b0, 1'b1};   // top→right, left→way0
        2'd2: plru_update = {1'b1, plru[1], 1'b0};    // top→left, right→way3
        2'd3: plru_update = {1'b0, plru[1], 1'b0};    // top→left, right→way2
    endcase
end
endfunction

// PLRU victim selection: follow tree to find replacement way
function [1:0] plru_victim(input [2:0] plru);
begin
    if (!plru[0])       // top=0 → go left
        plru_victim = plru[1] ? 2'd1 : 2'd0;
    else                // top=1 → go right
        plru_victim = plru[2] ? 2'd3 : 2'd2;
end
endfunction

// ============================================================================
// Address decomposition (physical address from BIU at cpu_valid time)
// ============================================================================
wire [TAG_BITS-1:0] addr_tag = cpu_addr[TAG_MSB:TAG_LSB];
wire [SET_BITS-1:0] addr_set = cpu_addr[SET_MSB:SET_LSB];
wire [WORD_OFFSET_BITS-1:0] addr_offset = cpu_addr[LINE_OFFSET_BITS-1:BYTE_OFFSET_BITS];
wire [SET_BITS-1:0] snoop_set = snoop_addr[SET_MSB:SET_LSB];

wire addr_uncacheable = !cache_enable || (cpu_addr[31:17] == 15'h5);

// ============================================================================
// Tag storage — fully synchronous: pre-read at lookup time, registered output.
// ============================================================================
(* ram_style = "block" *) reg [TAG_RAM_BITS-1:0] tag_way0 [0:NUM_SETS-1] /* synthesis syn_ramstyle="block_ram" */;
(* ram_style = "block" *) reg [TAG_RAM_BITS-1:0] tag_way1 [0:NUM_SETS-1] /* synthesis syn_ramstyle="block_ram" */;
(* ram_style = "block" *) reg [TAG_RAM_BITS-1:0] tag_way2 [0:NUM_SETS-1] /* synthesis syn_ramstyle="block_ram" */;
(* ram_style = "block" *) reg [TAG_RAM_BITS-1:0] tag_way3 [0:NUM_SETS-1] /* synthesis syn_ramstyle="block_ram" */;
(* ram_style = "block" *) reg [META_RAM_BITS-1:0] meta_ram [0:NUM_SETS-1] /* synthesis syn_ramstyle="block_ram" */;
reg [2:0] plru_set [0:NUM_SETS-1];

// Pre-read tags at lookup time (registered output)
// VIPT guarantee: set index bits are below the 4KB page boundary,
// so lookup_addr[SET_MSB:SET_LSB] == cpu_addr[SET_MSB:SET_LSB] at cpu_valid time.
reg [TAG_BITS-1:0] tag0_r, tag1_r, tag2_r, tag3_r;
reg        v0_r, v1_r, v2_r, v3_r;
reg [SET_BITS-1:0] preread_set_r;
reg        preread_invalid_r;
wire [2:0] addr_plru = plru_set[addr_set];

// Hit detection: compare physical tag against pre-read (registered) tags.
// A pending snoop bit keeps any set with queued invalidation out of the hit
// path without scanning the snoop queue combinationally.
wire addr_set_invalid = snoop_pending[addr_set] || (snoop_valid && (snoop_set == addr_set));
wire [3:0] valid_vec = preread_invalid_r ? 4'b0000 : {v3_r, v2_r, v1_r, v0_r};
wire [3:0] hit_vec = way_hit_vec(lookup_valid, valid_vec, addr_set_invalid, addr_tag,
                                 tag0_r, tag1_r, tag2_r, tag3_r);
wire cache_hit = |hit_vec;
wire [1:0] hit_way_enc = way_encode(hit_vec);

// ============================================================================
// Data BRAM — 4 BSRAMs, NUM_SETS * 4 DWORDs each
// Read on lookup (VIPT: 1 cycle before cpu_valid).
// bram_rdata holds result until next lookup.
// ============================================================================
reg         bram_we0, bram_we1, bram_we2, bram_we3;
reg [BRAM_ADDR_BITS-1:0] bram_waddr;
reg  [31:0] bram_wdata;
reg         tag_we0, tag_we1, tag_we2, tag_we3;
reg [SET_BITS-1:0] tag_waddr;
reg [TAG_RAM_BITS-1:0] tag_wdata;
reg         meta_we;
reg [SET_BITS-1:0] meta_waddr;
reg [META_RAM_BITS-1:0] meta_wdata;

wire [BRAM_ADDR_BITS-1:0] bram_raddr =
    {lookup_addr[SET_MSB:SET_LSB], lookup_addr[LINE_OFFSET_BITS-1:BYTE_OFFSET_BITS]};
wire [SET_BITS-1:0] tag_raddr = lookup_addr[SET_MSB:SET_LSB];
wire tag_raddr_invalid = snoop_pending[tag_raddr] || (snoop_valid && (snoop_set == tag_raddr));
reg  [31:0] bram_rdata0, bram_rdata1, bram_rdata2, bram_rdata3;

reg  [31:0] data_way0 [0:(NUM_SETS << WORD_OFFSET_BITS)-1];
reg  [31:0] data_way1 [0:(NUM_SETS << WORD_OFFSET_BITS)-1];
reg  [31:0] data_way2 [0:(NUM_SETS << WORD_OFFSET_BITS)-1];
reg  [31:0] data_way3 [0:(NUM_SETS << WORD_OFFSET_BITS)-1];

wire lookup_accepted = lookup && lookup_ready;
assign lookup_ready = !meta_init_active && !fill_just_done && !lookup_valid && (state == S_IDLE);
always @(posedge clk) begin
    if (lookup_accepted) begin
        bram_rdata0 <= data_way0[bram_raddr];
        bram_rdata1 <= data_way1[bram_raddr];
        bram_rdata2 <= data_way2[bram_raddr];
        bram_rdata3 <= data_way3[bram_raddr];
    end
end

always @(posedge clk) begin
    if (reset) begin
        v0_r              <= 0;
        v1_r              <= 0;
        v2_r              <= 0;
        v3_r              <= 0;
        preread_set_r     <= 0;
        preread_invalid_r <= 1'b1;
    end else begin
        if (snoop_pending[preread_set_r] || (snoop_valid && (snoop_set == preread_set_r)))
            preread_invalid_r <= 1'b1;

        if (lookup_accepted) begin
            tag0_r <= tag_way0[tag_raddr][TAG_BITS-1:0];
            tag1_r <= tag_way1[tag_raddr][TAG_BITS-1:0];
            tag2_r <= tag_way2[tag_raddr][TAG_BITS-1:0];
            tag3_r <= tag_way3[tag_raddr][TAG_BITS-1:0];
            v0_r   <= meta_ram[tag_raddr][META_VALID0_BIT];
            v1_r   <= meta_ram[tag_raddr][META_VALID1_BIT];
            v2_r   <= meta_ram[tag_raddr][META_VALID2_BIT];
            v3_r   <= meta_ram[tag_raddr][META_VALID3_BIT];
            // Keep snoop invalidation on a single sticky bit instead of
            // fanning the compare into every preread metadata register.
            preread_set_r     <= tag_raddr;
            preread_invalid_r <= tag_raddr_invalid;
        end
    end
end

always @(posedge clk) begin
    if (bram_we0) data_way0[bram_waddr] <= bram_wdata;
    if (bram_we1) data_way1[bram_waddr] <= bram_wdata;
    if (bram_we2) data_way2[bram_waddr] <= bram_wdata;
    if (bram_we3) data_way3[bram_waddr] <= bram_wdata;
end

always @(posedge clk) begin
    if (tag_we0) tag_way0[tag_waddr] <= tag_wdata;
    if (tag_we1) tag_way1[tag_waddr] <= tag_wdata;
    if (tag_we2) tag_way2[tag_waddr] <= tag_wdata;
    if (tag_we3) tag_way3[tag_waddr] <= tag_wdata;
end

always @(posedge clk) begin
    if (meta_we) meta_ram[meta_waddr] <= meta_wdata;
end

// ============================================================================
// Write buffer
// ============================================================================
reg [29:0] wb_addr  [0:1];
reg [31:0] wb_data  [0:1];
reg  [3:0] wb_be    [0:1];
reg        wb_valid [0:1];
reg        wb_head;
reg        wb_tail;

wire wb_full  = wb_valid[0] && wb_valid[1];
wire wb_empty = !wb_valid[0] && !wb_valid[1];

wire [29:0] rd_addr_dw = cpu_addr[31:2];
wire wb_hit0 = wb_valid[0] && (wb_addr[0] == rd_addr_dw);
wire wb_hit1 = wb_valid[1] && (wb_addr[1] == rd_addr_dw);
wire wb_hazard = wb_hit0 || wb_hit1;

function [31:0] byte_merge(input [31:0] old_data, input [31:0] new_data, input [3:0] be);
    byte_merge = {be[3] ? new_data[31:24] : old_data[31:24],
                  be[2] ? new_data[23:16] : old_data[23:16],
                  be[1] ? new_data[15:8]  : old_data[15:8],
                  be[0] ? new_data[7:0]   : old_data[7:0]};
endfunction

wire [31:0] wb_fwd_data;
wire  [3:0] wb_fwd_be;
wire newer = ~wb_tail;
assign wb_fwd_data = wb_hit0 && wb_hit1 ?
                     byte_merge(byte_merge(32'h0, wb_data[wb_tail], wb_be[wb_tail]),
                                wb_data[newer], wb_be[newer]) :
                     wb_hit0 ? wb_data[0] : wb_data[1];
assign wb_fwd_be   = wb_hit0 && wb_hit1 ?
                     (wb_be[0] | wb_be[1]) :
                     wb_hit0 ? wb_be[0] : wb_be[1];

// ============================================================================
// FSM
// ============================================================================
localparam S_IDLE        = 3'd0;
localparam S_FILL        = 3'd1;
localparam S_BYPASS_WAIT = 3'd2;
localparam S_WRITE_UPD   = 3'd3;

reg  [2:0] state;
reg [WORD_OFFSET_BITS-1:0] fill_count;
reg [WORD_OFFSET_BITS-1:0] target_offset;
reg [SET_BITS-1:0] fill_set;
reg [TAG_BITS-1:0] fill_tag;
reg  [1:0] fill_way;
reg        target_forwarded;
reg        fill_just_done;
reg        fill_requested;
reg        fill_meta_v0_r;
reg        fill_meta_v1_r;
reg        fill_meta_v2_r;
reg        fill_meta_v3_r;
reg  [2:0] fill_meta_plru_r;

// Write-update metadata
reg [31:0] wr_data_r;
reg  [3:0] wr_be_r;
reg        wr_hit_valid_r;
reg  [1:0] wr_hit_way_r;
reg [SET_BITS-1:0] wr_set_r;
reg [WORD_OFFSET_BITS-1:0] wr_offset_r;
reg [31:0] wr_base_data_r;
reg        last_cache_w_valid;
reg  [1:0] last_cache_w_way_r;
reg [BRAM_ADDR_BITS-1:0] last_cache_w_addr;
reg [31:0] last_cache_w_data;

// Sticky preread validity: set when lookup fires, held until the matching
// cpu_valid request is accepted into the cache hit/fill/bypass/write path.
reg        lookup_valid;

// Request metadata (for fill/bypass)
reg [31:0] req_addr_r;

// Registered WB hazard (for fill critical word forwarding)
reg        rd_wb_hazard_r;
reg [31:0] rd_wb_fwd_data_r;
reg  [3:0] rd_wb_fwd_be_r;

// Output registers (fill critical word + bypass)
reg [31:0] dout_r;
reg        resp_valid_r;
reg        ready_r;

reg        wb_draining;
reg        meta_init_active;
reg [SET_BITS-1:0] meta_init_set;
reg [SET_BITS-1:0] snoop_q_set [0:SNOOP_Q_DEPTH-1];
reg [SNOOP_Q_DEPTH-1:0] snoop_q_valid;
reg [NUM_SETS-1:0] snoop_pending;

// Memory interface
reg        mem_valid_r;
reg        mem_write_r;
reg [31:0] mem_addr_r;
reg [31:0] mem_din_r;
reg  [3:0] mem_be_r;
reg  [7:0] mem_burstcount_r;

wire fsm_using_bus = (state == S_FILL && fill_requested) || state == S_BYPASS_WAIT;
wire can_drain = !wb_empty && !fsm_using_bus && !mem_valid_r && !wb_draining
                 && (state == S_IDLE || (state == S_FILL && !fill_requested));

assign mem_addr       = mem_addr_r;
assign mem_din        = mem_din_r;
assign mem_be         = mem_be_r;
assign mem_burstcount = mem_burstcount_r;
assign mem_valid      = mem_valid_r;
assign mem_write      = mem_write_r;

// ============================================================================
// Response logic: combinational at cpu_valid time using pre-read tags.
// ============================================================================
wire cpu_rd_req = cpu_valid && !cpu_write;
wire cpu_wr_req = cpu_valid && cpu_write;

wire [TAG_BITS-1:0] req_addr_tag = req_addr_r[TAG_MSB:TAG_LSB];
wire [SET_BITS-1:0] req_addr_set = req_addr_r[SET_MSB:SET_LSB];
wire [WORD_OFFSET_BITS-1:0] req_addr_offset = req_addr_r[LINE_OFFSET_BITS-1:BYTE_OFFSET_BITS];
wire req_addr_uncacheable   = !cache_enable || (req_addr_r[31:17] == 15'h5);
wire [BRAM_ADDR_BITS-1:0] addr_bram_addr = {addr_set, addr_offset};
wire recent_hit = last_cache_w_valid && cache_hit
               && (last_cache_w_way_r == hit_way_enc)
               && (last_cache_w_addr == addr_bram_addr);
wire [31:0] hit_bram_data =
    way_data_mux(hit_way_enc, bram_rdata0, bram_rdata1, bram_rdata2, bram_rdata3);
wire [31:0] hit_base_data =
    recent_hit ? last_cache_w_data : hit_bram_data;
wire [31:0] accept_write_base_data =
    hit_base_data;

wire accept_read  = cpu_rd_req && lookup_valid && (state == S_IDLE) && !fill_just_done
                    && !meta_init_active
                    && (cache_hit || wb_empty);
wire accept_write = cpu_wr_req && lookup_valid && (state == S_IDLE) && !wb_full && !fill_just_done
                    && !meta_init_active;
wire lookup_consumed = accept_read || accept_write;

// Read hit: pre-read tags matched + data ready. 0-wait response.
wire read_hit = cpu_rd_req && (state == S_IDLE) && !fill_just_done
             && cache_hit && !addr_uncacheable;
wire [31:0] read_hit_dout = wb_hazard ?
    byte_merge(hit_base_data, wb_fwd_data, wb_fwd_be) :
    hit_base_data;

reg        snoop_q_has_valid;
reg        snoop_q_has_free;
reg [SNOOP_Q_IDX_BITS-1:0] snoop_q_service_idx;
reg [SNOOP_Q_IDX_BITS-1:0] snoop_q_free_idx;
reg [SET_BITS-1:0] snoop_q_service_set;
integer sq;
wire snoop_set_pending = snoop_pending[snoop_set];

always @(*) begin
    snoop_q_has_valid = 1'b0;
    snoop_q_has_free = 1'b0;
    snoop_q_service_idx = {SNOOP_Q_IDX_BITS{1'b0}};
    snoop_q_free_idx = {SNOOP_Q_IDX_BITS{1'b0}};
    snoop_q_service_set = {SET_BITS{1'b0}};
    for (sq = 0; sq < SNOOP_Q_DEPTH; sq = sq + 1) begin
        if (!snoop_q_has_valid && snoop_q_valid[sq]) begin
            snoop_q_has_valid = 1'b1;
            snoop_q_service_idx = sq[SNOOP_Q_IDX_BITS-1:0];
            snoop_q_service_set = snoop_q_set[sq];
        end
        if (!snoop_q_has_free && !snoop_q_valid[sq]) begin
            snoop_q_has_free = 1'b1;
            snoop_q_free_idx = sq[SNOOP_Q_IDX_BITS-1:0];
        end
    end
end

assign cpu_dout       = read_hit ? read_hit_dout : dout_r;
assign cpu_resp_valid = read_hit || resp_valid_r;
assign cpu_ready      = read_hit || ready_r;

initial begin
    if (SET_BITS > MAX_VIPT_SET_BITS) begin
        $error("l1_cache SET_BITS=%0d exceeds VIPT-safe maximum %0d for 4KB pages and 16-byte lines",
               SET_BITS, MAX_VIPT_SET_BITS);
        $fatal(1);
    end
end

always @(posedge clk) begin
    logic meta_port_used_v;
    if (reset) begin
        state          <= S_IDLE;
        dout_r         <= 0;
        resp_valid_r   <= 0;
        ready_r        <= 0;
        fill_just_done <= 0;
        fill_requested <= 0;
        lookup_valid   <= 0;
        mem_valid_r    <= 0;
        mem_write_r    <= 0;
        mem_addr_r     <= 0;
        mem_din_r      <= 0;
        mem_be_r       <= 0;
        mem_burstcount_r <= 0;
        wb_valid[0]    <= 0;
        wb_valid[1]    <= 0;
        wb_head        <= 0;
        wb_tail        <= 0;
        wb_draining    <= 0;
        meta_init_active <= 1;
        meta_init_set  <= 0;
        snoop_q_valid  <= {SNOOP_Q_DEPTH{1'b0}};
        snoop_pending  <= {NUM_SETS{1'b0}};
        bram_we0       <= 0;
        bram_we1       <= 0;
        bram_we2       <= 0;
        bram_we3       <= 0;
        tag_we0        <= 0;
        tag_we1        <= 0;
        tag_we2        <= 0;
        tag_we3        <= 0;
        meta_we        <= 0;
        wr_base_data_r <= 0;
        fill_meta_v0_r <= 0;
        fill_meta_v1_r <= 0;
        fill_meta_v2_r <= 0;
        fill_meta_v3_r <= 0;
        fill_meta_plru_r <= 0;
        last_cache_w_valid <= 0;
        last_cache_w_way_r <= 0;
        last_cache_w_addr <= 0;
        last_cache_w_data <= 0;
        wr_hit_valid_r <= 0;
        wr_hit_way_r   <= 0;
    end else begin
        meta_port_used_v = 1'b0;
        resp_valid_r   <= 0;
        ready_r        <= 0;
        fill_just_done <= 0;
        if (meta_init_active)
            lookup_valid <= 1'b0;
        else if (lookup_cancel)
            lookup_valid <= 1'b0;
        else if (lookup_accepted)
            lookup_valid <= 1'b1;
        else if (lookup_consumed)
            lookup_valid <= 1'b0;
        bram_we0       <= 0;
        bram_we1       <= 0;
        bram_we2       <= 0;
        bram_we3       <= 0;
        tag_we0        <= 0;
        tag_we1        <= 0;
        tag_we2        <= 0;
        tag_we3        <= 0;
        meta_we        <= 0;
        if (mem_valid_r && mem_ready)
            mem_valid_r <= 0;

        if (meta_init_active) begin
            meta_we    <= 1;
            meta_waddr <= meta_init_set;
            meta_wdata <= META_CLEAR;
            plru_set[meta_init_set] <= 3'b000;
            if (meta_init_set == NUM_SETS-1)
                meta_init_active <= 0;
            else
                meta_init_set <= meta_init_set + 1'b1;
        end else begin
            // DMA snoop
            if (snoop_valid) begin
                if (last_cache_w_valid && (last_cache_w_addr[BRAM_ADDR_BITS-1:WORD_OFFSET_BITS] == snoop_set))
                    last_cache_w_valid <= 0;
            end

            // Write buffer drain
            if (wb_draining && mem_ready) begin
                wb_valid[wb_tail] <= 0;
                wb_tail           <= ~wb_tail;
                wb_draining       <= 0;
            end

            if (can_drain) begin
                mem_valid_r      <= 1;
                mem_write_r      <= 1;
                mem_addr_r       <= {wb_addr[wb_tail], 2'b00};
                mem_din_r        <= wb_data[wb_tail];
                mem_be_r         <= wb_be[wb_tail];
                mem_burstcount_r <= 8'd1;
                wb_draining      <= 1;
            end

            // =================================================================
            // Main FSM
            // =================================================================
            case (state)
            S_IDLE: begin
                if (accept_write) begin
                    // ---- WRITE: push to WB ----
                    ready_r <= 1;
                    wb_addr[wb_head]  <= cpu_addr[31:2];
                    wb_data[wb_head]  <= cpu_din;
                    wb_be[wb_head]    <= cpu_be;
                    wb_valid[wb_head] <= 1;
                    wb_head           <= ~wb_head;

                    // Write hit: update cache BRAM. Pre-read tags tell us which way.
                    // Data BRAM was pre-read at lookup time; S_WRITE_UPD does merge.
                    if (!addr_uncacheable && cache_hit) begin
                        wr_data_r      <= cpu_din;
                        wr_be_r        <= cpu_be;
                        wr_hit_valid_r <= 1;
                        wr_hit_way_r   <= hit_way_enc;
                        wr_base_data_r <= accept_write_base_data;
                        wr_set_r       <= addr_set;
                        wr_offset_r    <= addr_offset;
                        state          <= S_WRITE_UPD;
                    end
                end else if (accept_read) begin
                    // ---- READ ----
                    req_addr_r <= cpu_addr;

                    if (addr_uncacheable) begin
                        ready_r          <= 1;
                        mem_addr_r       <= cpu_addr;
                        mem_be_r         <= cpu_be;
                        mem_burstcount_r <= 8'd1;
                        mem_valid_r      <= 1;
                        mem_write_r      <= 0;
                        state            <= S_BYPASS_WAIT;
                    end else if (cache_hit) begin
                        // VIPT hit: respond immediately using pre-read tags.
                        // read_hit fires combinationally → cpu_resp_valid + cpu_ready.
                        plru_set[addr_set] <= plru_update(addr_plru, hit_way_enc);
                    end else begin
                        // Cache miss: start fill
                        ready_r          <= 1;
                        fill_set         <= addr_set;
                        fill_tag         <= addr_tag;
                        fill_way         <= plru_victim(addr_plru);
                        fill_count       <= 0;
                        target_offset    <= addr_offset;
                        target_forwarded <= 0;
                        fill_requested   <= 0;
                        fill_meta_v0_r   <= v0_r;
                        fill_meta_v1_r   <= v1_r;
                        fill_meta_v2_r   <= v2_r;
                        fill_meta_v3_r   <= v3_r;
                        fill_meta_plru_r <= addr_plru;
                        rd_wb_hazard_r   <= wb_hazard;
                        rd_wb_fwd_data_r <= wb_fwd_data;
                        rd_wb_fwd_be_r   <= wb_fwd_be;
                        state            <= S_FILL;
                    end
                end
            end

            S_FILL: begin
                if (!fill_requested && wb_empty && !wb_draining && !mem_valid_r) begin
                    mem_addr_r       <= {req_addr_r[31:4], 4'b0};
                    mem_be_r         <= 4'b1111;
                    mem_burstcount_r <= 8'd4;
                    mem_valid_r      <= 1;
                    mem_write_r      <= 0;
                    fill_requested   <= 1;
                end

                if (mem_resp_valid) begin
                    bram_waddr <= {fill_set, fill_count};
                    bram_wdata <= mem_dout;
                    last_cache_w_valid <= 1;
                    last_cache_w_way_r <= fill_way;
                    last_cache_w_addr <= {fill_set, fill_count};
                    last_cache_w_data <= mem_dout;
                    case (fill_way)
                        2'd0: bram_we0 <= 1;
                        2'd1: bram_we1 <= 1;
                        2'd2: bram_we2 <= 1;
                        2'd3: bram_we3 <= 1;
                    endcase

                    if (fill_count == target_offset && !target_forwarded) begin
                        if (rd_wb_hazard_r) begin
                            dout_r <= byte_merge(mem_dout, rd_wb_fwd_data_r, rd_wb_fwd_be_r);
                            rd_wb_hazard_r <= 0;
                        end else begin
                            dout_r <= mem_dout;
                        end
                        resp_valid_r     <= 1;
                        target_forwarded <= 1;
                    end

                    if (fill_count == {WORD_OFFSET_BITS{1'b1}}) begin
                        tag_waddr <= fill_set;
                        tag_wdata <= {{(TAG_RAM_BITS-TAG_BITS){1'b0}}, fill_tag};
                        case (fill_way)
                            2'd0: tag_we0 <= 1;
                            2'd1: tag_we1 <= 1;
                            2'd2: tag_we2 <= 1;
                            2'd3: tag_we3 <= 1;
                        endcase
                        meta_we        <= 1;
                        meta_waddr     <= fill_set;
                        meta_wdata     <= meta_pack(
                            (fill_way == 2'd0) ? 1'b1 : fill_meta_v0_r,
                            (fill_way == 2'd1) ? 1'b1 : fill_meta_v1_r,
                            (fill_way == 2'd2) ? 1'b1 : fill_meta_v2_r,
                            (fill_way == 2'd3) ? 1'b1 : fill_meta_v3_r);
                        plru_set[fill_set] <= plru_update(fill_meta_plru_r, fill_way);
                        meta_port_used_v = 1'b1;
                        fill_just_done <= 1;
                        state          <= S_IDLE;
                    end

                    fill_count <= fill_count + 1'b1;
                end
            end

            S_BYPASS_WAIT: begin
                if (mem_resp_valid) begin
                    dout_r       <= mem_dout;
                    resp_valid_r <= 1;
                    state        <= S_IDLE;
                end
            end

            S_WRITE_UPD: begin
                // Byte-merge and update matching way using the cache word snapshot
                // captured when the write was accepted.
                bram_waddr <= {wr_set_r, wr_offset_r};
                bram_wdata <= byte_merge(wr_base_data_r, wr_data_r, wr_be_r);
                if (wr_hit_valid_r) begin
                    case (wr_hit_way_r)
                    2'd0: bram_we0 <= 1;
                    2'd1: bram_we1 <= 1;
                    2'd2: bram_we2 <= 1;
                    default: bram_we3 <= 1;
                    endcase
                    last_cache_w_valid <= 1;
                    last_cache_w_way_r <= wr_hit_way_r;
                    last_cache_w_addr <= {wr_set_r, wr_offset_r};
                    last_cache_w_data <= byte_merge(wr_base_data_r, wr_data_r, wr_be_r);
                end
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase

            if (!meta_port_used_v && snoop_q_has_valid) begin
                meta_we                   <= 1;
                meta_waddr                <= snoop_q_service_set;
                meta_wdata                <= META_CLEAR;
                snoop_pending[snoop_q_service_set] <= 1'b0;
                if (snoop_valid && !snoop_set_pending && !snoop_q_has_free) begin
                    snoop_q_set[snoop_q_service_idx] <= snoop_set;
                    snoop_q_valid[snoop_q_service_idx] <= 1'b1;
                    snoop_pending[snoop_set] <= 1'b1;
                end else begin
                    snoop_q_valid[snoop_q_service_idx] <= 1'b0;
                end
            end

            if (snoop_valid && !snoop_set_pending && snoop_q_has_free) begin
                snoop_q_set[snoop_q_free_idx] <= snoop_set;
                snoop_q_valid[snoop_q_free_idx] <= 1'b1;
                snoop_pending[snoop_set] <= 1'b1;
            end

            if (snoop_valid && !snoop_set_pending && !snoop_q_has_free &&
                meta_port_used_v) begin
                // Fallback safety net: if snoops arrive faster than the small queue
                // can drain while metadata BRAM is busy, block the cache and scrub
                // all metadata rather than risk a stale hit.
                meta_init_active <= 1'b1;
                meta_init_set    <= {SET_BITS{1'b0}};
                snoop_q_valid    <= {SNOOP_Q_DEPTH{1'b0}};
                snoop_pending    <= {NUM_SETS{1'b0}};
                lookup_valid     <= 1'b0;
                last_cache_w_valid <= 1'b0;
            end
        end

    end
end

// synthesis translate_off
localparam integer DBG_SHADOW_DWORDS = 1 * 1024 * 1024;  // 4MB coverage
reg [31:0] dbg_shadow [0:DBG_SHADOW_DWORDS-1] /* verilator public_flat_rw */;
reg        dbg_shvalid [0:DBG_SHADOW_DWORDS-1];
reg        dbg_cachecheck_en;
reg        dbg_cachecheck_failed;
reg [31:0] dbg_cycle;
wire [31:0] dbg_read_addr = read_hit ? cpu_addr : req_addr_r;
wire [21:0] dbg_rd_idx = dbg_read_addr[23:2];
wire [21:0] dbg_wr_idx = mem_addr_r[23:2];
wire dbg_accept_write = accept_write;
wire [31:0] dbg_exp_masked = byte_merge(32'h0, dbg_shadow[dbg_rd_idx], cpu_be);
wire [31:0] dbg_got_masked = byte_merge(32'h0, cpu_dout, cpu_be);
reg        dbg_req_accepted;

initial begin
    dbg_cachecheck_en = 1'b0;
    dbg_cachecheck_failed = 1'b0;
    dbg_cycle = 32'h0;
    for (integer j = 0; j < DBG_SHADOW_DWORDS; j = j + 1)
        dbg_shvalid[j] = 1'b0;
end

always @(posedge clk) begin
    if (reset) begin
        dbg_cachecheck_en <= $test$plusargs("cachecheck");
        dbg_cachecheck_failed <= 1'b0;
        dbg_cycle <= 32'h0;
    end else if (dbg_cachecheck_en) begin
        dbg_cycle <= dbg_cycle + 1'b1;
        if (dbg_accept_write && cpu_addr[23:2] < DBG_SHADOW_DWORDS) begin
            if (!dbg_shvalid[cpu_addr[23:2]])
                dbg_shadow[cpu_addr[23:2]] = 32'h0;
            dbg_shvalid[cpu_addr[23:2]] = 1'b1;
            if (cpu_be[0]) dbg_shadow[cpu_addr[23:2]][7:0]   = cpu_din[7:0];
            if (cpu_be[1]) dbg_shadow[cpu_addr[23:2]][15:8]  = cpu_din[15:8];
            if (cpu_be[2]) dbg_shadow[cpu_addr[23:2]][23:16] = cpu_din[23:16];
            if (cpu_be[3]) dbg_shadow[cpu_addr[23:2]][31:24] = cpu_din[31:24];
        end

        if (mem_valid_r && mem_write_r && mem_ready && dbg_wr_idx < DBG_SHADOW_DWORDS) begin
            if (!dbg_shvalid[dbg_wr_idx])
                dbg_shadow[dbg_wr_idx] = 32'h0;
            dbg_shvalid[dbg_wr_idx] = 1'b1;
            if (mem_be_r[0]) dbg_shadow[dbg_wr_idx][7:0]   = mem_din_r[7:0];
            if (mem_be_r[1]) dbg_shadow[dbg_wr_idx][15:8]  = mem_din_r[15:8];
            if (mem_be_r[2]) dbg_shadow[dbg_wr_idx][23:16] = mem_din_r[23:16];
            if (mem_be_r[3]) dbg_shadow[dbg_wr_idx][31:24] = mem_din_r[31:24];
        end

        if (state == S_FILL && mem_resp_valid) begin
            automatic logic [31:0] dbg_fill_addr;
            automatic logic [21:0] dbg_fill_idx;
            dbg_fill_addr = {req_addr_r[31:4], 4'b0} + {28'b0, fill_count, 2'b0};
            dbg_fill_idx = dbg_fill_addr[23:2];
            if (dbg_fill_idx < DBG_SHADOW_DWORDS) begin
                dbg_shadow[dbg_fill_idx] = mem_dout;
                dbg_shvalid[dbg_fill_idx] = 1'b1;
            end
        end

        if (!dbg_cachecheck_failed && cpu_resp_valid &&
            dbg_rd_idx < DBG_SHADOW_DWORDS && dbg_shvalid[dbg_rd_idx] &&
            dbg_got_masked !== dbg_exp_masked) begin
            dbg_cachecheck_failed <= 1'b1;
            $display("CACHE MISMATCH cycle=%0d addr=0x%08X be=0x%1X got=0x%08X exp=0x%08X got_masked=0x%08X exp_masked=0x%08X state=%0d read_hit=%0d cpu_addr=0x%08X req_addr=0x%08X lookup_valid=%0d",
                     dbg_cycle, dbg_read_addr, cpu_be, cpu_dout, dbg_shadow[dbg_rd_idx],
                     dbg_got_masked, dbg_exp_masked,
                     state, read_hit, cpu_addr, req_addr_r, lookup_valid);
            $stop;
        end
    end
end

always @(posedge clk) begin
    if (reset || !cpu_valid)
        dbg_req_accepted <= 1'b0;
    else if ((state == S_IDLE) && (accept_read || accept_write))
        dbg_req_accepted <= 1'b1;

    if (!reset && !meta_init_active && (state == S_IDLE) && cpu_valid
        && !addr_uncacheable && !lookup_valid && !dbg_req_accepted) begin
        $display("CACHE PROTOCOL VIOLATION: cpu_valid without preread addr=%08X write=%0d state=%0d",
                 cpu_addr, cpu_write, state);
        $fatal(1);
    end
end
// synthesis translate_on

endmodule
