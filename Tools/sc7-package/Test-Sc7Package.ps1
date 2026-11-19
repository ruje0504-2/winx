[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module -Name (Join-Path $Here 'Sc7Package.psm1') -Force

$script:PassedTests = 0
$script:FailedTests = 0
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sc7-pkg-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed ($Message): expected '$Expected', got '$Actual'"
    }
}

function Get-LocalSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToUpperInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Join-RelPath {
    param(
        [string]$BasePath,
        [string]$RelativePath
    )
    $res = $BasePath
    foreach ($seg in @($RelativePath -split '[\\/]')) {
        if (-not [string]::IsNullOrWhiteSpace($seg)) {
            $res = Join-Path $res $seg
        }
    }
    return $res
}

function New-MockPackageTree {
    param(
        [string]$RootDir,
        [string]$PayloadTag = 'cand-v1'
    )
    $specs = [ordered]@{
        'tegra210gpio'   = @{ Rel = 'drivers\tegra210gpio';   Ver = '1.0.0.5';  Date = '03/15/2026'; HwIds = @('ACPI\NVDA0108') }
        'tegra210i2c'    = @{ Rel = 'drivers\tegra210i2c';    Ver = '1.0.0.6';  Date = '03/15/2026'; HwIds = @('ACPI\NVDA0200') }
        'switchfan'      = @{ Rel = 'drivers\switchfan';      Ver = '1.0.0.15'; Date = '03/15/2026'; HwIds = @('ACPI\SWOA0F01') }
        'switchbattery'  = @{ Rel = 'drivers\switchbattery';  Ver = '1.0.0.13'; Date = '03/15/2026'; HwIds = @('ACPI\SWOA0B01') }
        'switchpwrbtn'   = @{ Rel = 'drivers\switchpwrbtn';   Ver = '1.0.0.5';  Date = '03/15/2026'; HwIds = @('ACPI\SWOA0P01') }
        'switchrtc'      = @{ Rel = 'drivers\switchrtc';      Ver = '1.0.0.3';  Date = '03/15/2026'; HwIds = @('ACPI\SWOA0R01') }
        'switchtouch'    = @{ Rel = 'drivers\switchtouch';    Ver = '1.0.1.1';  Date = '03/15/2026'; HwIds = @('ACPI\SWOA0T01') }
        'switchsio'      = @{ Rel = 'drivers\switchsio';      Ver = '0.2.4.0';  Date = '03/15/2026'; HwIds = @('ACPI\SWOA0S01') }
        'switchbt'       = @{ Rel = 'drivers\switchbt';       Ver = '1.0.0.2';  Date = '03/15/2026'; HwIds = @('ACPI\SWOA0U01') }
        'tegraxusb'      = @{ Rel = 'drivers\tegraxusb';      Ver = '0.1.1.0';  Date = '03/15/2026'; HwIds = @('ACPI\NVDA0300') }
        'tegra214pep'    = @{ Rel = 'drivers\tegra214pep';    Ver = '0.2.0.0';  Date = '03/15/2026'; HwIds = @('ACPI\SWOA0E01') }
        'tegragpurender' = @{ Rel = 'gpu\tegragpurender';     Ver = '1.0.0.9';  Date = '03/15/2026'; HwIds = @('ACPI\NVDA0400') }
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($name in $specs.Keys) {
        $sp = $specs[$name]
        $dir = Join-RelPath -BasePath $RootDir -RelativePath $sp.Rel
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $hwLine = ($sp.HwIds | ForEach-Object { "%Desc%=InstallSec, $_" }) -join "`r`n"
        $infContent = @"
[Version]
Signature="`$WINDOWS NT`$"
Class=System
ClassGuid={4d36e97d-e325-11ce-bfc1-08002be10318}
Provider=%Mfg%
CatalogFile=$name.cat
DriverVer=$($sp.Date),$($sp.Ver)

[SourceDisksNames]
1 = %DiskName%,,,""

[SourceDisksFiles]
$name.sys = 1,,

[Manufacturer]
%Mfg%=Models,NTARM64

[Models.NTARM64]
$hwLine

[Strings]
Mfg="SwitchWoA"
DiskName="$name Disk"
Desc="$name Device"
"@
        [System.IO.File]::WriteAllText((Join-Path $dir "$name.inf"), $infContent, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $dir "$name.sys"), "SYS-$name-$PayloadTag", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $dir "$name.cat"), "CAT-$name-$PayloadTag", $utf8)
    }
    return $specs
}

