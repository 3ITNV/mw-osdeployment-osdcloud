<#
.SYNOPSIS
    Collects all logs of an OSDCloud deployment onto the OSDCloudUSB stick and checks the result.

.DESCRIPTION
    Purpose:
        Run on a deployed device (in Windows, elevated PowerShell) with the OSDCloud stick plugged in,
        for example from the root of the stick:
            PowerShell -ExecutionPolicy Bypass -File E:\Collect-DeploymentLogs.ps1

        1. Copies the deployment, SetupComplete, Windows Update, debloat, Office, DISM/CBS and
           Setup/OOBE logs to <USB>:\Logs\<computername>-<date>.
        2. Checks the result and writes _summary.txt (also shown on screen):
             - Windows build (cumulative update applied?)
             - Language packs nl-NL / fr-FR updated to the same build as Windows
             - Autopilot profile language setting (a set language hides the OOBE language page)
             - Microsoft 365 Apps installed
             - Feature update hold (25H2) removed again
             - Debloat ran
             - Wi-Fi password left behind by OSDCloud in SetupComplete.ps1
        Read-only on the device: it changes nothing there. Wi-Fi passwords are redacted in the copies.
        The logs contain device information only. Never commit them to a repository.

    Author:  <Your name> - 3-IT

.NOTES
    Version history
    Version  Date        Author          Change
    -------  ----------  --------------  ------------------------------------------------------------
    1.0.0    2026-10-24  <Your name>     Initial version (troubleshooting Office + OOBE language)
    1.1.0    2026-10-24  <Your name>     Checks with OK/FAIL summary (build, languages, Office, feature
                                         update hold, debloat, Wi-Fi password); DISM/CBS and Windows
                                         Update logs; faster (no Get-WindowsCapability)
    1.1.1    2026-10-25  <Your name>     Check the cumulative update fallback (Install-LCUOnline log)
    1.1.2    2026-10-25  <Your name>     Office check accepts O365BusinessRetail (how the NoTeams SKU registers)
    1.2.0    2026-10-25  <Your name>     Language check fixed: compares the language pack version with the
                                         Windows build ("Partially localized" in DISM is normal); languages
                                         not chosen are INFO; reports the Autopilot profile language setting
    1.2.1    2026-10-25  <Your name>     Wi-Fi password check covers all OSDCloud script/log folders and
                                         ignores OSD's "*****" mask and the deploy script's removal marker
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

#region Configuration ------------------------------------------------------------------------------
$UsbLabel        = 'OSDCloudUSB'
$ExpectedLangs   = @('nl-NL', 'fr-FR')
$OfficeProductId = 'O365BusinessEEANoTeamsRetail'
$PolicyKey       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$HoldValues      = @('ProductVersion', 'TargetReleaseVersion', 'TargetReleaseVersionInfo')
# Log folders to copy: name in the output folder = path on the device
$Sources = [ordered]@{
    'OSDCloud-Logs'      = 'C:\OSDCloud\Logs'                     # Deploy, Install-M365Apps, Remove-FeatureUpdateBlock
    'Temp-osdcloud-logs' = 'C:\Windows\Temp\osdcloud-logs'        # OSDCloud SetupComplete.log (Windows Update)
    'Setup-Scripts'      = 'C:\Windows\Setup\Scripts'             # SetupComplete.cmd/.ps1 written by OSDCloud
    'Our-SetupComplete'  = 'C:\OSDCloud\Scripts\SetupComplete'    # Our SetupComplete.cmd (debloat, Office, hold removal)
    'Debloat'            = 'C:\ProgramData\Debloat'
    'Office-setup'       = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\M365AppsBusiness'
    'Panther'            = 'C:\Windows\Panther'                   # Setup / OOBE logs
    'DISM'               = 'C:\Windows\Logs\DISM'
    'CBS'                = 'C:\Windows\Logs\CBS'
}
#endregion -----------------------------------------------------------------------------------------

#region Helper functions ---------------------------------------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[string]
function Add-Result {
    param([ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Check, [string]$Detail)
    $line = '{0,-5} {1,-30} {2}' -f $Status, $Check, $Detail
    $script:Results.Add($line)
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$Status]
    Write-Host $line -ForegroundColor $color
}
#endregion -----------------------------------------------------------------------------------------

#region Main ---------------------------------------------------------------------------------------
$usb = (Get-Volume | Where-Object { $_.FileSystemLabel -eq $UsbLabel -and $_.DriveLetter } | Select-Object -First 1).DriveLetter
if (-not $usb) { throw "$UsbLabel stick not found. Plug it in and run this script again." }
$out = "$($usb):\Logs\$($env:COMPUTERNAME)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$null = New-Item -Path $out -ItemType Directory -Force
Write-Host "Collecting logs to $out (takes 1-3 minutes) ..." -ForegroundColor Cyan

