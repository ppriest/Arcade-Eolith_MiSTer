derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# The two 8052s (jt8052: the QS1000's on its 24 MHz enable, the Gradation 2D sound CPU's on its 12 MHz
# one) update every register on their enable, which is never two clk_sys clocks in a row
# (rtl/qs1000/eo_qs1000.sv, eo_sndcpu.sv): a path from one of a core's registers to another of the same
# core has two clocks, and so has one into its internal RAM, written and read on the same enable. Paths
# between the two cores (the serial line) keep one. As Arcade-Vamphalf_MiSTer's Vamphalf.sdc.
foreach inst {eo_qs1000:u_snd eo_sndcpu:u_sndcpu} {
	set_multicycle_path -setup 2 -from [get_registers "*${inst}|jt8052:u_mcu|*"] -to [get_registers "*${inst}|jt8052:u_mcu|*"]
	set_multicycle_path -hold 1 -from [get_registers "*${inst}|jt8052:u_mcu|*"] -to [get_registers "*${inst}|jt8052:u_mcu|*"]
	set_multicycle_path -setup 2 -from [get_registers "*${inst}|jt8052:u_mcu|*"] -to [get_keepers "*${inst}|vh_dpram:u_iram|*"]
	set_multicycle_path -hold 1 -from [get_registers "*${inst}|jt8052:u_mcu|*"] -to [get_keepers "*${inst}|vh_dpram:u_iram|*"]
}
