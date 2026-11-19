[CmdletBinding()]
param(
    [ValidateSet(-1, 0, 1)]
    [int]$Enable = -1,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
$PepKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\tegra214pep\Parameters'
$PwrKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\switchpwrbtn\Parameters'
$FanKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\switchfan\Parameters'

if ($Enable -ge 0) {
    if (-not (Test-Path -LiteralPath $PepKey)) {
        New-Item -Path $PepKey -Force | Out-Null
    }
    New-ItemProperty -Path $PepKey -Name 'EnableSc7' -PropertyType DWord -Value $Enable -Force | Out-Null
    Write-Host ("Updated {0}\EnableSc7 = {1} (takes effect on next display state notification or reboot)." -f $PepKey, $Enable)
}

$BitNames = @(
    '0:SDM1', '1:PWRB', '2:I2C1', '3:I2C3', '4:I2C5',
    '5:GPU0', '6:TCH0', '7:SIO0', '8:BAT0', '9:RTC0'
)

if (Test-Path -LiteralPath $PepKey) {
    $Props = Get-ItemProperty -LiteralPath $PepKey
    $Mask = if ($null -ne $Props.Sc7BlockingMask) { [uint32]$Props.Sc7BlockingMask } else { 0 }
    $Blockers = @()
    for ($i = 0; $i -lt $BitNames.Count; $i++) {
        if (($Mask -band (1 -shl $i)) -ne 0) {
            $Blockers += $BitNames[$i]
        }
    }
    Write-Host "=== Tegra214Power (PEP) ==="
    Write-Host ("  DriverVersion   : {0}" -f $Props.DriverVersion)
    Write-Host ("  EnableSc7 (cfg) : {0}" -f $Props.EnableSc7)
    Write-Host ("  EnableSc7Active : {0}" -f $Props.EnableSc7Active)
    Write-Host ("  DisplayOff      : {0}" -f $Props.DisplayOff)
    Write-Host ("  Sc7BlockingMask : 0x{0:X3} ({1})" -f $Mask, ($(if ($Blockers.Count) { $Blockers -join ', ' } else { 'ready' })))
    Write-Host ("  Cc6Attempts     : {0}" -f $Props.Cc6Attempts)
    Write-Host ("  Sc7Attempts     : {0}" -f $Props.Sc7Attempts)
    Write-Host ("  Sc7Returns      : {0}" -f $Props.Sc7Returns)
    Write-Host ("  Sc7Failures     : {0}" -f $Props.Sc7Failures)
    Write-Host ("  Sc7Downgrades   : {0}" -f $Props.Sc7Downgrades)
    Write-Host ("  LastSc7Status   : 0x{0:X8}" -f ($(if ($null -ne $Props.LastSc7Status) { [uint32]$Props.LastSc7Status } else { 0 })))
} else {
    Write-Host "Tegra214Power Parameters key not present yet ($PepKey)."
}

if (Test-Path -LiteralPath $PwrKey) {
    $Pwr = Get-ItemProperty -LiteralPath $PwrKey
    Write-Host "=== SwitchPowerButton ==="
    Write-Host ("  DriverVersion   : {0}" -f $Pwr.DriverVersion)
    Write-Host ("  WakeIrqReady    : {0}" -f $Pwr.WakeIrqReady)
    Write-Host ("  WakeReports     : {0}" -f $Pwr.WakeReports)
    Write-Host ("  PowerReports    : {0}" -f $Pwr.PowerReports)
}

if (Test-Path -LiteralPath $FanKey) {
    $Fan = Get-ItemProperty -LiteralPath $FanKey
    Write-Host "=== SwitchFan ==="
    Write-Host ("  DriverVersion   : {0}" -f $Fan.DriverVersion)
    Write-Host ("  ScreenOffIdle   : {0}" -f $Fan.ScreenOffIdle)
    Write-Host ("  CpuActualKhz    : {0}" -f $Fan.CpuActualKhz)
    Write-Host ("  Duty            : {0}" -f $Fan.Duty)
}
