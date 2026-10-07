`timescale 1ns / 1ps

module top(
    input clk,
    input reset,
    input TVALID0,
    input [511:0] TDATA0,
    input TLAST0,
    output TREADY0,
    input TVALID1,
    input [511:0] TDATA1,
    input TLAST1,
    output TREADY1,
    input read_completed,   
    output [63:0] pcie_lane0,
    output [63:0] pcie_lane1,
    output [63:0] pcie_lane2,
    output [63:0] pcie_lane3,
    output pcie_valid
);

    wire [511:0] DATA;
    wire VALID;
    wire TREADY;

    interconnect_layer u_ic (
        .clk(clk),
        .reset(reset),
        .TDATA0(TDATA0),
        .TVALID0(TVALID0),
        .TLAST0(TLAST0),
        .TREADY0(TREADY0),
        .TDATA1(TDATA1),
        .TVALID1(TVALID1),
        .TLAST1(TLAST1),
        .TREADY1(TREADY1),
        .TREADY(TREADY),
        .DATA(DATA),
        .current_tvalid(VALID)
    );

    linklayer u_link (
        .clk(clk),
        .reset(reset),
        .VALID(VALID),
        .DATA(DATA),
        .TREADY(TREADY),
        .read_completed(read_completed),
        .payload_layer0(pcie_lane0),
        .payload_layer1(pcie_lane1),
        .payload_layer2(pcie_lane2),
        .payload_layer3(pcie_lane3),
        .pcie_valid(pcie_valid)
    );

endmodule