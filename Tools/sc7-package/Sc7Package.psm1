Set-StrictMode -Version Latest

$script:Sc7PepServiceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\tegra214pep'
$script:Sc7PepParametersKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\tegra214pep\Parameters'
$script:DefaultBaseDrivers = @(
    'tegra210gpio',
    'tegra210i2c',
    'switchfan',
    'switchbattery',
    'switchpwrbtn',
    'switchrtc',
    'switchtouch',
    'switchsio',
    'switchbt',
    'tegraxusb'
)

$script:SC7_EXIT_OK = 0
$script:SC7_EXIT_ERROR = 1
$script:SC7_EXIT_REBOOT_REQUIRED = 3010
$script:SC7_EXIT_FAIL_REBOOT_REQUIRED = 3017

function Join-Sc7RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )
    $result = $BasePath
    foreach ($seg in @($RelativePath -split '[\\/]')) {
        if (-not [string]::IsNullOrWhiteSpace($seg)) {
            $result = Join-Path $result $seg
        }
    }
    return $result
}

function Get-Sc7Prop {
    param(
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        foreach ($k in $Object.Keys) {
            if ([string]::Equals([string]$k, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Object[$k]
            }
        }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        return $prop.Value
    }
    return $Default
}

function Test-Sc7NameInList {
    param(
        $List,
        [string]$Value
    )
    if ($null -eq $List -or [string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    foreach ($item in @($List)) {
        if ($null -ne $item -and [string]::Equals([string]$item, $Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Add-Sc7UniqueString {
    param(
        $List,
        [string]$Value
    )
    $out = New-Object System.Collections.ArrayList
    if ($null -ne $List) {
        foreach ($item in @($List)) {
            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item)) {
                if (-not (Test-Sc7NameInList -List $out -Value ([string]$item))) {
                    [void]$out.Add([string]$item)
                }
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        if (-not (Test-Sc7NameInList -List $out -Value $Value)) {
            [void]$out.Add($Value)
        }
    }
    return ,($out.ToArray())
}

function Remove-Sc7StringFromList {
    param(
        $List,
        [string]$Value
    )
    $out = New-Object System.Collections.ArrayList
    if ($null -ne $List) {
        foreach ($item in @($List)) {
            if ($null -ne $item -and -not [string]::Equals([string]$item, $Value, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$out.Add([string]$item)
            }
        }
    }
    return ,($out.ToArray())
}

function ConvertTo-Sc7MutableData {
    param($Value)
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $Value.Keys) {
            $out[[string]$k] = ConvertTo-Sc7MutableData -Value $Value[$k]
        }
        return $out
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) {
            $out[$p.Name] = ConvertTo-Sc7MutableData -Value $p.Value
        }
        return $out
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $arr = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$arr.Add((ConvertTo-Sc7MutableData -Value $item))
        }
        return ,($arr.ToArray())
    }
    return $Value
}

function ConvertTo-Sc7NormalizedVersion {
    param($Version)
    if ($null -eq $Version) {
        return $null
    }
    $s = ([string]$Version).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) {
        return $null
    }
    $parts = @($s.Split('.'))
    if ($parts.Count -lt 1 -or $parts.Count -gt 4) {
        return $null
    }
    $nums = New-Object System.Collections.ArrayList
    foreach ($p in $parts) {
        $trimmed = $p.Trim()
        if ($trimmed -notmatch '^\d+$') {
            return $null
        }
        try {
            [void]$nums.Add(([uint64]$trimmed).ToString([System.Globalization.CultureInfo]::InvariantCulture))
        } catch {
            return $null
        }
    }
    while ($nums.Count -lt 4) {
        [void]$nums.Add('0')
    }
    return ($nums.ToArray() -join '.')
}

function ConvertTo-Sc7NormalizedDate {
    param($Value)
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [DateTime]) {
        return $Value.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) {
        return $null
    }
    if ($s -match '^(\d{4})-(\d{1,2})-(\d{1,2})(?:$|T|\s)') {
        try {
            $dt = New-Object System.DateTime([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
            return $dt.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return $null
        }
    }
    if ($s -match '^(\d{1,2})/(\d{1,2})/(\d{4})$') {
        try {
            $dt = New-Object System.DateTime([int]$Matches[3], [int]$Matches[1], [int]$Matches[2])
            return $dt.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return $null
        }
    }
    if ($s -match '^(\d{4})(\d{2})(\d{2})\d{6}\.') {
        try {
            $dt = New-Object System.DateTime([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
            return $dt.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return $null
        }
    }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

function Get-Sc7FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hashBytes = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToUpperInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Strip-Sc7InfComment {
    param([string]$Line)
    if ([string]::IsNullOrEmpty($Line)) {
        return ''
    }
    $inQuotes = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($ch -eq '"') {
            $inQuotes = -not $inQuotes
        } elseif ($ch -eq ';' -and -not $inQuotes) {
            return $Line.Substring(0, $i).Trim()
        }
    }
    return $Line.Trim()
}

function Split-Sc7InfCsv {
    param([string]$Text)
    $fields = New-Object System.Collections.ArrayList
    if ($null -eq $Text) {
        return ,($fields.ToArray())
    }
    $sb = New-Object System.Text.StringBuilder
    $inQuotes = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '"') {
            $inQuotes = -not $inQuotes
            [void]$sb.Append($ch)
        } elseif ($ch -eq ',' -and -not $inQuotes) {
            [void]$fields.Add($sb.ToString().Trim())
            [void]$sb.Clear()
        } else {
            [void]$sb.Append($ch)
        }
    }
    [void]$fields.Add($sb.ToString().Trim())
    return ,($fields.ToArray())
}

function Unquote-Sc7InfValue {
    param([string]$Value)
    if ($null -eq $Value) {
        return ''
    }
    $s = $Value.Trim()
    if ($s.Length -ge 2 -and $s.StartsWith('"') -and $s.EndsWith('"')) {
        $s = $s.Substring(1, $s.Length - 2).Replace('""', '"')
    }
    return $s.Trim()
}

function Resolve-Sc7InfStrings {
    param(
        [string]$Text,
        [hashtable]$StringMap
    )
    if ([string]::IsNullOrEmpty($Text) -or $null -eq $StringMap -or $StringMap.Count -eq 0) {
        return $Text
    }
    $result = $Text
    $regexMatches = [regex]::Matches($Text, '%([^%]+)%')
    foreach ($m in $regexMatches) {
        $key = $m.Groups[1].Value.Trim().ToLowerInvariant()
        if ($StringMap.ContainsKey($key)) {
            $result = $result.Replace($m.Value, $StringMap[$key])
        }
    }
    return $result
}

function Read-Sc7InfMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InfPath,
        [switch]$SkipPayloadCheck,
        [switch]$SkipHash
    )

    $parseErrors = New-Object System.Collections.ArrayList
    $missingFiles = New-Object System.Collections.ArrayList
    $origName = [System.IO.Path]::GetFileName($InfPath)

    if (-not (Test-Path -LiteralPath $InfPath -PathType Leaf)) {
        [void]$missingFiles.Add($InfPath)
        return [ordered]@{
            InfPath       = $InfPath
            OriginalName  = $origName
            DriverVersion = $null
            DriverDate    = $null
            ProviderName  = $null
            ClassName     = $null
            CatalogFile   = $null
            PayloadFiles  = @()
            HardwareIds   = @()
            CompatibleIds = @()
            InfSha256     = $null
            FileHashes    = [ordered]@{}
            MissingFiles  = @($missingFiles.ToArray())
            ParseErrors   = @($parseErrors.ToArray())
            IsValid       = $false
        }
    }

    $rawLines = [System.IO.File]::ReadAllLines($InfPath)
    $logicalLines = New-Object System.Collections.ArrayList
    $buffer = ''
    foreach ($raw in $rawLines) {
        $clean = Strip-Sc7InfComment -Line $raw
        if ([string]::IsNullOrWhiteSpace($clean)) {
            if (-not [string]::IsNullOrWhiteSpace($buffer)) {
                [void]$logicalLines.Add($buffer.Trim())
                $buffer = ''
            }
            continue
        }
        if ($clean.EndsWith('\')) {
            $buffer += $clean.Substring(0, $clean.Length - 1)
        } else {
            $buffer += $clean
            [void]$logicalLines.Add($buffer.Trim())
            $buffer = ''
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($buffer)) {
        [void]$logicalLines.Add($buffer.Trim())
    }

    $sections = @{}
    $currentSection = $null
    foreach ($line in $logicalLines) {
        if ($line -match '^\[([^\]]+)\]$') {
            $currentSection = $Matches[1].Trim().ToLowerInvariant()
            if (-not $sections.ContainsKey($currentSection)) {
                $sections[$currentSection] = New-Object System.Collections.ArrayList
            }
            continue
        }
        if ($null -ne $currentSection) {
            [void]$sections[$currentSection].Add($line)
        }
    }

    # Parse [Strings] and [Strings.0409]
    $stringMap = @{}
    foreach ($strSec in @('strings', 'strings.0409')) {
        if ($sections.ContainsKey($strSec)) {
            foreach ($line in $sections[$strSec]) {
                $eq = $line.IndexOf('=')
                if ($eq -gt 0) {
                    $k = $line.Substring(0, $eq).Trim().ToLowerInvariant()
                    $v = Unquote-Sc7InfValue -Value ($line.Substring($eq + 1))
                    $stringMap[$k] = $v
                }
            }
        }
    }

    # Parse [Version]
    $versionKv = @{}
    if (-not $sections.ContainsKey('version')) {
        [void]$parseErrors.Add("Missing [Version] section in $InfPath")
    } else {
        foreach ($line in $sections['version']) {
            $eq = $line.IndexOf('=')
            if ($eq -gt 0) {
                $k = $line.Substring(0, $eq).Trim().ToLowerInvariant()
                $v = $line.Substring($eq + 1).Trim()
                $versionKv[$k] = $v
            }
        }
    }

    $driverDate = $null
    $driverVersion = $null
    if ($versionKv.ContainsKey('driverver')) {
        $dvParts = Split-Sc7InfCsv -Text (Resolve-Sc7InfStrings -Text $versionKv['driverver'] -StringMap $stringMap)
        if ($dvParts.Count -ge 2) {
            $driverDate = ConvertTo-Sc7NormalizedDate -Value (Unquote-Sc7InfValue -Value $dvParts[0])
            $driverVersion = ConvertTo-Sc7NormalizedVersion -Version (Unquote-Sc7InfValue -Value $dvParts[1])
        }
    }
    if ($null -eq $driverDate -or $null -eq $driverVersion) {
        [void]$parseErrors.Add("Missing or invalid DriverVer in $InfPath")
    }

    $providerName = $null
    if ($versionKv.ContainsKey('provider')) {
        $providerName = Unquote-Sc7InfValue -Value (Resolve-Sc7InfStrings -Text $versionKv['provider'] -StringMap $stringMap)
    }

    $className = $null
    if ($versionKv.ContainsKey('class')) {
        $className = Unquote-Sc7InfValue -Value (Resolve-Sc7InfStrings -Text $versionKv['class'] -StringMap $stringMap)
    }

    $catalogFile = $null
    foreach ($catKey in @('catalogfile.ntarm64', 'catalogfile.nt', 'catalogfile')) {
        if ($versionKv.ContainsKey($catKey)) {
            $candCat = Unquote-Sc7InfValue -Value (Resolve-Sc7InfStrings -Text $versionKv[$catKey] -StringMap $stringMap)
            if (-not [string]::IsNullOrWhiteSpace($candCat)) {
                $catalogFile = $candCat
                break
            }
        }
    }

    # Parse [SourceDisksNames] and [SourceDisksFiles]
    $diskPaths = @{}
    foreach ($sdnSec in @('sourcedisksnames', 'sourcedisksnames.arm64', 'sourcedisksnames.ntarm64')) {
        if ($sections.ContainsKey($sdnSec)) {
            foreach ($line in $sections[$sdnSec]) {
                $eq = $line.IndexOf('=')
                if ($eq -gt 0) {
                    $diskId = $line.Substring(0, $eq).Trim().ToLowerInvariant()
                    $rhsFields = Split-Sc7InfCsv -Text (Resolve-Sc7InfStrings -Text ($line.Substring($eq + 1)) -StringMap $stringMap)
                    $relDir = ''
                    if ($rhsFields.Count -ge 4) {
                        $relDir = (Unquote-Sc7InfValue -Value $rhsFields[3]).Trim('\', '/')
                    }
                    $diskPaths[$diskId] = $relDir
                }
            }
        }
    }

    $payloadList = New-Object System.Collections.ArrayList
    foreach ($sdfSec in @('sourcedisksfiles', 'sourcedisksfiles.arm64', 'sourcedisksfiles.ntarm64')) {
        if ($sections.ContainsKey($sdfSec)) {
            foreach ($line in $sections[$sdfSec]) {
                $eq = $line.IndexOf('=')
                if ($eq -gt 0) {
                    $fileName = Unquote-Sc7InfValue -Value (Resolve-Sc7InfStrings -Text ($line.Substring(0, $eq)) -StringMap $stringMap)
                    if ([string]::IsNullOrWhiteSpace($fileName)) {
                        continue
                    }
                    $rhsFields = Split-Sc7InfCsv -Text (Resolve-Sc7InfStrings -Text ($line.Substring($eq + 1)) -StringMap $stringMap)
                    $diskId = if ($rhsFields.Count -ge 1) { (Unquote-Sc7InfValue -Value $rhsFields[0]).ToLowerInvariant() } else { '' }
                    $subDir = if ($rhsFields.Count -ge 2) { (Unquote-Sc7InfValue -Value $rhsFields[1]).Trim('\', '/') } else { '' }
                    $diskDir = if ($diskPaths.ContainsKey($diskId)) { $diskPaths[$diskId] } else { '' }
                    $parts = New-Object System.Collections.ArrayList
                    if (-not [string]::IsNullOrWhiteSpace($diskDir)) { [void]$parts.Add($diskDir) }
                    if (-not [string]::IsNullOrWhiteSpace($subDir)) { [void]$parts.Add($subDir) }
                    [void]$parts.Add($fileName.Trim('\', '/'))
                    $relPayload = ($parts.ToArray() -join '\')
                    if (-not (Test-Sc7NameInList -List $payloadList -Value $relPayload)) {
                        [void]$payloadList.Add($relPayload)
                    }
                }
            }
        }
    }

    # Parse [Manufacturer] and target Models sections for HardwareIds / CompatibleIds
    $hardwareIds = New-Object System.Collections.ArrayList
    $compatibleIds = New-Object System.Collections.ArrayList
    if ($sections.ContainsKey('manufacturer')) {
        $modelSections = New-Object System.Collections.ArrayList
        foreach ($line in $sections['manufacturer']) {
            $eq = $line.IndexOf('=')
            if ($eq -le 0) { continue }
            $rhsFields = Split-Sc7InfCsv -Text (Resolve-Sc7InfStrings -Text ($line.Substring($eq + 1)) -StringMap $stringMap)
            if ($rhsFields.Count -lt 1) { continue }
            $baseSec = (Unquote-Sc7InfValue -Value $rhsFields[0]).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($baseSec)) { continue }
            if ($rhsFields.Count -eq 1) {
                if (-not (Test-Sc7NameInList -List $modelSections -Value $baseSec)) {
                    [void]$modelSections.Add($baseSec)
                }
            } else {
                $arm64Decs = New-Object System.Collections.ArrayList
                $ntDecs = New-Object System.Collections.ArrayList
                for ($i = 1; $i -lt $rhsFields.Count; $i++) {
                    $dec = (Unquote-Sc7InfValue -Value $rhsFields[$i]).ToLowerInvariant()
                    if ([string]::IsNullOrWhiteSpace($dec)) { continue }
                    if ($dec -like 'ntarm64*') {
                        [void]$arm64Decs.Add($dec)
                    } elseif (($dec -eq 'nt' -or $dec -like 'nt.*') -and ($dec -notlike 'ntx86*') -and ($dec -notlike 'ntamd64*') -and ($dec -notlike 'ntia64*')) {
                        [void]$ntDecs.Add($dec)
                    }
                }
                if ($arm64Decs.Count -gt 0) {
                    $chosenDecs = @($arm64Decs.ToArray())
                } else {
                    $chosenDecs = @($ntDecs.ToArray())
                }
                if ($chosenDecs.Count -gt 0) {
                    foreach ($dec in $chosenDecs) {
                        $secName = "$baseSec.$dec"
                        if ($sections.ContainsKey($secName)) {
                            if (-not (Test-Sc7NameInList -List $modelSections -Value $secName)) {
                                [void]$modelSections.Add($secName)
                            }
                        } elseif ($sections.ContainsKey($baseSec)) {
                            if (-not (Test-Sc7NameInList -List $modelSections -Value $baseSec)) {
                                [void]$modelSections.Add($baseSec)
                            }
                        }
                    }
                } elseif ($sections.ContainsKey($baseSec)) {
                    if (-not (Test-Sc7NameInList -List $modelSections -Value $baseSec)) {
                        [void]$modelSections.Add($baseSec)
                    }
                }
            }
        }

        foreach ($mSec in $modelSections) {
            if (-not $sections.ContainsKey($mSec)) { continue }
            foreach ($line in $sections[$mSec]) {
                $eq = $line.IndexOf('=')
                if ($eq -le 0) { continue }
                $rhsFields = Split-Sc7InfCsv -Text (Resolve-Sc7InfStrings -Text ($line.Substring($eq + 1)) -StringMap $stringMap)
                if ($rhsFields.Count -ge 2) {
                    $hwid = (Unquote-Sc7InfValue -Value $rhsFields[1]).ToUpperInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($hwid) -and -not (Test-Sc7NameInList -List $hardwareIds -Value $hwid)) {
                        [void]$hardwareIds.Add($hwid)
                    }
                }
                if ($rhsFields.Count -ge 3) {
                    for ($j = 2; $j -lt $rhsFields.Count; $j++) {
                        $cid = (Unquote-Sc7InfValue -Value $rhsFields[$j]).ToUpperInvariant()
                        if (-not [string]::IsNullOrWhiteSpace($cid) -and -not (Test-Sc7NameInList -List $compatibleIds -Value $cid)) {
                            [void]$compatibleIds.Add($cid)
                        }
                    }
                }
            }
        }
    }

    $infDir = Split-Path -Parent $InfPath
    $fileHashes = [ordered]@{}
    $infSha256 = $null
    if (-not $SkipHash) {
        $infSha256 = Get-Sc7FileSha256 -Path $InfPath
        $fileHashes[$origName.ToLowerInvariant()] = $infSha256
    }

    if (-not $SkipPayloadCheck) {
        if (-not [string]::IsNullOrWhiteSpace($catalogFile)) {
            $catRel = $catalogFile.Trim('\', '/')
            $catFull = Join-Sc7RelativePath -BasePath $infDir -RelativePath $catRel
            if (-not (Test-Path -LiteralPath $catFull -PathType Leaf)) {
                [void]$missingFiles.Add($catFull)
            } elseif (-not $SkipHash) {
                $fileHashes[$catRel.ToLowerInvariant()] = Get-Sc7FileSha256 -Path $catFull
            }
        }
        foreach ($relPayload in $payloadList) {
            $payloadFull = Join-Sc7RelativePath -BasePath $infDir -RelativePath $relPayload
            if (-not (Test-Path -LiteralPath $payloadFull -PathType Leaf)) {
                [void]$missingFiles.Add($payloadFull)
            } elseif (-not $SkipHash) {
                $fileHashes[$relPayload.ToLowerInvariant()] = Get-Sc7FileSha256 -Path $payloadFull
            }
        }
    }

    return [ordered]@{
        InfPath       = $InfPath
        OriginalName  = $origName
        DriverVersion = $driverVersion
        DriverDate    = $driverDate
        ProviderName  = $providerName
        ClassName     = $className
        CatalogFile   = $catalogFile
        PayloadFiles  = @($payloadList.ToArray())
        HardwareIds   = @($hardwareIds.ToArray())
        CompatibleIds = @($compatibleIds.ToArray())
        InfSha256     = $infSha256
        FileHashes    = $fileHashes
        MissingFiles  = @($missingFiles.ToArray())
        ParseErrors   = @($parseErrors.ToArray())
        IsValid       = (($parseErrors.Count -eq 0) -and ($missingFiles.Count -eq 0))
    }
}

function Get-Sc7SelectedComponents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot,
        [switch]$IncludePep,
        [switch]$IncludeStandaloneGpuKmd
    )
    $components = New-Object System.Collections.ArrayList
    $drivers = @($script:DefaultBaseDrivers)
    if ($IncludePep) {
        $drivers += 'tegra214pep'
    }
    foreach ($name in $drivers) {
        $relInf = "drivers\$name\$name.inf"
        [void]$components.Add([ordered]@{
            Name            = $name
            RelativeInfPath = $relInf
            InfPath         = Join-Sc7RelativePath -BasePath $PackageRoot -RelativePath $relInf
            IsGpuKmd        = $false
        })
    }
    if ($IncludeStandaloneGpuKmd) {
        $gpuRel = 'gpu\tegragpurender\tegragpurender.inf'
        [void]$components.Add([ordered]@{
            Name            = 'tegragpurender'
            RelativeInfPath = $gpuRel
            InfPath         = Join-Sc7RelativePath -BasePath $PackageRoot -RelativePath $gpuRel
            IsGpuKmd        = $true
        })
    }
    return $components.ToArray()
}

function Test-Sc7Preflight {
    param(
        [Parameter(Mandatory = $true)]
        $Components
    )
    $errors = New-Object System.Collections.ArrayList
    $validated = New-Object System.Collections.ArrayList

    foreach ($comp in @($Components)) {
        $infPath = Get-Sc7Prop $comp 'InfPath'
        $name = Get-Sc7Prop $comp 'Name'
        if (-not (Test-Path -LiteralPath $infPath -PathType Leaf)) {
            [void]$errors.Add("Missing INF for $($name): $infPath")
            continue
        }
        $meta = Read-Sc7InfMetadata -InfPath $infPath
        foreach ($mf in @($meta['MissingFiles'])) {
            [void]$errors.Add("Missing referenced file for $($name): $mf")
        }
        foreach ($pe in @($meta['ParseErrors'])) {
            [void]$errors.Add("INF validation error for $($name): $pe")
        }
        $entry = [ordered]@{
            Name            = $name
            RelativeInfPath = Get-Sc7Prop $comp 'RelativeInfPath'
            InfPath         = $infPath
            IsGpuKmd        = [bool](Get-Sc7Prop $comp 'IsGpuKmd' $false)
            OriginalName    = $meta['OriginalName']
            DriverVersion   = $meta['DriverVersion']
            DriverDate      = $meta['DriverDate']
            ProviderName    = $meta['ProviderName']
            ClassName       = $meta['ClassName']
            CatalogFile     = $meta['CatalogFile']
            PayloadFiles    = @($meta['PayloadFiles'])
            HardwareIds     = @($meta['HardwareIds'])
            CompatibleIds   = @($meta['CompatibleIds'])
            InfSha256       = $meta['InfSha256']
            FileHashes      = $meta['FileHashes']
        }
        [void]$validated.Add($entry)
    }

    return [ordered]@{
        Passed     = ($errors.Count -eq 0)
        Errors     = @($errors.ToArray())
        Components = @($validated.ToArray())
    }
}

function Get-Sc7DefaultJournalPath {
    $base = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = [System.IO.Path]::GetTempPath()
    }
    return Join-Path (Join-Path (Join-Path $base 'SwitchWoA') 'Sc7Package') 'transaction-journal.json'
}

function Read-Sc7Journal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $raw = [System.IO.File]::ReadAllText($Path, $utf8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'Journal file is empty.'
        }
        $parsed = $raw | ConvertFrom-Json
        $data = ConvertTo-Sc7MutableData -Value $parsed
        if (-not ($data -is [System.Collections.IDictionary]) -or $null -eq (Get-Sc7Prop $data 'SchemaVersion') -or $null -eq (Get-Sc7Prop $data 'Components')) {
            throw 'Journal JSON is missing required SchemaVersion or Components fields.'
        }
        return $data
    } catch {
        throw "SC7 transaction journal '$Path' is unreadable or corrupted ($($_.Exception.Message)). Refusing to discard rollback metadata; inspect '$Path' and backup '$Path.bak'."
    }
}

function Save-Sc7Journal {
    param(
        [Parameter(Mandatory = $true)]
        $Journal,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Journal['UpdatedUtc'] = [DateTime]::UtcNow.ToString('o')
    $json = $Journal | ConvertTo-Json -Depth 12
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'Failed to serialize SC7 transaction journal.'
    }
    $tmpPath = "{0}.tmp.{1}.{2}" -f $Path, $PID, ([Guid]::NewGuid().ToString('N'))
    $bakPath = "$Path.bak"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
        $null = [System.IO.File]::ReadAllText($tmpPath, $utf8NoBom) | ConvertFrom-Json
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($tmpPath, $Path, $bakPath, $true)
            } catch [System.PlatformNotSupportedException] {
                Copy-Item -LiteralPath $Path -Destination $bakPath -Force
                Move-Item -LiteralPath $tmpPath -Destination $Path -Force
            }
        } else {
            [System.IO.File]::Move($tmpPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $tmpPath -PathType Leaf) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Format-Sc7ProcessArguments {
    param([string[]]$Arguments)
    $quoted = New-Object System.Collections.ArrayList
    foreach ($arg in @($Arguments)) {
        if ($null -eq $arg -or $arg -eq '') {
            [void]$quoted.Add('""')
        } elseif ($arg -match '[\s"]') {
            $escaped = [regex]::Replace($arg, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            [void]$quoted.Add(('"' + $escaped + '"'))
        } else {
            [void]$quoted.Add($arg)
        }
    }
    return ($quoted.ToArray() -join ' ')
}

function Find-Sc7PublishedNameFromOutput {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $m = [regex]::Match($Text, '(?im):\s*(oem\d+\.inf)\b')
    if ($m.Success) {
        return $m.Groups[1].Value.ToLowerInvariant()
    }
    $m2 = [regex]::Match($Text, '(?i)\b(oem\d+\.inf)\b')
    if ($m2.Success) {
        return $m2.Groups[1].Value.ToLowerInvariant()
    }
    return $null
}

function Invoke-Sc7NativeDeviceRollback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )
    if (-not [Environment]::Is64BitProcess) {
        return [ordered]@{
            Supported    = $false
            ExitCode     = -1
            NeedReboot   = $false
            ErrorMessage = 'Per-device DiRollbackDriver requires a 64-bit PowerShell process.'
        }
    }
    try {
        if (-not ('Sc7PackageNative.DeviceRollback' -as [type])) {
            $csharp = @'
using System;
using System.Runtime.InteropServices;

namespace Sc7PackageNative {
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct SP_DEVINFO_DATA {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    public static class DeviceRollback {
        public const uint ROLLBACK_FLAG_NO_UI = 0x00000001;

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr ClassGuid, IntPtr hwndParent);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetupDiOpenDeviceInfo(
            IntPtr DeviceInfoSet,
            string DeviceInstanceId,
            IntPtr hwndParent,
            uint OpenFlags,
            ref SP_DEVINFO_DATA DeviceInfoData);

        [DllImport("setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

        [DllImport("newdev.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DiRollbackDriver(
            IntPtr DeviceInfoSet,
            ref SP_DEVINFO_DATA DeviceInfoData,
            IntPtr hwndParent,
            uint Flags,
            [MarshalAs(UnmanagedType.Bool)] out bool NeedReboot);

        public static int RollbackDevice(string instanceId, out bool needReboot) {
            needReboot = false;
            IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (set == IntPtr.Zero || set == new IntPtr(-1)) {
                return Marshal.GetLastWin32Error();
            }
            try {
                SP_DEVINFO_DATA data = new SP_DEVINFO_DATA();
                data.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                if (!SetupDiOpenDeviceInfo(set, instanceId, IntPtr.Zero, 0, ref data)) {
                    return Marshal.GetLastWin32Error();
                }
                bool ok = DiRollbackDriver(set, ref data, IntPtr.Zero, ROLLBACK_FLAG_NO_UI, out needReboot);
                if (!ok) {
                    return Marshal.GetLastWin32Error();
                }
                return 0;
            } finally {
                SetupDiDestroyDeviceInfoList(set);
            }
        }
    }
}
'@
            Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
        }
        $needReboot = $false
        $win32Err = [Sc7PackageNative.DeviceRollback]::RollbackDevice($InstanceId, [ref]$needReboot)
        if ($win32Err -eq 0) {
            return [ordered]@{
                Supported    = $true
                ExitCode     = if ($needReboot) { $script:SC7_EXIT_REBOOT_REQUIRED } else { 0 }
                NeedReboot   = $needReboot
                ErrorMessage = $null
            }
        }
        return [ordered]@{
            Supported    = $true
            ExitCode     = $win32Err
            NeedReboot   = $false
            ErrorMessage = "DiRollbackDriver returned Win32 error $win32Err"
        }
    } catch {
        return [ordered]@{
            Supported    = $false
            ExitCode     = -1
            NeedReboot   = $false
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Invoke-Sc7PnputilProcess {
    param([string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pnputil.exe'
    $psi.Arguments = Format-Sc7ProcessArguments -Arguments $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        return [ordered]@{
            ExitCode = [int]$proc.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    } finally {
        $proc.Dispose()
    }
}

function New-Sc7WindowsContext {
    return [ordered]@{
        GetBootId = {
            try {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                if ($null -ne $os -and $null -ne $os.LastBootUpTime) {
                    return $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                }
            } catch {
            }
            return 'unknown-boot'
        }
        TestIsAdministrator = {
            try {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = New-Object Security.Principal.WindowsPrincipal($identity)
                return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            } catch {
                return $true
            }
        }
        GetRegistryKeyExists = {
            param([string]$KeyPath)
            return (Test-Path -LiteralPath $KeyPath)
        }
        GetRegistryValue = {
            param([string]$KeyPath, [string]$Name)
            if (-not (Test-Path -LiteralPath $KeyPath)) {
                return $null
            }
            $item = Get-ItemProperty -LiteralPath $KeyPath -Name $Name -ErrorAction SilentlyContinue
            if ($null -eq $item) {
                return $null
            }
            return (Get-Sc7Prop -Object $item -Name $Name -Default $null)
        }
        EnsureRegistryKey = {
            param([string]$KeyPath)
            if (-not (Test-Path -LiteralPath $KeyPath)) {
                New-Item -Path $KeyPath -Force | Out-Null
            }
        }
        SetRegistryDWord = {
            param([string]$KeyPath, [string]$Name, [int]$Value)
            New-ItemProperty -Path $KeyPath -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
        }
        InvokePnputil = {
            param([string[]]$Arguments)
            return (Invoke-Sc7PnputilProcess -Arguments $Arguments)
        }
        GetDriverStorePackages = {
            $packages = New-Object System.Collections.ArrayList
            $dbInfRoot = 'HKLM:\SYSTEM\DriverDatabase\DriverInfFiles'
            $dbPkgRoot = 'HKLM:\SYSTEM\DriverDatabase\DriverPackages'
            $sysRoot = $env:SystemRoot
            $repoRoot = Join-Path (Join-Path $sysRoot 'System32') 'DriverStore\FileRepository'
            $infRoot = Join-Path $sysRoot 'INF'

            if (Test-Path -LiteralPath $dbInfRoot) {
                $oemKeys = @(Get-ChildItem -LiteralPath $dbInfRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^oem\d+\.inf$' })
                foreach ($k in $oemKeys) {
                    $pubName = $k.PSChildName.ToLowerInvariant()
                    $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                    $pkgId = Get-Sc7Prop -Object $props -Name 'Active' -Default $null
                    if ([string]::IsNullOrWhiteSpace([string]$pkgId)) {
                        $defVal = Get-Sc7Prop -Object $props -Name '(default)' -Default $null
                        if ($defVal -is [array] -and $defVal.Count -gt 0) {
                            $pkgId = [string]$defVal[0]
                        } elseif ($null -ne $defVal) {
                            $pkgId = [string]$defVal
                        }
                    }
                    $origName = $null
                    $storeInfPath = $null
                    if (-not [string]::IsNullOrWhiteSpace([string]$pkgId)) {
                        $pkgKeyPath = Join-Path $dbPkgRoot $pkgId
                        if (Test-Path -LiteralPath $pkgKeyPath) {
                            $pkgProps = Get-ItemProperty -LiteralPath $pkgKeyPath -ErrorAction SilentlyContinue
                            $origCandidate = Get-Sc7Prop -Object $pkgProps -Name '(default)' -Default $null
                            if (-not [string]::IsNullOrWhiteSpace([string]$origCandidate)) {
                                $origName = [System.IO.Path]::GetFileName([string]$origCandidate)
                            }
                        }
                        $pkgDir = Join-Path $repoRoot $pkgId
                        if (-not [string]::IsNullOrWhiteSpace($origName)) {
                            $candInf = Join-Path $pkgDir $origName
                            if (Test-Path -LiteralPath $candInf -PathType Leaf) {
                                $storeInfPath = $candInf
                            }
                        }
                        if ($null -eq $storeInfPath -and (Test-Path -LiteralPath $pkgDir -PathType Container)) {
                            $infs = @(Get-ChildItem -LiteralPath $pkgDir -Filter '*.inf' -File -ErrorAction SilentlyContinue)
                            if ($infs.Count -ge 1) {
                                $storeInfPath = $infs[0].FullName
                                if ([string]::IsNullOrWhiteSpace($origName)) {
                                    $origName = $infs[0].Name
                                }
                            }
                        }
                    }
                    $pubInfPath = Join-Path $infRoot $pubName
                    $parseInf = if ($null -ne $storeInfPath) { $storeInfPath } elseif (Test-Path -LiteralPath $pubInfPath -PathType Leaf) { $pubInfPath } else { $null }
                    $driverVer = $null
                    $driverDate = $null
                    $provider = $null
                    if ($null -ne $parseInf) {
                        $meta = Read-Sc7InfMetadata -InfPath $parseInf -SkipPayloadCheck -SkipHash
                        $driverVer = $meta['DriverVersion']
                        $driverDate = $meta['DriverDate']
                        $provider = $meta['ProviderName']
                    }
                    [void]$packages.Add([ordered]@{
                        PublishedName      = $pubName
                        OriginalName       = $origName
                        DriverVersion      = $driverVer
                        DriverDate         = $driverDate
                        ProviderName       = $provider
                        DriverStoreInfPath = $storeInfPath
                        PublishedInfPath   = if (Test-Path -LiteralPath $pubInfPath -PathType Leaf) { $pubInfPath } else { $null }
                        InfSha256          = $null
                        FileHashes         = $null
                    })
                }
            }

            if ($packages.Count -eq 0) {
                $enumRes = Invoke-Sc7PnputilProcess -Arguments @('/enum-drivers')
                if ($enumRes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($enumRes.StdOut)) {
                    $blocks = [regex]::Split($enumRes.StdOut, "(?:\r?\n){2,}")
                    foreach ($block in $blocks) {
                        $pubM = [regex]::Match($block, '(?im):\s*(oem\d+\.inf)\b')
                        if (-not $pubM.Success) { continue }
                        $pubName = $pubM.Groups[1].Value.ToLowerInvariant()
                        $origName = $null
                        foreach ($line in ($block -split '\r?\n')) {
                            if ($line -match ':\s*([^\r\n]+\.inf)\s*$') {
                                $cand = [System.IO.Path]::GetFileName($Matches[1].Trim())
                                if ($cand -notmatch '^oem\d+\.inf$') {
                                    $origName = $cand
                                    break
                                }
                            }
                        }
                        $verM = [regex]::Match($block, '(\d{1,2}/\d{1,2}/\d{4})\s+(\d+\.\d+\.\d+\.\d+)')
                        $dDate = if ($verM.Success) { ConvertTo-Sc7NormalizedDate -Value $verM.Groups[1].Value } else { $null }
                        $dVer = if ($verM.Success) { ConvertTo-Sc7NormalizedVersion -Version $verM.Groups[2].Value } else { $null }
                        $pubInfPath = Join-Path $infRoot $pubName
                        $provider = $null
                        $storeInfPath = $null
                        if (Test-Path -LiteralPath $pubInfPath -PathType Leaf) {
                            $meta = Read-Sc7InfMetadata -InfPath $pubInfPath -SkipPayloadCheck -SkipHash
                            $provider = $meta['ProviderName']
                            if ($null -eq $dDate) { $dDate = $meta['DriverDate'] }
                            if ($null -eq $dVer) { $dVer = $meta['DriverVersion'] }
                            if (-not [string]::IsNullOrWhiteSpace($origName) -and (Test-Path -LiteralPath $repoRoot -PathType Container)) {
                                $pubSha = Get-Sc7FileSha256 -Path $pubInfPath
                                $candDirs = @(Get-ChildItem -LiteralPath $repoRoot -Filter ("{0}_*" -f $origName) -Directory -ErrorAction SilentlyContinue)
                                foreach ($cd in $candDirs) {
                                    $candInf = Join-Path $cd.FullName $origName
                                    if ((Test-Path -LiteralPath $candInf -PathType Leaf) -and ((Get-Sc7FileSha256 -Path $candInf) -eq $pubSha)) {
                                        $storeInfPath = $candInf
                                        break
                                    }
                                }
                            }
                        }
                        [void]$packages.Add([ordered]@{
                            PublishedName      = $pubName
                            OriginalName       = $origName
                            DriverVersion      = $dVer
                            DriverDate         = $dDate
                            ProviderName       = $provider
                            DriverStoreInfPath = $storeInfPath
                            PublishedInfPath   = if (Test-Path -LiteralPath $pubInfPath -PathType Leaf) { $pubInfPath } else { $null }
                            InfSha256          = $null
                            FileHashes         = $null
                        })
                    }
                }
            }

            return $packages.ToArray()
        }
        GetPnpDevices = {
            $entities = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)
            $signed = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
            $signedMap = @{}
            foreach ($s in $signed) {
                $sid = Get-Sc7Prop -Object $s -Name 'DeviceID'
                if (-not [string]::IsNullOrWhiteSpace([string]$sid)) {
                    $signedMap[([string]$sid).ToLowerInvariant()] = $s
                }
            }
            $result = New-Object System.Collections.ArrayList
            $seen = @{}
            foreach ($e in $entities) {
                $eid = Get-Sc7Prop -Object $e -Name 'DeviceID'
                if ([string]::IsNullOrWhiteSpace([string]$eid)) { continue }
                $idLower = ([string]$eid).ToLowerInvariant()
                $seen[$idLower] = $true
                $s = if ($signedMap.ContainsKey($idLower)) { $signedMap[$idLower] } else { $null }
                $hwIds = New-Object System.Collections.ArrayList
                foreach ($h in @(Get-Sc7Prop -Object $e -Name 'HardwareID' -Default @())) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$h)) {
                        [void]$hwIds.Add(([string]$h).Trim().ToUpperInvariant())
                    }
                }
                $compatIds = New-Object System.Collections.ArrayList
                foreach ($c in @(Get-Sc7Prop -Object $e -Name 'CompatibleID' -Default @())) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$c)) {
                        [void]$compatIds.Add(([string]$c).Trim().ToUpperInvariant())
                    }
                }
                $presentVal = Get-Sc7Prop -Object $e -Name 'Present' -Default $true
                $infRaw = if ($null -ne $s) { Get-Sc7Prop -Object $s -Name 'InfName' } else { $null }
                $provRaw = if ($null -ne $s) { Get-Sc7Prop -Object $s -Name 'DriverProviderName' } else { $null }
                [void]$result.Add([ordered]@{
                    InstanceId    = [string]$eid
                    Present       = [bool]$presentVal
                    InfName       = if (-not [string]::IsNullOrWhiteSpace([string]$infRaw)) { ([string]$infRaw).Trim() } else { $null }
                    DriverVersion = if ($null -ne $s) { ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $s -Name 'DriverVersion') } else { $null }
                    DriverDate    = if ($null -ne $s) { ConvertTo-Sc7NormalizedDate -Value (Get-Sc7Prop -Object $s -Name 'DriverDate') } else { $null }
                    ProviderName  = if (-not [string]::IsNullOrWhiteSpace([string]$provRaw)) { ([string]$provRaw).Trim() } else { $null }
                    HardwareIds   = @($hwIds.ToArray())
                    CompatibleIds = @($compatIds.ToArray())
                })
            }
            foreach ($s in $signed) {
                $sid = Get-Sc7Prop -Object $s -Name 'DeviceID'
                if ([string]::IsNullOrWhiteSpace([string]$sid)) { continue }
                $idLower = ([string]$sid).ToLowerInvariant()
                if ($seen.ContainsKey($idLower)) { continue }
                $infRaw = Get-Sc7Prop -Object $s -Name 'InfName'
                $provRaw = Get-Sc7Prop -Object $s -Name 'DriverProviderName'
                [void]$result.Add([ordered]@{
                    InstanceId    = [string]$sid
                    Present       = $false
                    InfName       = if (-not [string]::IsNullOrWhiteSpace([string]$infRaw)) { ([string]$infRaw).Trim() } else { $null }
                    DriverVersion = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $s -Name 'DriverVersion')
                    DriverDate    = ConvertTo-Sc7NormalizedDate -Value (Get-Sc7Prop -Object $s -Name 'DriverDate')
                    ProviderName  = if (-not [string]::IsNullOrWhiteSpace([string]$provRaw)) { ([string]$provRaw).Trim() } else { $null }
                    HardwareIds   = @()
                    CompatibleIds = @()
                })
            }
            return $result.ToArray()
        }
        InvokeDeviceRollback = {
            param([string]$InstanceId)
            return (Invoke-Sc7NativeDeviceRollback -InstanceId $InstanceId)
        }
        Log = {
            param([string]$Message)
            Write-Host $Message
        }
    }
}

function Clear-Sc7Gate {
    param(
        [Parameter(Mandatory = $true)]
        $Context
    )
    $serviceExists = [bool](& $Context.GetRegistryKeyExists $script:Sc7PepServiceKey)
    $pepKeyExists = [bool](& $Context.GetRegistryKeyExists $script:Sc7PepParametersKey)

    if (-not $serviceExists -and -not $pepKeyExists) {
        return [ordered]@{
            Success              = $true
            KeyPresent           = $false
            ServiceKeyExisted    = $false
            PepKeyExisted        = $false
            GateCleared          = $false
            PriorEnableSc7       = $null
            PriorEnableSc7Active = $null
            EnableSc7            = $null
            EnableSc7Active      = $null
            RebootRequired       = $false
            ErrorMessage         = $null
        }
    }

    $priorCfg = if ($pepKeyExists) { & $Context.GetRegistryValue $script:Sc7PepParametersKey 'EnableSc7' } else { $null }
    $priorActive = if ($pepKeyExists) { & $Context.GetRegistryValue $script:Sc7PepParametersKey 'EnableSc7Active' } else { $null }

    try {
        if (-not $pepKeyExists) {
            & $Context.EnsureRegistryKey $script:Sc7PepParametersKey
        }
        & $Context.SetRegistryDWord $script:Sc7PepParametersKey 'EnableSc7' 0
        $verifiedCfg = & $Context.GetRegistryValue $script:Sc7PepParametersKey 'EnableSc7'
        if ($null -eq $verifiedCfg -or ([int]$verifiedCfg -ne 0)) {
            return [ordered]@{
                Success              = $false
                KeyPresent           = $true
                ServiceKeyExisted    = $serviceExists
                PepKeyExisted        = $pepKeyExists
                GateCleared          = $false
                PriorEnableSc7       = $priorCfg
                PriorEnableSc7Active = $priorActive
                EnableSc7            = $verifiedCfg
                EnableSc7Active      = $priorActive
                RebootRequired       = ($null -ne $priorActive -and ([int]$priorActive -ne 0))
                ErrorMessage         = "Verification failed: $($script:Sc7PepParametersKey)\EnableSc7 read back '$verifiedCfg' instead of 0."
            }
        }
        $liveActive = & $Context.GetRegistryValue $script:Sc7PepParametersKey 'EnableSc7Active'
        $reboot = ($null -ne $liveActive -and ([int]$liveActive -ne 0))
        return [ordered]@{
            Success              = $true
            KeyPresent           = $true
            ServiceKeyExisted    = $serviceExists
            PepKeyExisted        = $pepKeyExists
            GateCleared          = $true
            PriorEnableSc7       = $priorCfg
            PriorEnableSc7Active = $priorActive
            EnableSc7            = 0
            EnableSc7Active      = $liveActive
            RebootRequired       = $reboot
            ErrorMessage         = $null
        }
    } catch {
        return [ordered]@{
            Success              = $false
            KeyPresent           = $true
            ServiceKeyExisted    = $serviceExists
            PepKeyExisted        = $pepKeyExists
            GateCleared          = $false
            PriorEnableSc7       = $priorCfg
            PriorEnableSc7Active = $priorActive
            EnableSc7            = $null
            EnableSc7Active      = $priorActive
            RebootRequired       = ($null -ne $priorActive -and ([int]$priorActive -ne 0))
            ErrorMessage         = "Failed to clear EnableSc7=0: $($_.Exception.Message)"
        }
    }
}

function Test-Sc7DriverPackageMatchesCandidate {
    param(
        [Parameter(Mandatory = $true)]
        $Package,
        [Parameter(Mandatory = $true)]
        $Candidate
    )
    $pkgOrig = Get-Sc7Prop -Object $Package -Name 'OriginalName'
    $candOrig = Get-Sc7Prop -Object $Candidate -Name 'OriginalName'
    if ([string]::IsNullOrWhiteSpace([string]$pkgOrig) -or -not [string]::Equals([string]$pkgOrig, [string]$candOrig, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $pkgVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $Package -Name 'DriverVersion')
    $candVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $Candidate -Name 'DriverVersion')
    if ($null -eq $pkgVer -or $pkgVer -ne $candVer) {
        return $false
    }

    $candDate = ConvertTo-Sc7NormalizedDate -Value (Get-Sc7Prop -Object $Candidate -Name 'DriverDate')
    $pkgDate = ConvertTo-Sc7NormalizedDate -Value (Get-Sc7Prop -Object $Package -Name 'DriverDate')
    if ($null -ne $candDate -and ($null -eq $pkgDate -or $pkgDate -ne $candDate)) {
        return $false
    }

    $candProv = Get-Sc7Prop -Object $Candidate -Name 'ProviderName'
    $pkgProv = Get-Sc7Prop -Object $Package -Name 'ProviderName'
    if (-not [string]::IsNullOrWhiteSpace([string]$candProv) -and -not [string]::IsNullOrWhiteSpace([string]$pkgProv)) {
        if (-not [string]::Equals([string]$candProv, [string]$pkgProv, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    $candInfSha = Get-Sc7Prop -Object $Candidate -Name 'InfSha256'
    $pkgStoreInf = Get-Sc7Prop -Object $Package -Name 'DriverStoreInfPath'
    $pkgPubInf = Get-Sc7Prop -Object $Package -Name 'PublishedInfPath'
    $pkgHashes = Get-Sc7Prop -Object $Package -Name 'FileHashes'

    if (-not [string]::IsNullOrWhiteSpace([string]$candInfSha)) {
        $pkgInfSha = Get-Sc7Prop -Object $Package -Name 'InfSha256'
        if ([string]::IsNullOrWhiteSpace([string]$pkgInfSha)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$pkgStoreInf) -and (Test-Path -LiteralPath $pkgStoreInf -PathType Leaf)) {
                $pkgInfSha = Get-Sc7FileSha256 -Path $pkgStoreInf
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$pkgPubInf) -and (Test-Path -LiteralPath $pkgPubInf -PathType Leaf)) {
                $pkgInfSha = Get-Sc7FileSha256 -Path $pkgPubInf
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$pkgInfSha) -or -not [string]::Equals([string]$pkgInfSha, [string]$candInfSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    $candHashes = Get-Sc7Prop -Object $Candidate -Name 'FileHashes'
    if ($null -ne $candHashes -and $candHashes -is [System.Collections.IDictionary]) {
        $origKey = ([string]$candOrig).ToLowerInvariant()
        foreach ($relKey in $candHashes.Keys) {
            if ([string]::Equals([string]$relKey, $origKey, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $expectedHash = [string]$candHashes[$relKey]
            $actualHash = $null
            if ($null -ne $pkgHashes -and $pkgHashes -is [System.Collections.IDictionary]) {
                $actualHash = Get-Sc7Prop -Object $pkgHashes -Name ([string]$relKey) -Default $null
            }
            if ([string]::IsNullOrWhiteSpace([string]$actualHash) -and -not [string]::IsNullOrWhiteSpace([string]$pkgStoreInf) -and (Test-Path -LiteralPath $pkgStoreInf -PathType Leaf)) {
                $storeDir = Split-Path -Parent $pkgStoreInf
                $storeFile = Join-Sc7RelativePath -BasePath $storeDir -RelativePath ([string]$relKey)
                if (Test-Path -LiteralPath $storeFile -PathType Leaf) {
                    $actualHash = Get-Sc7FileSha256 -Path $storeFile
                }
            }
            if ([string]::IsNullOrWhiteSpace([string]$actualHash) -or -not [string]::Equals([string]$actualHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
    }

    return $true
}

function Get-Sc7MatchingDevices {
    param(
        [Parameter(Mandatory = $true)]
        $Candidate,
        [Parameter(Mandatory = $true)]
        $Devices,
        [switch]$PresentOnly
    )
    $candIds = New-Object System.Collections.ArrayList
    foreach ($id in @(Get-Sc7Prop -Object $Candidate -Name 'HardwareIds' -Default @())) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
            [void]$candIds.Add(([string]$id).Trim().ToUpperInvariant())
        }
    }
    foreach ($id in @(Get-Sc7Prop -Object $Candidate -Name 'CompatibleIds' -Default @())) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
            if (-not (Test-Sc7NameInList -List $candIds -Value ([string]$id))) {
                [void]$candIds.Add(([string]$id).Trim().ToUpperInvariant())
            }
        }
    }

    $matched = New-Object System.Collections.ArrayList
    if ($candIds.Count -eq 0) {
        return $matched.ToArray()
    }
    foreach ($dev in @($Devices)) {
        if ($PresentOnly -and -not [bool](Get-Sc7Prop -Object $dev -Name 'Present' -Default $true)) {
            continue
        }
        $devIds = @(Get-Sc7Prop -Object $dev -Name 'HardwareIds' -Default @()) + @(Get-Sc7Prop -Object $dev -Name 'CompatibleIds' -Default @())
        $isMatch = $false
        foreach ($did in $devIds) {
            if (-not [string]::IsNullOrWhiteSpace([string]$did) -and (Test-Sc7NameInList -List $candIds -Value ([string]$did))) {
                $isMatch = $true
                break
            }
        }
        if ($isMatch) {
            [void]$matched.Add($dev)
        }
    }
    return $matched.ToArray()
}

function Test-Sc7ComponentBound {
    param(
        [Parameter(Mandatory = $true)]
        $Candidate,
        [Parameter(Mandatory = $true)]
        $StorePackages,
        [Parameter(Mandatory = $true)]
        $Devices,
        [string]$ReportedPublishedName
    )

    $matchedPackages = New-Object System.Collections.ArrayList
    foreach ($pkg in @($StorePackages)) {
        if (Test-Sc7DriverPackageMatchesCandidate -Package $pkg -Candidate $Candidate) {
            [void]$matchedPackages.Add($pkg)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportedPublishedName)) {
        $reportedMatches = @($matchedPackages | Where-Object { [string]::Equals([string](Get-Sc7Prop $_ 'PublishedName'), $ReportedPublishedName, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($reportedMatches.Count -eq 0) {
            return [ordered]@{
                Verified            = $false
                Reason              = "Reported published package '$ReportedPublishedName' did not pass exact Driver Store metadata/hash verification for $($Candidate['OriginalName']) ($($Candidate['DriverVersion']))."
                TargetPublishedName = $null
                BoundDevices        = @()
                MismatchedDevices   = @()
            }
        }
        $matchedPackages = New-Object System.Collections.ArrayList
        foreach ($rm in $reportedMatches) { [void]$matchedPackages.Add($rm) }
    }

    if ($matchedPackages.Count -eq 0) {
        return [ordered]@{
            Verified            = $false
            Reason              = "No verified Driver Store package matches $($Candidate['OriginalName']) ($($Candidate['DriverVersion']) / $($Candidate['DriverDate']))."
            TargetPublishedName = $null
            BoundDevices        = @()
            MismatchedDevices   = @()
        }
    }

    $matchedPubNames = @($matchedPackages | ForEach-Object { ([string](Get-Sc7Prop $_ 'PublishedName')).ToLowerInvariant() })
    $candVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $Candidate -Name 'DriverVersion')
    $candDate = ConvertTo-Sc7NormalizedDate -Value (Get-Sc7Prop -Object $Candidate -Name 'DriverDate')
    $candProv = Get-Sc7Prop -Object $Candidate -Name 'ProviderName'

    $boundDevices = New-Object System.Collections.ArrayList
    foreach ($dev in @($Devices)) {
        if (-not [bool](Get-Sc7Prop -Object $dev -Name 'Present' -Default $true)) {
            continue
        }
        $devInf = Get-Sc7Prop -Object $dev -Name 'InfName'
        if ([string]::IsNullOrWhiteSpace([string]$devInf)) { continue }
        if (-not (Test-Sc7NameInList -List $matchedPubNames -Value ([string]$devInf))) { continue }
        $devVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $dev -Name 'DriverVersion')
        if ($devVer -ne $candVer) { continue }
        $devDate = ConvertTo-Sc7NormalizedDate -Value (Get-Sc7Prop -Object $dev -Name 'DriverDate')
        if ($null -ne $candDate -and $null -ne $devDate -and $devDate -ne $candDate) { continue }
        $devProv = Get-Sc7Prop -Object $dev -Name 'ProviderName'
        if (-not [string]::IsNullOrWhiteSpace([string]$candProv) -and -not [string]::IsNullOrWhiteSpace([string]$devProv)) {
            if (-not [string]::Equals([string]$candProv, [string]$devProv, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        [void]$boundDevices.Add($dev)
    }

    if ($boundDevices.Count -eq 0) {
        return [ordered]@{
            Verified            = $false
            Reason              = "Staging only: verified package ($($matchedPubNames -join ', ')) is in Driver Store, but zero present devices are bound to it."
            TargetPublishedName = Get-Sc7Prop -Object $matchedPackages[0] -Name 'PublishedName'
            BoundDevices        = @()
            MismatchedDevices   = @()
        }
    }

    $matchingPresent = @(Get-Sc7MatchingDevices -Candidate $Candidate -Devices $Devices -PresentOnly)
    $boundIdList = @($boundDevices | ForEach-Object { [string](Get-Sc7Prop $_ 'InstanceId') })
    $mismatched = New-Object System.Collections.ArrayList
    foreach ($mDev in $matchingPresent) {
        $mId = [string](Get-Sc7Prop $mDev 'InstanceId')
        if (-not (Test-Sc7NameInList -List $boundIdList -Value $mId)) {
            [void]$mismatched.Add($mDev)
        }
    }

    if ($mismatched.Count -gt 0) {
        $details = @($mismatched | ForEach-Object {
            $id = Get-Sc7Prop $_ 'InstanceId'
            $inf = Get-Sc7Prop $_ 'InfName' '<unbound>'
            $ver = Get-Sc7Prop $_ 'DriverVersion' '<none>'
            "$id ($inf / $ver)"
        }) -join '; '
        return [ordered]@{
            Verified            = $false
            Reason              = "Matching present device(s) are not bound to verified package ($($matchedPubNames -join ', ')): $details"
            TargetPublishedName = ([string](Get-Sc7Prop $boundDevices[0] 'InfName')).ToLowerInvariant()
            BoundDevices        = @($boundDevices.ToArray())
            MismatchedDevices   = @($mismatched.ToArray())
        }
    }

    $targetPub = ([string](Get-Sc7Prop $boundDevices[0] 'InfName')).ToLowerInvariant()
    return [ordered]@{
        Verified            = $true
        Reason              = $null
        TargetPublishedName = $targetPub
        BoundDevices        = @($boundDevices.ToArray())
        MismatchedDevices   = @()
    }
}

function Test-Sc7DeviceMatchesPrior {
    param(
        [Parameter(Mandatory = $true)]
        $Device,
        [Parameter(Mandatory = $true)]
        $Binding
    )
    $priorInf = Get-Sc7Prop -Object $Binding -Name 'PriorInf'
    $devInf = Get-Sc7Prop -Object $Device -Name 'InfName'
    if ([string]::IsNullOrWhiteSpace([string]$priorInf)) {
        return [string]::IsNullOrWhiteSpace([string]$devInf)
    }
    if ([string]::IsNullOrWhiteSpace([string]$devInf)) {
        return $false
    }
    if (-not [string]::Equals([string]$devInf, [string]$priorInf, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $priorVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $Binding -Name 'PriorVersion')
    if ($null -ne $priorVer) {
        $devVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $Device -Name 'DriverVersion')
        if ($devVer -ne $priorVer) {
            return $false
        }
    }
    return $true
}

function Reconcile-Sc7InterruptedComponent {
    param(
        [Parameter(Mandatory = $true)]
        $Component,
        [Parameter(Mandatory = $true)]
        $LiveStore,
        [Parameter(Mandatory = $true)]
        $LiveDevices
    )
    $preStore = @(Get-Sc7Prop -Object $Component -Name 'PreStorePublishedNames' -Default @())
    $origName = Get-Sc7Prop -Object $Component -Name 'OriginalName'
    $compVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop -Object $Component -Name 'DriverVersion')
    $compInfSha = Get-Sc7Prop -Object $Component -Name 'InfSha256'

    $staged = @(Get-Sc7Prop -Object $Component -Name 'StagedPackages' -Default @())
    $matchedPubs = New-Object System.Collections.ArrayList

    foreach ($pkg in @($LiveStore)) {
        $pub = ([string](Get-Sc7Prop $pkg 'PublishedName')).ToLowerInvariant()
        $pkgOrig = Get-Sc7Prop $pkg 'OriginalName'
        if (-not [string]::Equals([string]$pkgOrig, [string]$origName, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $pkgVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $pkg 'DriverVersion')
        if ($null -ne $compVer -and $pkgVer -ne $compVer) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$compInfSha)) {
            $pkgSha = Get-Sc7Prop $pkg 'InfSha256'
            if ([string]::IsNullOrWhiteSpace([string]$pkgSha)) {
                $pPath = Get-Sc7Prop $pkg 'DriverStoreInfPath'
                if ([string]::IsNullOrWhiteSpace([string]$pPath)) { $pPath = Get-Sc7Prop $pkg 'PublishedInfPath' }
                if (-not [string]::IsNullOrWhiteSpace([string]$pPath) -and (Test-Path -LiteralPath $pPath -PathType Leaf)) {
                    $pkgSha = Get-Sc7FileSha256 -Path $pPath
                }
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$pkgSha) -and -not [string]::Equals([string]$pkgSha, [string]$compInfSha, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }
        [void]$matchedPubs.Add($pub)
        if (-not (Test-Sc7NameInList -List $preStore -Value $pub)) {
            $staged = Add-Sc7UniqueString -List $staged -Value $pub
            $Component['StagedByTransaction'] = $true
        }
    }
    $Component['StagedPackages'] = @($staged)
    if ([string]::IsNullOrWhiteSpace([string](Get-Sc7Prop $Component 'TargetPublishedName')) -and $matchedPubs.Count -gt 0) {
        $Component['TargetPublishedName'] = [string]$matchedPubs[0]
    }

    $liveDevMap = @{}
    foreach ($d in @($LiveDevices)) {
        $id = Get-Sc7Prop $d 'InstanceId'
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
            $liveDevMap[([string]$id).ToLowerInvariant()] = $d
        }
    }

    foreach ($b in @(Get-Sc7Prop -Object $Component -Name 'DeviceBindings' -Default @())) {
        $id = [string](Get-Sc7Prop $b 'InstanceId')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $idLower = $id.ToLowerInvariant()
        if (-not $liveDevMap.ContainsKey($idLower)) { continue }
        $dev = $liveDevMap[$idLower]
        $devInf = Get-Sc7Prop $dev 'InfName'
        if ([string]::IsNullOrWhiteSpace([string]$devInf)) { continue }
        if (-not (Test-Sc7NameInList -List $matchedPubs -Value ([string]$devInf))) { continue }
        if (-not (Test-Sc7DeviceMatchesPrior -Device $dev -Binding $b)) {
            $b['TargetPublishedName'] = ([string]$devInf).ToLowerInvariant()
            $b['TargetVersion'] = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $dev 'DriverVersion')
            $b['AttributedToTransaction'] = $true
            $b['RestoreState'] = 'Pending'
            if ([string]::IsNullOrWhiteSpace([string](Get-Sc7Prop $Component 'TargetPublishedName'))) {
                $Component['TargetPublishedName'] = ([string]$devInf).ToLowerInvariant()
            }
        }
    }
}

function Invoke-Sc7ComponentRollback {
    param(
        [Parameter(Mandatory = $true)]
        $Component,
        [Parameter(Mandatory = $true)]
        $Journal,
        [Parameter(Mandatory = $true)]
        $Context
    )
    $rebootRequired = $false
    $errors = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList

    $liveStore = @(& $Context.GetDriverStorePackages)
    $liveDevices = @(& $Context.GetPnpDevices)

    if ([string]::Equals([string](Get-Sc7Prop $Component 'Status'), 'Installing', [System.StringComparison]::OrdinalIgnoreCase)) {
        Reconcile-Sc7InterruptedComponent -Component $Component -LiveStore $liveStore -LiveDevices $liveDevices
    }

    $liveDevMap = @{}
    foreach ($d in $liveDevices) {
        $id = Get-Sc7Prop $d 'InstanceId'
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
            $liveDevMap[([string]$id).ToLowerInvariant()] = $d
        }
    }

    $attributedBindings = @(
        @(Get-Sc7Prop -Object $Component -Name 'DeviceBindings' -Default @()) |
            Where-Object { [bool](Get-Sc7Prop $_ 'AttributedToTransaction' $false) }
    )

    $needRollback = New-Object System.Collections.ArrayList
    foreach ($b in $attributedBindings) {
        $id = [string](Get-Sc7Prop $b 'InstanceId')
        $idLower = $id.ToLowerInvariant()
        if (-not $liveDevMap.ContainsKey($idLower)) {
            $b['RestoreState'] = 'PreservedUnrelated'
            $msg = "Device $id is no longer present; skipped rollback."
            $b['RestoreNote'] = $msg
            [void]$notes.Add($msg)
            continue
        }
        $dev = $liveDevMap[$idLower]
        if (Test-Sc7DeviceMatchesPrior -Device $dev -Binding $b) {
            $b['RestoreState'] = 'Restored'
            $b['RestoreNote'] = 'Already at prior binding.'
            continue
        }
        $expectedTarget = Get-Sc7Prop $b 'TargetPublishedName'
        if ([string]::IsNullOrWhiteSpace([string]$expectedTarget)) {
            $expectedTarget = Get-Sc7Prop $Component 'TargetPublishedName'
        }
        $devInf = Get-Sc7Prop $dev 'InfName'
        $expectedVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $b 'TargetVersion')
        $devVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $dev 'DriverVersion')
        $verMatches = ($null -eq $expectedVer) -or ($devVer -eq $expectedVer)
        $onTarget = (-not [string]::IsNullOrWhiteSpace([string]$devInf)) -and (-not [string]::IsNullOrWhiteSpace([string]$expectedTarget)) -and [string]::Equals([string]$devInf, [string]$expectedTarget, [System.StringComparison]::OrdinalIgnoreCase) -and $verMatches
        if (-not $onTarget) {
            $b['RestoreState'] = 'PreservedUnrelated'
            $msg = "Preserved unrelated driver change on $id (currently $devInf / $(Get-Sc7Prop $dev 'DriverVersion'), not transaction package $expectedTarget)."
            $b['RestoreNote'] = $msg
            [void]$notes.Add($msg)
            & $Context.Log "  [skip] $msg"
            continue
        }
        [void]$needRollback.Add($b)
    }

    # Step 1: Try targeted per-device rollback (DiRollbackDriver) when a prior driver existed
    $fallbackBindings = New-Object System.Collections.ArrayList
    foreach ($b in $needRollback) {
        $priorInf = Get-Sc7Prop $b 'PriorInf'
        $id = [string](Get-Sc7Prop $b 'InstanceId')
        if ([string]::IsNullOrWhiteSpace([string]$priorInf)) {
            [void]$fallbackBindings.Add($b)
            continue
        }
        $rb = & $Context.InvokeDeviceRollback $id
        $rbSupported = [bool](Get-Sc7Prop $rb 'Supported' $false)
        $rbCode = [int](Get-Sc7Prop $rb 'ExitCode' -1)
        $rbNeedReboot = [bool](Get-Sc7Prop $rb 'NeedReboot' $false)
        if ($rbSupported -and ($rbCode -eq 0 -or $rbCode -eq $script:SC7_EXIT_REBOOT_REQUIRED)) {
            if ($rbNeedReboot -or $rbCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) {
                $rebootRequired = $true
            }
            $postDevs = @(& $Context.GetPnpDevices)
            $devNow = $null
            foreach ($pd in $postDevs) {
                if ([string]::Equals([string](Get-Sc7Prop $pd 'InstanceId'), $id, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $devNow = $pd
                    break
                }
            }
            if ($null -ne $devNow -and (Test-Sc7DeviceMatchesPrior -Device $devNow -Binding $b)) {
                $b['RestoreState'] = 'Restored'
                $b['RestoreNote'] = if ($rbNeedReboot -or $rbCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) { 'Rolled back via per-device rollback (reboot required).' } else { 'Rolled back via per-device rollback.' }
            } elseif (($rbNeedReboot -or $rbCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) -and $null -ne $devNow -and [string]::Equals([string](Get-Sc7Prop $devNow 'InfName'), [string](Get-Sc7Prop $b 'TargetPublishedName'), [System.StringComparison]::OrdinalIgnoreCase)) {
                $b['RestoreState'] = 'Restored'
                $b['RestoreNote'] = 'Per-device rollback staged (reboot required 3010; verify binding after reboot).'
            } else {
                $actualInf = if ($null -ne $devNow) { Get-Sc7Prop $devNow 'InfName' '<unbound>' } else { '<missing>' }
                $actualVer = if ($null -ne $devNow) { Get-Sc7Prop $devNow 'DriverVersion' '<none>' } else { '<none>' }
                $errMsg = "Per-device rollback of $id did not restore expected prior driver $priorInf ($(Get-Sc7Prop $b 'PriorVersion')); live binding is $actualInf ($actualVer)."
                $b['RestoreState'] = 'Incomplete'
                $b['RestoreNote'] = $errMsg
                [void]$errors.Add($errMsg)
            }
        } else {
            [void]$fallbackBindings.Add($b)
        }
    }

    # Step 2: Safe pnputil uninstall + prior re-bind fallback ONLY when all safety invariants hold
    if ($fallbackBindings.Count -gt 0) {
        $liveStore = @(& $Context.GetDriverStorePackages)
        $liveDevices = @(& $Context.GetPnpDevices)
        $liveStoreMap = @{}
        foreach ($p in $liveStore) {
            $pn = ([string](Get-Sc7Prop $p 'PublishedName')).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($pn)) { $liveStoreMap[$pn] = $p }
        }

        $groups = [ordered]@{}
        foreach ($b in $fallbackBindings) {
            $tInf = Get-Sc7Prop $b 'TargetPublishedName'
            if ([string]::IsNullOrWhiteSpace([string]$tInf)) { $tInf = Get-Sc7Prop $Component 'TargetPublishedName' }
            $tKey = ([string]$tInf).ToLowerInvariant()
            if (-not $groups.Contains($tKey)) {
                $groups[$tKey] = New-Object System.Collections.ArrayList
            }
            [void]$groups[$tKey].Add($b)
        }

        foreach ($targetInf in $groups.Keys) {
            $groupBindings = @($groups[$targetInf].ToArray())

            # Invariant (a): Target package must have been newly staged by this transaction
            $wasStaged = (Test-Sc7NameInList -List (Get-Sc7Prop $Component 'StagedPackages' @()) -Value $targetInf) -or (
                [bool](Get-Sc7Prop $Component 'StagedByTransaction' $false) -and
                [string]::Equals([string](Get-Sc7Prop $Component 'TargetPublishedName'), $targetInf, [System.StringComparison]::OrdinalIgnoreCase)
            )
            if (-not $wasStaged) {
                $errMsg = "Cannot safely uninstall ${targetInf}: package pre-existed in Driver Store before this transaction (refusing to delete pre-existing/shared OEM package) and per-device rollback was unavailable."
                foreach ($gb in $groupBindings) { $gb['RestoreState'] = 'Incomplete'; $gb['RestoreNote'] = $errMsg }
                [void]$errors.Add($errMsg)
                continue
            }

            # Invariant (b): Zero unrelated devices on the system may be bound to targetInf
            $groupIdList = @($groupBindings | ForEach-Object { [string](Get-Sc7Prop $_ 'InstanceId') })
            $unrelatedBound = @(
                $liveDevices | Where-Object {
                    [string]::Equals([string](Get-Sc7Prop $_ 'InfName'), $targetInf, [System.StringComparison]::OrdinalIgnoreCase) -and
                    -not (Test-Sc7NameInList -List $groupIdList -Value ([string](Get-Sc7Prop $_ 'InstanceId')))
                }
            )
            if ($unrelatedBound.Count -gt 0) {
                $unrelIds = @($unrelatedBound | ForEach-Object { Get-Sc7Prop $_ 'InstanceId' }) -join ', '
                $errMsg = "Cannot safely uninstall shared OEM package ${targetInf}: unrelated device(s) [$unrelIds] are bound to it, and per-device rollback was unavailable."
                foreach ($gb in $groupBindings) { $gb['RestoreState'] = 'Incomplete'; $gb['RestoreNote'] = $errMsg }
                [void]$errors.Add($errMsg)
                continue
            }

            # Invariant (c): No other un-reverted journal component may reference targetInf
            $otherRefs = @(
                @(Get-Sc7Prop $Journal 'Components' @()) | Where-Object {
                    (-not [string]::Equals([string](Get-Sc7Prop $_ 'Name'), [string](Get-Sc7Prop $Component 'Name'), [System.StringComparison]::OrdinalIgnoreCase)) -and
                    (-not (Test-Sc7NameInList -List @('RolledBack', 'AlreadyInstalled') -Value ([string](Get-Sc7Prop $_ 'Status')))) -and
                    ([string]::Equals([string](Get-Sc7Prop $_ 'TargetPublishedName'), $targetInf, [System.StringComparison]::OrdinalIgnoreCase) -or (Test-Sc7NameInList -List (Get-Sc7Prop $_ 'StagedPackages' @()) -Value $targetInf))
                }
            )
            if ($otherRefs.Count -gt 0) {
                $otherNames = @($otherRefs | ForEach-Object { Get-Sc7Prop $_ 'Name' }) -join ', '
                $errMsg = "Cannot safely uninstall shared OEM package ${targetInf}: referenced by active component(s) [$otherNames]."
                foreach ($gb in $groupBindings) { $gb['RestoreState'] = 'Incomplete'; $gb['RestoreNote'] = $errMsg }
                [void]$errors.Add($errMsg)
                continue
            }

            # Invariant (d): Every device with a prior OEM package must still have that prior OEM package in Driver Store
            $priorPaths = New-Object System.Collections.ArrayList
            $needsInboxScan = $false
            $missingPriorErr = $null
            foreach ($gb in $groupBindings) {
                $pInf = Get-Sc7Prop $gb 'PriorInf'
                if ([string]::IsNullOrWhiteSpace([string]$pInf)) { continue }
                if ([string]$pInf -match '^oem\d+\.inf$') {
                    $pKey = ([string]$pInf).ToLowerInvariant()
                    $livePrior = if ($liveStoreMap.ContainsKey($pKey)) { $liveStoreMap[$pKey] } else { $null }
                    $resolvedPath = if ($null -ne $livePrior) { Get-Sc7Prop $livePrior 'DriverStoreInfPath' } else { $null }
                    if ([string]::IsNullOrWhiteSpace([string]$resolvedPath)) {
                        $resolvedPath = Get-Sc7Prop $gb 'PriorDriverStoreInfPath'
                    }
                    if ($null -eq $livePrior -or [string]::IsNullOrWhiteSpace([string]$resolvedPath)) {
                        $missingPriorErr = "Cannot safely uninstall $targetInf for $(Get-Sc7Prop $gb 'InstanceId'): prior OEM package $pInf is no longer present in Driver Store."
                        break
                    }
                    if (-not (Test-Sc7NameInList -List $priorPaths -Value ([string]$resolvedPath))) {
                        [void]$priorPaths.Add([string]$resolvedPath)
                    }
                } else {
                    $needsInboxScan = $true
                }
            }
            if ($null -ne $missingPriorErr) {
                foreach ($gb in $groupBindings) { $gb['RestoreState'] = 'Incomplete'; $gb['RestoreNote'] = $missingPriorErr }
                [void]$errors.Add($missingPriorErr)
                continue
            }

            # Execute safe uninstall (never /force) and prior re-bind
            $delRes = & $Context.InvokePnputil @('/delete-driver', $targetInf, '/uninstall')
            $delCode = [int](Get-Sc7Prop $delRes 'ExitCode' 1)
            if ($delCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) {
                $rebootRequired = $true
            } elseif ($delCode -ne 0) {
                $errMsg = "pnputil /delete-driver $targetInf /uninstall failed with exit code $delCode."
                foreach ($gb in $groupBindings) { $gb['RestoreState'] = 'Incomplete'; $gb['RestoreNote'] = $errMsg }
                [void]$errors.Add($errMsg)
                continue
            }

            $Component['StagedPackages'] = Remove-Sc7StringFromList -List (Get-Sc7Prop $Component 'StagedPackages' @()) -Value $targetInf

            $rebindFailed = $false
            foreach ($pPath in $priorPaths) {
                $addRes = & $Context.InvokePnputil @('/add-driver', $pPath, '/install')
                $addCode = [int](Get-Sc7Prop $addRes 'ExitCode' 1)
                if ($addCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) {
                    $rebootRequired = $true
                } elseif ($addCode -ne 0 -and $addCode -ne 259) {
                    $rebindFailed = $true
                    [void]$errors.Add("Failed to re-bind prior driver ($pPath): pnputil exit code $addCode.")
                }
            }
            if ($needsInboxScan) {
                $scanRes = & $Context.InvokePnputil @('/scan-devices')
                $scanCode = [int](Get-Sc7Prop $scanRes 'ExitCode' 1)
                if ($scanCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) {
                    $rebootRequired = $true
                } elseif ($scanCode -ne 0) {
                    $rebindFailed = $true
                    [void]$errors.Add("pnputil /scan-devices failed while restoring inbox driver: exit code $scanCode.")
                }
            }

            $postDevs = @(& $Context.GetPnpDevices)
            $postDevMap = @{}
            foreach ($pd in $postDevs) {
                $pidVal = Get-Sc7Prop $pd 'InstanceId'
                if (-not [string]::IsNullOrWhiteSpace([string]$pidVal)) { $postDevMap[([string]$pidVal).ToLowerInvariant()] = $pd }
            }
            foreach ($gb in $groupBindings) {
                $id = [string](Get-Sc7Prop $gb 'InstanceId')
                $devNow = if ($postDevMap.ContainsKey($id.ToLowerInvariant())) { $postDevMap[$id.ToLowerInvariant()] } else { $null }
                if ($null -ne $devNow -and (Test-Sc7DeviceMatchesPrior -Device $devNow -Binding $gb)) {
                    $gb['RestoreState'] = 'Restored'
                    $gb['RestoreNote'] = if ($rebootRequired) { 'Restored via safe uninstall and prior re-bind (reboot required).' } else { 'Restored via safe uninstall and prior re-bind.' }
                } elseif ($delCode -eq $script:SC7_EXIT_REBOOT_REQUIRED -and -not $rebindFailed) {
                    $gb['RestoreState'] = 'Restored'
                    $gb['RestoreNote'] = 'Uninstall scheduled with reboot required (3010); verify binding after reboot.'
                } else {
                    $actInf = if ($null -ne $devNow) { Get-Sc7Prop $devNow 'InfName' '<unbound>' } else { '<missing>' }
                    $actVer = if ($null -ne $devNow) { Get-Sc7Prop $devNow 'DriverVersion' '<none>' } else { '<none>' }
                    $expInf = Get-Sc7Prop $gb 'PriorInf' '<unbound>'
                    $expVer = Get-Sc7Prop $gb 'PriorVersion' '<none>'
                    $errMsg = "Post-rollback verification failed for ${id}: expected $expInf ($expVer), observed $actInf ($actVer)."
                    $gb['RestoreState'] = 'Incomplete'
                    $gb['RestoreNote'] = $errMsg
                    [void]$errors.Add($errMsg)
                }
            }
        }
    }

    # Step 3: Delete any remaining newly-staged OEM packages ONLY if zero devices and zero other components reference them
    $remainingStaged = @(Get-Sc7Prop -Object $Component -Name 'StagedPackages' -Default @())
    if ($remainingStaged.Count -gt 0) {
        $liveStore = @(& $Context.GetDriverStorePackages)
        $liveDevices = @(& $Context.GetPnpDevices)
        $liveStoreNames = @($liveStore | ForEach-Object { ([string](Get-Sc7Prop $_ 'PublishedName')).ToLowerInvariant() })
        foreach ($oem in $remainingStaged) {
            if (-not (Test-Sc7NameInList -List $liveStoreNames -Value $oem)) {
                $Component['StagedPackages'] = Remove-Sc7StringFromList -List (Get-Sc7Prop $Component 'StagedPackages' @()) -Value $oem
                continue
            }
            $boundToOem = @($liveDevices | Where-Object { [string]::Equals([string](Get-Sc7Prop $_ 'InfName'), $oem, [System.StringComparison]::OrdinalIgnoreCase) })
            if ($boundToOem.Count -gt 0) {
                $boundIds = @($boundToOem | ForEach-Object { Get-Sc7Prop $_ 'InstanceId' }) -join ', '
                $msg = "Preserved $oem in Driver Store because device(s) [$boundIds] remain bound to it."
                [void]$notes.Add($msg)
                & $Context.Log "  [keep] $msg"
                continue
            }
            $otherRefs = @(
                @(Get-Sc7Prop $Journal 'Components' @()) | Where-Object {
                    (-not [string]::Equals([string](Get-Sc7Prop $_ 'Name'), [string](Get-Sc7Prop $Component 'Name'), [System.StringComparison]::OrdinalIgnoreCase)) -and
                    (-not (Test-Sc7NameInList -List @('RolledBack', 'AlreadyInstalled') -Value ([string](Get-Sc7Prop $_ 'Status')))) -and
                    ([string]::Equals([string](Get-Sc7Prop $_ 'TargetPublishedName'), $oem, [System.StringComparison]::OrdinalIgnoreCase) -or (Test-Sc7NameInList -List (Get-Sc7Prop $_ 'StagedPackages' @()) -Value $oem))
                }
            )
            if ($otherRefs.Count -gt 0) {
                $msg = "Preserved $oem in Driver Store because another active component references it."
                [void]$notes.Add($msg)
                & $Context.Log "  [keep] $msg"
                continue
            }
            $cleanRes = & $Context.InvokePnputil @('/delete-driver', $oem)
            $cleanCode = [int](Get-Sc7Prop $cleanRes 'ExitCode' 1)
            if ($cleanCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) {
                $rebootRequired = $true
                $Component['StagedPackages'] = Remove-Sc7StringFromList -List (Get-Sc7Prop $Component 'StagedPackages' @()) -Value $oem
            } elseif ($cleanCode -eq 0) {
                $Component['StagedPackages'] = Remove-Sc7StringFromList -List (Get-Sc7Prop $Component 'StagedPackages' @()) -Value $oem
            } else {
                [void]$errors.Add("Failed to remove unreferenced staged package $oem (pnputil exit code $cleanCode).")
            }
        }
    }

    if ($errors.Count -eq 0) {
        $Component['Status'] = 'RolledBack'
        $Component['LastError'] = $null
    } else {
        $Component['Status'] = 'RollbackIncomplete'
        $Component['LastError'] = ($errors.ToArray() -join ' | ')
    }

    return [ordered]@{
        Success        = ($errors.Count -eq 0)
        RebootRequired = $rebootRequired
        Errors         = @($errors.ToArray())
        Notes          = @($notes.ToArray())
    }
}

function New-Sc7BindingEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,
        $PriorDevice,
        [hashtable]$PreStoreMap,
        [string]$TargetPublishedName,
        [string]$TargetVersion,
        [bool]$Attributed
    )
    $priorInf = if ($null -ne $PriorDevice) { Get-Sc7Prop $PriorDevice 'InfName' } else { $null }
    $priorStorePath = $null
    $priorIsInbox = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$priorInf)) {
        if ([string]$priorInf -match '^oem\d+\.inf$') {
            $pKey = ([string]$priorInf).ToLowerInvariant()
            if ($null -ne $PreStoreMap -and $PreStoreMap.ContainsKey($pKey)) {
                $priorStorePath = Get-Sc7Prop $PreStoreMap[$pKey] 'DriverStoreInfPath'
            }
        } else {
            $priorIsInbox = $true
        }
    }
    return [ordered]@{
        InstanceId              = $InstanceId
        PriorInf                = $priorInf
        PriorVersion            = if ($null -ne $PriorDevice) { ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $PriorDevice 'DriverVersion') } else { $null }
        PriorDate               = if ($null -ne $PriorDevice) { ConvertTo-Sc7NormalizedDate -Value (Get-Sc7Prop $PriorDevice 'DriverDate') } else { $null }
        PriorProvider           = if ($null -ne $PriorDevice) { Get-Sc7Prop $PriorDevice 'ProviderName' } else { $null }
        PriorDriverStoreInfPath = $priorStorePath
        PriorIsInbox            = $priorIsInbox
        TargetPublishedName     = $TargetPublishedName
        TargetVersion           = $TargetVersion
        AttributedToTransaction = $Attributed
        RestoreState            = 'Pending'
        RestoreNote             = ''
    }
}

