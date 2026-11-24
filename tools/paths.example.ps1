# Tool locations used by every scripts\*.ps1 driver.
#
# Copy this file to tools\paths.ps1 and edit the three values for your machine:
#     copy tools\paths.example.ps1 tools\paths.ps1
# tools\paths.ps1 is listed in .gitignore. If it does not exist, the scripts
# fall back to the values below (the install locations of the author's
# machine, which are also the Xilinx/AMD installer defaults).
#
# <VIVADO_2019_ROOT>: Vivado 2019.1 install folder (contains bin\xvlog.bat).
#   Used for every functional simulation and the netlist-SAIF simulations.
$VIVADO2019_ROOT = 'C:\Xilinx\Vivado\2019.1'
# <VIVADO_2026_ROOT>: Vivado 2026.1 install folder (contains bin\vivado.bat).
#   Used for the Virtex-7 builds, RTL-SAIF simulation and report_power.
$VIVADO2026_ROOT = 'C:\AMDDesignTools\2026.1\Vivado'
# <PYTHON>: Python 3.12 interpreter (standard library only). The scripts run it
#   with -I. A bare 'python' uses the first one on PATH.
$PYTHON = 'python'
