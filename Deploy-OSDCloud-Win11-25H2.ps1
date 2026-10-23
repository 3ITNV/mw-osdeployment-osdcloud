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
          2. Adds the nl-NL and fr-FR language packs + language features from a local repository
             on the OSDCloud USB stick. Because more than one language is installed, OOBE asks the
             user to pick a language, then region, then keyboard layout.
          3. Re-applies the latest cumulative update (LCU) after the language packs, as Microsoft
             requires (otherwise parts of Windows can stay in English).
        All other drivers (and firmware offered through Windows Update) are installed by Windows
        Update during SetupComplete, before OOBE starts.

    Author:  <Your name> - 3-IT

    Requirements:
        - OSDCloud boot media with network drivers in WinPE (Edit-OSDCloudWinPE -CloudDriver ...)
        - OSD PowerShell module (tested against source of OSD 26.10.16.1)
        - Language repository on the USB stick, created with Prepare-OSDCloudLanguageRepo.ps1:
              <USB>:\OSDCloud\Languages\LOF\   language packs, FODs and metadata
              <USB>:\OSDCloud\Languages\LCU\   latest cumulative update (.msu) for 25H2 x64

    WARNING: This script is ZERO TOUCH. It wipes the internal disk WITHOUT asking.
             Run it with -WhatIf first to do the pre-flight checks only.

.EXAMPLE
    # Pre-flight checks only, nothing is wiped or installed
    .\Deploy-OSDCloud-Win11-25H2.ps1 -WhatIf

.EXAMPLE
    # Full deployment (wipes the disk!)
    .\Deploy-OSDCloud-Win11-25H2.ps1

.NOTES
    Version history
    Version  Date        Author          Change
    -------  ----------  --------------  ------------------------------------------------------------
    1.0.0    2026-10-23  <Your name>     Initial version
#>

#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

#region Configuration ------------------------------------------------------------------------------
# Change these values here instead of further down in the script.
$Config = [ordered]@{
    OSName               = 'Windows 11 25H2 x64'
    OSEdition            = 'Pro'
    OSActivation         = 'Retail'
    OSLanguage           = 'en-us'                  # Base language of the downloaded image
    ExtraLanguages       = @('nl-NL', 'fr-FR')      # Added offline, selectable in OOBE
    # Language features (FODs) per language. 'Basic' is required, the rest is optional:
    # if one does not exist for a language, the script logs a warning and continues.
    LanguageFeatures     = @('Basic', 'Handwriting', 'OCR', 'Speech', 'TextToSpeech')
    RepoRelativePath     = 'OSDCloud\Languages'      # Folder on the USB stick
    LogFolder            = 'C:\OSDCloud\Logs'
    ScratchFolder        = 'C:\OSDCloud\Scratch'
    NetDriverFolder      = 'C:\Drivers\Net'
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
    $lcu = @(Get-ChildItem -Path (Join-Path $RepoPath 'LCU') -Filter '*.msu' -File -ErrorAction SilentlyContinue)
    if ($lcu.Count -eq 0) {
        Write-Warning ('No cumulative update (.msu) found in ' + (Join-Path $RepoPath 'LCU') +
            '. Deployment will continue, but parts of Windows may stay in English until the next monthly update.')
    }
    else {
        $lcu | ForEach-Object { Write-Host "  OK  LCU found: $($_.Name)" }
    }
}

function Export-WinPENetworkDriver {
    # Copies the driver packages of the network adapters WinPE is currently using
    # (Ethernet + Wi-Fi) from the WinPE driver store to $Destination.
    # How: WinPE publishes injected drivers as X:\Windows\INF\oemXX.inf. That file is an exact copy
    # of the .inf inside the driver store folder, so we match them by file hash.
    param([Parameter(Mandatory)][string]$Destination)

    $netDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver |
        Where-Object { $_.DeviceClass -eq 'NET' -and $_.InfName -like 'oem*.inf' } |
        Sort-Object -Property InfName -Unique)

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

    $repo = Find-LanguageRepo -RelativePath $Config.RepoRelativePath
    if (-not $repo) {
        throw "Language repository '$($Config.RepoRelativePath)\LOF' not found on any drive. Is the OSDCloud USB stick connected?"
    }
    Write-Host "  OK  Language repository: $repo"
    Test-LanguageRepo -RepoPath $repo -Languages $Config.ExtraLanguages

    if ($WhatIfPreference) {
        Write-Step 'WhatIf: pre-flight checks passed. The real run would now:'
        Write-Host "  - WIPE the internal disk and install $($Config.OSName) $($Config.OSEdition) ($($Config.OSActivation), $($Config.OSLanguage))"
        Write-Host '  - Inject only the Ethernet/Wi-Fi drivers WinPE is using'
        Write-Host "  - Add languages: $($Config.ExtraLanguages -join ', ') + re-apply the LCU"
        Write-Host '  - Let Windows Update install all other drivers and firmware during SetupComplete'
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
    # Microsoft: after adding a language pack the LCU must be reinstalled. Windows Update will NOT
    # offer an LCU that is already installed, so this has to happen here.
    $lcuFolder = Join-Path $repo 'LCU'
    if (@(Get-ChildItem -Path $lcuFolder -Filter '*.msu' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Step 'Re-applying the cumulative update (this can take 10-20 minutes)'
        # Passing the folder lets DISM install checkpoint + latest update in the right order.
        Add-WindowsPackage -Path 'C:\' -PackagePath $lcuFolder -ScratchDirectory $Config.ScratchFolder | Out-Null
        Write-Host '  OK  Cumulative update applied'
    }
    else {
        Write-Warning 'No LCU in the repository. Skipped. Some text may stay in English until the next monthly update.'
    }

    #--- 6. Verify ---------------------------------------------------------------------------------
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
#endregion -----------------------------------------------------------------------------------------