#--- 1. Copy logs (missing folders are reported, not an error) ----------------------------------------
foreach ($name in $Sources.Keys) {
    $path = $Sources[$name]
    if (-not (Test-Path $path)) { "MISSING  $path" | Out-File "$out\_collected.txt" -Append; continue }
    Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.log', '.txt', '.cmd', '.ps1', '.xml', '.etl', '.cab' -and $_.Length -lt 300MB } |
        ForEach-Object {
            $target = Join-Path (Join-Path $out $name) $_.FullName.Substring($path.Length).TrimStart('\')
            $null = New-Item -Path (Split-Path $target) -ItemType Directory -Force
            Copy-Item -Path $_.FullName -Destination $target -Force -ErrorAction SilentlyContinue
        }
    "OK       $path" | Out-File "$out\_collected.txt" -Append
}

# Windows Update log (built from ETL traces, takes a moment)
Get-WindowsUpdateLog -LogPath "$out\WindowsUpdate.log" *> $null

# Redact Wi-Fi passwords: OSDCloud writes 'Set-WiFi -SSID "..." -PSK "<password>"' in plain text into
# C:\Windows\Setup\Scripts\SetupComplete.ps1 (and it can end up in transcripts).
Get-ChildItem -Path $out -Recurse -File | Where-Object { $_.Extension -in '.log', '.txt', '.cmd', '.ps1', '.xml' } | ForEach-Object {
    $text = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
    if ($text -and $text -match '-PSK\s+"') {
        $text -replace '(-PSK\s+")[^"]*(")', '$1***REDACTED***$2' | Set-Content -Path $_.FullName -NoNewline
    }
}

#--- 2. Status information --------------------------------------------------------------------------
$intl = dism.exe /online /get-intl | Out-String
$langPacks = @(Get-WindowsPackage -Online | Where-Object PackageName -like '*LanguagePack*')
& {
    '=== dism /online /get-intl'; $intl
    '=== Language packs (DISM)'
    $langPacks | Format-Table PackageName, PackageState -AutoSize | Out-String -Width 300
    '=== Get-InstalledLanguage'; Get-InstalledLanguage | Out-String -Width 300
    '=== Get-WinUserLanguageList'; Get-WinUserLanguageList | Format-Table LanguageTag, Autonym -AutoSize | Out-String
} *> "$out\languages.txt"

$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
& {
    '=== Click-to-Run configuration'
    $c2r | Select-Object ProductReleaseIds, Platform, VersionToReport, UpdateChannel, CDNBaseUrl | Format-List | Out-String
    '=== Installed programs matching Office/365'
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Office|365' } | Select-Object DisplayName, DisplayVersion | Format-Table -AutoSize | Out-String
} *> "$out\office.txt"

$policy = Get-ItemProperty -Path $PolicyKey -ErrorAction SilentlyContinue
& {
    "=== $PolicyKey (local policy; our hold must be gone)"
    if ($policy) { $policy | Format-List | Out-String } else { '(key does not exist)' }
    '=== Intune/MDM Update policies (PolicyManager, for information)'
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update' -ErrorAction SilentlyContinue | Format-List | Out-String
} *> "$out\featureupdate.txt"

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
& {
    "=== Windows: $($os.ProductName) $($os.DisplayVersion) build $($os.CurrentBuild).$($os.UBR)"
    '=== Installed updates'; Get-HotFix | Sort-Object InstalledOn | Format-Table HotFixID, Description, InstalledOn -AutoSize | Out-String
} *> "$out\windows.txt"

#--- 3. Checks ---------------------------------------------------------------------------------------
Write-Host ''
Add-Result INFO 'Device' "$((Get-CimInstance Win32_ComputerSystem).Model), serial $((Get-CimInstance Win32_BIOS).SerialNumber)"
Add-Result INFO 'Windows' "$($os.DisplayVersion) build $($os.CurrentBuild).$($os.UBR)"

# Languages: an added language pack must be updated together with Windows (same build as the OS,
# not its RTM version 10.0.26100.1). Note: DISM always lists added languages as "Partially localized
# language, MUI type"; that is normal and says nothing about the OOBE language choice.
foreach ($lang in $ExpectedLangs) {
    $versions = @($langPacks | Where-Object PackageState -eq 'Installed' | ForEach-Object {
        if ($_.PackageName -match "~$([regex]::Escape($lang))~(\d+\.\d+\.\d+\.\d+)$") { [version]$Matches[1] } })
    $newest = $versions | Sort-Object -Descending | Select-Object -First 1
    if (-not $newest) { Add-Result INFO "Language $lang" 'not installed (not chosen in the menu?)' }
    elseif ($newest.Revision -eq [int]$os.UBR) { Add-Result OK "Language $lang" "language pack at $newest (matches Windows)" }
    elseif ($newest -le [version]'10.0.26100.1') { Add-Result FAIL "Language $lang" "language pack still at RTM $newest - cumulative update not applied" }
    else { Add-Result WARN "Language $lang" "language pack at $newest, Windows at build $($os.CurrentBuild).$($os.UBR)" }
}

# Autopilot: a profile with "Language (Region)" set makes OOBE skip the language page (Microsoft Learn,
# Autopilot self-deploying "Validation"). File and field names are not officially documented; they come
# from Michael Niehaus' Convert-WindowsAutopilotProfile. Only the language/region values are reported:
# the file also holds tenant details, so it is not copied.
$ztd = 'C:\Windows\ServiceState\wmansvc\AutopilotDDSZTDFile.json'
if (Test-Path $ztd) {
    $profileJson = Get-Content $ztd -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    $apLanguage = $profileJson.CloudAssignedLanguage
    $apRegion   = $profileJson.CloudAssignedRegion
    if ($apLanguage -or $apRegion) {
        Add-Result WARN 'Autopilot profile' "sets language '$apLanguage' / region '$apRegion': OOBE skips the language page (Intune: Language (Region) = User select)"
    }
    else { Add-Result INFO 'Autopilot profile' 'found, no language set in it' }
}
else { Add-Result INFO 'Autopilot profile' 'no profile file found on this device' }

# Cumulative update fallback (only when the offline install in WinPE failed)
$lcuLog = Get-ChildItem 'C:\OSDCloud\Logs' -Filter 'Install-LCUOnline_*.log' -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($lcuLog) {
    if (Select-String -Path $lcuLog.FullName -Pattern '^OK: cumulative update installed' -Quiet) {
        Add-Result OK 'Cumulative update' 'installed in SetupComplete (fallback, offline install had failed)'
    }
    else { Add-Result FAIL 'Cumulative update' "fallback in SetupComplete failed - see $($lcuLog.Name) and dism-online-LCU.log" }
}
else { Add-Result INFO 'Cumulative update' 'applied offline in WinPE (no fallback needed), or older deploy script' }

# Office
# "Without Teams" variants are registered under the base product (O365BusinessEEANoTeamsRetail -> O365BusinessRetail)
$officeNames = @($OfficeProductId, ($OfficeProductId -replace 'EEANoTeams|NoTeams', '')) | Select-Object -Unique
$officeFound = @($c2r.ProductReleaseIds -split ',' | Where-Object { $_ -in $officeNames })
if ($c2r.ProductReleaseIds -and $officeFound.Count) {
    Add-Result OK 'Microsoft 365 Apps' "$($officeFound -join ', ') $($c2r.VersionToReport)"
}
elseif (Test-Path 'C:\OSDCloud\Scripts\SetupComplete\Office') {
    Add-Result FAIL 'Microsoft 365 Apps' 'staged but not installed - see OSDCloud-Logs\Install-M365Apps_*.log'
}
else { Add-Result INFO 'Microsoft 365 Apps' 'not staged (deployed with -SkipOffice?)' }

# Feature update hold must be gone
$left = @($HoldValues | Where-Object { $null -ne $policy.$_ })
if ($left.Count -eq 0) { Add-Result OK 'Feature update hold' 'removed (no local TargetReleaseVersion policy)' }
else { Add-Result FAIL 'Feature update hold' "STILL PRESENT: $(($left | ForEach-Object { "$_=$($policy.$_)" }) -join ', ')" }
$holdLog = Get-ChildItem 'C:\OSDCloud\Logs' -Filter 'Remove-FeatureUpdateBlock_*.log' -ErrorAction SilentlyContinue | Select-Object -Last 1
if (-not $holdLog) { Add-Result WARN 'Hold removal log' 'Remove-FeatureUpdateBlock log not found (older deploy script?)' }

# Debloat
if (Test-Path 'C:\ProgramData\Debloat\Debloat.log') {
    $done = Select-String -Path 'C:\ProgramData\Debloat\Debloat.log' -Pattern 'Total Script Duration' -Quiet
    if ($done) { Add-Result OK 'Debloat' 'ran to the end' } else { Add-Result WARN 'Debloat' 'log exists but the script did not finish' }
}
else { Add-Result FAIL 'Debloat' 'C:\ProgramData\Debloat\Debloat.log not found' }

# Wi-Fi password left behind by OSDCloud (plain text, readable by local administrators). A real value,
# not OSD's own "*****" mask and not the marker the deploy script (1.7.0+) leaves after removing it.
$pskPattern = '-PSK\s+"(?!\*+"|<removed after deployment>")[^"]+"'
$pskFiles = @(Get-ChildItem -Path 'C:\Windows\Setup\Scripts', 'C:\OSDCloud\Logs', 'C:\Windows\Temp\osdcloud-logs' `
    -Recurse -File -Include *.ps1, *.cmd, *.log, *.txt, *.json -ErrorAction SilentlyContinue |
    Where-Object { Select-String -Path $_.FullName -Pattern $pskPattern -Quiet })
if ($pskFiles.Count) { Add-Result WARN 'Wi-Fi password' "still in plain text in $($pskFiles.FullName -join ', ')" }
else { Add-Result OK 'Wi-Fi password' 'no plain-text Wi-Fi password found on the device' }

$script:Results | Out-File "$out\_summary.txt"
Write-Host ''
Write-Host "Done. Logs and _summary.txt saved to $out" -ForegroundColor Green
Write-Host 'Safely remove the stick and bring it back to the build PC.' -ForegroundColor Green
#endregion -----------------------------------------------------------------------------------------
