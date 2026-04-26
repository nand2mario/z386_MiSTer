// Dual-port RAM of any size
module dpram
 #(  parameter ADRW = 8, // address width (therefore total size is 2**ADRW)
     parameter DATW = 8, // data width
     parameter FILE = "", // initialization hex file, optional
     parameter SSRAM = 0
  )( input                 clock    , // clock
     input                 wren_a , // write enable for port A
     input                 wren_b , // write enable for port B
     input      [ADRW-1:0] address_a , // address      for port A
     input      [ADRW-1:0] address_b , // address      for port B
     input      [DATW-1:0] data_a, // write data   for port A
     input      [DATW-1:0] data_b, // write data   for port B
     output reg [DATW-1:0] q_a, // read  data   for port A
     output reg [DATW-1:0] q_b  // read  data   for port B
  );

    localparam MEMD = 1 << ADRW;

    // initialize RAM, with zeros if ZERO or file if FILE.
    integer i;

    reg [DATW-1:0] mem [0:MEMD-1]; // memory array
    initial
        if (FILE != "") $readmemh(FILE, mem);

    // PORT A
    always @(posedge clock) 
        if (wren_a)
            mem[address_a] <= data_a;

    always @(posedge clock) 
        if (!wren_a)
            q_a <= mem[address_a]; 

    // PORT B
    always @(posedge clock) 
        if (wren_b) 
            mem[address_b] <= data_b;

    always @(posedge clock)
        if (!wren_b)
            q_b <= mem[address_b];

endmodule

