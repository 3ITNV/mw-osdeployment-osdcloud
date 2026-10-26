<#
.SYNOPSIS
    OSDCloud zero-touch deployment: Windows 11 25H2 Pro (Retail) with English, Dutch and French
    selectable during OOBE.

.DESCRIPTION
    Purpose:
        Runs in OSDCloud WinPE. Deploys Windows 11 25H2 Pro (Retail, en-US base image) without any
        driver packs, then services the freshly applied OS offline:
          1. Injects ONLY the network (Ethernet/Wi-Fi) drivers that WinPE itself is using, so the
             device has network at first boot / OOBE.
          2. Adds the chosen language packs (default nl-NL and fr-FR, -Languages to choose) +
             language features from a local repository on the OSDCloud USB stick. With more than one
             language installed, OOBE asks the user to pick a language, unless an Autopilot profile
             sets "Language (Region)" (then OOBE skips the language page).
          3. Re-applies the latest cumulative update (LCU) after the language packs, as Microsoft
             requires (otherwise the language packs stay at their RTM version). Only when languages
             are added; then the pre-flight stops without it. The language pack versions are checked.
          3b. Holds feature updates at 25H2 (Windows Update policy in the offline image), so
             Windows Update during SetupComplete does not install 26H2. Lifted before OOBE.
          4. Stages Andrew Taylor's RemoveBloat.ps1 (debloat, always) and the Microsoft 365 Apps
             install (same setup.exe + XML as our Intune package, skip with -SkipOffice). Both run at
             the end of SetupComplete, debloat first.
        All other drivers (and firmware offered through Windows Update) are installed by Windows
        Update during SetupComplete, before OOBE starts.

    Author:  <Your name> - 3-IT

    Requirements:
        - OSDCloud boot media with network drivers in WinPE (Edit-OSDCloudWinPE -CloudDriver ...)
        - OSD PowerShell module (tested against source of OSD 26.10.16.1)
        - Language repository on the USB stick, created with Prepare-OSDCloudLanguageRepo.ps1:
              <USB>:\OSDCloud\Languages\LOF\   language packs, FODs and metadata
              <USB>:\OSDCloud\Languages\LCU\   latest cumulative update (.msu) for 25H2 x64
        - Office files on the USB stick, copied by Initialize-OSDCloudBuild.ps1:
              <USB>:\OSDCloud\Office\          setup.exe, installM365BP.xml, Install-M365Apps.ps1
              <USB>:\OSDCloud\Debloat\         RemoveBloat.ps1 (pinned version, SHA-256 checked)

    WARNING: This script is ZERO TOUCH. It wipes the internal disk WITHOUT asking.
             Run it with -WhatIf first to do the pre-flight checks only.

.PARAMETER SkipOffice
    Do not install Microsoft 365 Apps (for customers without Microsoft 365 Apps licences).

.PARAMETER Languages
    Extra display languages, comma separated, for example 'nl-NL,fr-FR' or 'nl-NL'. Use 'none' for
    English only (faster: no language packs and no cumulative update from the stick). Default: all
    languages in $Config.ExtraLanguages. A single string, because the menu passes it with -File.

.EXAMPLE
    # Pre-flight checks only, nothing is wiped or installed
    .\Deploy-OSDCloud-Win11-25H2.ps1 -WhatIf

.EXAMPLE
    # Full deployment (wipes the disk!)
    .\Deploy-OSDCloud-Win11-25H2.ps1

.EXAMPLE
    # Full deployment without Microsoft 365 Apps
    .\Deploy-OSDCloud-Win11-25H2.ps1 -SkipOffice

.EXAMPLE
    # English + Dutch only
    .\Deploy-OSDCloud-Win11-25H2.ps1 -Languages 'nl-NL'

