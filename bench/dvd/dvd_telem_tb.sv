`timescale 1ns/1ps
//============================================================================
// dvd_telem_tb -- the EXT_BUS telemetry responder.
//
// Four properties, the middle two being the ones that fail silently:
//   [1] a matching command returns MAGIC then the counters, in order
//   [2] a NON-matching command never drives the bus (hijacking another
//       command would break unrelated Main <-> core traffic, and the symptom
//       would appear nowhere near here)
//   [3] the snapshot is ATOMIC: counters changing mid-transaction must not
//       appear in the readout. Without this the words are samples taken
//       milliseconds apart and the refresh/pickup ratio this exists to measure
//       becomes noise rather than a number.
//   [4] the CDC stability filter never commits a mid-increment value
//   [6] words 11..20: the phase/scheduler words, the DUTY_MAGIC marker, and the
//       four dec_duty counters in order (docs/decode_pacing.md). Every input is
//       driven with a distinct value, so a swapped or unwired word cannot pass.
//   [7] words 21..24: the PIC_MAGIC marker and dec_duty's per-picture words, in
//       order, with word 16 still DD01 (an older Main keys on it).
//   [8] words 25..31: AUD_MAGIC, the audio engine's words, and word 31 field_par
//       (docs/field_parity.md "Strict first field") -- the LAST word wcnt can reach.
//============================================================================
module dvd_telem_tb;
    reg clk = 0;
    always #5 clk = ~clk;                     // 100 MHz, arbitrary

    reg         io_enable = 0, io_strobe = 0;
    reg  [15:0] io_din = 0;
    wire        drive;
    wire [15:0] dout;

    reg [15:0] refreshes = 16'h1111, pickups = 16'h2222, lates = 16'h3333;
    reg [15:0] drops = 16'h4444, vid_err = 16'h5555, drop_costs = 16'h6666;
    reg [15:0] aud_frames = 16'h8888;
    reg  [7:0] vbuf_fill = 8'h77, flags = 8'h07;
    reg [15:0] aud_play = 16'h9999, aud_gate = 16'hA0A0;
    // Tie-offs for every remaining input (a new INPUT left unconnected floats Z).
    reg [15:0] disp_lag = 16'hB1B1, play_err = 16'hB2B2, av_drift = 16'hB3B3;
    reg [15:0] sched_flags = 16'hB4B4, sched_dur = 16'hB5B5;
    reg [15:0] dec_disp = 16'hC1C1, dec_starve = 16'hC2C2, dec_back = 16'hC3C3, dec_ref = 16'hC4C4;
    reg [15:0] pic_max = 16'hD1D1, pic_n = 16'hD2D2, pic_over = 16'hD3D3;
    reg [15:0] dts_flags = 16'hE1E1, eng_frames = 16'hE4E4, eng_refused = 16'hE5E5;
    reg [31:0] cb_sum = 32'hE2E2_E3E3;
    reg [15:0] field_par = 16'hF1F1;

    integer errors = 0;
    reg [15:0] got [0:31];

    // CMD_AF inputs. Tied off explicitly: a new INPUT left unconnected floats Z
    // and quietly poisons whatever reads it (see CLAUDE.md's note on new ports).
    reg af_pt = 0, af_pcm = 0, af_bs = 0;
    // The DVD-remote request fields share this word (B19 Eject, B20/B21 Volume).
    reg       rq_ej = 0;
    reg [3:0] rq_up = 0, rq_dn = 0;

    dvd_telem dut (
        .clk(clk), .io_enable(io_enable), .io_strobe(io_strobe),
        .io_din(io_din), .drive(drive), .dout(dout),
        .refreshes(refreshes), .pickups(pickups), .lates(lates),
        .drops(drops), .vid_err(vid_err), .drop_costs(drop_costs),
        .vbuf_fill(vbuf_fill), .aud_frames(aud_frames), .flags(flags),
        .aud_play(aud_play), .aud_gate(aud_gate),
        .disp_lag(disp_lag), .play_err(play_err), .av_drift(av_drift),
        .sched_flags(sched_flags), .sched_dur(sched_dur),
        .dec_disp(dec_disp), .dec_starve(dec_starve), .dec_back(dec_back), .dec_ref(dec_ref),
        .dec_pic_max(pic_max), .dec_pic_n(pic_n), .dec_pic_over(pic_over),
        .dts_flags(dts_flags), .cb_sum(cb_sum), .eng_frames(eng_frames), .eng_refused(eng_refused),
        .field_par(field_par),
        .af_passthru(af_pt), .af_pcm_session(af_pcm), .af_bs_session(af_bs),
        .rq_eject_tgl(rq_ej), .rq_volup_seq(rq_up), .rq_voldn_seq(rq_dn));

    task strobe(input [15:0] d);
        begin
            @(negedge clk); io_din = d; io_strobe = 1;
            @(negedge clk); io_strobe = 0;
            @(negedge clk);
        end
    endtask

    // Read a transaction. `disturb` changes the counters after the command
    // word, which is how [3] is tested.
    task run_xact(input [15:0] cmd, input disturb, output drove);
        integer i;
        begin
            drove = 0;
            @(negedge clk); io_enable = 1;
            strobe(cmd);
            got[0] = dout;
            if (drive) drove = 1;
            if (disturb) begin
                refreshes = 16'hAAAA; pickups = 16'hBBBB; lates = 16'hCCCC;
                drops = 16'hDDDD; vid_err = 16'hEEEE;
                repeat (100) @(negedge clk);    // let the sampler walk every source (3*NSRC = 72 cycles)
            end
            for (i = 1; i <= 31; i = i + 1) begin
                strobe(16'd0);
                got[i] = dout;
                if (drive) drove = 1;
            end
            @(negedge clk); io_enable = 0;
            @(negedge clk);
        end
    endtask

    task check(input [127:0] name, input [15:0] a, input [15:0] b);
        begin
            if (a !== b) begin
                $display("  FAIL %0s: got %04h want %04h", name, a, b);
                errors = errors + 1;
            end else
                $display("  ok   %0s = %04h", name, a);
        end
    endtask

    reg drove;
    initial begin
        repeat (100) @(negedge clk);   // sampler rotation is 3*NSRC = 72 cycles

        $display("[1] matching command returns MAGIC then the counters");
        run_xact(16'h007A, 1'b0, drove);
        check("magic",     got[0], 16'hD7D1);
        check("refreshes", got[1], 16'h1111);
        check("pickups",   got[2], 16'h2222);
        check("lates",     got[3], 16'h3333);
        check("drops",     got[4], 16'h4444);
        check("vid_err",   got[5], 16'h5555);
        check("costs",     got[6], 16'h6666);
        check("vbuf|flags",got[7], 16'h7707);
        check("aud",       got[8], 16'h8888);
        check("aud_play",  got[9], 16'h9999);
        check("aud_gate",  got[10], 16'hA0A0);
        if (!drove) begin
            $display("  FAIL: never drove the bus for its own command");
            errors = errors + 1;
        end

        $display("[2] non-matching command must NOT drive the bus");
        run_xact(16'h0016, 1'b0, drove);       // 0x16 = hps_io's sd command
        if (drove) begin
            $display("  FAIL: hijacked command 0x16");
            errors = errors + 1;
        end else
            $display("  ok   stayed off the bus");

        $display("[3] snapshot is atomic across a disturbed transaction");
        refreshes = 16'h1111; pickups = 16'h2222; lates = 16'h3333;
        drops = 16'h4444; vid_err = 16'h5555;
        repeat (100) @(negedge clk);   // sampler rotation is 72 cycles
        run_xact(16'h007A, 1'b1, drove);       // counters change mid-readout
        check("refreshes", got[1], 16'h1111);
        check("pickups",   got[2], 16'h2222);
        check("lates",     got[3], 16'h3333);
        check("drops",     got[4], 16'h4444);
        check("vid_err",   got[5], 16'h5555);

        $display("[4] the next transaction sees the NEW values");
        run_xact(16'h007A, 1'b0, drove);
        check("refreshes", got[1], 16'hAAAA);
        check("pickups",   got[2], 16'hBBBB);

        $display("[5] CMD_AF reports the audio link format, independently of 0x7A");
        // Bit 15 is the FORMAT VERSION and is set in every answer, content or
        // not: Main uses it to tell a core that reports bs_session from one that
        // predates it, and both answer bs=0 when nothing is playing.
        af_pt = 1; af_pcm = 0; af_bs = 1;      // Passthru, an AC-3/DTS track
        repeat (100) @(negedge clk);   // sampler rotation is 72 cycles
        run_xact(16'h007B, 1'b0, drove);
        if (!drove) begin
            $display("  FAIL: CMD_AF did not drive the bus"); errors = errors + 1; end
        check("afmt-bitstream", got[1], 16'h9005);
        af_pcm = 1; af_bs = 0;                 // ...now an LPCM/MP2 track
        repeat (100) @(negedge clk);   // sampler rotation is 72 cycles
        run_xact(16'h007B, 1'b0, drove);
        check("afmt-pcm", got[1], 16'h9003);
        af_pt = 1; af_pcm = 0; af_bs = 0;      // Passthru, nothing playing yet
        repeat (100) @(negedge clk);   // sampler rotation is 72 cycles
        run_xact(16'h007B, 1'b0, drove);
        check("afmt-idle", got[1], 16'h9001);
        af_pt = 0; af_pcm = 0; af_bs = 0;      // back to Decode
        repeat (100) @(negedge clk);   // sampler rotation is 72 cycles
        run_xact(16'h007B, 1'b0, drove);
        check("afmt-decode", got[1], 16'h9000);
        // ---- [5b] the DVD-remote request fields share this word -----------
        // Main reads Eject as a TOGGLE and the two volume requests as WRAPPING
        // COUNTERS, so the word has to carry them without disturbing the audio
        // format bits below them -- an overlap would make a volume press look
        // like a bitstream session, or vice versa.
        $display("[5b] CMD_AF also carries the Eject/Volume requests");
        rq_ej = 1; rq_up = 4'd0; rq_dn = 4'd0;
        repeat (100) @(negedge clk);
        run_xact(16'h007B, 1'b0, drove);
        check("rq eject toggle -> bit 3", got[1], 16'h9008);
        rq_ej = 0; rq_up = 4'd5; rq_dn = 4'd0;
        repeat (100) @(negedge clk);
        run_xact(16'h007B, 1'b0, drove);
        check("rq vol-up 5 -> bits 7:4", got[1], 16'h9050);
        rq_up = 4'd0; rq_dn = 4'd9;
        repeat (100) @(negedge clk);
        run_xact(16'h007B, 1'b0, drove);
        check("rq vol-down 9 -> bits 11:8", got[1], 16'h9900);
        // All at once, WITH a live bitstream session: the fields must coexist.
        rq_ej = 1; rq_up = 4'd15; rq_dn = 4'd15;
        af_pt = 1; af_bs = 1;
        repeat (100) @(negedge clk);
        run_xact(16'h007B, 1'b0, drove);
        check("all fields together", got[1], 16'h9FFD);
        rq_ej = 0; rq_up = 4'd0; rq_dn = 4'd0; af_pt = 0; af_bs = 0;
        repeat (100) @(negedge clk);

        // ...and the diagnostic snapshot is untouched by any of it.
        run_xact(16'h007A, 1'b0, drove);
        check("0x7A still reports counters", got[1], 16'hAAAA);

        $display("[6] words 11..20: phase words, DUTY_MAGIC, dec_duty counters");
        check("disp_lag",    got[11], 16'hB1B1);
        check("play_err",    got[12], 16'hB2B2);
        check("av_drift",    got[13], 16'hB3B3);
        check("sched_flags", got[14], 16'hB4B4);
        check("sched_dur",   got[15], 16'hB5B5);
        check("DUTY_MAGIC",  got[16], 16'hDD01);
        check("dec_disp",    got[17], 16'hC1C1);
        check("dec_starve",  got[18], 16'hC2C2);
        check("dec_back",    got[19], 16'hC3C3);
        check("dec_ref",     got[20], 16'hC4C4);
        // the duty words are snapshotted atomically like the rest
        dec_disp = 16'h0101; repeat (100) @(negedge clk);
        run_xact(16'h007A, 1'b0, drove);
        check("dec_disp follows its input", got[17], 16'h0101);

        $display("[7] words 21..24: PIC_MAGIC, dec_duty per picture");
        check("DUTY_MAGIC unchanged", got[16], 16'hDD01);
        check("PIC_MAGIC",   got[21], 16'hDD02);
        check("pic_max",     got[22], 16'hD1D1);
        check("pic_n",       got[23], 16'hD2D2);
        check("pic_over",    got[24], 16'hD3D3);
        pic_over = 16'h0202; repeat (100) @(negedge clk);
        run_xact(16'h007A, 1'b0, drove);
        check("pic_over follows its input", got[24], 16'h0202);

        $display("[8] words 25..31: AUD_MAGIC, the audio engine, field_par");
        check("AUD_MAGIC",   got[25], 16'hDD03);
        check("dts_flags",   got[26], 16'hE1E1);
        check("cb_sum hi",   got[27], 16'hE2E2);
        check("cb_sum lo",   got[28], 16'hE3E3);
        check("eng_frames",  got[29], 16'hE4E4);
        check("eng_refused", got[30], 16'hE5E5);
        check("field_par",   got[31], 16'hF1F1);
        field_par = 16'h8102; repeat (100) @(negedge clk);
        run_xact(16'h007A, 1'b0, drove);
        check("field_par follows its input", got[31], 16'h8102);

        if (errors == 0) $display("dvd_telem_tb: ALL GREEN");
        else             $display("dvd_telem_tb: FAILURES");
        if (errors != 0) $fatal(1, "%0d failure(s)", errors);
        $finish;
    end
endmodule
