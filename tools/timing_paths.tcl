# timing_paths.tcl — dump the top intra-clock setup paths (the Fmax-limiter cluster).
#
# The chroma-fringe doctrine (docs/history.md §8-9): the limiter MOVES as features grow —
# framestore_request (PR #58) → disp_vscale (PR #92) → ??? . Before retiming anything,
# MEASURE which cluster is on top NOW. This script is the one-command version of the
# report_timing step PR #92 ran by hand.
#
# Run via the wrapper (handles Docker):   [USE_DOCKER=1] tools/timing_paths.sh [npaths]
# or directly:                            quartus_sta -t tools/timing_paths.tcl [npaths]
#
# Environment knobs (all optional; tools/docker_reexec.sh forwards them):
#   TIMING_CLOCK  dec (default) | mem | a full clock name from DVD.sta.rpt
#                 dec = clk_dec (sys_pll outclk_3), mem = clk_mem (sys_pll outclk_1, the
#                 DDR3 bridge, mem_shim_burst) — the same strings tools/fmax_check.sh uses.
#   TIMING_TEMP   100 (default) | -40 — the slow-model corner. ⚠ fmax_check gates BOTH
#                 slow corners and −40 °C often binds; dump the corner that is failing.
#   TIMING_OUT    output file (default output_files/clk_<dec|mem>_paths.txt)
#
# Output: a summary table of the top N intra-clock setup paths at the chosen corner + the
# 3 worst paths in full detail. Read the From/To Node columns to spot the dominant cluster.

set rev DVD
set npaths 100
if { [info exists quartus(args)] && [llength $quartus(args)] > 0 } {
    set npaths [lindex $quartus(args) 0]
}

set sel dec
if { [info exists ::env(TIMING_CLOCK)] && $::env(TIMING_CLOCK) ne "" } { set sel $::env(TIMING_CLOCK) }
switch -- $sel {
    dec     { set clk {emu|sys_pll|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}; set tag clk_dec }
    mem     { set clk {emu|sys_pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}; set tag clk_mem }
    default { set clk $sel; set tag clk_custom }
}
set temp 100
if { [info exists ::env(TIMING_TEMP)] && $::env(TIMING_TEMP) ne "" } { set temp $::env(TIMING_TEMP) }
set out output_files/${tag}_paths.txt
if { [info exists ::env(TIMING_OUT)] && $::env(TIMING_OUT) ne "" } { set out $::env(TIMING_OUT) }

project_open $rev -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist

# Pin the analysis to the requested slow corner.
if { [catch { set_operating_conditions -model slow -temperature $temp -voltage 1100 } msg] } {
    post_message -type warning "timing_paths: could not pin slow/${temp}C corner ($msg); using default"
} else {
    update_timing_netlist
}

report_timing -setup \
    -from_clock [get_clocks $clk] -to_clock [get_clocks $clk] \
    -npaths $npaths -detail summary -file $out

report_timing -setup \
    -from_clock [get_clocks $clk] -to_clock [get_clocks $clk] \
    -npaths 3 -detail full_path -append -file $out

post_message -type info "timing_paths: wrote top $npaths intra-$tag setup paths (slow ${temp}C) to $out"
project_close