.NOTES
    Version history
    Version  Date        Author          Change
    -------  ----------  --------------  ------------------------------------------------------------
    1.0.0    2026-10-23  <Your name>     Initial version
    1.1.0    2026-10-23  <Your name>     Install Microsoft 365 Apps during SetupComplete; -SkipOffice;
                                         pre-flight internet check before the disk is wiped;
                                         outdated LCU on the stick is a warning instead of a failure
    1.2.0    2026-10-23  <Your name>     Exit code 1 on failure (used by Start-OSDCloudDeployMenu.ps1)
    1.3.0    2026-10-23  <Your name>     Always run Andrew Taylor's RemoveBloat.ps1 in SetupComplete,
                                         before the Office install
    1.3.1    2026-10-23  <Your name>     Fix: network drivers in use are read from the registry; WMI class
                                         Win32_PnPSignedDriver does not exist in WinPE ("Invalid class")
    1.4.0    2026-10-24  <Your name>     Cumulative update is required again (pre-flight stops without it:
                                         no OOBE language choice); warn when the checkpoint .msu may be
                                         missing; hold feature updates at 25H2 during the deployment
                                         (Windows Update offered 26H2), lifted before OOBE
    1.5.0    2026-10-25  <Your name>     Fallback when the offline LCU install fails (WinPE update agent too
                                         old for the KB5043080 checkpoint: 0x80070228, XML parse error):
                                         install it online at the start of SetupComplete; dism.log saved
    1.6.0    2026-10-25  <Your name>     -Languages (choose extra languages per deployment, 'none' = English
                                         only). Online LCU fallback removed: the KB5043080 checkpoint fails
                                         online too (its own 2024 update agent cannot parse the 25H2 compDB),
                                         while the target LCU does update the language packs. Instead the
                                         language pack versions are verified after the LCU step.
    1.7.0    2026-10-25  <Your name>     Remove the plain-text Wi-Fi password OSDCloud leaves in
                                         C:\Windows\Setup\Scripts\SetupComplete.ps1 (last SetupComplete step)
#>

#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipOffice,
    [string]$Languages
)

$ErrorActionPreference = 'Stop'

#region Configuration ------------------------------------------------------------------------------
# Change these values here instead of further down in the script.
$Config = [ordered]@{
    OSName               = 'Windows 11 25H2 x64'
    OSEdition            = 'Pro'
    OSActivation         = 'Retail'
    OSLanguage           = 'en-us'                  # Base language of the downloaded image
    ExtraLanguages       = @('nl-NL', 'fr-FR')      # Default extra languages; -Languages overrides per deployment
    # Language features (FODs) per language. 'Basic' is required, the rest is optional:
    # if one does not exist for a language, the script logs a warning and continues.
    LanguageFeatures     = @('Basic', 'Handwriting', 'OCR', 'Speech', 'TextToSpeech')
    RepoRelativePath     = 'OSDCloud\Languages'      # Folder on the USB stick
    # Checked BEFORE the disk is wiped. OSDCloud wipes first and downloads Windows after that,
    # so without internet the device would end up with an empty disk.
    WindowsDownloadHost  = 'dl.delivery.mp.microsoft.com:80'   # Windows image (from the OSD catalog)
    OfficeDownloadHost   = 'officecdn.microsoft.com:443'       # Microsoft 365 Apps
    OfficeRelativePath   = 'OSDCloud\Office'         # Folder on the USB stick
    OfficeFiles          = @('setup.exe', 'installM365BP.xml', 'Install-M365Apps.ps1')
    DebloatRelativePath  = 'OSDCloud\Debloat'        # Folder on the USB stick
    DebloatFile          = 'RemoveBloat.ps1'         # Andrew Taylor, put there by Initialize-OSDCloudBuild.ps1
    # OSDCloud runs SetupComplete.cmd from this folder at the end of SetupComplete (after Windows Update)
    SetupCompleteFolder  = 'C:\OSDCloud\Scripts\SetupComplete'
    LogFolder            = 'C:\OSDCloud\Logs'
    ScratchFolder        = 'C:\OSDCloud\Scratch'
    NetDriverFolder      = 'C:\Drivers\Net'
    # Hold feature updates during the deployment (Windows Update in SetupComplete offered 26H2).
    # Lifted again just before OOBE, so Intune feature update policies decide afterwards.
    FeatureUpdateProduct = 'Windows 11'
    FeatureUpdateTarget  = '25H2'
}

# -Languages overrides the default list (one string, because powershell.exe -File passes no arrays)
if ($PSBoundParameters.ContainsKey('Languages')) {
    $Config.ExtraLanguages = @(
        if ($Languages -ne 'none') { $Languages -split '[,; ]+' | Where-Object { $_ } }
    )
}

# OSDCloud settings. $Global:MyOSDCloud is merged LAST by Invoke-OSDCloud, so it overrides defaults.
$Global:MyOSDCloud = [ordered]@{
    ZTI                  = [bool]$true    # No prompts
    ClearDiskConfirm     = [bool]$false   # No disk wipe confirmation
    Restart              = [bool]$false   # We restart ourselves after offline servicing
    DriverPackName       = 'None'         # No driver packs at all
    MSCatalogFirmware    = [bool]$true    # Allow firmware (see note in README / chat)
    WindowsUpdate        = [bool]$true    # Install updates during SetupComplete
    WindowsUpdateDrivers = [bool]$true    # Install all other drivers + firmware from Windows Update
    OEMActivation        = [bool]$true    # Activate Pro with the key embedded in the firmware (if any)
}
#endregion -----------------------------------------------------------------------------------------

