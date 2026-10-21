# Vivado pre-synthesis hook (CORE-R6.xpr, synth_1): rebuild the QNICE firmware.
# Runs in CORE/CORE-R6.runs/synth_1.
set cur_dir [exec pwd]
cd ../../../CORE/m2m-rom/
exec ./make_rom.sh <@stdin >@stdout 2>@stderr
cd $cur_dir
