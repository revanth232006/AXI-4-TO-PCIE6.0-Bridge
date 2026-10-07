`timescale 1ns / 1ps

module linklayer(
    input  wire         clk,
    input  wire         reset,
    input  wire         VALID,
    input  wire [511:0] DATA,
    output wire         TREADY,
    input  wire         read_completed,   
    output wire [63:0]  payload_layer0, 
    output wire [63:0]  payload_layer1, 
    output wire [63:0]  payload_layer2, 
    output wire [63:0]  payload_layer3, 
    output wire         pcie_valid      
);

    reg [255:0] memory_array [0:7];

    reg [3:0] wr_ptr;
    reg [3:0] rd_ptr;

    wire [3:0] occupied_slots = wr_ptr - rd_ptr;
    
    assign TREADY     = (occupied_slots <= 4'd6); 
    assign pcie_valid = (occupied_slots > 4'd0);

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            wr_ptr <= 4'd0;
            for (i = 0; i < 8; i = i + 1) begin
                memory_array[i] <= 256'd0;
            end
        end else if (VALID & TREADY) begin
            memory_array[wr_ptr[2:0]]        <= DATA[255:0];
            memory_array[wr_ptr[2:0] + 3'd1] <= DATA[511:256];
            wr_ptr <= wr_ptr + 4'd2;
        end
    end

    wire [255:0] raw_payload = memory_array[rd_ptr[2:0]];
    
    assign payload_layer0 = raw_payload[63:0];
    assign payload_layer1 = raw_payload[127:64];
    assign payload_layer2 = raw_payload[191:128];
    assign payload_layer3 = raw_payload[255:192];

    always @(posedge clk) begin
        if (reset) begin
            rd_ptr <= 4'd0;
        end else begin
            if (pcie_valid && read_completed) begin
                rd_ptr <= rd_ptr + 4'd1;
            end
        end
    end

endmodule