#region Helper functions ---------------------------------------------------------------------------
function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Find-LanguageRepo {
    # Looks on every drive for <drive>:\OSDCloud\Languages\LOF.
    # Called twice: drive letters can change after OSDCloud partitions the internal disk.
    param([Parameter(Mandatory)][string]$RelativePath)

    $roots = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -ne 'X:\' } |
        Select-Object -ExpandProperty Root
    foreach ($root in $roots) {
        $candidate = Join-Path $root $RelativePath
        if (Test-Path (Join-Path $candidate 'LOF')) { return $candidate }
    }
    return $null
}

function Test-LanguageRepo {
    # Makes sure every language pack cab is present BEFORE the disk is wiped.
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Languages
    )
    $lof = Join-Path $RepoPath 'LOF'
    foreach ($lang in $Languages) {
        $cab = Join-Path $lof "Microsoft-Windows-Client-Language-Pack_x64_$($lang.ToLower()).cab"
        if (-not (Test-Path $cab)) {
            throw "Language pack not found: $cab. Run Prepare-OSDCloudLanguageRepo.ps1 first."
        }
        Write-Host "  OK  $lang language pack found"
    }
    # The LCU is REQUIRED when languages are added: Microsoft requires it after adding language packs,
    # otherwise they stay at their RTM version. Stop here, before anything is wiped.
    $lcu = @(Get-ChildItem -Path (Join-Path $RepoPath 'LCU') -Filter '*.msu' -File -ErrorAction SilentlyContinue)
    if ($lcu.Count -eq 0) {
        throw ('No cumulative update (.msu) found in ' + (Join-Path $RepoPath 'LCU') + '. It is required when adding ' +
            'languages. Put the latest update (and its checkpoint) on the stick (README section 5), or deploy English only.')
    }
    $lcu | ForEach-Object { Write-Host "  OK  LCU found: $($_.Name)" }
    if ($lcu.Count -eq 1) {
        # Since 24H2 an LCU can need a checkpoint LCU next to it (KB5043080 for 24H2/25H2 in 2026).
        # When adding languages it cannot be skipped: without it DISM fails with 0x80073712.
        Write-Warning ('Only one .msu in the LCU folder. If the Update Catalog download window listed more than one ' +
            'file (a checkpoint update), all of them must be in this folder.')
    }
}

function Set-OfflineFeatureUpdateBlock {
    # Writes the Windows Update policy "Select the target feature update version" into the offline
    # image, so Windows Update during SetupComplete cannot install a newer feature update (26H2).
    # Removed again at the end of SetupComplete (Remove-FeatureUpdateBlock.ps1): after OOBE the
    # customer's Intune feature update policy decides. A local policy would win over Intune.
    $hiveKey = 'HKLM\OSDOfflineSoftware'
    & reg.exe load $hiveKey 'C:\Windows\System32\config\SOFTWARE' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not load the registry of the new Windows (reg load exit code $LASTEXITCODE)." }
    try {
        $key = "$hiveKey\Policies\Microsoft\Windows\WindowsUpdate"
        $values = @(
            @('ProductVersion', 'REG_SZ', $Config.FeatureUpdateProduct),
            @('TargetReleaseVersion', 'REG_DWORD', '1'),
            @('TargetReleaseVersionInfo', 'REG_SZ', $Config.FeatureUpdateTarget)
        )
        foreach ($value in $values) {
            & reg.exe add $key /v $value[0] /t $value[1] /d $value[2] /f | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not set $($value[0]) (reg add exit code $LASTEXITCODE)." }
        }
    }
    finally {
        [gc]::Collect()   # release any handles before unloading the hive
        & reg.exe unload $hiveKey | Out-Null
    }
    Write-Host "  OK  Feature updates held at $($Config.FeatureUpdateProduct) $($Config.FeatureUpdateTarget) until the end of SetupComplete"
}

function Test-InternetHost {
    # Opens a TCP connection to host:port (this also tests DNS). Plain .NET, because
    # Test-NetConnection is not always available in WinPE. Retries a few times, since a
    # Wi-Fi connection can take a moment to get an IP address.
    param(
        [Parameter(Mandatory)][string]$HostAndPort,
        [int]$Attempts = 4,
        [int]$TimeoutSeconds = 5
    )
    $hostName, $port = $HostAndPort -split ':'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $client.ConnectAsync($hostName, [int]$port)
            if ($connect.Wait($TimeoutSeconds * 1000) -and $client.Connected) { return $true }
        }
        catch { }   # DNS or connection error: try again
        finally { $client.Dispose() }
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 5 }
    }
    return $false
}

