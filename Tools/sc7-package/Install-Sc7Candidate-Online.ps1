[CmdletBinding()]
param(
    [switch]$IncludePep,
    [switch]$IncludeStandaloneGpuKmd,
    [string]$JournalPath,
    [switch]$NoRollbackOnFailure
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Note: All kernel .sys/.cat packages must be test-signed by the parent host
# signing workflow prior to pnputil installation on Windows 11 ARM64.
# By default:
#   - EnableSc7 remains 0 (CC6/C7 only until parent stages SC7 firmware + warmboot/BPMP).
#   - Standalone tegragpurender.inf is NOT installed unless -IncludeStandaloneGpuKmd
#     is explicitly requested, preserving active tgd3d UMD registration and the
#     5-second post-logon tgd3d startup path.

Import-Module -Name (Join-Path $Here 'Sc7Package.psm1') -Force

$Result = Invoke-Sc7InstallTransaction `
    -PackageRoot $Here `
    -IncludePep:$IncludePep `
    -IncludeStandaloneGpuKmd:$IncludeStandaloneGpuKmd `
    -JournalPath $JournalPath `
    -NoRollbackOnFailure:$NoRollbackOnFailure `
    -Context (New-Sc7WindowsContext)

exit $Result.ExitCode