// Dual-port RAM of any size, with different clocks for each port
/* verilator lint_off MULTIDRIVEN */
module dpram_difclk
 #(  parameter ADRW = 8, // address width (therefore total size is 2**ADRW)
     parameter DATW = 8, // data width
     parameter FILE = ""  // initialization hex file, optional
  )( input                 clk_a,
     input                 clk_b,

     input      [ADRW-1:0] address_a , // address      for port A
     input      [DATW-1:0] data_a, // write data   for port A
     input                 wren_a , // write enable for port A
     input                 enable_a, // clock enable for port A
     output     [DATW-1:0] q_a, // read  data   for port A

     input      [ADRW-1:0] address_b , // address      for port B
     input      [DATW-1:0] data_b, // write data   for port B
     input                 wren_b , // write enable for port B
     input                 enable_b, // clock enable for port B
     output     [DATW-1:0] q_b  // read  data   for port B
  );

    // Some ao486 blocks leave enable_a/data_b/wren_b unconnected and rely on
    // the primitive defaults. Treat floating/unknown enables as enabled and
    // floating/unknown write-enables as deasserted so the simulation model
    // matches the intended Cyclone V altsyncram behavior more closely.
    wire enable_a_i = (enable_a == 1'b0) ? 1'b0 : 1'b1;
    wire enable_b_i = (enable_b == 1'b0) ? 1'b0 : 1'b1;
    wire wren_a_i   = (wren_a   == 1'b1);
    wire wren_b_i   = (wren_b   == 1'b1);

`ifdef ALTERA_RESERVED_QIS
    wire [DATW-1:0] q_a_int;
    wire [DATW-1:0] q_b_int;
    assign q_a = q_a_int;
    assign q_b = q_b_int;

    altsyncram #(
        .address_reg_b("CLOCK1"),
        .clock_enable_input_a("NORMAL"),
        .clock_enable_input_b("NORMAL"),
        .clock_enable_output_a("BYPASS"),
        .clock_enable_output_b("BYPASS"),
        .indata_reg_b("CLOCK1"),
        .intended_device_family("Cyclone V"),
        .lpm_hint(""),
        .lpm_type("altsyncram"),
        .numwords_a(1 << ADRW),
        .numwords_b(1 << ADRW),
        .operation_mode("BIDIR_DUAL_PORT"),
        .outdata_aclr_a("NONE"),
        .outdata_aclr_b("NONE"),
        .outdata_reg_a("UNREGISTERED"),
        .outdata_reg_b("UNREGISTERED"),
        .power_up_uninitialized("FALSE"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .init_file(FILE),
        .widthad_a(ADRW),
        .widthad_b(ADRW),
        .width_a(DATW),
        .width_b(DATW),
        .width_byteena_a(1),
        .width_byteena_b(1),
        .wrcontrol_wraddress_reg_b("CLOCK1")
    ) ram (
        .address_a(address_a),
        .address_b(address_b),
        .clock0(clk_a),
        .clock1(clk_b),
        .clocken0(enable_a_i),
        .clocken1(enable_b_i),
        .data_a(data_a),
        .data_b(data_b),
        .wren_a(wren_a_i),
        .wren_b(wren_b_i),
        .q_a(q_a_int),
        .q_b(q_b_int),
        .aclr0(1'b0),
        .aclr1(1'b0),
        .addressstall_a(1'b0),
        .addressstall_b(1'b0),
        .byteena_a(1'b1),
        .byteena_b(1'b1),
        .clocken2(1'b1),
        .clocken3(1'b1),
        .eccstatus(),
        .rden_a(1'b1),
        .rden_b(1'b1)
    );
`else
    localparam MEMD = 1 << ADRW;

    // initialize RAM, with zeros if ZERO or file if FILE.
    integer i;

    reg [DATW-1:0] q_a_r;
    reg [ADRW-1:0] address_b_r;
    assign q_a = q_a_r;
    assign q_b = mem[address_b_r];

    reg [DATW-1:0] mem [0:MEMD-1]; // memory array
    initial
        if (FILE != "") $readmemh(FILE, mem);

    // PORT A
    always @(posedge clk_a) 
        if (wren_a_i)
            mem[address_a] <= data_a;

    always @(posedge clk_a) 
        if (enable_a_i && !wren_a_i)
            q_a_r <= mem[address_a]; 

    // PORT B
    always @(posedge clk_b) 
        if (wren_b_i) 
            mem[address_b] <= data_b;

    always @(posedge clk_b)
        if (enable_b_i)
            address_b_r <= address_b;
`endif

endmodule
/* verilator lint_on MULTIDRIVEN */

// Dual-port RAM with byte enable
module dpram_be
 #(  parameter ADRW = 8, // address width (therefore total size is 2**ADRW)
     parameter DATW = 32 // data width
  )( input                 clock    , // clock
     input                 wren_a , // write enable for port A
     input                 wren_b , // write enable for port B
     input      [ADRW-1:0] address_a , // address      for port A
     input      [ADRW-1:0] address_b , // address      for port B
     input      [DATW/4-1:0] be_a, // byte enable for port A
     input      [DATW/4-1:0] be_b, // byte enable for port B
     input      [DATW-1:0] data_a, // write data   for port A
     input      [DATW-1:0] data_b, // write data   for port B
     output reg [DATW-1:0] q_a, // read  data   for port A
     output reg [DATW-1:0] q_b  // read  data   for port B
  );

    localparam MEMD = 1 << ADRW;

    // initialize RAM, with zeros if ZERO or file if FILE.
    integer i;

    reg [DATW-1:0] mem [0:MEMD-1]; // memory array

    // PORT A

    always @(posedge clock) 
        if (wren_a) 
            for (i = 0; i < DATW/8; i = i + 1'd1) begin
                if (be_a[i]) mem[address_a][i*8 +: 8] <= data_a[i*8 +: 8];
            end

    always @(posedge clock) 
        if (!wren_a)
            q_a <= mem[address_a]; 

    // PORT B
    always @(posedge clock) 
        if (wren_b) 
            for (i = 0; i < DATW/8; i = i + 1'd1) begin
                if (be_b[i]) mem[address_b][i*8 +: 8] <= data_b[i*8 +: 8];
            end

    always @(posedge clock)
        if (!wren_b)
            q_b <= mem[address_b];

endmodule

// Dual-port RAM with asynchronous read, modeling `altdpram`
module dpram_async #(
    parameter width = 8,
    parameter widthad = 8
) (
    input               clk,
    
    input [widthad-1:0] rdaddress, // read address
    input [widthad-1:0] wraddress, // write address
    input [width-1:0]   data,
    input               wren,
    output [width-1:0]  q
);

    reg [width-1:0] mem [0:2**widthad-1];

    assign q = mem[rdaddress];

    always @(posedge clk)
        if (wren)
            mem[wraddress] <= data;
endmodule