function Test-OfficeSource {
    # Makes sure the Office files are on the stick BEFORE the disk is wiped.
    param([Parameter(Mandatory)][string]$OfficePath)
    foreach ($file in $Config.OfficeFiles) {
        if (-not (Test-Path (Join-Path $OfficePath $file))) {
            throw "Office file not found: $(Join-Path $OfficePath $file). Re-run Initialize-OSDCloudBuild.ps1, or deploy with -SkipOffice."
        }
    }
    Write-Host "  OK  Office files found: $OfficePath"
}

function Add-SetupCompleteCommand {
    # Adds a line that runs $ScriptPath to the SetupComplete.cmd that OSDCloud starts at the end of
    # SetupComplete. Lines run in the order they are added. Safe to call twice for the same script.
    param([Parameter(Mandatory)][string]$ScriptPath)
    $command = '%windir%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
        $ScriptPath + '"'
    $setupCompleteCmd = Join-Path $Config.SetupCompleteFolder 'SetupComplete.cmd'
    if (-not (Test-Path $setupCompleteCmd)) {
        $null = New-Item -Path $Config.SetupCompleteFolder -ItemType Directory -Force
        Set-Content -Path $setupCompleteCmd -Value '@echo off' -Encoding Ascii
    }
    if (-not (Select-String -Path $setupCompleteCmd -Pattern $ScriptPath -SimpleMatch -Quiet)) {
        Add-Content -Path $setupCompleteCmd -Value $command -Encoding Ascii
    }
}

function Export-WinPENetworkDriver {
    # Copies the driver packages of the network adapters WinPE is currently using
    # (Ethernet + Wi-Fi) from the WinPE driver store to $Destination.
    # How: WinPE publishes injected drivers as X:\Windows\INF\oemXX.inf. That file is an exact copy
    # of the .inf inside the driver store folder, so we match them by file hash.
    param([Parameter(Mandatory)][string]$Destination)

    # Which drivers are in use: read from the registry, NOT from WMI. Win32_PnPSignedDriver does not
    # exist in WinPE ("Invalid class"). Every installed network adapter has a subkey (0000, 0001, ...)
    # under the Net device class with the .inf it uses; third-party drivers are oemXX.inf.
    $netClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $netDrivers = @(Get-ChildItem -Path $netClassKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.InfPath -like 'oem*.inf' } |
        Sort-Object -Property InfPath -Unique |
        Select-Object @{ n = 'InfName'; e = { $_.InfPath } }, @{ n = 'DeviceName'; e = { $_.DriverDesc } })

    if ($netDrivers.Count -eq 0) {
        Write-Warning 'No third-party network drivers in use in WinPE. Windows will rely on its built-in drivers at OOBE.'
        return 0
    }

    $storePath = 'X:\Windows\System32\DriverStore\FileRepository'
    $hashIndex = @{}
    Get-ChildItem -Path $storePath -Filter '*.inf' -File -Recurse -Depth 1 | ForEach-Object {
        $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
        if (-not $hashIndex.ContainsKey($hash)) { $hashIndex[$hash] = $_.Directory.FullName }
    }

    $null = New-Item -Path $Destination -ItemType Directory -Force
    $exported = 0
    foreach ($driver in $netDrivers) {
        $oemInf = Join-Path 'X:\Windows\INF' $driver.InfName
        if (-not (Test-Path $oemInf)) {
            Write-Warning "  $($driver.DeviceName): $oemInf not found, skipped"
            continue
        }
        $hash = (Get-FileHash -Path $oemInf -Algorithm SHA256).Hash
        if ($hashIndex.ContainsKey($hash)) {
            $source = $hashIndex[$hash]
            Copy-Item -Path $source -Destination (Join-Path $Destination (Split-Path $source -Leaf)) -Recurse -Force
            Write-Host "  OK  $($driver.DeviceName)"
            $exported++
        }
        else {
            Write-Warning "  $($driver.DeviceName): driver store folder not found, skipped"
        }
    }
    return $exported
}
#endregion -----------------------------------------------------------------------------------------

#region Main ---------------------------------------------------------------------------------------
$transcript = "X:\Windows\Temp\Deploy-OSDCloud-Win11-25H2_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $transcript -Force -WhatIf:$false | Out-Null
$deploymentOk = $false

