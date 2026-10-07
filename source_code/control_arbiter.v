`timescale 1ns/1ps

module interconnect_layer(
      input clk,
      input reset,
      input [511:0] TDATA0,
      input TVALID0,TLAST0,
      input [511:0] TDATA1
      input TVALID1,TLAST1,
      input TREADY,
      output [511:0] DATA
      );
      reg control_reg,   control_next;  
      reg in_packet_reg, in_packet_next;

    wire current_tvalid = control_reg ? TVALID1 : TVALID0;  
    wire current_tlast  = control_reg ? TLAST1  : TLAST0;

    wire pkt_done    = current_tvalid && TREADY && current_tlast;   
    wire bus_is_free = !in_packet_reg || pkt_done;

    always @* begin  
        control_next   = control_reg;
        in_packet_next = in_packet_reg;

        if (in_packet_reg) begin
            if (pkt_done) begin
                in_packet_next = 1'b0;
            end
        end else begin
            if (current_tvalid && TREADY && !current_tlast) begin
                in_packet_next = 1'b1;
            end
        end

        if (bus_is_free) begin   
            if (control_reg == 1'b0) begin  
                if (TVALID1 && (!TVALID0 || pkt_done)) begin  
                    control_next = 1'b1;  
                end  
            end else begin  
                if (TVALID0 && (!TVALID1 || pkt_done)) begin  
                    control_next = 1'b0;  
                end  
            end  
        end  
    end  

    always @(posedge clk) begin  
        if (reset) begin  
            control_reg   <= 1'b0;  
            in_packet_reg <= 1'b0;  
        end else begin  
            control_reg   <= control_next;  
            in_packet_reg <= in_packet_next;  
        end  
    end
assign DATA  = control_reg ? TDATA1  : TDATA0;
endmodule