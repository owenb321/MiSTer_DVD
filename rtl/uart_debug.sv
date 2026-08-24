
module uart_debug (
    input clk,          // 27 MHz
    input rst_n,
    input locked,
    input active,
    input [12:0] arx,
    input [12:0] ary,
    input        busy,
    input        valid,
    // Additional debug signals
    input [8:0]  init_cnt,
    input        sync_rst,
    input        vbw_almost_full,
    input        mem_req_en,
    input        mem_req_valid,
    input        mem_res_almost_full,  // Response FIFO backpressure
    input [3:0]  shim_state,           // Memory shim state machine
    input [1:0]  shim_saved_cmd,       // Skid buffer cmd type (0=none 2=RD 3=WR)
    input        sdram_busy,           // SDRAM controller busy signal
    input        sdram_ack,            // SDRAM controller ack signal
    // MPG streamer debug
    input        streamer_active,      // File streaming active
    input        streamer_sd_rd,       // SD read request
    input        streamer_sd_ack,      // SD acknowledge
    input        streamer_has_data,    // Cache has data
    input [15:0] streamer_file_size,   // File size (lower 16 bits)
    input [15:0] streamer_total_sectors, // Total sectors
    input [15:0] streamer_next_lba,    // Next LBA to read
    // Memory read/write counters
    input [15:0] mem_rd_count,         // 64-bit read completions
    input [15:0] mem_wr_count,         // 64-bit write completions
    input [15:0] mem_rsp_count,        // readdatavalid pulse count
    input [15:0] mem_pend_cycles,      // cycles stuck in S_READ_PEND
    // HDMI debug
    input        hdmi_lock,
    // Decoder health
    input        watchdog_rst,          // Watchdog fired (latched until next print)
    input  [2:0] core_vs_edge_cnt,      // Vsync edges seen (0-7, saturates at 7)
    input [15:0] core_frame_cnt,        // Free-running frame counter (all vsync edges)
    input [28:0] mem_addr,
    output tx_pin
);

    wire tx_ready;
    reg [7:0] tx_data;
    reg tx_valid;

    uart_tx #(
        .CLK_FRE(27),
        .BAUD_RATE(115200)
    ) uart_inst (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready),
        .tx_pin(tx_pin)
    );

    // Update timer: every ~1 second (27,000,000 cycles)
    reg [24:0] timer;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) timer <= 0;
        else if (timer == 27000000) timer <= 0;
        else timer <= timer + 1;
    end

    // Capture values when timer hits 0 to ensure stable output during transmission
    reg locked_r, active_r, busy_r, valid_r;
    reg [12:0] arx_r, ary_r;
    reg [8:0] init_cnt_r;
    reg sync_rst_r, vbw_almost_full_r, mem_req_en_r, mem_req_valid_r, mem_res_almost_full_r;
    reg [3:0] shim_state_r;
    reg [1:0] shim_saved_cmd_r;
    reg sdram_busy_r, sdram_ack_r;
    reg streamer_active_r, streamer_sd_rd_r, streamer_sd_ack_r, streamer_has_data_r;
    reg [15:0] streamer_file_size_r, streamer_total_sectors_r, streamer_next_lba_r;
    reg [15:0] mem_rd_count_r, mem_wr_count_r;
    reg [15:0] mem_rsp_count_r, mem_pend_cycles_r;
    reg hdmi_lock_r;
    reg watchdog_r, watchdog_latch;
    reg [2:0]  core_vs_edge_cnt_r;
    reg [15:0] core_frame_cnt_r;
    reg [28:0] mem_addr_r;

    // State machine
    // (watchdog_latch is driven entirely inside the main always block below)
    localparam S_IDLE = 0;
    localparam S_PRINT = 1;
    localparam S_WAIT_TX = 2; // Wait for ready to go low (ack) then high (done)

    reg [3:0] state = S_IDLE;
    reg [7:0] char_idx = 0;  // 8 bits to hold indices 0-160

    // Message Format: "L:x A:x B:x V:x X:xxx Y:xxx I:xxx S:x F:x E:x Q:x R:x M:x U:x K:x T:x D:x C:x H:x W:xxxx P:xxxx J:xxxx Z:xxxx @:xxxxxxxx G:x O:x N:x SC:x FC:xxxx RP:xxxx PC:xxxx\r\n"
    // I=init_cnt S=sync_rst F=vbw_almost_full E=mem_req_en Q=mem_req_valid R=mem_res_almost_full
    // M=shim_state (Hex: [3:2]=Cmd 1=Saved 0=State) U=sdram_busy K=sdram_ack
    // T=sTreamer_active D=sd_rD C=sd_aCk H=cache_Has_data
    // W=mem_Writes P=mem_reads(P) J=next_lba(Jump)
    // G=vld_err O=watchdOg_rst(latched) N=vsyNc_edge_count(0-7)
    // SC=Saved Cmd type (0=none 2=READ 3=WRITE) FC=Frame Counter (vsync edges)
    
    function [7:0] to_hex;
        input [3:0] val;
        begin
            to_hex = (val < 10) ? ("0" + val) : ("A" + val - 10);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            tx_valid      <= 0;
            char_idx      <= 0;
            watchdog_latch <= 0;
        end else begin
            // Watchdog latch: set when watchdog_rst fires (active LOW pulse); cleared at print capture
            if (!watchdog_rst) watchdog_latch <= 1;

            case (state)
                S_IDLE: begin
                    tx_valid <= 0;
                    if (timer == 0) begin
                        locked_r <= locked;
                        active_r <= active;
                        busy_r <= busy;
                        valid_r <= valid;
                        arx_r <= arx;
                        ary_r <= ary;
                        init_cnt_r <= init_cnt;
                        sync_rst_r <= sync_rst;
                        vbw_almost_full_r <= vbw_almost_full;
                        mem_req_en_r <= mem_req_en;
                        mem_req_valid_r <= mem_req_valid;
                        mem_res_almost_full_r <= mem_res_almost_full;
                        shim_state_r <= shim_state;
                        shim_saved_cmd_r <= shim_saved_cmd;
                        sdram_busy_r <= sdram_busy;
                        sdram_ack_r <= sdram_ack;
                        streamer_active_r <= streamer_active;
                        streamer_sd_rd_r <= streamer_sd_rd;
                        streamer_sd_ack_r <= streamer_sd_ack;
                        streamer_has_data_r <= streamer_has_data;
                        streamer_file_size_r <= streamer_file_size;
                        streamer_total_sectors_r <= streamer_total_sectors;
                        streamer_next_lba_r <= streamer_next_lba;
                        mem_rd_count_r <= mem_rd_count;
                        mem_wr_count_r <= mem_wr_count;
                        mem_rsp_count_r <= mem_rsp_count;
                        mem_pend_cycles_r <= mem_pend_cycles;
                        hdmi_lock_r <= hdmi_lock;
                        watchdog_r     <= watchdog_latch | !watchdog_rst; // include same-cycle fires
                        if (watchdog_rst) watchdog_latch <= 0; // clear only when NOT firing (watchdog_rst HIGH = not fired)
                        core_vs_edge_cnt_r <= core_vs_edge_cnt;
                        core_frame_cnt_r   <= core_frame_cnt;
                        mem_addr_r <= mem_addr;
                        char_idx <= 0;
                        state <= S_PRINT;
                    end
                end

                S_PRINT: begin
                    if (tx_ready) begin
                        state <= S_WAIT_TX;
                        tx_valid <= 1;
                        case (char_idx)
                            0: tx_data <= "L";
                            1: tx_data <= ":";
                            2: tx_data <= locked_r ? "1" : "0";
                            3: tx_data <= " ";
                            4: tx_data <= "A";
                            5: tx_data <= ":";
                            6: tx_data <= active_r ? "1" : "0";
                            7: tx_data <= " ";
                            8: tx_data <= "B";
                            9: tx_data <= ":";
                            10: tx_data <= busy_r ? "1" : "0";
                            11: tx_data <= " ";
                            12: tx_data <= "V";
                            13: tx_data <= ":";
                            14: tx_data <= valid_r ? "1" : "0";
                            15: tx_data <= " ";
                            16: tx_data <= "X";
                            17: tx_data <= ":";
                            18: tx_data <= to_hex(arx_r[11:8]);
                            19: tx_data <= to_hex(arx_r[7:4]);
                            20: tx_data <= to_hex(arx_r[3:0]);
                            21: tx_data <= " ";
                            22: tx_data <= "Y";
                            23: tx_data <= ":";
                            24: tx_data <= to_hex(ary_r[11:8]);
                            25: tx_data <= to_hex(ary_r[7:4]);
                            26: tx_data <= to_hex(ary_r[3:0]);
                            27: tx_data <= " ";
                            28: tx_data <= "I";
                            29: tx_data <= ":";
                            30: tx_data <= to_hex({3'b0, init_cnt_r[8]});
                            31: tx_data <= to_hex(init_cnt_r[7:4]);
                            32: tx_data <= to_hex(init_cnt_r[3:0]);
                            33: tx_data <= " ";
                            34: tx_data <= "S";
                            35: tx_data <= ":";
                            36: tx_data <= sync_rst_r ? "1" : "0";
                            37: tx_data <= " ";
                            38: tx_data <= "F";
                            39: tx_data <= ":";
                            40: tx_data <= vbw_almost_full_r ? "1" : "0";
                            41: tx_data <= " ";
                            42: tx_data <= "E";
                            43: tx_data <= ":";
                            44: tx_data <= mem_req_en_r ? "1" : "0";
                            45: tx_data <= " ";
                            46: tx_data <= "Q";
                            47: tx_data <= ":";
                            48: tx_data <= mem_req_valid_r ? "1" : "0";
                            49: tx_data <= " ";
                            50: tx_data <= "R";
                            51: tx_data <= ":";
                            52: tx_data <= mem_res_almost_full_r ? "1" : "0";
                            53: tx_data <= " ";
                            54: tx_data <= "M";
                            55: tx_data <= ":";
                            56: tx_data <= to_hex(shim_state_r);
                            57: tx_data <= " ";
                            58: tx_data <= "U"; // bUsy
                            59: tx_data <= ":";
                            60: tx_data <= sdram_busy_r ? "1" : "0";
                            61: tx_data <= " ";
                            62: tx_data <= "K"; // acK
                            63: tx_data <= ":";
                            64: tx_data <= sdram_ack_r ? "1" : "0";
                            65: tx_data <= " ";
                            66: tx_data <= "T"; // sTreamer active
                            67: tx_data <= ":";
                            68: tx_data <= streamer_active_r ? "1" : "0";
                            69: tx_data <= " ";
                            70: tx_data <= "D"; // sd_rD
                            71: tx_data <= ":";
                            72: tx_data <= streamer_sd_rd_r ? "1" : "0";
                            73: tx_data <= " ";
                            74: tx_data <= "C"; // sd_aCk
                            75: tx_data <= ":";
                            76: tx_data <= streamer_sd_ack_r ? "1" : "0";
                            77: tx_data <= " ";
                            78: tx_data <= "H"; // cache_Has_data
                            79: tx_data <= ":";
                            80: tx_data <= streamer_has_data_r ? "1" : "0";
                            81: tx_data <= " ";
                            82: tx_data <= "W"; // Write count
                            83: tx_data <= ":";
                            84: tx_data <= to_hex(mem_wr_count_r[15:12]);
                            85: tx_data <= to_hex(mem_wr_count_r[11:8]);
                            86: tx_data <= to_hex(mem_wr_count_r[7:4]);
                            87: tx_data <= to_hex(mem_wr_count_r[3:0]);
                            88: tx_data <= " ";
                            89: tx_data <= "P"; // read(P) count
                            90: tx_data <= ":";
                            91: tx_data <= to_hex(mem_rd_count_r[15:12]);
                            92: tx_data <= to_hex(mem_rd_count_r[11:8]);
                            93: tx_data <= to_hex(mem_rd_count_r[7:4]);
                            94: tx_data <= to_hex(mem_rd_count_r[3:0]);
                            95: tx_data <= " ";
                            96: tx_data <= "J"; // next_lba(Jump)
                            97: tx_data <= ":";
                            98: tx_data <= to_hex(streamer_next_lba_r[15:12]);
                            99: tx_data <= to_hex(streamer_next_lba_r[11:8]);
                            100: tx_data <= to_hex(streamer_next_lba_r[7:4]);
                            101: tx_data <= to_hex(streamer_next_lba_r[3:0]);
                            102: tx_data <= " ";
                            103: tx_data <= "Z"; // Total Sectors
                            104: tx_data <= ":";
                            105: tx_data <= to_hex(streamer_total_sectors_r[15:12]);
                            106: tx_data <= to_hex(streamer_total_sectors_r[11:8]);
                            107: tx_data <= to_hex(streamer_total_sectors_r[7:4]);
                            108: tx_data <= to_hex(streamer_total_sectors_r[3:0]);
                            109: tx_data <= " ";
                            110: tx_data <= "@";
                            111: tx_data <= ":";
                            112: tx_data <= to_hex({3'b0, mem_addr_r[28]});
                            113: tx_data <= to_hex(mem_addr_r[27:24]);
                            114: tx_data <= to_hex(mem_addr_r[23:20]);
                            115: tx_data <= to_hex(mem_addr_r[19:16]);
                            116: tx_data <= to_hex(mem_addr_r[15:12]);
                            117: tx_data <= to_hex(mem_addr_r[11:8]);
                            118: tx_data <= to_hex(mem_addr_r[7:4]);
                            119: tx_data <= to_hex(mem_addr_r[3:0]);
                            120: tx_data <= " ";
                            121: tx_data <= "G"; // General Error / VLD Error
                            122: tx_data <= ":";
                            123: tx_data <= hdmi_lock_r ? "1" : "0";
                            124: tx_data <= " ";
                            125: tx_data <= "O"; // watchdOg fired (latched)
                            126: tx_data <= ":";
                            127: tx_data <= watchdog_r ? "1" : "0";
                            128: tx_data <= " ";
                            129: tx_data <= "N"; // vsyNc edge count (0-7)
                            130: tx_data <= ":";
                            131: tx_data <= to_hex({1'b0, core_vs_edge_cnt_r});
                            132: tx_data <= " ";
                            133: tx_data <= "S"; // Saved Cmd type in skid buffer
                            134: tx_data <= "C";
                            135: tx_data <= ":";
                            136: tx_data <= to_hex({2'b0, shim_saved_cmd_r}); // 0=none/NOOP 2=READ 3=WRITE
                            137: tx_data <= " ";
                            138: tx_data <= "F"; // Frame Counter
                            139: tx_data <= "C";
                            140: tx_data <= ":";
                            141: tx_data <= to_hex(core_frame_cnt_r[15:12]);
                            142: tx_data <= to_hex(core_frame_cnt_r[11:8]);
                            143: tx_data <= to_hex(core_frame_cnt_r[7:4]);
                            144: tx_data <= to_hex(core_frame_cnt_r[3:0]);
                            145: tx_data <= " ";
                            146: tx_data <= "R"; // Response count (RP)
                            147: tx_data <= "P";
                            148: tx_data <= ":";
                            149: tx_data <= to_hex(mem_rsp_count_r[15:12]);
                            150: tx_data <= to_hex(mem_rsp_count_r[11:8]);
                            151: tx_data <= to_hex(mem_rsp_count_r[7:4]);
                            152: tx_data <= to_hex(mem_rsp_count_r[3:0]);
                            153: tx_data <= " ";
                            154: tx_data <= "P"; // Pend Cycles (PC)
                            155: tx_data <= "C";
                            156: tx_data <= ":";
                            157: tx_data <= to_hex(mem_pend_cycles_r[15:12]);
                            158: tx_data <= to_hex(mem_pend_cycles_r[11:8]);
                            159: tx_data <= to_hex(mem_pend_cycles_r[7:4]);
                            160: tx_data <= to_hex(mem_pend_cycles_r[3:0]);
                            161: tx_data <= "\r";
                            162: tx_data <= "\n";
                            default: begin
                                state <= S_IDLE;
                                tx_valid <= 0;
                            end
                        endcase
                    end
                end

                S_WAIT_TX: begin
                    tx_valid <= 0;
                    state <= S_PRINT; 
                    char_idx <= char_idx + 1;
                end
            endcase
        end
    end

endmodule