try {
    #--- 1. Pre-flight checks (nothing is changed yet) --------------------------------------------
    Write-Step 'Pre-flight checks'

    if ($env:SystemDrive -ne 'X:') {
        throw 'This script must run in OSDCloud WinPE (SystemDrive is not X:). Stopping to protect this machine.'
    }
    if (-not (Get-Module -ListAvailable -Name OSD)) {
        throw 'OSD PowerShell module not found in WinPE.'
    }
    Import-Module OSD -Force
    Write-Host "  OK  OSD module $((Get-Module OSD).Version)"

    $hosts = @($Config.WindowsDownloadHost)
    if (-not $SkipOffice) { $hosts += $Config.OfficeDownloadHost }
    foreach ($hostAndPort in $hosts) {
        if (-not (Test-InternetHost -HostAndPort $hostAndPort)) {
            throw ("No internet: cannot reach $hostAndPort. Nothing has been wiped. Connect Ethernet, or Wi-Fi " +
                "with Start-WinREWiFi, then run the script again. (A Microsoft download server down is rare; " +
                "a network that blocks it, such as a guest network with a login page, is more likely.)")
        }
        Write-Host "  OK  Internet: $hostAndPort reachable"
    }

    $repo = Find-LanguageRepo -RelativePath $Config.RepoRelativePath
    if (-not $repo) {
        throw "Language repository '$($Config.RepoRelativePath)\LOF' not found on any drive. Is the OSDCloud USB stick connected?"
    }
    Write-Host "  OK  Language repository: $repo"
    if ($Config.ExtraLanguages.Count -gt 0) {
        Write-Host "  OK  Extra languages: $($Config.ExtraLanguages -join ', ')"
        Test-LanguageRepo -RepoPath $repo -Languages $Config.ExtraLanguages
    }
    else {
        Write-Host '  OK  English only: no language packs and no cumulative update from the stick'
    }
    $debloatSource = Join-Path (Join-Path (Split-Path $repo -Qualifier) $Config.DebloatRelativePath) $Config.DebloatFile
    if (-not (Test-Path $debloatSource)) {
        throw "Debloat script not found: $debloatSource. Re-run Initialize-OSDCloudBuild.ps1 (step 9 puts it on the stick)."
    }
    Write-Host "  OK  Debloat script found: $debloatSource"
    if ($SkipOffice) {
        Write-Host '  -SkipOffice: Microsoft 365 Apps will not be installed'
    }
    else {
        # The Office folder is on the same stick as the language repository
        Test-OfficeSource -OfficePath (Join-Path (Split-Path $repo -Qualifier) $Config.OfficeRelativePath)
    }

    if ($WhatIfPreference) {
        Write-Step 'WhatIf: pre-flight checks passed. The real run would now:'
        Write-Host "  - WIPE the internal disk and install $($Config.OSName) $($Config.OSEdition) ($($Config.OSActivation), $($Config.OSLanguage))"
        Write-Host '  - Inject only the Ethernet/Wi-Fi drivers WinPE is using'
        if ($Config.ExtraLanguages.Count -gt 0) { Write-Host "  - Add languages: $($Config.ExtraLanguages -join ', ') + re-apply the LCU" }
        else { Write-Host '  - English only (no extra languages)' }
        Write-Host '  - Let Windows Update install all other drivers and firmware during SetupComplete'
        Write-Host '  - Debloat (RemoveBloat.ps1 by Andrew Taylor) at the end of SetupComplete'
        if (-not $SkipOffice) { Write-Host '  - Install Microsoft 365 Apps at the end of SetupComplete' }
        Write-Host "  - Hold feature updates at $($Config.FeatureUpdateTarget) during the deployment, lifted before OOBE"
        Write-Host '  - Remove the plain-text Wi-Fi password OSDCloud leaves behind, before OOBE'
        Write-Host '  - Restart into OOBE (language > region > keyboard)'
        $deploymentOk = $true
        return
    }

    #--- 2. OSDCloud: wipe disk, apply Windows, prepare SetupComplete -----------------------------
    Write-Step "Starting OSDCloud: $($Config.OSName) $($Config.OSEdition) $($Config.OSActivation) $($Config.OSLanguage)"
    Start-OSDCloud -OSName $Config.OSName -OSEdition $Config.OSEdition -OSActivation $Config.OSActivation `
        -OSLanguage $Config.OSLanguage -ZTI -SkipAutopilot -SkipODT

    # Invoke-OSDCloud does not always throw on failure, so check the result ourselves.
    if (-not (Test-Path 'C:\Windows\System32\ntoskrnl.exe')) {
        throw 'OSDCloud finished but no Windows installation was found on C:. Check the OSDCloud logs.'
    }
    Write-Host '  OK  Windows applied to C:'

    $null = New-Item -Path $Config.ScratchFolder -ItemType Directory -Force

    #--- 3. Network drivers only --------------------------------------------------------------------
    Write-Step 'Injecting Ethernet/Wi-Fi drivers from WinPE into the new OS'
    $count = Export-WinPENetworkDriver -Destination $Config.NetDriverFolder
    if ($count -gt 0) {
        Add-WindowsDriver -Path 'C:\' -Driver $Config.NetDriverFolder -Recurse -ScratchDirectory $Config.ScratchFolder | Out-Null
        Write-Host "  OK  $count network driver package(s) added"
    }

    #--- 3b. Hold feature updates until the end of SetupComplete ------------------------------------
    Write-Step "Holding feature updates at $($Config.FeatureUpdateTarget) during the deployment"
    Set-OfflineFeatureUpdateBlock

    #--- 4. Languages -------------------------------------------------------------------------------
    # Re-detect the repo: the USB drive letter can change after the disk was partitioned.
    $repo = Find-LanguageRepo -RelativePath $Config.RepoRelativePath
    if (-not $repo) { throw 'Language repository disappeared after partitioning. Is the USB stick still connected?' }
    $lof = Join-Path $repo 'LOF'

    foreach ($lang in $Config.ExtraLanguages) {
        Write-Step "Adding language $lang"

        # The language pack itself. DISM also picks up matching satellite packages for
        # already-installed features from the same folder.
        $cab = Join-Path $lof "Microsoft-Windows-Client-Language-Pack_x64_$($lang.ToLower()).cab"
        Add-WindowsPackage -Path 'C:\' -PackagePath $cab -ScratchDirectory $Config.ScratchFolder | Out-Null
        Write-Host '  OK  Language pack'

        # Language features (spell check, handwriting, OCR, speech, ...)
        foreach ($feature in $Config.LanguageFeatures) {
            $capability = "Language.$feature~~~$lang~0.0.1.0"
            try {
                Add-WindowsCapability -Path 'C:\' -Name $capability -Source $lof -LimitAccess `
                    -ScratchDirectory $Config.ScratchFolder | Out-Null
                Write-Host "  OK  $capability"
            }
            catch {
                if ($feature -eq 'Basic') { throw "Required feature $capability failed: $($_.Exception.Message)" }
                Write-Warning "  Optional feature $capability not added: $($_.Exception.Message)"
            }
        }
    }

    #--- 5. Re-apply the cumulative update ---------------------------------------------------------
    # Microsoft: after adding a language pack the LCU must be reinstalled, otherwise the language packs
    # stay at their RTM version (10.0.26100.1). Windows Update will NOT offer an LCU that is already
    # installed, so this has to happen here. Only needed when languages were added.
    # Known in October 2026: the KB5043080 checkpoint .msu fails with 0x80070228 (its own 2024 update
    # agent cannot parse the 25H2 compDB: "XML parse error ... Type=UUPProduct"), offline AND online.
    # The target LCU (KB5127648) still installs and does update the language packs (tested: nl-NL and
    # fr-FR at 10.0.26100.9711). So a failure here is a warning; what counts is the version check below.
    if ($Config.ExtraLanguages.Count -gt 0) {
        $lcuFolder = Join-Path $repo 'LCU'
        Write-Step 'Re-applying the cumulative update (this can take 10-20 minutes)'
        try {
            # Passing the folder lets DISM install checkpoint + latest update in the right order.
            Add-WindowsPackage -Path 'C:\' -PackagePath $lcuFolder -ScratchDirectory $Config.ScratchFolder | Out-Null
            Write-Host '  OK  Cumulative update applied'
        }
        catch {
            $hresult = '{0:X8}' -f $_.Exception.HResult
            if ($hresult -eq '800F081E' -or $_.Exception.Message -match 'not applicable') {
                Write-Warning ('The cumulative update on the stick is older than the one already in the Windows image ' +
                    '(not applicable). Put the latest update on the stick.')
            }
            else {
                Write-Warning "Part of the cumulative update failed (0x$hresult): $($_.Exception.Message.Trim())"
                $null = New-Item -Path $Config.LogFolder -ItemType Directory -Force
                Copy-Item -Path 'X:\Windows\Logs\DISM\dism.log' -Destination (Join-Path $Config.LogFolder 'dism-offline-LCU.log') -Force -ErrorAction SilentlyContinue
            }
        }

        # What matters: are the added language packs updated past their RTM version?
        Write-Step 'Checking the language pack versions'
        $lpPackages = @(Get-WindowsPackage -Path 'C:\' | Where-Object {
            $_.PackageName -like '*Client-LanguagePack-Package*' -and $_.PackageState -in 'Installed', 'InstallPending' })
        foreach ($lang in $Config.ExtraLanguages) {
            $versions = @($lpPackages | ForEach-Object {
                if ($_.PackageName -match "~$([regex]::Escape($lang))~(\d+\.\d+\.\d+\.\d+)$") { [version]$Matches[1] } })
            $newest = $versions | Sort-Object -Descending | Select-Object -First 1
            if ($newest -and $newest -gt [version]'10.0.26100.1') { Write-Host "  OK  $lang language pack at $newest" }
            else {
                Write-Warning ("$lang language pack is still at its original version ($newest): the cumulative update did not " +
                    'update it. Some Windows text may stay in English. Check the update files on the stick.')
            }
        }
    }

    #--- 6. Debloat + Microsoft 365 Apps -----------------------------------------------------------
    # Both need the full Windows, not WinPE. We stage the files and let OSDCloud's SetupComplete run
    # them in the new Windows, after Windows Update and before OOBE. Debloat goes first: it removes
    # consumer Office editions, so it must never run after our Office install.
    # A failure of either does not stop the other or OOBE (each line in SetupComplete.cmd runs on its own).

    Write-Step 'Staging debloat for SetupComplete'
    $debloatDest = Join-Path $Config.SetupCompleteFolder 'Debloat'
    $null = New-Item -Path $debloatDest -ItemType Directory -Force
    Copy-Item -Path (Join-Path (Join-Path (Split-Path $repo -Qualifier) $Config.DebloatRelativePath) $Config.DebloatFile) `
        -Destination $debloatDest -Force
    Add-SetupCompleteCommand -ScriptPath (Join-Path $debloatDest $Config.DebloatFile)
    Write-Host "  OK  Debloat staged in $debloatDest"

    if (-not $SkipOffice) {
        Write-Step 'Staging Microsoft 365 Apps install for SetupComplete'
        $officeSource = Join-Path (Split-Path $repo -Qualifier) $Config.OfficeRelativePath
        $officeDest   = Join-Path $Config.SetupCompleteFolder 'Office'
        $null = New-Item -Path $officeDest -ItemType Directory -Force
        foreach ($file in $Config.OfficeFiles) {
            Copy-Item -Path (Join-Path $officeSource $file) -Destination $officeDest -Force
        }
        Add-SetupCompleteCommand -ScriptPath (Join-Path $officeDest 'Install-M365Apps.ps1')
        Write-Host "  OK  Office staged in $officeDest"
    }

    # Last line of SetupComplete.cmd: lift the feature update hold from step 3b again, so it never
    # outlives the deployment (a local policy would override the customer's Intune feature update policy).
    Write-Step 'Staging removal of the feature update hold for the end of SetupComplete'
    $releaseScript = Join-Path $Config.SetupCompleteFolder 'Remove-FeatureUpdateBlock.ps1'
    Set-Content -Path $releaseScript -Encoding Ascii -Value @'
# Generated by Deploy-OSDCloud-Win11-25H2.ps1. Runs at the end of SetupComplete, before OOBE.
# Removes the feature update hold that the deployment set, so Intune decides from now on.
Start-Transcript -Path "C:\OSDCloud\Logs\Remove-FeatureUpdateBlock_$(Get-Date -Format 'yyyyMMdd-HHmmss').log" | Out-Null
$key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
foreach ($name in 'ProductVersion', 'TargetReleaseVersion', 'TargetReleaseVersionInfo') {
    Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue
}
# Remove the key itself only if nothing else is configured in it
$item = Get-Item -Path $key -ErrorAction SilentlyContinue
if ($item -and $item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) { Remove-Item -Path $key -Force }
$left = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
if ($left.TargetReleaseVersion -or $left.TargetReleaseVersionInfo) { Write-Output 'FAILED: feature update hold is still present' }
else { Write-Output 'OK: feature update hold removed' }
Stop-Transcript | Out-Null
'@
    Add-SetupCompleteCommand -ScriptPath $releaseScript
    Write-Host "  OK  Hold is lifted at the end of SetupComplete ($releaseScript)"

    # Very last line: remove the Wi-Fi password OSDCloud leaves behind. OSDCloud writes
    # 'Set-WiFi -SSID "..." -PSK "<password in plain text>"' into C:\Windows\Setup\Scripts\SetupComplete.ps1
    # to rebuild the Wi-Fi connection. By the time this runs that line has been executed, and
    # PowerShell loaded the whole script at the start, so editing the file is safe. The Wi-Fi profile
    # itself stays (Windows stores its key protected): OOBE and Autopilot need the connection.
    Write-Step 'Staging removal of the plain-text Wi-Fi password for the end of SetupComplete'
    $wifiScript = Join-Path $Config.SetupCompleteFolder 'Remove-WiFiPassword.ps1'
    Set-Content -Path $wifiScript -Encoding Ascii -Value @'
# Generated by Deploy-OSDCloud-Win11-25H2.ps1. Runs as the last step of SetupComplete, before OOBE.
# Removes the plain-text Wi-Fi password that OSDCloud leaves in its SetupComplete files and logs.
# The password itself is never written to this log.
Start-Transcript -Path "C:\OSDCloud\Logs\Remove-WiFiPassword_$(Get-Date -Format 'yyyyMMdd-HHmmss').log" | Out-Null
$pattern = '(-PSK\s+")(?!\*+"|<removed after deployment>")[^"]*(")'   # a real value: not OSD's "*****" mask, not our marker
$files = @(Get-ChildItem -Path 'C:\Windows\Setup\Scripts', 'C:\OSDCloud\Logs', 'C:\Windows\Temp\osdcloud-logs' `
    -Recurse -File -Include *.ps1, *.cmd, *.log, *.txt, *.json -ErrorAction SilentlyContinue)
