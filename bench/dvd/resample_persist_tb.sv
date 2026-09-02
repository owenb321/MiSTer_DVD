`timescale 1ns/1ps
//
// resample_persist_tb.sv — reproduce the "held still frame strobes black every
// other frame" bug in simulation (decode-independent, per HW observation that a
// frozen end-of-clip frame still strobes with NO decode happening).
//
// Drives rtl/mpeg2/resample_addrgen.v: present ONE output frame, then hold
// output_frame_valid=0 (clip ended) with persistence=1 and watch whether the
// FSM keeps re-emitting the frame (good) or periodically falls idle / emits a
// blank pass (the strobe). A "display pass" = a full frame of address gen
// (reaches STATE_NEXT_MB with last_mb && last_y). A "blank/idle" symptom = the
// FSM visiting STATE_INIT while held, or long gaps with busy=0.
//
// Build: iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/resample_persist_sim \
//                 dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v \
//                 bench/dvd/resample_persist_tb.sv
//
module resample_persist_tb;
  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd2;
  reg         output_frame_valid = 0;
  wire        output_frame_rd;
  reg         progressive_sequence = 1, progressive_frame = 1;
  reg         top_field_first = 0, repeat_first_field = 0;
  reg   [7:0] mb_width = 8'd4, mb_height = 8'd4;     // tiny frame -> fast sim
  reg  [13:0] horizontal_size = 14'd64, vertical_size = 14'd64;
  reg         interlaced = 0, deinterlace = 1, persistence = 1;
  reg   [4:0] repeat_frame = 0;
  reg         disp_wr_addr_full = 0, disp_wr_addr_ack = 1;
  wire        disp_wr_addr_en;
  wire [21:0] disp_wr_addr;
  wire  [2:0] resample_wr_dta;
  wire        resample_wr_en;
  reg         disp_wr_addr_almost_full = 0, resample_wr_almost_full = 0;
  wire        busy;

  resample_addrgen dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid), .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame), .informative(1'b1),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .mb_width(mb_width), .mb_height(mb_height),
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
    .interlaced(interlaced), .deinterlace(deinterlace),
    .persistence(persistence), .repeat_frame(repeat_frame),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_en(disp_wr_addr_en),
    .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .resample_wr_dta(resample_wr_dta), .resample_wr_en(resample_wr_en),
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full), .resample_wr_almost_full(resample_wr_almost_full),
    .busy(busy), .video_live(), .pickup_hold(1'b0), .pause(1'b0), .raster_par_err(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(1'b0));

  always #5 clk = ~clk;

  // ---- instrumentation (hierarchical access to FSM internals) ----
  localparam STATE_INIT = 4'h0, STATE_NEXT_IMG = 4'h1, STATE_REPEAT = 4'h2, STATE_NEXT_MB = 4'h3;
  localparam NO_OUTPUT = 3'h0, FRAME = 3'h1, TOP = 3'h2, BOTTOM = 3'h3;

  reg        held = 0;
  integer    held_cycles = 0;
  integer    busy_cycles = 0;
  integer    init_visits_held = 0;     // STATE_INIT entries while held (strobe symptom)
  integer    display_passes = 0;       // full frames emitted
  integer    real_pass_held = 0, blank_pass_held = 0;
  reg  [3:0] prev_state = STATE_INIT;
  reg  [2:0] disp_img;                 // image value at start of a display pass

  // count a "display pass" when a frame finishes (NEXT_MB with last_mb&&last_y -> NEXT_IMG)
  wire pass_done = (dut.state == STATE_NEXT_MB) && dut.last_mb && dut.last_y;

  always @(posedge clk) begin
    if (rst) begin
      if (held) begin
        held_cycles = held_cycles + 1;
        if (busy) busy_cycles = busy_cycles + 1;
        if ((dut.state == STATE_INIT) && (prev_state != STATE_INIT))
          init_visits_held = init_visits_held + 1;
      end
      if (pass_done) begin
        display_passes = display_passes + 1;
        if (held) begin
          // dut.image holds the image being emitted this pass
          if (dut.image == NO_OUTPUT) blank_pass_held = blank_pass_held + 1;
          else                        real_pass_held  = real_pass_held + 1;
        end
      end
      prev_state <= dut.state;
    end
  end

  // compact trace of the held loop (first ~600 held cycles)
  integer tracen = 0;
  always @(posedge clk)
    if (rst && held && tracen < 600) begin
      if (dut.state != prev_state) begin
        $display("[%0t] state=%0d image=%0d image_0=%0d last_image=%0d ofv=%0d busy=%0d",
                 $time, dut.state, dut.image, dut.image_0, dut.last_image, output_frame_valid, busy);
        tracen = tracen + 1;
      end
    end

  // ADDR-SCAN: dump the display read address vs disp_y around the line-256
  // boundary. If disp_wr_addr stays monotonic (= disp_y*mb_width*2 + word_x)
  // past line 256, the addrgen+memory_address are correct and the 256 bug is
  // downstream. If it wraps/jumps at disp_y==256, the bug is here.
  always @(posedge clk)
    if (rst && disp_wr_addr_en && (dut.disp_y >= 12'd250) && (dut.disp_y <= 12'd270))
      $display("[scan] disp_y=%0d disp_mb=%0d disp_frame=%0d addr=%0d (0x%05h)",
               dut.disp_y, dut.disp_mb, dut.disp_frame, disp_wr_addr, disp_wr_addr);

  initial begin
    rst = 0; output_frame_valid = 0;
    mb_width  = 8'd4;            // narrow -> fast sim; address = disp_y*8 + word_x
    mb_height = 8'd18;           // 288 lines -> scans PAST the 256 boundary
    horizontal_size = 14'd64; vertical_size = 14'd288;
    repeat (4) @(posedge clk);
    rst = 1;                              // release reset (active high enable here)
    repeat (4) @(posedge clk);

    // Keep frames available so the addrgen continuously scans full frames.
    output_frame_valid = 1;
    held = 0;

    // Run long enough to scan several full 288-line frames across line 256.
    repeat (200000) @(posedge clk);

    $display("\n==== ADDR-SCAN DONE (check [scan] lines: addr must stay monotonic past disp_y=256) ====");
    $finish;
  end

  initial begin
    #50_000_000;
    $display("TIMEOUT"); $finish;
  end
endmodule
