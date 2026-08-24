# timing_paths.tcl — dump the top intra-clk_dec setup paths (the Fmax-limiter cluster).
#
# The chroma-fringe doctrine (docs/history.md §8-9): the clk_dec Fmax limiter MOVES as
# features grow — framestore_request (PR #58) → disp_vscale (PR #92) → ??? . Before
# retiming anything, MEASURE which cluster is on top NOW. This script is the
# one-command version of the report_timing step PR #92 ran by hand.
#
# Run via the wrapper (handles Docker):   [USE_DOCKER=1] tools/timing_paths.sh [npaths]
# or directly:                            quartus_sta -t tools/timing_paths.tcl [npaths]
#
# Output: output_files/clk_dec_paths.txt — a summary table of the top N intra-clk_dec
# setup paths (slow 1100mV 100C corner, the gate's worst corner) + the 3 worst paths
# in full detail. Read the From/To Node columns to spot the dominant cluster.

set rev DVD
set npaths 100
if { [info exists quartus(args)] && [llength $quartus(args)] > 0 } {
    set npaths [lindex $quartus(args) 0]
}

# Same clock string as tools/fmax_check.sh CLK_DEC (outclk_3 = clk_dec).
set clk_dec {emu|sys_pll|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}
set out output_files/clk_dec_paths.txt

project_open $rev -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist

# Pin the analysis to the hot slow corner (the one fmax_check gates hardest on).
if { [catch { set_operating_conditions -model slow -temperature 100 -voltage 1100 } msg] } {
    post_message -type warning "timing_paths: could not pin slow/100C corner ($msg); using default"
} else {
    update_timing_netlist
}

report_timing -setup \
    -from_clock [get_clocks $clk_dec] -to_clock [get_clocks $clk_dec] \
    -npaths $npaths -detail summary -file $out

report_timing -setup \
    -from_clock [get_clocks $clk_dec] -to_clock [get_clocks $clk_dec] \
    -npaths 3 -detail full_path -append -file $out

post_message -type info "timing_paths: wrote top $npaths intra-clk_dec setup paths to $out"
project_close
