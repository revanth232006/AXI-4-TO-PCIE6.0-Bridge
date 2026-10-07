`timescale 1ns / 1ps

module tb1 (
    output        clk_o,
    output        reset_o,
    output [3:0]  phase_o,
    output        tvalid0_o,
    output        tready0_o,
    output        tvalid1_o,
    output        tready1_o,
    output        read_completed_o,
    output        pcie_valid_o,
    output [255:0] actual_data_o,
    output [255:0] expected_data_o,
    output        data_match_o,
    output [31:0] error_count_o,
    output        test_done_o,
    output        test_pass_o
);

    parameter BUF_SLOTS        = 8;
    parameter VERBOSE          = 0;
    parameter CHECK_FAIR       = 1;
    parameter CHECK_IDLE_LANES = 0;
    parameter DRAIN_MAX        = 5000;
    parameter SEND_MAX         = 3000;
    parameter TIMEOUT_NS       = 20000000;

    localparam MEMD = 8192;

    reg clk;
    reg reset;

    reg          TVALID0;
    reg  [511:0] TDATA0;
    reg          TLAST0;
    wire         TREADY0;

    reg          TVALID1;
    reg  [511:0] TDATA1;
    reg          TLAST1;
    wire         TREADY1;

    reg          read_completed = 1'b0;
    wire [63:0]  pcie_lane0;
    wire [63:0]  pcie_lane1;
    wire [63:0]  pcie_lane2;
    wire [63:0]  pcie_lane3;
    wire         pcie_valid;

    top uut (
        .clk(clk), .reset(reset),
        .TVALID0(TVALID0), .TDATA0(TDATA0), .TLAST0(TLAST0), .TREADY0(TREADY0),
        .TVALID1(TVALID1), .TDATA1(TDATA1), .TLAST1(TLAST1), .TREADY1(TREADY1),
        .read_completed(read_completed),
        .pcie_lane0(pcie_lane0), .pcie_lane1(pcie_lane1),
        .pcie_lane2(pcie_lane2), .pcie_lane3(pcie_lane3),
        .pcie_valid(pcie_valid)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer error_count = 0;

    integer seed0     = 32'h1234_0001;
    integer seed1     = 32'h5678_0002;
    integer seed_g0   = 32'h0BAD_F00D;
    integer seed_g1   = 32'h0DEA_D001;
    integer seed_sink = 32'h9ABC_0003;

    reg [511:0] expected_memory [0:MEMD-1];
    integer     exp_wr_ptr      = 0;
    integer     exp_rd_ptr      = 0;
    reg         read_upper_half = 1'b0;

    reg pkt_open       = 1'b0;
    reg pkt_owner      = 1'b0;
    reg fair_pending   = 1'b0;
    reg fair_owner     = 1'b0;
    reg last_pkt_valid = 1'b0;
    reg last_pkt_owner = 1'b0;
    reg prev_acc_valid = 1'b0;
    reg prev_acc_s     = 1'b0;
    reg reset_q        = 1'b1;

    integer cov_acc0 = 0, cov_acc1 = 0;
    integer cov_both = 0, cov_full = 0, cov_mid = 0, cov_b2b = 0;
    integer cov_hand = 0, cov_fair = 0, cov_ob = 0;
    integer cov_ss = 0, cov_oi = 0, cov_rst = 0;

    wire         acc0 = TVALID0 & TREADY0;
    wire         acc1 = TVALID1 & TREADY1;
    wire [255:0] actual_out = {pcie_lane3, pcie_lane2, pcie_lane1, pcie_lane0};

    reg          cur_s, cur_last;
    reg [511:0]  cur_data, cur_word;
    reg [255:0]  exp_cmp;
    reg [255:0]  exp_out   = 256'd0;
    reg          exp_pend  = 1'b0;
    reg          exp_match = 1'b1;

    wire [255:0] exp_out_v = (pcie_valid === 1'b1) ? exp_out : 256'd0;

    reg test_done = 1'b0;
    reg test_pass = 1'b0;

    assign clk_o            = clk;
    assign reset_o          = reset;
    assign phase_o          = cur_phase[3:0];
    assign tvalid0_o        = TVALID0;
    assign tready0_o        = TREADY0;
    assign tvalid1_o        = TVALID1;
    assign tready1_o        = TREADY1;
    assign read_completed_o = read_completed;
    assign pcie_valid_o     = pcie_valid;
    assign actual_data_o    = (pcie_valid === 1'b1) ? actual_out : 256'd0;
    assign expected_data_o  = exp_out_v;
    assign data_match_o     = exp_match;
    assign error_count_o    = error_count;
    assign test_done_o      = test_done;
    assign test_pass_o      = test_pass;

    always @(posedge clk) begin
        if (reset) begin
            if (!reset_q && pkt_open && (exp_wr_ptr > exp_rd_ptr))
                cov_rst = cov_rst + 1;
            exp_wr_ptr = 0;  exp_rd_ptr = 0;  read_upper_half = 1'b0;
            pkt_open = 1'b0; fair_pending = 1'b0;
            last_pkt_valid = 1'b0; prev_acc_valid = 1'b0;
        end else begin

            if ((^{pcie_valid, TREADY0, TREADY1}) === 1'bx) begin
                $display("ERROR [%0t]: X/Z on pcie_valid/TREADY0/TREADY1 after reset", $time);
                error_count = error_count + 1;
            end
            if (CHECK_IDLE_LANES && pcie_valid === 1'b0 && actual_out !== 256'd0) begin
                $display("ERROR [%0t]: lanes not zero while pcie_valid is low: %h", $time, actual_out);
                error_count = error_count + 1;
            end
            if (TREADY0 && TREADY1) begin
                $display("ERROR [%0t]: arbiter failure - TREADY0 and TREADY1 both high", $time);
                error_count = error_count + 1;
            end
            if (TVALID0 && TVALID1) cov_both = cov_both + 1;
            if ((TVALID0 || TVALID1) && !TREADY0 && !TREADY1) cov_full = cov_full + 1;
            if (pkt_open && (pkt_owner ? !TVALID1 : !TVALID0) &&
                            (pkt_owner ?  TVALID0 :  TVALID1))
                cov_mid = cov_mid + 1;
            if (pcie_valid === 1'b1 && !read_completed) cov_ss = cov_ss + 1;
            if (pcie_valid === 1'b0 &&  read_completed) cov_oi = cov_oi + 1;

            if (pcie_valid === 1'b1 && read_completed) begin
                if (exp_rd_ptr >= exp_wr_ptr) begin
                    $display("ERROR [%0t]: UNEXPECTED OUTPUT - pcie_valid with nothing pending", $time);
                    error_count = error_count + 1;
                end else begin
                    cur_word = expected_memory[exp_rd_ptr % MEMD];
                    exp_cmp  = read_upper_half ? cur_word[511:256] : cur_word[255:0];
                    cov_ob   = cov_ob + 1;
                    if (actual_out !== exp_cmp) begin
                        $display("ERROR [%0t]: DATA MISMATCH (word %0d, %0s half)", $time,
                                 exp_rd_ptr, read_upper_half ? "upper" : "lower");
                        $display("  -> Expected: %h", exp_cmp);
                        $display("  -> Actual  : %h", actual_out);
                        error_count = error_count + 1;
                    end else if (VERBOSE) begin
                        $display("PASS  [%0t] word %0d %0s: %h", $time, exp_rd_ptr,
                                 read_upper_half ? "upper" : "lower", actual_out);
                    end
                    if (read_upper_half) begin
                        read_upper_half = 1'b0;
                        exp_rd_ptr = exp_rd_ptr + 1;
                    end else begin
                        read_upper_half = 1'b1;
                    end
                end
            end

            if (acc0 || acc1) begin
                cur_s    = ~acc0;
                cur_last = acc0 ? TLAST0 : TLAST1;
                cur_data = acc0 ? TDATA0 : TDATA1;
                if (acc0) cov_acc0 = cov_acc0 + 1; else cov_acc1 = cov_acc1 + 1;

                if (exp_wr_ptr - exp_rd_ptr >= MEMD) begin
                    $display("ERROR [%0t]: scoreboard memory overflow (raise MEMD)", $time);
                    error_count = error_count + 1;
                end
                expected_memory[exp_wr_ptr % MEMD] = cur_data;
                exp_wr_ptr = exp_wr_ptr + 1;

                if (prev_acc_valid && prev_acc_s == cur_s) cov_b2b = cov_b2b + 1;

                if (pkt_open && pkt_owner != cur_s) begin
                    $display("ERROR [%0t]: PACKETS INTERLEAVED - stream %0d beat inside stream %0d packet",
                             $time, cur_s, pkt_owner);
                    error_count = error_count + 1;
                end

                if (!pkt_open) begin
                    if (fair_pending) begin
                        cov_fair = cov_fair + 1;
                        if (CHECK_FAIR && cur_s != fair_owner) begin
                            $display("ERROR [%0t]: FAIRNESS - stream %0d got two packets in a row while stream %0d was waiting",
                                     $time, cur_s, ~cur_s);
                            error_count = error_count + 1;
                        end
                    end
                    fair_pending = 1'b0;
                    if (last_pkt_valid && last_pkt_owner != cur_s) cov_hand = cov_hand + 1;
                end

                if (cur_last) begin
                    pkt_open       = 1'b0;
                    last_pkt_valid = 1'b1;
                    last_pkt_owner = cur_s;
                    if (cur_s ? TVALID0 : TVALID1) begin
                        fair_pending = 1'b1;
                        fair_owner   = ~cur_s;
                    end else begin
                        fair_pending = 1'b0;
                    end
                end else begin
                    pkt_open  = 1'b1;
                    pkt_owner = cur_s;
                end
            end
            prev_acc_valid = acc0 || acc1;
            prev_acc_s     = ~acc0;
        end

        if (exp_rd_ptr < exp_wr_ptr) begin
            cur_word = expected_memory[exp_rd_ptr % MEMD];
            exp_out  = read_upper_half ? cur_word[511:256] : cur_word[255:0];
            exp_pend = 1'b1;
        end else begin
            exp_out  = 256'd0;
            exp_pend = 1'b0;
        end
        reset_q <= reset;
    end

    always @(negedge clk) begin
        if (reset) begin
            exp_match <= 1'b1;
        end else if (pcie_valid === 1'b1) begin
            exp_match <= exp_pend && (actual_out === exp_out);
        end else begin
            exp_match <= 1'b1;
        end

        if (!reset && !reset_q && pcie_valid === 1'b1) begin
            if (!exp_pend) begin
                $display("ERROR [%0t]: pcie_valid HIGH but nothing pending: %h", $time, actual_out);
                error_count = error_count + 1;
            end else if (actual_out !== exp_out) begin
                $display("ERROR [%0t]: DATA MISMATCH WHILE VALID (read_completed=%b)", $time, read_completed);
                $display("  -> Expected: %h", exp_out);
                $display("  -> Actual  : %h", actual_out);
                error_count = error_count + 1;
            end
        end
    end

`ifdef WHITEBOX
    always @(posedge clk) begin
        if (!reset) begin
            if ((uut.u_link.occupied_slots > BUF_SLOTS - 2) && (TREADY0 || TREADY1)) begin
                $display("ERROR [%0t]: TREADY high with buffer almost full (slots %0d)",
                         $time, uut.u_link.occupied_slots);
                error_count = error_count + 1;
            end
            if (pcie_valid === 1'b1 && uut.u_link.occupied_slots == 0) begin
                $display("ERROR [%0t]: pcie_valid high but buffer is empty", $time);
                error_count = error_count + 1;
            end
        end
    end
`endif

    reg [1:0] sink_mode = 2'd0;
    always @(negedge clk) begin
        case (sink_mode)
            2'd0: read_completed <= 1'b0;
            2'd1: read_completed <= 1'b1;
            2'd2: read_completed <= ({$random(seed_sink)} % 2) == 1;
            2'd3: read_completed <= ({$random(seed_sink)} % 4) == 0;
        endcase
    end

    function [511:0] make_data(input [3:0] s, input [7:0] pkt, input [7:0] beat);
        integer k;
        reg [511:0] r;
        reg [7:0]   kb;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                kb = k;
                r[32*k +: 32] = {s, pkt, beat, kb[3:0], (8'h5A + kb)};
            end
            make_data = r;
        end
    endfunction

    function integer pick_gap(input integer mode, input s);
        begin
            case (mode)
                0: pick_gap = 0;
                1: pick_gap = 1;
                2: pick_gap = s ? ({$random(seed_g1)} % 4) : ({$random(seed_g0)} % 4);
                3: pick_gap = 16;
                4: pick_gap = 4;
                default: pick_gap = 0;
            endcase
        end
    endfunction

    task send_burst0(input [7:0] first_id, input integer npkts,
                     input integer bmin, input integer bmax,
                     input integer bgap_mode, input integer pgap_mode);
        integer p, b, len, g, wd;
        begin
            @(negedge clk);
            for (p = 0; p < npkts; p = p + 1) begin
                len = bmin + ({$random(seed0)} % (bmax - bmin + 1));
                for (b = 0; b < len; b = b + 1) begin
                    TVALID0 = 1'b1;
                    TDATA0  = make_data(4'd0, first_id + p, b);
                    TLAST0  = (b == len - 1);
                    wd = 0;
                    @(posedge clk);
                    while (!TREADY0 && wd < SEND_MAX) begin
                        @(posedge clk);
                        wd = wd + 1;
                    end
                    if (wd >= SEND_MAX) begin
                        $display("ERROR [%0t]: stream 0 STARVED/DEADLOCK - TREADY0 low for %0d cycles", $time, SEND_MAX);
                        error_count = error_count + 1;
                        TVALID0 = 1'b0; TLAST0 = 1'b0;
                        disable send_burst0;
                    end
                    @(negedge clk);
                    if (b < len - 1)         g = pick_gap(bgap_mode, 1'b0);
                    else if (p < npkts - 1)  g = pick_gap(pgap_mode, 1'b0);
                    else                     g = 1000000;
                    if (g > 0) begin
                        TVALID0 = 1'b0; TLAST0 = 1'b0;
                        if (g < 1000000) repeat (g) @(negedge clk);
                    end
                end
            end
            TVALID0 = 1'b0; TLAST0 = 1'b0;
        end
    endtask

    task send_burst1(input [7:0] first_id, input integer npkts,
                     input integer bmin, input integer bmax,
                     input integer bgap_mode, input integer pgap_mode);
        integer p, b, len, g, wd;
        begin
            @(negedge clk);
            for (p = 0; p < npkts; p = p + 1) begin
                len = bmin + ({$random(seed1)} % (bmax - bmin + 1));
                for (b = 0; b < len; b = b + 1) begin
                    TVALID1 = 1'b1;
                    TDATA1  = make_data(4'd1, first_id + p, b);
                    TLAST1  = (b == len - 1);
                    wd = 0;
                    @(posedge clk);
                    while (!TREADY1 && wd < SEND_MAX) begin
                        @(posedge clk);
                        wd = wd + 1;
                    end
                    if (wd >= SEND_MAX) begin
                        $display("ERROR [%0t]: stream 1 STARVED/DEADLOCK - TREADY1 low for %0d cycles", $time, SEND_MAX);
                        error_count = error_count + 1;
                        TVALID1 = 1'b0; TLAST1 = 1'b0;
                        disable send_burst1;
                    end
                    @(negedge clk);
                    if (b < len - 1)         g = pick_gap(bgap_mode, 1'b1);
                    else if (p < npkts - 1)  g = pick_gap(pgap_mode, 1'b1);
                    else                     g = 1000000;
                    if (g > 0) begin
                        TVALID1 = 1'b0; TLAST1 = 1'b0;
                        if (g < 1000000) repeat (g) @(negedge clk);
                    end
                end
            end
            TVALID1 = 1'b0; TLAST1 = 1'b0;
        end
    endtask

    integer cur_phase = 0;
    reg [8:1] phase_pass = 8'h00;

    integer s_err, s_acc0, s_acc1, s_both, s_mid, s_b2b, s_hand, s_fair,
            s_ob, s_ss, s_oi, s_rst, s_full;
    integer d_acc0, d_acc1, d_both, d_mid, d_b2b, d_hand, d_fair,
            d_ob, d_ss, d_oi, d_rst, d_full;

    task begin_phase(input integer n, input [8*40-1:0] name);
        begin
            cur_phase = n;
            $display("\n=== PHASE %0d: %0s ===", n, name);
            s_err  = error_count; s_acc0 = cov_acc0; s_acc1 = cov_acc1;
            s_both = cov_both;    s_mid  = cov_mid;  s_b2b  = cov_b2b;
            s_hand = cov_hand;    s_fair = cov_fair; s_ob   = cov_ob;
            s_ss   = cov_ss;      s_oi   = cov_oi;   s_rst  = cov_rst;
            s_full = cov_full;
        end
    endtask

    task require(input cond, input [8*100-1:0] what);
        begin
            if (!cond) begin
                $display("COVERAGE FAIL [phase %0d]: scenario never happened - %0s", cur_phase, what);
                error_count = error_count + 1;
            end
        end
    endtask

    task drain;
        integer c;
        begin
            sink_mode = 2'd1;
            c = 0;
            @(negedge clk);
            while ((exp_rd_ptr != exp_wr_ptr || read_upper_half) && c < DRAIN_MAX) begin
                @(negedge clk);
                c = c + 1;
            end
            if (c >= DRAIN_MAX) begin
                $display("ERROR [%0t]: DRAIN TIMEOUT - %0d beat(s) accepted but never delivered",
                         $time, exp_wr_ptr - exp_rd_ptr);
                error_count = error_count + 1;
                exp_rd_ptr = exp_wr_ptr;
                read_upper_half = 1'b0;
            end
            repeat (6) @(negedge clk);
        end
    endtask

    task do_reset(input integer ncycles);
        begin
            @(negedge clk);
            reset = 1'b1;
            repeat (ncycles) @(negedge clk);
            reset = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task end_phase;
        begin
            d_acc0 = cov_acc0 - s_acc0;
            d_acc1 = cov_acc1 - s_acc1;
            d_both = cov_both - s_both;
            d_mid  = cov_mid  - s_mid;
            d_b2b  = cov_b2b  - s_b2b;
            d_hand = cov_hand - s_hand;
            d_fair = cov_fair - s_fair;
            d_ob   = cov_ob   - s_ob;
            d_ss   = cov_ss   - s_ss;
            d_oi   = cov_oi   - s_oi;
            d_rst  = cov_rst  - s_rst;
            d_full = cov_full - s_full;

            case (cur_phase)
                1: begin
                    require(d_acc0 > 0 && d_acc1 > 0,          "both streams delivered beats");
                    require(d_ob > 0,                          "output beats were checked");
                end
                2: begin
                    require(d_oi >= 10,                        "output idle while source silent (>=10 cycles)");
                    require(d_ob > 0,                          "output beats were checked");
                end
                3: begin
                    require(d_full >= 4,                       "both TREADY low while TVALID high >= 4 cycles");
                    require(d_ss > 0,                          "sink stalled while data was valid");
                end
                4: begin
                    require(d_both > 0,                        "both streams offered data in the same cycle");
                    require(d_hand > 0,                        "bus changed hands between packets");
                    require(d_fair > 0,                        "fairness handover was checked");
                end
                5: begin
                    require(d_ss > 0,                          "random sink stalls hit while data was valid");
                    require(d_ob > 0,                          "output beats were checked");
                end
                6: begin
                    require(d_full >= 4,                       "buffer ran full under load >= 4 cycles");
                    require(d_acc0 + d_acc1 >= 3 * BUF_SLOTS,  "pointers lapped the buffer at least 3 times");
                end
                7: begin
                    require(d_rst > 0,                         "reset hit mid-packet with data in flight");
                    require(d_acc0 + d_acc1 > 0,               "post-reset traffic delivered");
                end
                8: begin
                    require(d_mid > 0,                         "mid-packet gap while other stream waited");
                    require(d_hand > 0,                        "bus changed hands between packets");
                    require(d_ss > 0,                          "sink stalls during two-stream traffic");
                    require(d_b2b > 0,                         "back-to-back beats at full rate");
                end
            endcase

            phase_pass[cur_phase] = (error_count == s_err);
            $display("  PHASE %0d RESULT: %0s | beats in %0d, out(256b) %0d | buffer-full cycles %0d, sink stalls %0d | errors %0d",
                     cur_phase, (error_count == s_err) ? "PASS" : "FAIL",
                     d_acc0 + d_acc1, d_ob, d_full, d_ss, error_count - s_err);
        end
    endtask

    initial begin
        #(TIMEOUT_NS);
        $display("\nFATAL: global simulation timeout - testbench or DUT hung");
        $display(" VERDICT: FAIL");
        test_done = 1'b1;
        #20 $finish;
    end

    integer r, bg, pg, wait_cnt;

    initial begin
        reset = 1'b1;
        TVALID0 = 0; TDATA0 = 0; TLAST0 = 0;
        TVALID1 = 0; TDATA1 = 0; TLAST1 = 0;
        sink_mode = 2'd0;
        repeat (4) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);

        begin_phase(1, "PERFECT WORLD (BASELINE)");
        sink_mode = 2'd1;
        send_burst0(8'h10, 1, 1, 1, 0, 0);   drain;
        send_burst1(8'h90, 1, 1, 1, 0, 0);   drain;
        send_burst0(8'h11, 1, 4, 4, 0, 0);   drain;
        end_phase;

        begin_phase(2, "SOURCE STARVATION (LONG IDLE GAPS)");
        sink_mode = 2'd1;
        send_burst0(8'h20, 3, 1, 1, 0, 3);
        send_burst0(8'h28, 1, 4, 4, 3, 0);
        send_burst1(8'hA0, 1, 3, 3, 3, 0);
        drain;
        end_phase;

        begin_phase(3, "SINK BACKPRESSURE (BUSY COMPUTER)");
        sink_mode = 2'd0;
        fork
            send_burst0(8'h30, 1, BUF_SLOTS*2, BUF_SLOTS*2, 0, 0);
            begin
                wait_cnt = 0;
                while (((cov_full - s_full) < 6) && wait_cnt < 400) begin
                    @(negedge clk);
                    wait_cnt = wait_cnt + 1;
                end
                sink_mode = 2'd1;
            end
        join
        drain;
        end_phase;

        begin_phase(4, "ARBITER CONTENTION (FAIRNESS)");
        sink_mode = 2'd1;
        fork
            send_burst0(8'h40, 16, 1, 1, 0, 0);
            send_burst1(8'hC0, 16, 1, 1, 0, 0);
        join
        drain;
        fork
            send_burst0(8'h50, 8, 3, 3, 0, 0);
            send_burst1(8'hD0, 8, 3, 3, 0, 0);
        join
        drain;
        end_phase;

        begin_phase(5, "RANDOMIZED PCIE READS");
        sink_mode = 2'd2;
        send_burst0(8'h58, 10, 1, 4, 2, 2);
        drain;
        end_phase;

        begin_phase(6, "MEMORY WRAP-AROUND (NEAR FULL)");
        sink_mode = 2'd3;
        fork
            send_burst0(8'h68, 8, 2, 2, 0, 0);
            send_burst1(8'hE8, 8, 2, 2, 0, 0);
        join
        drain;
        end_phase;

        begin_phase(7, "IN-FLIGHT RESET (PULLING THE PLUG)");
        sink_mode = 2'd0;
        @(negedge clk);
        TVALID0 = 1; TDATA0 = make_data(4'd0, 8'h70, 8'd0); TLAST0 = 0;
        repeat (3) @(negedge clk);
        TVALID1 = 1; TDATA1 = make_data(4'd1, 8'hF0, 8'd0); TLAST1 = 1;
        repeat (3) @(negedge clk);
        $display(">> HITTING RESET MID-PACKET <<");
        reset = 1; TVALID0 = 0; TLAST0 = 0; TVALID1 = 0; TLAST1 = 0;
        repeat (3) @(negedge clk);
        reset = 0;
        sink_mode = 2'd1;
        repeat (6) @(negedge clk);
        send_burst1(8'hF1, 1, 2, 2, 0, 0);
        drain;
        fork
            send_burst0(8'h71, 2, 3, 3, 0, 0);
            send_burst1(8'hF2, 2, 3, 3, 0, 0);
        join
        drain;
        end_phase;

        begin_phase(8, "TWO-STREAM STRESS (MID-PACKET GAPS)");
        do_reset(2);
        sink_mode = 2'd1;

        fork
            send_burst0(8'h81, 1, 3, 3, 4, 0);
            send_burst1(8'hC1, 1, 2, 2, 0, 0);
        join
        drain;

        fork
            send_burst1(8'hC2, 1, 3, 3, 4, 0);
            begin
                repeat (4) @(negedge clk);
                send_burst0(8'h82, 1, 2, 2, 0, 0);
            end
        join
        drain;

        for (r = 0; r < 4; r = r + 1) begin
            case (r)
                0: begin sink_mode = 2'd1; bg = 0; pg = 0; end
                1: begin sink_mode = 2'd2; bg = 2; pg = 2; end
                2: begin sink_mode = 2'd3; bg = 2; pg = 0; end
                3: begin sink_mode = 2'd2; bg = 1; pg = 2; end
            endcase
            fork
                send_burst0(8'h90 + 8'd16 * r, 8, 3, 6, bg, pg);
                send_burst1(8'hB0 + 8'd16 * r, 8, 3, 6, bg, pg);
            join
            drain;
        end
        end_phase;

        #50;
        $display("\n========================================================");
        $display("                  SIMULATION COMPLETE");
        $display("========================================================");
        for (r = 1; r <= 8; r = r + 1)
            $display("  Phase %0d : %0s", r, phase_pass[r] ? "PASS" : "FAIL");
        $display("--------------------------------------------------------");
        $display("  beats accepted: stream0 %0d, stream1 %0d | output beats checked: %0d",
                 cov_acc0, cov_acc1, cov_ob);
        $display("  contention cycles %0d, mid-packet gaps %0d, handovers %0d, fairness checks %0d",
                 cov_both, cov_mid, cov_hand, cov_fair);
        $display("  back-to-back beats %0d, buffer-full cycles %0d, sink stalls %0d, resets mid-packet %0d",
                 cov_b2b, cov_full, cov_ss, cov_rst);
        $display("--------------------------------------------------------");
        if (error_count == 0) begin
            $display(" VERDICT: PASS");
            $display(" TOTAL ERRORS: 0");
        end else begin
            $display(" VERDICT: FAIL");
            $display(" TOTAL ERRORS: %0d", error_count);
        end
        $display("========================================================");
        test_pass = (error_count == 0);
        test_done = 1'b1;
        #20 $finish;
    end

endmodule


module tb;

    wire         clk, reset;
    wire [3:0]   phase;
    wire         TVALID0, TREADY0, TVALID1, TREADY1;
    wire         read_completed, pcie_valid;
    wire [255:0] actual_data, expected_data;
    wire         data_match;
    wire [31:0]  error_count;
    wire         test_done, test_pass;

    tb1 u_env (
        .clk_o(clk),
        .reset_o(reset),
        .phase_o(phase),
        .tvalid0_o(TVALID0),
        .tready0_o(TREADY0),
        .tvalid1_o(TVALID1),
        .tready1_o(TREADY1),
        .read_completed_o(read_completed),
        .pcie_valid_o(pcie_valid),
        .actual_data_o(actual_data),
        .expected_data_o(expected_data),
        .data_match_o(data_match),
        .error_count_o(error_count),
        .test_done_o(test_done),
        .test_pass_o(test_pass)
    );

endmodule