$cleaned = 0
foreach ($file in $files) {
    $text = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
    if ($text -and $text -match $pattern) {
        try {
            $text -replace $pattern, '$1<removed after deployment>$2' | Set-Content -Path $file.FullName -NoNewline -ErrorAction Stop
            Write-Output "Removed Wi-Fi password from $($file.FullName)"
            $cleaned++
        }
        catch { Write-Output "FAILED to clean $($file.FullName): $($_.Exception.Message)" }
    }
}
# OSDCloud's own copy (normally already removed by its SetupComplete)
Remove-Item -Path 'C:\OSDCloud\Configs\WiFi.JSON' -Force -ErrorAction SilentlyContinue
$left = @($files | Where-Object { (Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue) -match $pattern })
if ($left.Count -eq 0) { Write-Output "OK: no plain-text Wi-Fi password left ($cleaned file(s) cleaned)" }
else { Write-Output "FAILED: Wi-Fi password still in $($left.FullName -join ', ')" }
Stop-Transcript | Out-Null
'@
    Add-SetupCompleteCommand -ScriptPath $wifiScript
    Write-Host "  OK  Wi-Fi password is removed at the end of SetupComplete ($wifiScript)"

    #--- 7. Verify ---------------------------------------------------------------------------------
    Write-Step 'Verifying installed languages'
    $installed = Get-WindowsPackage -Path 'C:\' | Where-Object { $_.PackageName -like '*Client-LanguagePack*' }
    $installed | ForEach-Object { Write-Host "  $($_.PackageName)  [$($_.PackageState)]" }
    foreach ($lang in $Config.ExtraLanguages) {
        if (-not ($installed | Where-Object { $_.PackageName -like "*$lang*" })) {
            throw "Language pack $lang is not present in the image after installation."
        }
    }

    $deploymentOk = $true
}
catch {
    Write-Host ''
    Write-Host "DEPLOYMENT FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'The device will NOT restart. Check the log, fix the issue and run the script again.' -ForegroundColor Red
}
finally {
    if (Test-Path $Config.ScratchFolder) { Remove-Item -Path $Config.ScratchFolder -Recurse -Force -ErrorAction SilentlyContinue }
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path 'C:\Windows') {
        $null = New-Item -Path $Config.LogFolder -ItemType Directory -Force
        Copy-Item -Path $transcript -Destination $Config.LogFolder -Force
    }
    Write-Host "Log: $transcript" -ForegroundColor DarkGray
}

if ($deploymentOk -and -not $WhatIfPreference) {
    Write-Step 'Deployment finished. Restarting in 10 seconds into SetupComplete (Windows Update) and OOBE...'
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
# Exit code 1 on failure, so Start-OSDCloudDeployMenu.ps1 can tell whether the (pre-flight) run passed
if (-not $deploymentOk) { exit 1 }
#endregion -----------------------------------------------------------------------------------------