function Invoke-Sc7InstallTransaction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot,
        [switch]$IncludePep,
        [switch]$IncludeStandaloneGpuKmd,
        [string]$JournalPath,
        [switch]$NoRollbackOnFailure,
        $Context
    )
    if ($null -eq $Context) {
        $Context = New-Sc7WindowsContext
    }
    if ([string]::IsNullOrWhiteSpace($JournalPath)) {
        $JournalPath = Get-Sc7DefaultJournalPath
    }

    $selected = @(Get-Sc7SelectedComponents -PackageRoot $PackageRoot -IncludePep:$IncludePep -IncludeStandaloneGpuKmd:$IncludeStandaloneGpuKmd)

    # Phase 0: Preflight all selected files BEFORE any system or journal mutation
    $preflight = Test-Sc7Preflight -Components $selected
    if (-not $preflight['Passed']) {
        foreach ($err in @($preflight['Errors'])) {
            & $Context.Log "ERROR [preflight]: $err"
        }
        & $Context.Log 'Preflight failed; no system files, drivers, or registry values were modified.'
        return [ordered]@{
            ExitCode        = $script:SC7_EXIT_ERROR
            Success         = $false
            RebootRequired  = $false
            PreflightFailed = $true
            Errors          = @($preflight['Errors'])
            RollbackErrors  = @()
            JournalPath     = $JournalPath
        }
    }

    if ($null -ne (Get-Sc7Prop $Context 'TestIsAdministrator')) {
        if (-not [bool](& $Context.TestIsAdministrator)) {
            $msg = 'Administrator privileges are required to install Windows drivers and update HKLM registry keys.'
            & $Context.Log "ERROR: $msg"
            return [ordered]@{
                ExitCode        = $script:SC7_EXIT_ERROR
                Success         = $false
                RebootRequired  = $false
                PreflightFailed = $false
                Errors          = @($msg)
                RollbackErrors  = @()
                JournalPath     = $JournalPath
            }
        }
    }

    # Phase 1: Load existing journal (refuse to discard corrupted journal)
    $journal = $null
    try {
        $journal = Read-Sc7Journal -Path $JournalPath
    } catch {
        & $Context.Log "ERROR: $($_.Exception.Message)"
        return [ordered]@{
            ExitCode        = $script:SC7_EXIT_ERROR
            Success         = $false
            RebootRequired  = $false
            PreflightFailed = $false
            Errors          = @($_.Exception.Message)
            RollbackErrors  = @()
            JournalPath     = $JournalPath
        }
    }

    $currentBootId = [string](& $Context.GetBootId)
    $rebootRequired = $false

    if ($null -eq $journal) {
        $journal = [ordered]@{
            SchemaVersion       = 1
            TransactionId       = [Guid]::NewGuid().ToString()
            CreatedUtc          = [DateTime]::UtcNow.ToString('o')
            UpdatedUtc          = [DateTime]::UtcNow.ToString('o')
            State               = 'InProgress'
            PackageRoot         = $PackageRoot
            RebootRequired      = $false
            PendingRebootBootId = $null
            Sc7Gate             = [ordered]@{ Recorded = $false }
            Components          = @()
        }
    } else {
        $journal['PackageRoot'] = $PackageRoot
        if ([bool](Get-Sc7Prop $journal 'RebootRequired' $false)) {
            $pendingBoot = [string](Get-Sc7Prop $journal 'PendingRebootBootId' '')
            if (-not [string]::IsNullOrWhiteSpace($pendingBoot) -and $pendingBoot -eq $currentBootId) {
                $rebootRequired = $true
            } else {
                $journal['RebootRequired'] = $false
                $journal['PendingRebootBootId'] = $null
            }
        }
    }

    # Clear SC7 gate FIRST before any driver mutation
    $gateRes = Clear-Sc7Gate -Context $Context
    if (-not $gateRes['Success']) {
        & $Context.Log "ERROR: $($gateRes['ErrorMessage'])"
        if ($gateRes['RebootRequired']) {
            $rebootRequired = $true
        }
        return [ordered]@{
            ExitCode        = if ($rebootRequired) { $script:SC7_EXIT_FAIL_REBOOT_REQUIRED } else { $script:SC7_EXIT_ERROR }
            Success         = $false
            RebootRequired  = $rebootRequired
            PreflightFailed = $false
            Errors          = @($gateRes['ErrorMessage'])
            RollbackErrors  = @()
            JournalPath     = $JournalPath
        }
    }

    if (-not [bool](Get-Sc7Prop $journal['Sc7Gate'] 'Recorded' $false)) {
        $journal['Sc7Gate'] = [ordered]@{
            Recorded                    = $true
            PepServiceKeyExisted        = $gateRes['ServiceKeyExisted']
            PepKeyExisted               = $gateRes['PepKeyExisted']
            PriorEnableSc7              = $gateRes['PriorEnableSc7']
            PriorEnableSc7Active        = $gateRes['PriorEnableSc7Active']
            ClearedToZero               = $gateRes['GateCleared']
            LastObservedEnableSc7Active = $gateRes['EnableSc7Active']
        }
    } else {
        $journal['Sc7Gate']['ClearedToZero'] = $gateRes['GateCleared']
        $journal['Sc7Gate']['LastObservedEnableSc7Active'] = $gateRes['EnableSc7Active']
    }

    if ($gateRes['RebootRequired']) {
        $rebootRequired = $true
        $journal['RebootRequired'] = $true
        $journal['PendingRebootBootId'] = $currentBootId
        & $Context.Log "WARNING: EnableSc7 (cfg) set to 0, but runtime EnableSc7Active is still $($gateRes['EnableSc7Active']) (takes effect on next display state notification or reboot)."
    } elseif ($gateRes['GateCleared']) {
        & $Context.Log 'Cleared SC7 opt-in gate (EnableSc7=0) before driver installation.'
    }

    $journal['State'] = 'InProgress'
    Save-Sc7Journal -Journal $journal -Path $JournalPath

    # Phase 2: Per-component snapshot, install, verify, and journal commit
    $sessionMutatedNames = New-Object System.Collections.ArrayList
    $failureMessage = $null
    $installedCount = 0
    $alreadyVerifiedCount = 0

    $maxOrder = 0
    foreach ($ec in @(Get-Sc7Prop $journal 'Components' @())) {
        $ord = [int](Get-Sc7Prop $ec 'InstallOrder' 0)
        if ($ord -gt $maxOrder) { $maxOrder = $ord }
    }

    foreach ($comp in @($preflight['Components'])) {
        $compName = [string]$comp['Name']
        $existingIdx = -1
        $compList = @(Get-Sc7Prop $journal 'Components' @())
        for ($i = 0; $i -lt $compList.Count; $i++) {
            if ([string]::Equals([string](Get-Sc7Prop $compList[$i] 'Name'), $compName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $existingIdx = $i
                break
            }
        }

        $preStore = @(& $Context.GetDriverStorePackages)
        $preDevices = @(& $Context.GetPnpDevices)
        $preStoreMap = @{}
        foreach ($p in $preStore) {
            $pn = ([string](Get-Sc7Prop $p 'PublishedName')).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($pn)) { $preStoreMap[$pn] = $p }
        }
        $preDevMap = @{}
        foreach ($d in $preDevices) {
            $id = Get-Sc7Prop $d 'InstanceId'
            if (-not [string]::IsNullOrWhiteSpace([string]$id)) { $preDevMap[([string]$id).ToLowerInvariant()] = $d }
        }

        $existingEntry = if ($existingIdx -ge 0) { $compList[$existingIdx] } else { $null }
        $existingStatus = if ($null -ne $existingEntry) { [string](Get-Sc7Prop $existingEntry 'Status' '') } else { '' }
        if ($existingStatus -eq 'Installing') {
            Reconcile-Sc7InterruptedComponent -Component $existingEntry -LiveStore $preStore -LiveDevices $preDevices
            Save-Sc7Journal -Journal $journal -Path $JournalPath
        }

        $preserveExisting = ($null -ne $existingEntry) -and (Test-Sc7NameInList -List @('Installed', 'RollbackIncomplete', 'Installing') -Value $existingStatus)
        $compRecord = $null

        if ($preserveExisting) {
            $compRecord = $existingEntry
            $compRecord['RelativeInfPath'] = $comp['RelativeInfPath']
            $compRecord['OriginalName'] = $comp['OriginalName']
            $compRecord['DriverVersion'] = $comp['DriverVersion']
            $compRecord['DriverDate'] = $comp['DriverDate']
            $compRecord['ProviderName'] = $comp['ProviderName']
            $compRecord['InfSha256'] = $comp['InfSha256']
            $compRecord['HardwareIds'] = @($comp['HardwareIds'])
        } else {
            $maxOrder++
            $initialBindings = New-Object System.Collections.ArrayList
            $preMatched = @(Get-Sc7MatchingDevices -Candidate $comp -Devices $preDevices -PresentOnly)
            $seenInit = @{}
            foreach ($md in $preMatched) {
                $mid = [string](Get-Sc7Prop $md 'InstanceId')
                $seenInit[$mid.ToLowerInvariant()] = $true
                [void]$initialBindings.Add((New-Sc7BindingEntry -InstanceId $mid -PriorDevice $md -PreStoreMap $preStoreMap -TargetPublishedName $null -TargetVersion $null -Attributed $false))
            }
            foreach ($pd in $preDevices) {
                $pidVal = [string](Get-Sc7Prop $pd 'InstanceId')
                if ([string]::IsNullOrWhiteSpace($pidVal) -or $seenInit.ContainsKey($pidVal.ToLowerInvariant())) { continue }
                $pInf = Get-Sc7Prop $pd 'InfName'
                if ([string]::IsNullOrWhiteSpace([string]$pInf)) { continue }
                $pKey = ([string]$pInf).ToLowerInvariant()
                if ($preStoreMap.ContainsKey($pKey) -and [string]::Equals([string](Get-Sc7Prop $preStoreMap[$pKey] 'OriginalName'), [string]$comp['OriginalName'], [System.StringComparison]::OrdinalIgnoreCase)) {
                    $seenInit[$pidVal.ToLowerInvariant()] = $true
                    [void]$initialBindings.Add((New-Sc7BindingEntry -InstanceId $pidVal -PriorDevice $pd -PreStoreMap $preStoreMap -TargetPublishedName $null -TargetVersion $null -Attributed $false))
                }
            }

            $compRecord = [ordered]@{
                Name                   = $compName
                RelativeInfPath        = $comp['RelativeInfPath']
                OriginalName           = $comp['OriginalName']
                DriverVersion          = $comp['DriverVersion']
                DriverDate             = $comp['DriverDate']
                ProviderName           = $comp['ProviderName']
                InfSha256              = $comp['InfSha256']
                HardwareIds            = @($comp['HardwareIds'])
                Status                 = 'Installing'
                InstallOrder           = $maxOrder
                LastPnputilExitCode    = $null
                RebootRequired         = $false
                PreStorePublishedNames = @($preStore | ForEach-Object { ([string](Get-Sc7Prop $_ 'PublishedName')).ToLowerInvariant() })
                TargetPublishedName    = $null
                StagedByTransaction    = $false
                StagedPackages         = @()
                DeviceBindings         = @($initialBindings.ToArray())
                LastError              = $null
            }
            $newCompArr = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $compList.Count; $i++) {
                if ($i -eq $existingIdx) {
                    [void]$newCompArr.Add($compRecord)
                } else {
                    [void]$newCompArr.Add($compList[$i])
                }
            }
            if ($existingIdx -lt 0) {
                [void]$newCompArr.Add($compRecord)
            }
            $journal['Components'] = @($newCompArr.ToArray())
            # Write-ahead intent persisted before calling pnputil
            Save-Sc7Journal -Journal $journal -Path $JournalPath
        }

        & $Context.Log ("Installing {0} ({1})..." -f $compName, $comp['InfPath'])
        $pnpRes = & $Context.InvokePnputil @('/add-driver', [string]$comp['InfPath'], '/install')
        $pnpCode = [int](Get-Sc7Prop $pnpRes 'ExitCode' 1)
        $reportedPub = Find-Sc7PublishedNameFromOutput -Text ("{0}`n{1}" -f (Get-Sc7Prop $pnpRes 'StdOut' ''), (Get-Sc7Prop $pnpRes 'StdErr' ''))

        $postStore = @(& $Context.GetDriverStorePackages)
        $postDevices = @(& $Context.GetPnpDevices)

        $newlyStaged = New-Object System.Collections.ArrayList
        foreach ($p in $postStore) {
            $pn = ([string](Get-Sc7Prop $p 'PublishedName')).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($pn) -and -not $preStoreMap.ContainsKey($pn)) {
                [void]$newlyStaged.Add($pn)
            }
        }
        if ($newlyStaged.Count -gt 0) {
            $stagedList = @(Get-Sc7Prop $compRecord 'StagedPackages' @())
            foreach ($ns in $newlyStaged) {
                $stagedList = Add-Sc7UniqueString -List $stagedList -Value $ns
            }
            $compRecord['StagedPackages'] = @($stagedList)
            $compRecord['StagedByTransaction'] = $true
            if (-not (Test-Sc7NameInList -List $sessionMutatedNames -Value $compName)) {
                [void]$sessionMutatedNames.Add($compName)
            }
        }

        $compRecord['LastPnputilExitCode'] = $pnpCode
        if ($pnpCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) {
            $rebootRequired = $true
            $compRecord['RebootRequired'] = $true
            $journal['RebootRequired'] = $true
            $journal['PendingRebootBootId'] = $currentBootId
        }
        if ($newlyStaged.Count -gt 0 -or $pnpCode -eq $script:SC7_EXIT_REBOOT_REQUIRED) {
            Save-Sc7Journal -Journal $journal -Path $JournalPath
        }

        $recordPartialMutations = {
            $changedAny = $false
            $existingBindings = New-Object System.Collections.ArrayList
            foreach ($eb in @(Get-Sc7Prop $compRecord 'DeviceBindings' @())) { [void]$existingBindings.Add($eb) }
            foreach ($pd in $postDevices) {
                $pdInf = Get-Sc7Prop $pd 'InfName'
                if ([string]::IsNullOrWhiteSpace([string]$pdInf)) { continue }
                if (-not (Test-Sc7NameInList -List $newlyStaged -Value ([string]$pdInf))) { continue }
                $pdId = [string](Get-Sc7Prop $pd 'InstanceId')
                $preD = if ($preDevMap.ContainsKey($pdId.ToLowerInvariant())) { $preDevMap[$pdId.ToLowerInvariant()] } else { $null }
                $preInf = if ($null -ne $preD) { Get-Sc7Prop $preD 'InfName' } else { $null }
                if ([string]::Equals([string]$preInf, [string]$pdInf, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $changedAny = $true
                $foundB = $null
                foreach ($eb in $existingBindings) {
                    if ([string]::Equals([string](Get-Sc7Prop $eb 'InstanceId'), $pdId, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $foundB = $eb
                        break
                    }
                }
                if ($null -ne $foundB) {
                    $foundB['TargetPublishedName'] = ([string]$pdInf).ToLowerInvariant()
                    $foundB['TargetVersion'] = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $pd 'DriverVersion')
                    $foundB['AttributedToTransaction'] = $true
                    $foundB['RestoreState'] = 'Pending'
                } else {
                    [void]$existingBindings.Add((New-Sc7BindingEntry -InstanceId $pdId -PriorDevice $preD -PreStoreMap $preStoreMap -TargetPublishedName ([string]$pdInf).ToLowerInvariant() -TargetVersion (ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $pd 'DriverVersion')) -Attributed $true))
                }
            }
            if ($changedAny) {
                $compRecord['DeviceBindings'] = @($existingBindings.ToArray())
                if (-not (Test-Sc7NameInList -List $sessionMutatedNames -Value $compName)) {
                    [void]$sessionMutatedNames.Add($compName)
                }
            }
        }

        if ($pnpCode -notin @(0, $script:SC7_EXIT_REBOOT_REQUIRED, 259)) {
            . $recordPartialMutations
            $failureMessage = "pnputil failed for $compName with exit code $pnpCode."
            if (-not $preserveExisting) {
                $compRecord['Status'] = 'Failed'
            }
            $compRecord['LastError'] = $failureMessage
            Save-Sc7Journal -Journal $journal -Path $JournalPath
            break
        }

        $verify = Test-Sc7ComponentBound -Candidate $comp -StorePackages $postStore -Devices $postDevices -ReportedPublishedName $reportedPub
        if (-not $verify['Verified']) {
            . $recordPartialMutations
            $failureMessage = "Independent verification failed for $compName (pnputil exit $pnpCode): $($verify['Reason'])"
            if (-not $preserveExisting) {
                $compRecord['Status'] = 'Failed'
            }
            $compRecord['LastError'] = $failureMessage
            Save-Sc7Journal -Journal $journal -Path $JournalPath
            break
        }

        # Verification passed: merge attributable device bindings without losing original pre-SC7 prior records
        $targetPub = [string]$verify['TargetPublishedName']
        $compRecord['TargetPublishedName'] = $targetPub
        $bindingsArr = New-Object System.Collections.ArrayList
        foreach ($eb in @(Get-Sc7Prop $compRecord 'DeviceBindings' @())) { [void]$bindingsArr.Add($eb) }

        $anyDeviceChangedThisCall = $false
        foreach ($bDev in @($verify['BoundDevices'])) {
            $bId = [string](Get-Sc7Prop $bDev 'InstanceId')
            $bInf = ([string](Get-Sc7Prop $bDev 'InfName')).ToLowerInvariant()
            $bVer = ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $bDev 'DriverVersion')
            $preD = if ($preDevMap.ContainsKey($bId.ToLowerInvariant())) { $preDevMap[$bId.ToLowerInvariant()] } else { $null }
            $preInf = if ($null -ne $preD) { Get-Sc7Prop $preD 'InfName' } else { $null }
            $preVer = if ($null -ne $preD) { ConvertTo-Sc7NormalizedVersion -Version (Get-Sc7Prop $preD 'DriverVersion') } else { $null }
            $changedThisCall = (-not [string]::Equals([string]$preInf, $bInf, [System.StringComparison]::OrdinalIgnoreCase)) -or ($preVer -ne $bVer)

            $existingB = $null
            foreach ($eb in $bindingsArr) {
                if ([string]::Equals([string](Get-Sc7Prop $eb 'InstanceId'), $bId, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $existingB = $eb
                    break
                }
            }

            if ($changedThisCall) {
                $anyDeviceChangedThisCall = $true
                if ($null -ne $existingB -and [bool](Get-Sc7Prop $existingB 'AttributedToTransaction' $false)) {
                    $existingB['TargetPublishedName'] = $bInf
                    $existingB['TargetVersion'] = $bVer
                    $existingB['RestoreState'] = 'Pending'
                    $existingB['RestoreNote'] = ''
                } elseif ($null -ne $existingB) {
                    $freshB = New-Sc7BindingEntry -InstanceId $bId -PriorDevice $preD -PreStoreMap $preStoreMap -TargetPublishedName $bInf -TargetVersion $bVer -Attributed $true
                    foreach ($k in $freshB.Keys) { $existingB[$k] = $freshB[$k] }
                } else {
                    [void]$bindingsArr.Add((New-Sc7BindingEntry -InstanceId $bId -PriorDevice $preD -PreStoreMap $preStoreMap -TargetPublishedName $bInf -TargetVersion $bVer -Attributed $true))
                }
            } else {
                if ($null -ne $existingB -and [bool](Get-Sc7Prop $existingB 'AttributedToTransaction' $false)) {
                    # Preserve existing pre-SC7 prior binding verbatim across retries
                    $existingB['TargetPublishedName'] = $bInf
                    $existingB['TargetVersion'] = $bVer
                } elseif ($null -eq $existingB) {
                    [void]$bindingsArr.Add((New-Sc7BindingEntry -InstanceId $bId -PriorDevice $preD -PreStoreMap $preStoreMap -TargetPublishedName $bInf -TargetVersion $bVer -Attributed $false))
                }
            }
        }
        $compRecord['DeviceBindings'] = @($bindingsArr.ToArray())

        if ($anyDeviceChangedThisCall -or $newlyStaged.Count -gt 0) {
            if (-not (Test-Sc7NameInList -List $sessionMutatedNames -Value $compName)) {
                [void]$sessionMutatedNames.Add($compName)
            }
            $compRecord['Status'] = 'Installed'
            $installedCount++
            & $Context.Log ("  Verified bound: {0} -> {1} ({2}) on {3} device(s)." -f $compName, $targetPub, $comp['DriverVersion'], @($verify['BoundDevices']).Count)
        } else {
            if ($preserveExisting -and ($existingStatus -eq 'Installed' -or $existingStatus -eq 'RollbackIncomplete')) {
                $compRecord['Status'] = 'Installed'
            } else {
                $compRecord['Status'] = 'AlreadyInstalled'
            }
            $alreadyVerifiedCount++
            & $Context.Log ("  Verified already bound (pnputil {0}): {1} -> {2} ({3}) on {4} device(s)." -f $pnpCode, $compName, $targetPub, $comp['DriverVersion'], @($verify['BoundDevices']).Count)
        }
        $compRecord['LastError'] = $null

        # Immediately assert EnableSc7=0 once tegra214pep service key exists
        if ([string]::Equals($compName, 'tegra214pep', [System.StringComparison]::OrdinalIgnoreCase)) {
            $pepGate = Clear-Sc7Gate -Context $Context
            if (-not $pepGate['Success']) {
                $failureMessage = "Failed to assert EnableSc7=0 after installing tegra214pep: $($pepGate['ErrorMessage'])"
                $compRecord['LastError'] = $failureMessage
                Save-Sc7Journal -Journal $journal -Path $JournalPath
                break
            }
            $journal['Sc7Gate']['ClearedToZero'] = $pepGate['GateCleared']
            $journal['Sc7Gate']['LastObservedEnableSc7Active'] = $pepGate['EnableSc7Active']
            if ($pepGate['RebootRequired']) {
                $rebootRequired = $true
                $journal['RebootRequired'] = $true
                $journal['PendingRebootBootId'] = $currentBootId
            }
        }

        Save-Sc7Journal -Journal $journal -Path $JournalPath
    }

    # Always re-assert EnableSc7=0 if service/parameters key exists
    $postGate = Clear-Sc7Gate -Context $Context
    if (-not $postGate['Success']) {
        if ($null -eq $failureMessage) {
            $failureMessage = $postGate['ErrorMessage']
        }
    } else {
        $journal['Sc7Gate']['ClearedToZero'] = $postGate['GateCleared']
        $journal['Sc7Gate']['LastObservedEnableSc7Active'] = $postGate['EnableSc7Active']
        if ($postGate['RebootRequired']) {
            $rebootRequired = $true
        }
    }

    # Phase 3: Failure rollback OR commit
    if ($null -ne $failureMessage) {
        & $Context.Log "ERROR: $failureMessage"
        $rollbackErrors = New-Object System.Collections.ArrayList
        if (-not $NoRollbackOnFailure -and $sessionMutatedNames.Count -gt 0) {
            & $Context.Log ("Rolling back {0} component(s) mutated during this failed session..." -f $sessionMutatedNames.Count)
            for ($idx = $sessionMutatedNames.Count - 1; $idx -ge 0; $idx--) {
                $rName = [string]$sessionMutatedNames[$idx]
                $rec = $null
                foreach ($c in @(Get-Sc7Prop $journal 'Components' @())) {
                    if ([string]::Equals([string](Get-Sc7Prop $c 'Name'), $rName, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $rec = $c
                        break
                    }
                }
                if ($null -eq $rec) { continue }
                & $Context.Log "  Rolling back $rName..."
                $rbRes = Invoke-Sc7ComponentRollback -Component $rec -Journal $journal -Context $Context
                if ($rbRes['RebootRequired']) {
                    $rebootRequired = $true
                    $journal['RebootRequired'] = $true
                    $journal['PendingRebootBootId'] = $currentBootId
                }
                foreach ($re in @($rbRes['Errors'])) {
                    [void]$rollbackErrors.Add($re)
                    & $Context.Log "  ERROR [rollback $rName]: $re"
                }
                Save-Sc7Journal -Journal $journal -Path $JournalPath
            }
            # Re-assert EnableSc7=0 after rollback if PEP key still exists
            $afterRbGate = Clear-Sc7Gate -Context $Context
            if ($afterRbGate['Success']) {
                $journal['Sc7Gate']['ClearedToZero'] = $afterRbGate['GateCleared']
                $journal['Sc7Gate']['LastObservedEnableSc7Active'] = $afterRbGate['EnableSc7Active']
                if ($afterRbGate['RebootRequired']) {
                    $rebootRequired = $true
                }
            } else {
                [void]$rollbackErrors.Add($afterRbGate['ErrorMessage'])
            }
        }

        $journal['State'] = if ($rollbackErrors.Count -eq 0) { 'FailedRolledBack' } else { 'FailedIncomplete' }
        $journal['RebootRequired'] = $rebootRequired
        $journal['PendingRebootBootId'] = if ($rebootRequired) { $currentBootId } else { $null }
        Save-Sc7Journal -Journal $journal -Path $JournalPath

        $exitCode = if ($rebootRequired) { $script:SC7_EXIT_FAIL_REBOOT_REQUIRED } else { $script:SC7_EXIT_ERROR }
        if ($rebootRequired) {
            & $Context.Log "Installation failed AND reboot is required (exit code $exitCode / ERROR_FAIL_REBOOT_REQUIRED). Pending reboot state preserved in journal: $JournalPath"
        } else {
            & $Context.Log "Installation failed (exit code $exitCode). Transaction journal: $JournalPath"
        }
        return [ordered]@{
            ExitCode        = $exitCode
            Success         = $false
            RebootRequired  = $rebootRequired
            PreflightFailed = $false
            Errors          = @($failureMessage)
            RollbackErrors  = @($rollbackErrors.ToArray())
            JournalPath     = $JournalPath
        }
    }

    $journal['State'] = if ($rebootRequired) { 'CommittedRebootPending' } else { 'Committed' }
    $journal['RebootRequired'] = $rebootRequired
    $journal['PendingRebootBootId'] = if ($rebootRequired) { $currentBootId } else { $null }
    Save-Sc7Journal -Journal $journal -Path $JournalPath

    & $Context.Log ("SC7 candidate drivers verified ({0} updated, {1} already bound; EnableSc7=0 default preserved). Journal: {2}" -f $installedCount, $alreadyVerifiedCount, $JournalPath)
    if ($rebootRequired) {
        & $Context.Log 'Reboot required (exit code 3010).'
        return [ordered]@{
            ExitCode        = $script:SC7_EXIT_REBOOT_REQUIRED
            Success         = $true
            RebootRequired  = $true
            PreflightFailed = $false
            Errors          = @()
            RollbackErrors  = @()
            JournalPath     = $JournalPath
        }
    }
    return [ordered]@{
        ExitCode        = $script:SC7_EXIT_OK
        Success         = $true
        RebootRequired  = $false
        PreflightFailed = $false
        Errors          = @()
        RollbackErrors  = @()
        JournalPath     = $JournalPath
    }
}

