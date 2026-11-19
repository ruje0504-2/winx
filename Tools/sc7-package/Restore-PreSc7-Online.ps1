[CmdletBinding()]
param(
    [string]$JournalPath
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module -Name (Join-Path $Here 'Sc7Package.psm1') -Force

$Result = Invoke-Sc7RestoreTransaction `
    -JournalPath $JournalPath `
    -Context (New-Sc7WindowsContext)

$ManualNotes = @()
if (-not $Result.JournalFound) {
    $ManualNotes += "  - Driver packages: no transaction journal was found at '$($Result.JournalPath)', so drivers were not automatically modified. Inspect bound oem*.inf packages with 'pnputil /enum-drivers' and Device Manager before rolling back individual Switch drivers."
} elseif (-not $Result.Success) {
    $ManualNotes += "  - Incomplete driver rollback: inspect '$($Result.JournalPath)' for remaining devices/packages. Use Device Manager ('Roll Back Driver' / 'Update Driver -> Let me pick') on affected devices without deleting shared OEM packages."
}
if ($Result.HadStandaloneGpuKmd -or -not $Result.JournalFound) {
    $ManualNotes += '  - GPU / tgd3d: if standalone tegragpurender.inf was installed, verify active tgd3d UMD registration and the 5-second post-logon tgd3d startup path after reboot.'
}

$ManualSection = if ($ManualNotes.Count -gt 0) { ("`n" + ($ManualNotes -join "`n")) } else { '' }

Write-Host @"
Recovery summary (exit code $($Result.ExitCode)):$ManualSection
To fully revert UEFI/TF-A firmware on the FAT32 boot partition (owned by parent):
  1. Replace SC7 bl31.bin with firmware\bl31-default-stock.bin (SHA256 c2d048aa... = lite-entry-r8)
     and rebuild UEFI without -D SWITCH_LITE_SC7=1.
  2. Preserve baseline clocks/tray settings via switch-lite-dvfs-tray-arm64 if needed.
"@

if ($Result.ExitCode -eq 3010) {
    Write-Host 'Reboot required to complete restoration / SC7 deactivation (exit code 3010).'
} elseif ($Result.ExitCode -eq 3017) {
    Write-Host 'Restore completed with errors AND a reboot is required (exit code 3017 / ERROR_FAIL_REBOOT_REQUIRED).'
}

exit $Result.ExitCode
