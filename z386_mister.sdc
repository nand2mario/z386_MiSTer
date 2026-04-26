derive_pll_clocks
derive_clock_uncertainty

# Reset/control-release paths are intentionally asynchronous.
# Cut them so TimeQuest reports real datapaths.
set_false_path -from [get_registers {*cpu_reset_n*}]
set_false_path -from [get_registers {*reset_sync_r*}]
set_false_path -from [get_registers {*boot_done*}]
