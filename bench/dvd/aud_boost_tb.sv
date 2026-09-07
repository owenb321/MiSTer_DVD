//============================================================================
//  aud_boost_tb.sv -- gate for the framework core-audio boost (sys/audio_out.sv).
//
//  Drives `aud_mix_top` directly and sweeps ALL 65,536 input codes for each
//  boost setting, with att=0, mix=0 and linux_audio=0 so `out` is exactly the
//  boosted sample.
//
//  ★ The checks are PROPERTIES of the transfer curve, not a restatement of the
//    RTL expression -- a golden model copied from the DUT agrees with it by
//    construction and cannot fail (see docs/field_parity.md for how that has
//    bitten this project before).  The load-bearing one is [P2]: upstream's
//    `boost_x = .../... + 1` makes the curve top out ONE PAST s16 full scale,
//    and because `v1` is unsigned while `a1` is signed with no clamp between
//    them, a near-full-scale sample WRAPS TO LARGE NEGATIVE.  run_aud_boost.sh
//    proves that by re-running this bench against the un-fixed constants.
//
//  Properties checked, per boost setting, for every input code:
//    [P1] boost==0 is bit-identical passthrough (the no-regression arm: this
//         file sits in EVERY core's audio path, DVD included).
//    [P2] the sign is never inverted.                       <-- catches upstream
//    [P3] the curve is monotonic non-decreasing.            <-- catches upstream
//    [P4] boost never attenuates: |out| >= |in| (unless saturated -- see below).
//    [P5] below the knee the gain is EXACTLY x2 / x4.
//    [P6] full scale maps to exactly +32767 / -32767, never beyond.
//    [P7] with att>0 the result still clamps rather than wrapping.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module aud_boost_tb;

    reg         clk = 1'b0;
    always #5   clk = ~clk;

    reg  [15:0] core_audio  = 16'd0;
    reg  [15:0] linux_audio = 16'd0;
    reg  [15:0] pre_in      = 16'd0;
    reg   [4:0] att         = 5'd0;
    reg   [1:0] boost       = 2'd0;
    reg   [1:0] mix         = 2'd0;
    wire [15:0] pre_out, out;

    aud_mix_top dut (
        .clk(clk), .ce(1'b1),
        .att(att), .boost(boost), .mix(mix),
        .core_audio(core_audio), .linux_audio(linux_audio),
        .pre_in(pre_in),
        .pre_out(pre_out), .out(out)
    );

    integer errors = 0;
    integer checked = 0;

    task fail(input [1023:0] what, input integer inv, input integer outv);
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("  FAIL %0s : in=%0d out=%0d (boost=%0d att=%0d)",
                         what, inv, outv, boost, att);
        end
    endtask

    // Hold an input across the whole feed-forward pipeline, then sample `out`.
    task apply(input integer sv);
        integer k;
        begin
            core_audio = sv[15:0];
            for (k = 0; k < 10; k = k + 1) @(posedge clk);
            #1;
        end
    endtask

    integer i, sv, ov, prev_ov, mag, omag, knee, shl;
    integer max_pos, min_neg;

    initial begin
        $display("== aud_boost_tb ==");

        // -------------------------------------------------------------- P1
        boost = 2'd0; att = 5'd0;
        for (i = 0; i < 65536; i = i + 1) begin
            sv = (i >= 32768) ? (i - 65536) : i;
            apply(sv);
            ov = $signed(out);
            checked = checked + 1;
            if (ov !== sv) fail("[P1] boost=0 not passthrough", sv, ov);
        end
        $display("  [P1] boost=0 passthrough: %0d codes", checked);

        // ------------------------------------------------- P2..P6 per setting
        for (boost = 2'd1; boost <= 2'd2; boost = boost + 2'd1) begin
            knee = (boost == 2'd1) ? 14043 : 7399;
            shl  = (boost == 2'd1) ? 1     : 2;
            prev_ov = -32768;
            max_pos = -100000;
            min_neg =  100000;

            for (i = 0; i < 65536; i = i + 1) begin
                // walk ascending in SIGNED order so [P3] is meaningful
                sv = i - 32768;
                apply(sv);
                ov  = $signed(out);
                mag = (sv < 0) ? -sv : sv;
                omag = (ov < 0) ? -ov : ov;
                checked = checked + 1;

                // [P2] sign preserved
                if (sv > 0 && ov <= 0) fail("[P2] positive became <=0", sv, ov);
                if (sv < 0 && ov >= 0) fail("[P2] negative became >=0", sv, ov);
                if (sv == 0 && ov != 0) fail("[P2] zero moved", sv, ov);

                // [P3] monotonic non-decreasing
                if (ov < prev_ov) fail("[P3] curve went backwards", sv, ov);
                prev_ov = ov;

                // [P4] never attenuates.  Exception: a SATURATED result is allowed
                // to be smaller, which matters for exactly one code -- in=-32768 has
                // magnitude 32768, which has no positive s16 counterpart, so -32767
                // is the correct answer rather than an attenuation.
                if (omag < mag && omag != 32767)
                    fail("[P4] boost attenuated", sv, ov);

                // [P5] exact x2 / x4 below the knee
                if (mag < knee && omag !== (mag << shl))
                    fail("[P5] sub-knee gain not exact", sv, ov);

                // [P6] never exceeds full scale
                if (omag > 32767) fail("[P6] magnitude past full scale", sv, ov);

                if (ov > max_pos) max_pos = ov;
                if (ov < min_neg) min_neg = ov;
            end

            // [P6] full scale must actually be REACHED, or the knee is wrong
            if (max_pos !== 32767) begin
                $display("  FAIL [P6] boost=%0d peak positive is %0d, expected 32767",
                         boost, max_pos);
                errors = errors + 1;
            end
            if (min_neg !== -32767) begin
                $display("  FAIL [P6] boost=%0d peak negative is %0d, expected -32767",
                         boost, min_neg);
                errors = errors + 1;
            end
            $display("  [P2..P6] boost=%0d swept 65536 codes, peaks %0d / %0d",
                     boost, min_neg, max_pos);
        end

        // -------------------------------------------------------------- P7
        // att is a right shift applied AFTER the boost; the final stage must
        // still clamp.  Spot-check the extremes at every attenuation.
        boost = 2'd2;
        for (att = 5'd0; att <= 5'd15; att = att + 5'd1) begin
            apply(32767);  ov = $signed(out);
            if (ov < 0) fail("[P7] positive wrapped under att", 32767, ov);
            apply(-32768); ov = $signed(out);
            if (ov > 0) fail("[P7] negative wrapped under att", -32768, ov);
        end
        att = 5'd16;                       // att[4] = mute
        apply(32767);
        if ($signed(out) !== 0) fail("[P7] att[4] did not mute", 32767, $signed(out));
        $display("  [P7] attenuation interaction ok");

        $display("== aud_boost_tb: %0d checks, %0d errors ==", checked, errors);
        if (errors != 0) $fatal(1, "aud_boost_tb FAILED with %0d errors", errors);
        $display("PASS");
        $finish;
    end

endmodule

`default_nettype wire