function New-MockSystem {
    param(
        [string]$PackageRoot,
        $Specs,
        [switch]$WithPepServiceKey,
        [switch]$WithPepParametersKey,
        [int]$InitialEnableSc7 = 0,
        [int]$InitialEnableSc7Active = 0,
        [switch]$NoPepDevice
    )
    $storeRoot = Join-Path $PackageRoot '_mock_driverstore'
    New-Item -ItemType Directory -Path $storeRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $state = [ordered]@{
        BootId           = 'BOOT-1'
        IsAdministrator  = $true
        NextOem          = 41
        StoreRoot        = $storeRoot
        PepSvc           = 'HKLM:\SYSTEM\CurrentControlSet\Services\tegra214pep'
        Registry         = @{}
        Store            = New-Object System.Collections.ArrayList
        Devices          = New-Object System.Collections.ArrayList
        OperationLog     = New-Object System.Collections.ArrayList
        Logs             = New-Object System.Collections.ArrayList
        Hooks            = [ordered]@{
            OnAddDriver      = $null
            OnDeleteDriver   = $null
            OnRollbackDevice = $null
        }
        StageHelper      = $null
        BindHelper       = $null
    }

    $pepSvc = 'HKLM:\SYSTEM\CurrentControlSet\Services\tegra214pep'
    $pepParam = 'HKLM:\SYSTEM\CurrentControlSet\Services\tegra214pep\Parameters'
    if ($WithPepServiceKey -or $WithPepParametersKey) {
        $state.Registry[$pepSvc.ToLowerInvariant()] = @{}
    }
    if ($WithPepParametersKey) {
        $state.Registry[$pepParam.ToLowerInvariant()] = @{
            'EnableSc7'       = $InitialEnableSc7
            'EnableSc7Active' = $InitialEnableSc7Active
        }
    }

    # Populate baseline pre-SC7 OEM drivers and devices
    $oemIdx = 10
    $baseSpecs = @(
        @{ Name = 'tegra210gpio';  Ver = '1.0.0.4';  Date = '2026-01-10'; Hw = 'ACPI\NVDA0108'; Insts = @('ACPI\NVDA0108\0') }
        @{ Name = 'tegra210i2c';   Ver = '1.0.0.5';  Date = '2026-01-10'; Hw = 'ACPI\NVDA0200'; Insts = @('ACPI\NVDA0200\0', 'ACPI\NVDA0200\1', 'ACPI\NVDA0200\2', 'ACPI\NVDA0200\3', 'ACPI\NVDA0200\4', 'ACPI\NVDA0200\5') }
        @{ Name = 'switchfan';     Ver = '1.0.0.14'; Date = '2026-01-10'; Hw = 'ACPI\SWOA0F01'; Insts = @('ACPI\SWOA0F01\0') }
        @{ Name = 'switchbattery'; Ver = '1.0.0.12'; Date = '2026-01-10'; Hw = 'ACPI\SWOA0B01'; Insts = @('ACPI\SWOA0B01\0') }
        @{ Name = 'switchpwrbtn';  Ver = '1.0.0.4';  Date = '2026-01-10'; Hw = 'ACPI\SWOA0P01'; Insts = @('ACPI\SWOA0P01\0') }
        @{ Name = 'switchrtc';     Ver = '1.0.0.2';  Date = '2026-01-10'; Hw = 'ACPI\SWOA0R01'; Insts = @('ACPI\SWOA0R01\0') }
        @{ Name = 'switchtouch';   Ver = '1.0.1.0';  Date = '2026-01-10'; Hw = 'ACPI\SWOA0T01'; Insts = @('ACPI\SWOA0T01\0') }
        @{ Name = 'switchsio';     Ver = '0.2.3.0';  Date = '2026-01-10'; Hw = 'ACPI\SWOA0S01'; Insts = @('ACPI\SWOA0S01\0') }
        @{ Name = 'switchbt';      Ver = '1.0.0.1';  Date = '2026-01-10'; Hw = 'ACPI\SWOA0U01'; Insts = @('ACPI\SWOA0U01\0') }
        @{ Name = 'tegraxusb';     Ver = '0.1.0.0';  Date = '2026-01-10'; Hw = 'ACPI\NVDA0300'; Insts = @('ACPI\NVDA0300\0') }
    )

    foreach ($bs in $baseSpecs) {
        $oemName = "oem$oemIdx.inf"
        $oemIdx++
        $pkgDir = Join-Path $storeRoot "$($bs.Name)_prior_$oemName"
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        $infPath = Join-Path $pkgDir "$($bs.Name).inf"
        $infTxt = "[Version]`r`nProvider=SwitchWoA`r`nCatalogFile=$($bs.Name).cat`r`nDriverVer=01/10/2026,$($bs.Ver)`r`n[SourceDisksFiles]`r`n$($bs.Name).sys=1,,`r`n[Manufacturer]`r`nM=Models,NTARM64`r`n[Models.NTARM64]`r`nD=I, $($bs.Hw)`r`n"
        [System.IO.File]::WriteAllText($infPath, $infTxt, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $pkgDir "$($bs.Name).sys"), "PRIOR-SYS-$($bs.Name)", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $pkgDir "$($bs.Name).cat"), "PRIOR-CAT-$($bs.Name)", $utf8)
        $fHashes = @{
            "$($bs.Name).inf" = Get-LocalSha256 $infPath
            "$($bs.Name).sys" = Get-LocalSha256 (Join-Path $pkgDir "$($bs.Name).sys")
            "$($bs.Name).cat" = Get-LocalSha256 (Join-Path $pkgDir "$($bs.Name).cat")
        }
        [void]$state.Store.Add([ordered]@{
            PublishedName      = $oemName
            OriginalName       = "$($bs.Name).inf"
            DriverVersion      = $bs.Ver
            DriverDate         = $bs.Date
            ProviderName       = 'SwitchWoA'
            DriverStoreInfPath = $infPath
            PublishedInfPath   = $infPath
            InfSha256          = $fHashes["$($bs.Name).inf"]
            FileHashes         = $fHashes
            HardwareIds        = @($bs.Hw)
        })
        foreach ($inst in $bs.Insts) {
            [void]$state.Devices.Add([ordered]@{
                InstanceId    = $inst
                Present       = $true
                InfName       = $oemName
                DriverVersion = $bs.Ver
                DriverDate    = $bs.Date
                ProviderName  = 'SwitchWoA'
                HardwareIds   = @($bs.Hw)
                CompatibleIds = @()
                RollbackStack = New-Object System.Collections.ArrayList
            })
        }
    }

    # Pre-SC7 tgd3d GPU package (oem20.inf)
    $gpuPkgDir = Join-Path $storeRoot 'tgd3d_prior_oem20'
    New-Item -ItemType Directory -Path $gpuPkgDir -Force | Out-Null
    $gpuPriorInf = Join-Path $gpuPkgDir 'tgd3d.inf'
    [System.IO.File]::WriteAllText($gpuPriorInf, "[Version]`r`nProvider=MesaTgd3d`r`nCatalogFile=tgd3d.cat`r`nDriverVer=01/15/2026,1.0.0.8`r`n[SourceDisksFiles]`r`ntgd3d.sys=1,,`r`n[Manufacturer]`r`nM=Models,NTARM64`r`n[Models.NTARM64]`r`nD=I, ACPI\NVDA0400`r`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $gpuPkgDir 'tgd3d.sys'), 'PRIOR-TGD3D-SYS', $utf8)
    [System.IO.File]::WriteAllText((Join-Path $gpuPkgDir 'tgd3d.cat'), 'PRIOR-TGD3D-CAT', $utf8)
    [void]$state.Store.Add([ordered]@{
        PublishedName      = 'oem20.inf'
        OriginalName       = 'tgd3d.inf'
        DriverVersion      = '1.0.0.8'
        DriverDate         = '2026-01-15'
        ProviderName       = 'MesaTgd3d'
        DriverStoreInfPath = $gpuPriorInf
        PublishedInfPath   = $gpuPriorInf
        InfSha256          = Get-LocalSha256 $gpuPriorInf
        FileHashes         = @{
            'tgd3d.inf' = Get-LocalSha256 $gpuPriorInf
            'tgd3d.sys' = Get-LocalSha256 (Join-Path $gpuPkgDir 'tgd3d.sys')
            'tgd3d.cat' = Get-LocalSha256 (Join-Path $gpuPkgDir 'tgd3d.cat')
        }
        HardwareIds        = @('ACPI\NVDA0400')
    })
    [void]$state.Devices.Add([ordered]@{
        InstanceId    = 'ACPI\NVDA0400\0'
        Present       = $true
        InfName       = 'oem20.inf'
        DriverVersion = '1.0.0.8'
        DriverDate    = '2026-01-15'
        ProviderName  = 'MesaTgd3d'
        HardwareIds   = @('ACPI\NVDA0400')
        CompatibleIds = @()
        RollbackStack = New-Object System.Collections.ArrayList
    })

    if (-not $NoPepDevice) {
        # Unbound ACPI\SWOA0E01 device awaiting tegra214pep
        [void]$state.Devices.Add([ordered]@{
            InstanceId    = 'ACPI\SWOA0E01\0'
            Present       = $true
            InfName       = $null
            DriverVersion = $null
            DriverDate    = $null
            ProviderName  = $null
            HardwareIds   = @('ACPI\SWOA0E01')
            CompatibleIds = @()
            RollbackStack = New-Object System.Collections.ArrayList
        })
    }

    $stagePackageFn = {
        param([string]$InfPath)
        $meta = Read-Sc7InfMetadata -InfPath $InfPath
        foreach ($existing in $state.Store) {
            if ($existing.OriginalName -ieq $meta.OriginalName -and $existing.InfSha256 -eq $meta.InfSha256) {
                return $existing
            }
        }
        $oem = "oem$($state.NextOem).inf"
        $state.NextOem++
        $pkgDir = Join-Path $state.StoreRoot "$($meta.OriginalName)_$oem"
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        $srcDir = Split-Path -Parent $InfPath
        Copy-Item -LiteralPath $InfPath -Destination (Join-Path $pkgDir $meta.OriginalName) -Force
        if ($meta.CatalogFile) {
            Copy-Item -LiteralPath (Join-Path $srcDir $meta.CatalogFile) -Destination (Join-Path $pkgDir $meta.CatalogFile) -Force
        }
        foreach ($pf in @($meta.PayloadFiles)) {
            $dest = $pkgDir
            $src = $srcDir
            foreach ($seg in @(([string]$pf) -split '[\\/]')) {
                if (-not [string]::IsNullOrWhiteSpace($seg)) {
                    $dest = Join-Path $dest $seg
                    $src = Join-Path $src $seg
                }
            }
            $destParent = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
        $pkg = [ordered]@{
            PublishedName      = $oem
            OriginalName       = $meta.OriginalName
            DriverVersion      = $meta.DriverVersion
            DriverDate         = $meta.DriverDate
            ProviderName       = $meta.ProviderName
            DriverStoreInfPath = Join-Path $pkgDir $meta.OriginalName
            PublishedInfPath   = Join-Path $pkgDir $meta.OriginalName
            InfSha256          = $meta.InfSha256
            FileHashes         = $meta.FileHashes
            HardwareIds        = @($meta.HardwareIds)
        }
        [void]$state.Store.Add($pkg)
        return $pkg
    }.GetNewClosure()

    $bindDeviceToPkgFn = {
        param($Device, $Pkg)
        if ($null -ne $Device.InfName) {
            [void]$Device.RollbackStack.Add([ordered]@{
                InfName       = $Device.InfName
                DriverVersion = $Device.DriverVersion
                DriverDate    = $Device.DriverDate
                ProviderName  = $Device.ProviderName
            })
        }
        $Device.InfName = $Pkg.PublishedName
        $Device.DriverVersion = $Pkg.DriverVersion
        $Device.DriverDate = $Pkg.DriverDate
        $Device.ProviderName = $Pkg.ProviderName
        if ($Pkg.OriginalName -ieq 'tegra214pep.inf') {
            $svcK = $state.PepSvc.ToLowerInvariant()
            if (-not $state.Registry.ContainsKey($svcK)) {
                $state.Registry[$svcK] = @{}
            }
        }
    }.GetNewClosure()

    $state.StageHelper = $stagePackageFn
    $state.BindHelper = $bindDeviceToPkgFn

    $ctx = [ordered]@{
        State       = $state
        StageHelper = $stagePackageFn
        BindHelper  = $bindDeviceToPkgFn
        GetBootId   = { return $state.BootId }.GetNewClosure()
        TestIsAdministrator = { return $state.IsAdministrator }.GetNewClosure()
        GetRegistryKeyExists = {
            param([string]$KeyPath)
            return $state.Registry.ContainsKey($KeyPath.ToLowerInvariant())
        }.GetNewClosure()
        GetRegistryValue = {
            param([string]$KeyPath, [string]$Name)
            $k = $KeyPath.ToLowerInvariant()
            if (-not $state.Registry.ContainsKey($k)) { return $null }
            $props = $state.Registry[$k]
            if ($props.ContainsKey($Name)) { return $props[$Name] }
            return $null
        }.GetNewClosure()
        EnsureRegistryKey = {
            param([string]$KeyPath)
            [void]$state.OperationLog.Add("RegEnsure:$KeyPath")
            $k = $KeyPath.ToLowerInvariant()
            if (-not $state.Registry.ContainsKey($k)) { $state.Registry[$k] = @{} }
        }.GetNewClosure()
        SetRegistryDWord = {
            param([string]$KeyPath, [string]$Name, [int]$Value)
            [void]$state.OperationLog.Add("RegSet:$KeyPath\$Name=$Value")
            $k = $KeyPath.ToLowerInvariant()
            if (-not $state.Registry.ContainsKey($k)) { $state.Registry[$k] = @{} }
            $state.Registry[$k][$Name] = $Value
        }.GetNewClosure()
        GetDriverStorePackages = {
            $copy = New-Object System.Collections.ArrayList
            foreach ($p in $state.Store) {
                [void]$copy.Add([ordered]@{
                    PublishedName      = $p.PublishedName
                    OriginalName       = $p.OriginalName
                    DriverVersion      = $p.DriverVersion
                    DriverDate         = $p.DriverDate
                    ProviderName       = $p.ProviderName
                    DriverStoreInfPath = $p.DriverStoreInfPath
                    PublishedInfPath   = $p.PublishedInfPath
                    InfSha256          = $p.InfSha256
                    FileHashes         = $p.FileHashes
                })
            }
            return $copy.ToArray()
        }.GetNewClosure()
        GetPnpDevices = {
            $copy = New-Object System.Collections.ArrayList
            foreach ($d in $state.Devices) {
                [void]$copy.Add([ordered]@{
                    InstanceId    = $d.InstanceId
                    Present       = $d.Present
                    InfName       = $d.InfName
                    DriverVersion = $d.DriverVersion
                    DriverDate    = $d.DriverDate
                    ProviderName  = $d.ProviderName
                    HardwareIds   = @($d.HardwareIds)
                    CompatibleIds = @($d.CompatibleIds)
                })
            }
            return $copy.ToArray()
        }.GetNewClosure()
        InvokeDeviceRollback = {
            param([string]$InstanceId)
            [void]$state.OperationLog.Add("RollbackDevice:$InstanceId")
            if ($null -ne $state.Hooks.OnRollbackDevice) {
                $override = & $state.Hooks.OnRollbackDevice $InstanceId $state
                if ($null -ne $override) { return $override }
            }
            $dev = $null
            foreach ($d in $state.Devices) {
                if ($d.InstanceId -ieq $InstanceId) { $dev = $d; break }
            }
            if ($null -eq $dev -or $dev.RollbackStack.Count -eq 0) {
                return [ordered]@{ Supported = $true; ExitCode = 259; NeedReboot = $false; ErrorMessage = 'ERROR_NO_MORE_ITEMS' }
            }
            $prev = $dev.RollbackStack[$dev.RollbackStack.Count - 1]
            $dev.RollbackStack.RemoveAt($dev.RollbackStack.Count - 1)
            $dev.InfName = $prev.InfName
            $dev.DriverVersion = $prev.DriverVersion
            $dev.DriverDate = $prev.DriverDate
            $dev.ProviderName = $prev.ProviderName
            return [ordered]@{ Supported = $true; ExitCode = 0; NeedReboot = $false; ErrorMessage = $null }
        }.GetNewClosure()
        InvokePnputil = {
            param([string[]]$Arguments)
            [void]$state.OperationLog.Add("Pnputil:$($Arguments -join ' ')")
            if ($Arguments -contains '/force') {
                throw 'Forbidden pnputil /force argument used!'
            }
            if ($Arguments[0] -ieq '/add-driver') {
                $infPath = $Arguments[1]
                $origName = [System.IO.Path]::GetFileName($infPath)
                if ($null -ne $state.Hooks.OnAddDriver) {
                    $override = & $state.Hooks.OnAddDriver $infPath $origName $state $state.StageHelper $state.BindHelper
                    if ($null -ne $override) { return $override }
                }
                $pkg = & $state.StageHelper $infPath
                $matchedDevs = @($state.Devices | Where-Object {
                    $_.Present -and (@($_.HardwareIds | Where-Object { $_ -in $pkg.HardwareIds }).Count -gt 0)
                })
                $updated = 0
                foreach ($md in $matchedDevs) {
                    if ($md.InfName -ieq $pkg.PublishedName -and $md.DriverVersion -eq $pkg.DriverVersion) {
                        continue
                    }
                    if ($null -ne $md.DriverVersion -and ([version]$md.DriverVersion -gt [version]$pkg.DriverVersion)) {
                        continue
                    }
                    & $state.BindHelper $md $pkg
                    $updated++
                }
                if ($updated -eq 0) {
                    return [ordered]@{ ExitCode = 259; StdOut = "Published Name: $($pkg.PublishedName)"; StdErr = '' }
                }
                return [ordered]@{ ExitCode = 0; StdOut = "Published Name: $($pkg.PublishedName)"; StdErr = '' }
            } elseif ($Arguments[0] -ieq '/delete-driver') {
                $oem = $Arguments[1]
                $withUninstall = ($Arguments -contains '/uninstall')
                if ($null -ne $state.Hooks.OnDeleteDriver) {
                    $override = & $state.Hooks.OnDeleteDriver $oem $withUninstall $state
                    if ($null -ne $override) { return $override }
                }
                $boundDevs = @($state.Devices | Where-Object { $_.InfName -ieq $oem })
                if ($boundDevs.Count -gt 0 -and -not $withUninstall) {
                    return [ordered]@{ ExitCode = 259; StdOut = ''; StdErr = 'Package in use' }
                }
                if ($withUninstall) {
                    foreach ($bd in $boundDevs) {
                        $bd.InfName = $null
                        $bd.DriverVersion = $null
                        $bd.DriverDate = $null
                        $bd.ProviderName = $null
                    }
                }
                for ($i = $state.Store.Count - 1; $i -ge 0; $i--) {
                    if ($state.Store[$i].PublishedName -ieq $oem) { $state.Store.RemoveAt($i) }
                }
                return [ordered]@{ ExitCode = 0; StdOut = "Deleted $oem"; StdErr = '' }
            } elseif ($Arguments[0] -ieq '/scan-devices') {
                return [ordered]@{ ExitCode = 0; StdOut = 'Scan complete'; StdErr = '' }
            }
            return [ordered]@{ ExitCode = 87; StdOut = ''; StdErr = 'Unsupported mock pnputil command' }
        }.GetNewClosure()
        Log = {
            param([string]$Message)
            [void]$state.Logs.Add($Message)
        }.GetNewClosure()
    }
    return $ctx
}

function Invoke-TestCase {
    param(
        [string]$Name,
        [scriptblock]$Body
    )
    try {
        & $Body
        $script:PassedTests++
        Write-Host "[PASS] $Name"
    } catch {
        $script:FailedTests++
        Write-Host "[FAIL] $Name : $($_.Exception.Message)"
        if ($_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace
        }
    }
}

try {
    # Test 1: Preflight fails on missing INF or referenced .sys/.cat BEFORE any mutation
    Invoke-TestCase 'Preflight rejects missing payload/INF before any registry or pnputil mutation' {
        $dir = Join-Path $script:TempRoot 't1'
        $specs = New-MockPackageTree -RootDir $dir
        Remove-Item -LiteralPath (Join-RelPath -BasePath $dir -RelativePath 'drivers\tegraxusb\tegraxusb.sys') -Force
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs -WithPepParametersKey -InitialEnableSc7 1
        $jPath = Join-Path $dir 'journal.json'
        $res = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 1 $res.ExitCode 'preflight failure exit code'
        Assert-True $res.PreflightFailed 'PreflightFailed should be true'
        Assert-Equal 0 $ctx.State.OperationLog.Count 'no operations before preflight passes'
        Assert-Equal 1 $ctx.State.Registry['hklm:\system\currentcontrolset\services\tegra214pep\parameters']['EnableSc7'] 'EnableSc7 untouched on preflight failure'
        Assert-True (-not (Test-Path -LiteralPath $jPath)) 'journal must not be created on preflight failure'
    }

    # Test 2: SC7 gate cleared FIRST before first pnputil call, and preserved across mid-install failure
    Invoke-TestCase 'SC7 gate cleared before first pnputil and preserved on mid-install failure' {
        $dir = Join-Path $script:TempRoot 't2'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs -WithPepParametersKey -InitialEnableSc7 1 -InitialEnableSc7Active 0
        $ctx.State.Hooks.OnAddDriver = {
            param($inf, $orig, $st, $stage, $bind)
            if ($orig -ieq 'switchfan.inf') {
                return [ordered]@{ ExitCode = 1603; StdOut = ''; StdErr = 'simulated failure' }
            }
            return $null
        }
        $jPath = Join-Path $dir 'journal.json'
        $res = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 1 $res.ExitCode 'failure exit code without reboot'
        $regIdx = -1; $pnpIdx = -1
        for ($i = 0; $i -lt $ctx.State.OperationLog.Count; $i++) {
            if ($regIdx -lt 0 -and $ctx.State.OperationLog[$i] -like 'RegSet:*EnableSc7=0') { $regIdx = $i }
            if ($pnpIdx -lt 0 -and $ctx.State.OperationLog[$i] -like 'Pnputil:/add-driver*') { $pnpIdx = $i }
        }
        Assert-True ($regIdx -ge 0 -and $pnpIdx -gt $regIdx) 'EnableSc7=0 must occur before first pnputil'
        Assert-Equal 0 $ctx.State.Registry['hklm:\system\currentcontrolset\services\tegra214pep\parameters']['EnableSc7'] 'EnableSc7 remains 0 after failure'
    }

    # Test 3 & 4: Mid-install failure rolls back earlier drivers, returns 3017 preserving 3010 across retry, then clears on reboot
    Invoke-TestCase 'Mid-install failure rolls back drivers, preserves 3010 as 3017, and retry carries 3010 until reboot' {
        $dir = Join-Path $script:TempRoot 't3'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        $ctx.State['FailFan'] = $true
        $ctx.State.Hooks.OnAddDriver = {
            param($inf, $orig, $st, $stage, $bind)
            if ($orig -ieq 'tegra210gpio.inf') {
                $pkg = & $stage $inf
                $dev = @($st.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
                if ($dev.InfName -ne $pkg.PublishedName) {
                    & $bind $dev $pkg
                    return [ordered]@{ ExitCode = 3010; StdOut = "Published Name: $($pkg.PublishedName)"; StdErr = '' }
                }
                return [ordered]@{ ExitCode = 259; StdOut = "Published Name: $($pkg.PublishedName)"; StdErr = '' }
            }
            if ($st['FailFan'] -and $orig -ieq 'switchfan.inf') {
                return [ordered]@{ ExitCode = 1603; StdOut = ''; StdErr = 'fan failure' }
            }
            return $null
        }
        $jPath = Join-Path $dir 'journal.json'
        $res1 = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 3017 $res1.ExitCode 'failure with prior 3010 must return 3017'
        Assert-True $res1.RebootRequired 'RebootRequired preserved on failure'
        $gpioDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        Assert-Equal 'oem10.inf' $gpioDev.InfName 'tegra210gpio rolled back to prior oem10.inf'
        Assert-Equal '1.0.0.4' $gpioDev.DriverVersion 'tegra210gpio prior version restored'
        $i2cDevs = @($ctx.State.Devices | Where-Object { $_.HardwareIds -contains 'ACPI\NVDA0200' })
        foreach ($idv in $i2cDevs) {
            Assert-Equal 'oem11.inf' $idv.InfName "I2C bus $($idv.InstanceId) rolled back to oem11.inf"
        }
        Assert-True (@($ctx.State.Store | Where-Object { $_.PublishedName -eq 'oem41.inf' }).Count -eq 0) 'newly staged oem41.inf cleaned up'
        Assert-True (@($ctx.State.Store | Where-Object { $_.PublishedName -eq 'oem10.inf' }).Count -eq 1) 'prior oem10.inf preserved'

        # Retry in same boot session after fixing switchfan -> should succeed with 3010
        $ctx.State['FailFan'] = $false
        $ctx.State.Hooks.OnAddDriver = $null
        $res2 = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 3010 $res2.ExitCode 'retry in same boot carries forward 3010'
        Assert-True $res2.Success 'retry succeeded'

        # Simulate reboot (new BootId), re-run -> all 259 verified exact match -> exit 0, prior bindings preserved
        $ctx.State.BootId = 'BOOT-2'
        $res3 = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 0 $res3.ExitCode 'post-reboot idempotent retry returns 0'
        $j = Read-Sc7Journal -Path $jPath
        $gpioRec = @($j.Components | Where-Object { $_.Name -eq 'tegra210gpio' })[0]
        Assert-Equal 'oem10.inf' $gpioRec.DeviceBindings[0].PriorInf 'original prior oem10.inf preserved across retries'
    }

    # Test 5: Incremental -IncludePep re-run handles verified 259 and asserts EnableSc7=0
    Invoke-TestCase 'Incremental -IncludePep handles verified 259, installs PEP, and asserts EnableSc7=0' {
        $dir = Join-Path $script:TempRoot 't5'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        $jPath = Join-Path $dir 'journal.json'
        $r1 = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 0 $r1.ExitCode 'base install ok'
        Assert-True (-not $ctx.State.Registry.ContainsKey('hklm:\system\currentcontrolset\services\tegra214pep')) 'no orphan PEP service key without -IncludePep'

        $r2 = Invoke-Sc7InstallTransaction -PackageRoot $dir -IncludePep -JournalPath $jPath -Context $ctx
        Assert-Equal 0 $r2.ExitCode 'incremental -IncludePep ok'
        Assert-Equal 0 $ctx.State.Registry['hklm:\system\currentcontrolset\services\tegra214pep\parameters']['EnableSc7'] 'EnableSc7=0 asserted after PEP install'
        $pepDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\SWOA0E01\0' })[0]
        Assert-Equal '0.2.0.0' $pepDev.DriverVersion 'PEP bound to ACPI\SWOA0E01\0'
    }

    # Test 6: pnputil 259 rejected when staging-only (no matching device bound) and staged package cleaned up
    Invoke-TestCase 'pnputil 259 rejected for staging-only (no matching PEP device) without disturbing prior committed drivers' {
        $dir = Join-Path $script:TempRoot 't6'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs -NoPepDevice
        $jPath = Join-Path $dir 'journal.json'
        $r1 = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 0 $r1.ExitCode 'base install ok'
        $storeBefore = $ctx.State.Store.Count
        $r2 = Invoke-Sc7InstallTransaction -PackageRoot $dir -IncludePep -JournalPath $jPath -Context $ctx
        Assert-Equal 1 $r2.ExitCode 'staging-only 259 must fail'
        Assert-Equal $storeBefore $ctx.State.Store.Count 'newly staged unreferenced PEP package removed on rollback'
        $gpioDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        Assert-Equal '1.0.0.5' $gpioDev.DriverVersion 'previously committed base drivers untouched'
    }

    # Test 7: pnputil 259 rejected when matching device bound to newer/different package or same version with different hash
    Invoke-TestCase 'pnputil 259 rejected for newer bound tgd3d or same-version hash mismatch' {
        $dir = Join-Path $script:TempRoot 't7'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        # Make pre-existing tgd3d newer than candidate tegragpurender (1.0.0.9)
        $gpuDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0400\0' })[0]
        $gpuPkg = @($ctx.State.Store | Where-Object { $_.PublishedName -eq 'oem20.inf' })[0]
        $gpuDev.DriverVersion = '1.0.0.99'
        $gpuPkg.DriverVersion = '1.0.0.99'
        $jPath = Join-Path $dir 'journal.json'
        $r1 = Invoke-Sc7InstallTransaction -PackageRoot $dir -IncludeStandaloneGpuKmd -JournalPath $jPath -Context $ctx
        Assert-Equal 1 $r1.ExitCode '259 with newer tgd3d bound must fail'
        Assert-Equal 'oem20.inf' $gpuDev.InfName 'tgd3d binding untouched'
        Assert-True (@($ctx.State.Store | Where-Object { $_.OriginalName -ieq 'tegragpurender.inf' }).Count -eq 0) 'newly staged tegragpurender cleaned up'

        # Same version/date/OriginalName as candidate tegra210gpio but DIFFERENT payload hash
        $gpioDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        $gpioPkg = @($ctx.State.Store | Where-Object { $_.PublishedName -eq 'oem10.inf' })[0]
        $gpioDev.DriverVersion = '1.0.0.5'
        $gpioDev.DriverDate = '2026-03-15'
        $gpioPkg.DriverVersion = '1.0.0.5'
        $gpioPkg.DriverDate = '2026-03-15'
        $ctx.State.Hooks.OnAddDriver = {
            param($inf, $orig, $st, $stage, $bind)
            if ($orig -ieq 'tegra210gpio.inf') {
                return [ordered]@{ ExitCode = 259; StdOut = 'Published Name: oem10.inf'; StdErr = '' }
            }
            return $null
        }
        $r2 = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath (Join-Path $dir 'j2.json') -Context $ctx
        Assert-Equal 1 $r2.ExitCode 'same-version different-hash package must fail 259 verification'
    }

    # Test 8: pnputil exit 0 rejected if staging-only
    Invoke-TestCase 'pnputil exit 0 rejected if staging-only (zero bound devices)' {
        $dir = Join-Path $script:TempRoot 't8'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        $ctx.State.Hooks.OnAddDriver = {
            param($inf, $orig, $st, $stage, $bind)
            if ($orig -ieq 'tegra210gpio.inf') {
                $pkg = & $stage $inf
                return [ordered]@{ ExitCode = 0; StdOut = "Published Name: $($pkg.PublishedName)"; StdErr = '' }
            }
            return $null
        }
        $jPath = Join-Path $dir 'journal.json'
        $res = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 1 $res.ExitCode 'exit 0 with zero bound devices must fail'
        Assert-True (@($ctx.State.Store | Where-Object { $_.PublishedName -eq 'oem41.inf' }).Count -eq 0) 'staged package cleaned up'
    }

    # Test 9: Full Restore reverts all attributable drivers (including unbound PEP & standalone GPU), clears EnableSc7, and returns 3010 when EnableSc7Active=1
    Invoke-TestCase 'Full Restore reverts drivers in reverse order, clears EnableSc7, and returns 3010 when EnableSc7Active=1' {
        $dir = Join-Path $script:TempRoot 't9'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        $jPath = Join-Path $dir 'journal.json'
        $ins = Invoke-Sc7InstallTransaction -PackageRoot $dir -IncludePep -IncludeStandaloneGpuKmd -JournalPath $jPath -Context $ctx
        Assert-Equal 0 $ins.ExitCode 'full install ok'

        # Enable SC7 and simulate live EnableSc7Active=1
        $pepParamKey = 'hklm:\system\currentcontrolset\services\tegra214pep\parameters'
        $ctx.State.Registry[$pepParamKey]['EnableSc7'] = 1
        $ctx.State.Registry[$pepParamKey]['EnableSc7Active'] = 1

        $rst = Invoke-Sc7RestoreTransaction -JournalPath $jPath -Context $ctx
        Assert-Equal 3010 $rst.ExitCode 'restore must return 3010 while EnableSc7Active=1'
        Assert-True $rst.Success 'restore succeeded'
        Assert-True $rst.HadStandaloneGpuKmd 'detected standalone GPU KMD'
        Assert-Equal 0 $ctx.State.Registry[$pepParamKey]['EnableSc7'] 'EnableSc7 reset to 0'
        Assert-True ((@($ctx.State.Logs | Where-Object { $_ -like '*EnableSc7Active is still 1*' }).Count) -ge 1) 'explicitly warns EnableSc7Active is still 1'

        $gpuDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0400\0' })[0]
        Assert-Equal 'oem20.inf' $gpuDev.InfName 'GPU restored to tgd3d oem20.inf'
        $pepDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\SWOA0E01\0' })[0]
        Assert-True ([string]::IsNullOrWhiteSpace([string]$pepDev.InfName)) 'PEP returned to unbound state'
        $gpioDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        Assert-Equal 'oem10.inf' $gpioDev.InfName 'base driver restored to oem10.inf'
    }

    # Test 10: Restore preserves unrelated changes and NEVER deletes shared or pre-existing OEM packages
    Invoke-TestCase 'Restore preserves unrelated device updates and protects shared/pre-existing OEM packages' {
        # 10a: Unrelated later upgrade on tegra210gpio preserved
        $dirA = Join-Path $script:TempRoot 't10a'
        $specsA = New-MockPackageTree -RootDir $dirA
        $ctxA = New-MockSystem -PackageRoot $dirA -Specs $specsA
        $jA = Join-Path $dirA 'journal.json'
        $rA = Invoke-Sc7InstallTransaction -PackageRoot $dirA -JournalPath $jA -Context $ctxA
        Assert-Equal 0 $rA.ExitCode '10a install ok'
        $gpioA = @($ctxA.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        $gpioA.InfName = 'oem99.inf'
        $gpioA.DriverVersion = '2.0.0.0'
        $rstA = Invoke-Sc7RestoreTransaction -JournalPath $jA -Context $ctxA
        Assert-Equal 0 $rstA.ExitCode '10a restore ok'
        Assert-Equal 'oem99.inf' $gpioA.InfName 'unrelated manual upgrade preserved'

        # 10b: Shared OEM package with unrelated device + DiRollbackDriver available
        $dirB = Join-Path $script:TempRoot 't10b'
        $specsB = New-MockPackageTree -RootDir $dirB
        $ctxB = New-MockSystem -PackageRoot $dirB -Specs $specsB
        $jB = Join-Path $dirB 'journal.json'
        $rB = Invoke-Sc7InstallTransaction -PackageRoot $dirB -JournalPath $jB -Context $ctxB
        Assert-Equal 0 $rB.ExitCode '10b install ok'
        $gpioTargetOem = (@($ctxB.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]).InfName
        [void]$ctxB.State.Devices.Add([ordered]@{
            InstanceId    = 'ACPI\UNRELATED\0'
            Present       = $true
            InfName       = $gpioTargetOem
            DriverVersion = '1.0.0.5'
            DriverDate    = '2026-03-15'
            ProviderName  = 'SwitchWoA'
            HardwareIds   = @('ACPI\UNRELATED')
            CompatibleIds = @()
            RollbackStack = New-Object System.Collections.ArrayList
        })
        $rstB = Invoke-Sc7RestoreTransaction -JournalPath $jB -Context $ctxB
        Assert-Equal 0 $rstB.ExitCode '10b restore ok'
        $gpioB = @($ctxB.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        $unrelB = @($ctxB.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\UNRELATED\0' })[0]
        Assert-Equal 'oem10.inf' $gpioB.InfName 'attributable device rolled back'
        Assert-Equal $gpioTargetOem $unrelB.InfName 'unrelated device untouched'
        Assert-True (@($ctxB.State.Store | Where-Object { $_.PublishedName -eq $gpioTargetOem }).Count -eq 1) 'shared OEM package NOT deleted'

        # 10c: Shared OEM package + DiRollbackDriver unavailable -> must refuse uninstall and report incomplete
        $dirC = Join-Path $script:TempRoot 't10c'
        $specsC = New-MockPackageTree -RootDir $dirC
        $ctxC = New-MockSystem -PackageRoot $dirC -Specs $specsC
        $jC = Join-Path $dirC 'journal.json'
        $rC = Invoke-Sc7InstallTransaction -PackageRoot $dirC -JournalPath $jC -Context $ctxC
        Assert-Equal 0 $rC.ExitCode '10c install ok'
        $gpioTargetC = (@($ctxC.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]).InfName
        [void]$ctxC.State.Devices.Add([ordered]@{
            InstanceId    = 'ACPI\UNRELATED\0'
            Present       = $true
            InfName       = $gpioTargetC
            DriverVersion = '1.0.0.5'
            DriverDate    = '2026-03-15'
            ProviderName  = 'SwitchWoA'
            HardwareIds   = @('ACPI\UNRELATED')
            CompatibleIds = @()
            RollbackStack = New-Object System.Collections.ArrayList
        })
        $ctxC.State.Hooks.OnRollbackDevice = { return [ordered]@{ Supported = $true; ExitCode = 259; NeedReboot = $false; ErrorMessage = 'no rollback history' } }
        $rstC = Invoke-Sc7RestoreTransaction -JournalPath $jC -Context $ctxC
        Assert-Equal 1 $rstC.ExitCode '10c must fail honestly instead of deleting shared package'
        $unrelC = @($ctxC.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\UNRELATED\0' })[0]
        Assert-Equal $gpioTargetC $unrelC.InfName '10c unrelated device untouched'
        Assert-True (@($ctxC.State.Store | Where-Object { $_.PublishedName -eq $gpioTargetC }).Count -eq 1) '10c shared OEM package NOT deleted'

        # 10d: Pre-existing OEM package in Driver Store (StagedByTransaction=false) never deleted on restore
        $dirD = Join-Path $script:TempRoot 't10d'
        $specsD = New-MockPackageTree -RootDir $dirD
        $ctxD = New-MockSystem -PackageRoot $dirD -Specs $specsD
        $preStagedPkg = & $ctxD.StageHelper (Join-RelPath -BasePath $dirD -RelativePath 'drivers\tegra210gpio\tegra210gpio.inf')
        $jD = Join-Path $dirD 'journal.json'
        $rD = Invoke-Sc7InstallTransaction -PackageRoot $dirD -JournalPath $jD -Context $ctxD
        Assert-Equal 0 $rD.ExitCode '10d install ok'
        $rstD = Invoke-Sc7RestoreTransaction -JournalPath $jD -Context $ctxD
        Assert-Equal 0 $rstD.ExitCode '10d restore ok'
        Assert-True (@($ctxD.State.Store | Where-Object { $_.PublishedName -eq $preStagedPkg.PublishedName }).Count -eq 1) 'pre-existing OEM package preserved'
    }

    # Test 11: Pure pnputil fallback works when DiRollbackDriver returns 259, and guards against missing prior OEM package
    Invoke-TestCase 'Fallback pnputil rollback re-binds prior OEM and refuses if prior OEM missing from Driver Store' {
        # 11a: Fallback succeeds when prior OEM exists
        $dirA = Join-Path $script:TempRoot 't11a'
        $specsA = New-MockPackageTree -RootDir $dirA
        $ctxA = New-MockSystem -PackageRoot $dirA -Specs $specsA
        $jA = Join-Path $dirA 'journal.json'
        Assert-Equal 0 (Invoke-Sc7InstallTransaction -PackageRoot $dirA -JournalPath $jA -Context $ctxA).ExitCode '11a install ok'
        $ctxA.State.Hooks.OnRollbackDevice = { return [ordered]@{ Supported = $true; ExitCode = 259; NeedReboot = $false; ErrorMessage = 'no rollback history' } }
        $rstA = Invoke-Sc7RestoreTransaction -JournalPath $jA -Context $ctxA
        Assert-Equal 0 $rstA.ExitCode '11a fallback restore ok'
        $gpioA = @($ctxA.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        Assert-Equal 'oem10.inf' $gpioA.InfName '11a restored to oem10.inf via pnputil fallback'

        # 11b: Prior oem10.inf externally removed from Driver Store -> must refuse uninstall
        $dirB = Join-Path $script:TempRoot 't11b'
        $specsB = New-MockPackageTree -RootDir $dirB
        $ctxB = New-MockSystem -PackageRoot $dirB -Specs $specsB
        $jB = Join-Path $dirB 'journal.json'
        Assert-Equal 0 (Invoke-Sc7InstallTransaction -PackageRoot $dirB -JournalPath $jB -Context $ctxB).ExitCode '11b install ok'
        for ($i = $ctxB.State.Store.Count - 1; $i -ge 0; $i--) {
            if ($ctxB.State.Store[$i].PublishedName -eq 'oem10.inf') { $ctxB.State.Store.RemoveAt($i) }
        }
        $ctxB.State.Hooks.OnRollbackDevice = { return [ordered]@{ Supported = $true; ExitCode = 259; NeedReboot = $false; ErrorMessage = 'no rollback history' } }
        $rstB = Invoke-Sc7RestoreTransaction -JournalPath $jB -Context $ctxB
        Assert-Equal 1 $rstB.ExitCode '11b must refuse uninstall when prior OEM missing'
        $gpioB = @($ctxB.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$gpioB.InfName)) '11b device not left driverless'
    }

    # Test 12: Restore with missing PEP key & no journal reports honestly without fabricating Services\tegra214pep
    Invoke-TestCase 'Restore with absent PEP key and no journal avoids creating orphan key and reports honestly' {
        $dir = Join-Path $script:TempRoot 't12'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        $rst = Invoke-Sc7RestoreTransaction -JournalPath (Join-Path $dir 'missing.json') -Context $ctx
        Assert-Equal 0 $rst.ExitCode 'exit 0 when no gate active and no journal'
        Assert-True (-not $rst.JournalFound) 'JournalFound should be false'
        Assert-True (-not $ctx.State.Registry.ContainsKey('hklm:\system\currentcontrolset\services\tegra214pep')) 'must not fabricate orphan service key'
        Assert-True ((@($ctx.State.Logs | Where-Object { $_ -like '*not present*' }).Count) -ge 1) 'logs honest absent key message'
    }

    # Test 13: Crash recovery from interrupted Installing journal entry + refusal on corrupt JSON
    Invoke-TestCase 'Recovers interrupted Installing journal entry and refuses corrupt journal' {
        $dir = Join-Path $script:TempRoot 't13'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        $jPath = Join-Path $dir 'journal.json'

        # Simulate mid-pnputil crash: tegra210gpio was staged & bound after Installing WAL written
        $gpioInf = Join-RelPath -BasePath $dir -RelativePath 'drivers\tegra210gpio\tegra210gpio.inf'
        $meta = Read-Sc7InfMetadata -InfPath $gpioInf
        $preStoreNames = @($ctx.State.Store | ForEach-Object { $_.PublishedName })
        $gpioPkg = & $ctx.StageHelper $gpioInf
        $gpioDev = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        $priorStoreInf = (@($ctx.State.Store | Where-Object { $_.PublishedName -eq 'oem10.inf' })[0]).DriverStoreInfPath
        & $ctx.BindHelper $gpioDev $gpioPkg
        $crashedJournal = [ordered]@{
            SchemaVersion       = 1
            TransactionId       = 'crash-test'
            CreatedUtc          = '2026-11-18T00:00:00Z'
            UpdatedUtc          = '2026-11-18T00:00:00Z'
            State               = 'InProgress'
            PackageRoot         = $dir
            RebootRequired      = $false
            PendingRebootBootId = $null
            Sc7Gate             = [ordered]@{ Recorded = $false }
            Components          = @(
                [ordered]@{
                    Name                   = 'tegra210gpio'
                    RelativeInfPath        = 'drivers\tegra210gpio\tegra210gpio.inf'
                    OriginalName           = 'tegra210gpio.inf'
                    DriverVersion          = $meta.DriverVersion
                    DriverDate             = $meta.DriverDate
                    ProviderName           = $meta.ProviderName
                    InfSha256              = $meta.InfSha256
                    HardwareIds            = @($meta.HardwareIds)
                    Status                 = 'Installing'
                    InstallOrder           = 1
                    LastPnputilExitCode    = $null
                    RebootRequired         = $false
                    PreStorePublishedNames = $preStoreNames
                    TargetPublishedName    = $null
                    StagedByTransaction    = $false
                    StagedPackages         = @()
                    DeviceBindings         = @(
                        [ordered]@{
                            InstanceId              = 'ACPI\NVDA0108\0'
                            PriorInf                = 'oem10.inf'
                            PriorVersion            = '1.0.0.4'
                            PriorDate               = '2026-01-10'
                            PriorProvider           = 'SwitchWoA'
                            PriorDriverStoreInfPath = $priorStoreInf
                            PriorIsInbox            = $false
                            TargetPublishedName     = $null
                            TargetVersion           = $null
                            AttributedToTransaction = $false
                            RestoreState            = 'Pending'
                            RestoreNote             = ''
                        }
                    )
                    LastError              = $null
                }
            )
        }
        Save-Sc7Journal -Journal $crashedJournal -Path $jPath
        $rst = Invoke-Sc7RestoreTransaction -JournalPath $jPath -Context $ctx
        Assert-Equal 0 $rst.ExitCode 'crash recovery restore succeeded'
        Assert-Equal 'oem10.inf' $gpioDev.InfName 'crashed component reverted to oem10.inf'
        Assert-True (@($ctx.State.Store | Where-Object { $_.PublishedName -eq $gpioPkg.PublishedName }).Count -eq 0) 'crashed newly-staged package deleted'

        # Corrupt JSON must fail loudly
        [System.IO.File]::WriteAllText($jPath, '{corrupt json', (New-Object System.Text.UTF8Encoding($false)))
        $corruptIns = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 1 $corruptIns.ExitCode 'install refuses corrupt journal'
        $corruptRst = Invoke-Sc7RestoreTransaction -JournalPath $jPath -Context $ctx
        Assert-Equal 1 $corruptRst.ExitCode 'restore refuses corrupt journal'
    }

    # Test 14: Existing Services\tegra214pep key without Parameters subkey creates Parameters and writes EnableSc7=0
    Invoke-TestCase 'Existing PEP service key without Parameters subkey gets Parameters\EnableSc7=0' {
        $dir = Join-Path $script:TempRoot 't14'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs -WithPepServiceKey
        $rst = Invoke-Sc7RestoreTransaction -JournalPath (Join-Path $dir 'none.json') -Context $ctx
        Assert-Equal 0 $rst.ExitCode 'restore ok'
        Assert-True $ctx.State.Registry.ContainsKey('hklm:\system\currentcontrolset\services\tegra214pep\parameters') 'Parameters subkey created under existing service key'
        Assert-Equal 0 $ctx.State.Registry['hklm:\system\currentcontrolset\services\tegra214pep\parameters']['EnableSc7'] 'EnableSc7=0 persisted'
    }

    # Test 15: -NoRollbackOnFailure preserves partial installs, 3010->3017, retry via 259, and full restore
    Invoke-TestCase 'NoRollbackOnFailure preserves prior OEM/3010 across retry and full restore' {
        $dir = Join-Path $script:TempRoot 't15'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        $ctx.State['FailI2c'] = $true
        $ctx.State.Hooks.OnAddDriver = {
            param($inf, $orig, $st, $stage, $bind)
            if ($orig -ieq 'tegra210gpio.inf') {
                $pkg = & $stage $inf
                $dev = @($st.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
                if ($dev.InfName -ne $pkg.PublishedName) {
                    & $bind $dev $pkg
                    return [ordered]@{ ExitCode = 3010; StdOut = "Published Name: $($pkg.PublishedName)"; StdErr = '' }
                }
                return [ordered]@{ ExitCode = 259; StdOut = "Published Name: $($pkg.PublishedName)"; StdErr = '' }
            }
            if ($st['FailI2c'] -and $orig -ieq 'tegra210i2c.inf') {
                return [ordered]@{ ExitCode = 5; StdOut = ''; StdErr = 'access denied' }
            }
            return $null
        }
        $jPath = Join-Path $dir 'journal.json'
        $r1 = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -NoRollbackOnFailure -Context $ctx
        Assert-Equal 3017 $r1.ExitCode 'NoRollbackOnFailure with prior 3010 returns 3017'
        $gpio = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0108\0' })[0]
        Assert-Equal '1.0.0.5' $gpio.DriverVersion 'tegra210gpio kept installed when -NoRollbackOnFailure set'
        Assert-True (Test-Path -LiteralPath "$jPath.bak" -PathType Leaf) 'atomic journal replacement created .bak backup'

        # Retry after fixing tegra210i2c -> tegra210gpio returns 259, preserves prior oem10.inf and carries 3010
        $ctx.State['FailI2c'] = $false
        $r2 = Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx
        Assert-Equal 3010 $r2.ExitCode 'retry completes with carried 3010'
        $j = Read-Sc7Journal -Path $jPath
        $gpioRec = @($j.Components | Where-Object { $_.Name -eq 'tegra210gpio' })[0]
        Assert-Equal 'oem10.inf' $gpioRec.DeviceBindings[0].PriorInf 'prior oem10.inf preserved through NoRollbackOnFailure retry'

        # Full restore reverts all 10 including tegra210gpio back to oem10.inf
        $rst = Invoke-Sc7RestoreTransaction -JournalPath $jPath -Context $ctx
        Assert-Equal 3010 $rst.ExitCode 'same-boot restore carries 3010'
        Assert-Equal 'oem10.inf' $gpio.InfName 'tegra210gpio reverted to oem10.inf'
        Assert-Equal '1.0.0.4' $gpio.DriverVersion 'tegra210gpio reverted to 1.0.0.4'
    }

    # Test 16: Multi-instance tegra210i2c (6 buses) partial unrelated update preserved while other 5 buses revert cleanly
    Invoke-TestCase 'Multi-instance tegra210i2c reverts 5 attributable buses while preserving 1 manually updated bus' {
        $dir = Join-Path $script:TempRoot 't16'
        $specs = New-MockPackageTree -RootDir $dir
        $ctx = New-MockSystem -PackageRoot $dir -Specs $specs
        $jPath = Join-Path $dir 'journal.json'
        Assert-Equal 0 (Invoke-Sc7InstallTransaction -PackageRoot $dir -JournalPath $jPath -Context $ctx).ExitCode 'install ok'
        $bus5 = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq 'ACPI\NVDA0200\5' })[0]
        $i2cCandOem = $bus5.InfName
        $bus5.InfName = 'oem88.inf'
        $bus5.DriverVersion = '2.0.0.0'

        $rst = Invoke-Sc7RestoreTransaction -JournalPath $jPath -Context $ctx
        Assert-Equal 0 $rst.ExitCode 'restore succeeded preserving bus 5'
        for ($b = 0; $b -lt 5; $b++) {
            $devB = @($ctx.State.Devices | Where-Object { $_.InstanceId -eq "ACPI\NVDA0200\$b" })[0]
            Assert-Equal 'oem11.inf' $devB.InfName "I2C bus $b reverted to oem11.inf"
        }
        Assert-Equal 'oem88.inf' $bus5.InfName 'I2C bus 5 unrelated upgrade preserved'
        Assert-True (@($ctx.State.Store | Where-Object { $_.PublishedName -eq $i2cCandOem }).Count -eq 0) 'unused candidate I2C OEM package cleaned up'
    }
} finally {
    if (Test-Path -LiteralPath $script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ("Test summary: {0} passed, {1} failed." -f $script:PassedTests, $script:FailedTests)
if ($script:FailedTests -gt 0) {
    exit 1
}
exit 0