function Invoke-Sc7RestoreTransaction {
    param(
        [string]$JournalPath,
        $Context
    )
    if ($null -eq $Context) {
        $Context = New-Sc7WindowsContext
    }
    if ([string]::IsNullOrWhiteSpace($JournalPath)) {
        $JournalPath = Get-Sc7DefaultJournalPath
    }

    $rebootRequired = $false
    $errors = New-Object System.Collections.ArrayList
    $componentResults = New-Object System.Collections.ArrayList
    $hadStandaloneGpuKmd = $false

    # Step 1: Clear SC7 gate first and inspect live EnableSc7Active
    $gateRes = Clear-Sc7Gate -Context $Context
    if (-not $gateRes['Success']) {
        & $Context.Log "ERROR: $($gateRes['ErrorMessage'])"
        [void]$errors.Add($gateRes['ErrorMessage'])
        if ($gateRes['RebootRequired']) { $rebootRequired = $true }
        return [ordered]@{
            ExitCode            = if ($rebootRequired) { $script:SC7_EXIT_FAIL_REBOOT_REQUIRED } else { $script:SC7_EXIT_ERROR }
            Success             = $false
            RebootRequired      = $rebootRequired
            JournalFound        = $false
            GateResult          = $gateRes
            ComponentResults    = @()
            Errors              = @($errors.ToArray())
            HadStandaloneGpuKmd = $false
            JournalPath         = $JournalPath
        }
    }

    if ($gateRes['KeyPresent']) {
        if ($gateRes['RebootRequired']) {
            $rebootRequired = $true
            & $Context.Log ("Persisted EnableSc7 (cfg) = 0, but runtime EnableSc7Active is still {0}. SC7 deactivation takes effect on the next display state notification or reboot (reboot required)." -f $gateRes['EnableSc7Active'])
        } else {
            $activeLabel = if ($null -eq $gateRes['EnableSc7Active']) { 'not set' } else { [string]$gateRes['EnableSc7Active'] }
            & $Context.Log "Verified SC7 gate disabled: EnableSc7 (cfg) = 0 (EnableSc7Active = $activeLabel). Platform idle falls back to C7/CC6 or WFI."
        }
    } else {
        & $Context.Log "Tegra214Power service/parameters key is not present ($($script:Sc7PepParametersKey)); SC7 PEP gate is not configured on this system."
    }

    if ($null -ne (Get-Sc7Prop $Context 'TestIsAdministrator')) {
        if (-not [bool](& $Context.TestIsAdministrator)) {
            $msg = 'Administrator privileges are required to revert Windows drivers and update HKLM registry keys.'
            & $Context.Log "ERROR: $msg"
            [void]$errors.Add($msg)
            return [ordered]@{
                ExitCode            = if ($rebootRequired) { $script:SC7_EXIT_FAIL_REBOOT_REQUIRED } else { $script:SC7_EXIT_ERROR }
                Success             = $false
                RebootRequired      = $rebootRequired
                JournalFound        = $false
                GateResult          = $gateRes
                ComponentResults    = @()
                Errors              = @($errors.ToArray())
                HadStandaloneGpuKmd = $false
                JournalPath         = $JournalPath
            }
        }
    }

    # Step 2: Load transaction journal
    $journal = $null
    try {
        $journal = Read-Sc7Journal -Path $JournalPath
    } catch {
        & $Context.Log "ERROR: $($_.Exception.Message)"
        [void]$errors.Add($_.Exception.Message)
        return [ordered]@{
            ExitCode            = if ($rebootRequired) { $script:SC7_EXIT_FAIL_REBOOT_REQUIRED } else { $script:SC7_EXIT_ERROR }
            Success             = $false
            RebootRequired      = $rebootRequired
            JournalFound        = $false
            GateResult          = $gateRes
            ComponentResults    = @()
            Errors              = @($errors.ToArray())
            HadStandaloneGpuKmd = $false
            JournalPath         = $JournalPath
        }
    }

    if ($null -eq $journal) {
        & $Context.Log "No SC7 install transaction journal found at '$JournalPath'; no driver packages were automatically reverted."
        $exitNoJournal = if ($rebootRequired) { $script:SC7_EXIT_REBOOT_REQUIRED } else { $script:SC7_EXIT_OK }
        return [ordered]@{
            ExitCode            = $exitNoJournal
            Success             = $true
            RebootRequired      = $rebootRequired
            JournalFound        = $false
            GateResult          = $gateRes
            ComponentResults    = @()
            Errors              = @()
            HadStandaloneGpuKmd = $false
            JournalPath         = $JournalPath
        }
    }

    $currentBootId = [string](& $Context.GetBootId)
    if ([bool](Get-Sc7Prop $journal 'RebootRequired' $false)) {
        $pendingBoot = [string](Get-Sc7Prop $journal 'PendingRebootBootId' '')
        if (-not [string]::IsNullOrWhiteSpace($pendingBoot) -and $pendingBoot -eq $currentBootId) {
            $rebootRequired = $true
        }
    }

    # Step 3: Revert attributable components in reverse installation order
    $candidates = @(
        @(Get-Sc7Prop $journal 'Components' @()) | Where-Object {
            $st = [string](Get-Sc7Prop $_ 'Status' '')
            $stagedCnt = @(Get-Sc7Prop $_ 'StagedPackages' @()).Count
            (Test-Sc7NameInList -List @('Installed', 'Installing', 'Failed', 'RollbackIncomplete') -Value $st) -or
            ($stagedCnt -gt 0 -and [bool](Get-Sc7Prop $_ 'StagedByTransaction' $false))
        } | Sort-Object -Property @{ Expression = { [int](Get-Sc7Prop $_ 'InstallOrder' 0) }; Descending = $true }
    )

    foreach ($rec in $candidates) {
        $rName = [string](Get-Sc7Prop $rec 'Name')
        if ([string]::Equals($rName, 'tegragpurender', [System.StringComparison]::OrdinalIgnoreCase)) {
            $hadStandaloneGpuKmd = $true
        }
        & $Context.Log "Reverting component $rName..."
        $rbRes = Invoke-Sc7ComponentRollback -Component $rec -Journal $journal -Context $Context
        if ($rbRes['RebootRequired']) {
            $rebootRequired = $true
            $journal['RebootRequired'] = $true
            $journal['PendingRebootBootId'] = $currentBootId
        }
        foreach ($re in @($rbRes['Errors'])) {
            [void]$errors.Add($re)
            & $Context.Log "  ERROR [$rName]: $re"
        }
        [void]$componentResults.Add([ordered]@{
            Name    = $rName
            Status  = Get-Sc7Prop $rec 'Status'
            Success = $rbRes['Success']
            Errors  = @($rbRes['Errors'])
            Notes   = @($rbRes['Notes'])
        })
        Save-Sc7Journal -Journal $journal -Path $JournalPath
    }

    # Re-assert EnableSc7=0 if PEP service/parameters key still exists after driver rollbacks
    $postGate = Clear-Sc7Gate -Context $Context
    if (-not $postGate['Success']) {
        [void]$errors.Add($postGate['ErrorMessage'])
        & $Context.Log "ERROR: $($postGate['ErrorMessage'])"
    } else {
        $gateRes = $postGate
        if ($postGate['RebootRequired']) {
            $rebootRequired = $true
        }
    }

    $journal['State'] = if ($errors.Count -eq 0) { 'Restored' } else { 'RestoreIncomplete' }
    $journal['RebootRequired'] = $rebootRequired
    $journal['PendingRebootBootId'] = if ($rebootRequired) { $currentBootId } else { $null }
    if ($journal['Sc7Gate'] -is [System.Collections.IDictionary]) {
        $journal['Sc7Gate']['ClearedToZero'] = $gateRes['GateCleared']
        $journal['Sc7Gate']['LastObservedEnableSc7Active'] = $gateRes['EnableSc7Active']
    }
    Save-Sc7Journal -Journal $journal -Path $JournalPath

    $exitCode = if ($errors.Count -eq 0) {
        if ($rebootRequired) { $script:SC7_EXIT_REBOOT_REQUIRED } else { $script:SC7_EXIT_OK }
    } else {
        if ($rebootRequired) { $script:SC7_EXIT_FAIL_REBOOT_REQUIRED } else { $script:SC7_EXIT_ERROR }
    }

    return [ordered]@{
        ExitCode            = $exitCode
        Success             = ($errors.Count -eq 0)
        RebootRequired      = $rebootRequired
        JournalFound        = $true
        GateResult          = $gateRes
        ComponentResults    = @($componentResults.ToArray())
        Errors              = @($errors.ToArray())
        HadStandaloneGpuKmd = $hadStandaloneGpuKmd
        JournalPath         = $JournalPath
    }
}

Export-ModuleMember -Function @(
    'New-Sc7WindowsContext',
    'Read-Sc7InfMetadata',
    'Get-Sc7SelectedComponents',
    'Test-Sc7Preflight',
    'Get-Sc7DefaultJournalPath',
    'Read-Sc7Journal',
    'Save-Sc7Journal',
    'Clear-Sc7Gate',
    'Test-Sc7ComponentBound',
    'Invoke-Sc7ComponentRollback',
    'Invoke-Sc7InstallTransaction',
    'Invoke-Sc7RestoreTransaction'
)
