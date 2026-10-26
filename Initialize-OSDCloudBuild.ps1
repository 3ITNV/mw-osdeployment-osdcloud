<#
.SYNOPSIS
    Sets up everything needed for the Windows 11 25H2 OSDCloud deployment on a technician PC:
    ADK, OSD module, WinPE with network drivers, the OSDCloud USB stick, the language
    repository and the deployment script.

.DESCRIPTION
    Purpose:
        One script for the whole build. Run it on a Windows 11 technician PC in an elevated
        Windows PowerShell 5.1 window (not PowerShell 7: the OSD module and ADK tools expect 5.1).

        Steps (each step is skipped when it is already done, so the script is safe to re-run):
          1. Pre-flight checks (admin, Windows 11, free space, script files present)
          2. Install Windows ADK (Deployment Tools) + WinPE add-on, if missing
          3. Install or update the OSD PowerShell module
          4. Create the OSDCloud template (WinRE based, needed for Wi-Fi) and workspace, with a
             Belgian keyboard in WinPE ($WinPEInputLocale)
          5. Add network drivers to WinPE (Edit-OSDCloudWinPE -CloudDriver *)
          6. Create the OSDCloud USB stick (ERASES the stick, asks for confirmation)
             or update an existing one
          7. Download the Languages and Optional Features ISO, if not provided
          8. Fill the language repository on the stick (Prepare-OSDCloudLanguageRepo.ps1)
          9. Copy the deployment script, the start menu (StartNet), the Office folder
             (Microsoft 365 Apps) and the debloat script (pinned download, SHA-256 checked) to the stick

        Monthly maintenance (required): download the new cumulative update (ALL .msu files, including
        the checkpoint) and re-run with -LcuPath. Only the update on the stick is replaced; everything
        else is skipped. Without it, deployments stop at the pre-flight (no OOBE language choice).

        Keep these files in the same folder:
            Initialize-OSDCloudBuild.ps1
            Prepare-OSDCloudLanguageRepo.ps1
            Deploy-OSDCloud-Win11-25H2.ps1
            Start-OSDCloudDeployMenu.ps1
            Office\   (setup.exe, installM365BP.xml, Install-M365Apps.ps1)

    Author:  <Your name> - 3-IT

.PARAMETER WorkspacePath
    OSDCloud workspace folder. Default C:\OSDCloud.

.PARAMETER DownloadPath
    Folder for downloads (ADK installers, LOF ISO) and logs. Default C:\OSDCloudBuild.

.PARAMETER LofIsoPath
    Optional. Path to an already downloaded LOF ISO. If omitted, the script downloads it.

.PARAMETER LcuPath
    Optional. Folder with the .msu file(s) of the latest cumulative update for
    Windows 11 25H2 x64, downloaded from the Microsoft Update Catalog.

.PARAMETER Languages
    Extra languages. Default nl-NL, fr-FR.

.PARAMETER RebuildWinPE
    Rebuild template, workspace and WinPE drivers even if they already exist.

.PARAMETER RecreateUsb
    Recreate the USB stick even if an OSDCloudUSB stick is already connected (ERASES it).

.PARAMETER RefreshLanguages
    Copy the language files to the stick again even if they are already there.

.EXAMPLE
    # First run: shows what would happen, changes nothing
    .\Initialize-OSDCloudBuild.ps1 -WhatIf

.EXAMPLE
    # First real run
    .\Initialize-OSDCloudBuild.ps1 -LcuPath 'C:\Updates\25H2'

.EXAMPLE
    # Monthly: refresh only the cumulative update on the stick
    .\Initialize-OSDCloudBuild.ps1 -LcuPath 'C:\Updates\2026-11'

.NOTES
    Version history
    Version  Date        Author          Change
    -------  ----------  --------------  ------------------------------------------------------------
    1.0.0    2026-10-23  <Your name>     Initial version
    1.0.1    2026-10-23  <Your name>     Stop when New-OSDCloudTemplate fails to add WinPE packages
    1.0.2    2026-10-23  <Your name>     Renamed Get-AdkPaths to Get-3ITAdkPath (OSD alias clash);
                                         update stick when its WinPE is older than the workspace
    1.0.3    2026-10-23  <Your name>     Fix: script stopped after step 6 (single USB volume was not
                                         counted correctly in PowerShell 5.1)
    1.1.0    2026-10-23  <Your name>     Copy the Office folder (Microsoft 365 Apps) to the stick;
                                         cumulative update on the stick is now recommended, not required
    1.2.0    2026-10-23  <Your name>     Belgian (Period) keyboard in WinPE instead of US (needs -RebuildWinPE
                                         on an existing workspace)
    1.2.1    2026-10-23  <Your name>     Fix: step 5 crashed when dell.com refused the driver pack lookup
                                         (OSD bug, empty fallback URL); discard leftover boot.wim mounts
    1.3.0    2026-10-23  <Your name>     Copy Start-OSDCloudDeployMenu.ps1 to OSDCloud\Config\Scripts\StartNet
                                         (deployment menu starts automatically, asks for confirmation)
    1.4.0    2026-10-23  <Your name>     Download Andrew Taylor's RemoveBloat.ps1 (pinned commit, SHA-256
                                         checked) to OSDCloud\Debloat on the stick
    1.4.1    2026-10-24  <Your name>     Texts only: the cumulative update on the stick is required again
#>

#Requires -Version 5.1
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspacePath = 'C:\OSDCloud',
    [string]$DownloadPath  = 'C:\OSDCloudBuild',
    [string]$LofIsoPath,
    [string]$LcuPath,
    [string[]]$Languages   = @('nl-NL', 'fr-FR'),
    [switch]$RebuildWinPE,
    [switch]$RecreateUsb,
    [switch]$RefreshLanguages
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Makes Invoke-WebRequest much faster

#region Configuration ------------------------------------------------------------------------------
# Download links from Microsoft Learn (checked 2026-10-23):
#   ADK:  https://learn.microsoft.com/windows-hardware/get-started/adk-install
#   LOF:  https://learn.microsoft.com/azure/virtual-desktop/windows-11-language-packs
$Urls = @{
    Adk      = 'https://go.microsoft.com/fwlink/?linkid=2289980'   # ADK 10.1.26100.9457 (Sept 2026)
    AdkWinPE = 'https://go.microsoft.com/fwlink/?linkid=2289981'   # WinPE add-on for that ADK
    LofIso   = 'https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1.240331-1435.ge_release_amd64fre_CLIENT_LOF_PACKAGES_OEM.iso'
    Catalog  = 'https://www.catalog.update.microsoft.com/Search.aspx?q=Cumulative%20Update%20for%20Windows%2011%20Version%2025H2%20for%20x64'
}
$MinFreeSpaceGB  = 20
# Keyboard in WinPE, for typing the Wi-Fi password. Default WinPE is US (0409:00000409).
# Belgian (Period) = 0813:00000813, Belgian French = 080C:0000080C. IDs from Microsoft Learn:
# https://learn.microsoft.com/windows-hardware/manufacture/desktop/default-input-locales-for-windows-language-packs
# Changing this only takes effect after a run with -RebuildWinPE.
$WinPEInputLocale = '0813:00000813'
$WinPEMarkerFile = Join-Path $WorkspacePath '.3it-winpe-netdrivers.done'
$DeployScript    = Join-Path $PSScriptRoot 'Deploy-OSDCloud-Win11-25H2.ps1'
$PrepareScript   = Join-Path $PSScriptRoot 'Prepare-OSDCloudLanguageRepo.ps1'
$MenuScript      = Join-Path $PSScriptRoot 'Start-OSDCloudDeployMenu.ps1'
$OfficeFolder    = Join-Path $PSScriptRoot 'Office'
$OfficeFiles     = @('setup.exe', 'installM365BP.xml', 'Install-M365Apps.ps1')
# Debloat: Andrew Taylor's RemoveBloat.ps1 (GPL-3.0, https://github.com/andrew-s-taylor/public).
# Not stored in this repo: downloaded at ONE fixed commit and checked against its SHA-256, so a change
# upstream never reaches our devices unnoticed. To update: pick a new commit, review the changes,
# and replace both values below (README section 11).
$DebloatUrl      = 'https://raw.githubusercontent.com/andrew-s-taylor/public/ce39945d999568ee67aec9f7571250293fde9689/De-Bloat/RemoveBloat.ps1'
$DebloatSha256   = '4500FE5538471CC2DF8D0FDE5AD23BFEF037561E095F27A3E341E744E69AF039'   # Version 5.6.5
#endregion -----------------------------------------------------------------------------------------

#region Helper functions ---------------------------------------------------------------------------
function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "=== [$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Write-Ok   { param([string]$Message) Write-Host "  OK    $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "  SKIP  $Message" -ForegroundColor DarkGray }

function Get-3ITAdkPath {
    # Named with a 3IT prefix: the OSD module creates an alias "Get-AdkPaths", and aliases
    # win over functions in PowerShell, which broke re-runs in the same window.
    $kitsRoot = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' `
        -ErrorAction SilentlyContinue).KitsRoot10
    if (-not $kitsRoot) { $kitsRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\" }
    $adk = Join-Path $kitsRoot 'Assessment and Deployment Kit'
    [pscustomobject]@{
        DeploymentTools = Join-Path $adk 'Deployment Tools\amd64\DISM\dism.exe'
        WinPE           = Join-Path $adk 'Windows Preinstallation Environment\amd64\en-us\winpe.wim'
    }
}

function Save-MicrosoftFile {
    # Downloads a file and, for executables, checks it is signed by Microsoft.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Large
    )
    if (Test-Path $Destination) { Write-Skip "Already downloaded: $Destination"; return }
    $null = New-Item -Path (Split-Path $Destination) -ItemType Directory -Force
    Write-Host "  Downloading $(Split-Path $Destination -Leaf) ..."
    $partial = "$Destination.partial"
    if ($Large) {
        # BITS is more reliable for multi-GB files
        Start-BitsTransfer -Source $Url -Destination $partial -DisplayName (Split-Path $Destination -Leaf)
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
    }
    if ($Destination -like '*.exe') {
        $sig = Get-AuthenticodeSignature -FilePath $partial
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            Remove-Item $partial -Force
            throw "Downloaded file $Destination is not validly signed by Microsoft. Download removed."
        }
    }
    Move-Item -Path $partial -Destination $Destination -Force
    Write-Ok "Downloaded $(Split-Path $Destination -Leaf)"
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$Name
    )
    Write-Host "  Installing $Name (silent, this can take 5-15 minutes) ..."
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw "$Name setup failed with exit code $($process.ExitCode). Logs: $env:LOCALAPPDATA\Temp\windows kits\adk"
    }
    if ($process.ExitCode -eq 3010) { Write-Warning "$Name asks for a restart. Restart later and re-run this script." }
    Write-Ok "$Name installed"
}

function Get-OSDCloudUsbVolume {
    @(Get-Volume | Where-Object { $_.FileSystemLabel -eq 'OSDCloudUSB' -and $_.DriveLetter })
}

function Dismount-WorkspaceBootWim {
    # A failed Edit-OSDCloudWinPE can leave the workspace boot.wim mounted, which blocks the next run.
    # Discard such a leftover mount: its changes were never completed.
    $bootWim = Join-Path $WorkspacePath 'Media\sources\boot.wim'
    $mounts  = @(Get-WindowsImage -Mounted | Where-Object { $_.ImagePath -eq $bootWim })
    foreach ($mount in $mounts) {
        Write-Warning "Discarding leftover mount of boot.wim at $($mount.Path) (from an earlier failed run)"
        Dismount-WindowsImage -Path $mount.Path -Discard | Out-Null
    }
    if ($mounts.Count -gt 0) { Clear-WindowsCorruptMountPoint | Out-Null }
}

function Set-DellWinPEDriverPackFallback {
    # Workaround for a bug in OSD 26.10.16.1: when dell.com refuses the scripted request (which
    # happens often), Get-DellWinPEDriverPack falls back to resource key 'LastKnownGood11', but the
    # key is named 'LastKnownGoodWin11'. The empty fallback makes Edit-OSDCloudWinPE crash with
    # "Invalid URI: The hostname could not be parsed". We look up the current pack ourselves (a few
    # tries) and store it under the key the module reads.
    $dell = $Global:OSDModuleResource.WinPEDriverPack.Dell
    if (-not $dell -or $dell.LastKnownGood11) { return }   # Nothing to fix (newer OSD version)
    $url = $null
    for ($attempt = 1; $attempt -le 3 -and -not $url; $attempt++) {
        $url = Get-DellWinPEDriverPack -WarningAction SilentlyContinue
        if (-not $url) { Start-Sleep -Seconds 5 }
    }
    if (-not $url) {
        $url = $dell.LastKnownGoodWin11
        Write-Warning "dell.com did not answer; using the Dell WinPE driver pack known to the OSD module: $url"
    }
    if (-not $url) { throw 'No Dell WinPE driver pack URL found. Try again later (dell.com may be refusing requests).' }
    $dell['LastKnownGood11'] = $url
    Write-Ok "Dell WinPE driver pack: $url"
}

function Test-UsbWinPEOutdated {
    # True when the boot.wim on the stick's WinPE partition differs from (is older than) the
    # workspace boot.wim, for example when the stick was made before the WinPE was rebuilt.
    param([Parameter(Mandatory)][string]$DataDriveLetter)
    $diskNumber = (Get-Partition -DriveLetter $DataDriveLetter).DiskNumber
    $winpeVol   = Get-Partition -DiskNumber $diskNumber | Get-Volume |
        Where-Object { $_.FileSystemLabel -eq 'WinPE' -and $_.DriveLetter } | Select-Object -First 1
    if (-not $winpeVol) { Write-Warning 'WinPE partition of the stick not found; it will be updated.'; return $true }
    $usbWim  = Get-Item "$($winpeVol.DriveLetter):\sources\boot.wim" -ErrorAction SilentlyContinue
    $workWim = Get-Item (Join-Path $WorkspacePath 'Media\sources\boot.wim') -ErrorAction SilentlyContinue
    if (-not $workWim) { return $false }
    if (-not $usbWim)  { return $true }
    return ($usbWim.LastWriteTime -lt $workWim.LastWriteTime)
}
#endregion -----------------------------------------------------------------------------------------

#region Main ---------------------------------------------------------------------------------------
$null = New-Item -Path (Join-Path $DownloadPath 'Logs') -ItemType Directory -Force -WhatIf:$false
$logFile = Join-Path $DownloadPath "Logs\Initialize-OSDCloudBuild_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logFile -WhatIf:$false | Out-Null
$winPEChanged = $false

try {
    #--- 1. Pre-flight -----------------------------------------------------------------------------
    Write-Step '1/9  Pre-flight checks'
    if ([Environment]::OSVersion.Version.Build -lt 22000) {
        throw 'Run this on Windows 11. The WinRE-based WinPE (needed for Wi-Fi) is taken from this PC.'
    }
    Write-Ok 'Windows 11'
    foreach ($file in $DeployScript, $PrepareScript, $MenuScript) {
        if (-not (Test-Path $file)) { throw "Missing file next to this script: $(Split-Path $file -Leaf)" }
    }
    Write-Ok 'Deploy and Prepare scripts found'
    foreach ($file in $OfficeFiles) {
        if (-not (Test-Path (Join-Path $OfficeFolder $file))) { throw "Missing file: Office\$file" }
    }
    $sig = Get-AuthenticodeSignature -FilePath (Join-Path $OfficeFolder 'setup.exe')
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw 'Office\setup.exe is not validly signed by Microsoft. Download the Office Deployment Tool again.'
    }
    Write-Ok "Office files found (setup.exe $((Get-Item (Join-Path $OfficeFolder 'setup.exe')).VersionInfo.FileVersion), signed by Microsoft)"
    $freeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
    if ($freeGB -lt $MinFreeSpaceGB) { throw "Only $freeGB GB free on C:. Need at least $MinFreeSpaceGB GB." }
    Write-Ok "$freeGB GB free on C:"
    if ($LcuPath -and -not @(Get-ChildItem -Path $LcuPath -Filter '*.msu' -File -ErrorAction SilentlyContinue).Count) {
        throw "No .msu files found in -LcuPath '$LcuPath'."
    }

    #--- 2. ADK ------------------------------------------------------------------------------------
    Write-Step '2/9  Windows ADK + WinPE add-on'
    $adkPaths = Get-3ITAdkPath
    if (Test-Path $adkPaths.DeploymentTools) {
        Write-Skip 'ADK Deployment Tools already installed'
    }
    elseif ($PSCmdlet.ShouldProcess('Windows ADK', 'Download and install Deployment Tools')) {
        $exe = Join-Path $DownloadPath 'Downloads\adksetup.exe'
        Save-MicrosoftFile -Url $Urls.Adk -Destination $exe
        Invoke-Installer -FilePath $exe -Arguments '/quiet /features OptionId.DeploymentTools' -Name 'Windows ADK'
    }
    if (Test-Path $adkPaths.WinPE) {
        Write-Skip 'WinPE add-on already installed'
    }
    elseif ($PSCmdlet.ShouldProcess('WinPE add-on', 'Download and install')) {
        $exe = Join-Path $DownloadPath 'Downloads\adkwinpesetup.exe'
        Save-MicrosoftFile -Url $Urls.AdkWinPE -Destination $exe
        Invoke-Installer -FilePath $exe -Arguments '/quiet /features OptionId.WindowsPreinstallationEnvironment' -Name 'WinPE add-on'
    }
    $adkVersion = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Windows Assessment and Deployment Kit*' -and $_.DisplayName -notlike '*Preinstallation*' } |
        Select-Object -First 1 -ExpandProperty DisplayVersion
    if ($adkVersion -and [version]$adkVersion -lt [version]'10.1.26100.0') {
        Write-Warning "Installed ADK is version $adkVersion. Version 10.1.26100.x or newer is recommended for 25H2. Uninstall the old ADK and re-run."
    }

    #--- 3. OSD module -----------------------------------------------------------------------------
    Write-Step '3/9  OSD PowerShell module'
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object Version -ge '2.8.5.201')) {
        if ($PSCmdlet.ShouldProcess('NuGet package provider', 'Install')) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
            Write-Ok 'NuGet provider installed'
        }
    }
    $installed = Get-Module -ListAvailable -Name OSD | Sort-Object Version -Descending | Select-Object -First 1
    $latest    = Find-Module -Name OSD -Repository PSGallery
    if ($installed -and $installed.Version -ge $latest.Version) {
        Write-Skip "OSD $($installed.Version) is the latest version"
    }
    elseif ($PSCmdlet.ShouldProcess("OSD $($latest.Version)", 'Install from PowerShell Gallery')) {
        Install-Module -Name OSD -RequiredVersion $latest.Version -Scope AllUsers -Force -AllowClobber
        Write-Ok "OSD $($latest.Version) installed"
    }
    if (Get-Module -ListAvailable -Name OSD) {
        Import-Module OSD -Force -WarningAction SilentlyContinue
        Write-Ok "OSD $((Get-Module OSD).Version) loaded"
    }

    #--- 4. Template + workspace -------------------------------------------------------------------
    Write-Step '4/9  OSDCloud template (WinRE) and workspace'
    $workspaceReady = Test-Path (Join-Path $WorkspacePath 'Media\sources\boot.wim')
    if ($workspaceReady -and -not $RebuildWinPE) {
        Write-Skip "Workspace already exists: $WorkspacePath"
    }
    elseif ($PSCmdlet.ShouldProcess($WorkspacePath, 'Create OSDCloud template (WinRE) and workspace')) {
        # WinRE is taken from this PC, so the recovery environment must be enabled.
        $winRE = Get-WinREPartition -ErrorAction SilentlyContinue
        if (-not $winRE -or $winRE.OperationalStatus -ne 'Online') {
            throw 'Windows Recovery Environment is not available on this PC. Run "reagentc /enable" in an elevated prompt and try again.'
        }
        $templateStart = Get-Date
        New-OSDCloudTemplate -WinRE -SetInputLocale $WinPEInputLocale

        # New-OSDCloudTemplate does not stop when adding WinPE packages fails (it only warns),
        # which leaves a WinPE without PowerShell. Check its own log and stop if anything failed.
        $templateLog = Get-ChildItem -Path "$env:ProgramData\OSDCloud\Logs\Template" -Filter '*New-OSDCloudTemplate.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $templateStart } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $templateLog) { throw 'Could not find the New-OSDCloudTemplate log to verify the result.' }
        # Count the short 'Add-WindowsPackage failed' line: it is never wrapped in the log.
        $failedCount = @(Select-String -Path $templateLog.FullName -Pattern 'Add-WindowsPackage failed').Count
        if ($failedCount -gt 0) {
            throw ("New-OSDCloudTemplate could not add $failedCount WinPE package(s). The WinPE would not work " +
                "(no PowerShell). Template log: $($templateLog.FullName). " +
                "Per-package logs: $env:ProgramData\OSDCloud\Logs\Template")
        }
        Write-Ok 'All WinPE packages added'

        New-OSDCloudWorkspace -WorkspacePath $WorkspacePath
        if (-not (Test-Path (Join-Path $WorkspacePath 'Media\sources\boot.wim'))) {
            throw "Workspace creation failed: no boot.wim in $WorkspacePath\Media\sources."
        }
        if (Test-Path $WinPEMarkerFile) { Remove-Item $WinPEMarkerFile -Force }
        $winPEChanged = $true
        Write-Ok 'Template and workspace created'
    }

    #--- 5. WinPE network drivers ------------------------------------------------------------------
    Write-Step '5/9  Network drivers in WinPE'
    if ((Test-Path $WinPEMarkerFile) -and -not $RebuildWinPE) {
        Write-Skip 'Network drivers already added to WinPE'
    }
    elseif ($PSCmdlet.ShouldProcess('WinPE boot.wim', 'Add cloud drivers (Edit-OSDCloudWinPE -CloudDriver *)')) {
        Dismount-WorkspaceBootWim
        Set-DellWinPEDriverPackFallback
        try {
            Edit-OSDCloudWinPE -WorkspacePath $WorkspacePath -CloudDriver '*'
        }
        catch {
            Dismount-WorkspaceBootWim
            throw
        }
        Set-Content -Path $WinPEMarkerFile -Value (Get-Date -Format s)
        $winPEChanged = $true
        Write-Ok 'Network drivers added to WinPE'
    }

    #--- 6. USB stick ------------------------------------------------------------------------------
    Write-Step '6/9  OSDCloud USB stick'
    $usb = @(Get-OSDCloudUsbVolume)
    if ($usb.Count -gt 1) { throw 'More than one OSDCloudUSB stick connected. Connect only one and re-run.' }

    if ($usb.Count -eq 0 -or $RecreateUsb) {
        $question = 'New-OSDCloudUSB will ERASE the USB stick you select in the next window. All data on it is lost. Continue?'
        if ($WhatIfPreference) {
            Write-Host '  What if: New-OSDCloudUSB would create the stick (ERASES the selected USB drive)'
        }
        elseif ($PSCmdlet.ShouldContinue($question, 'Erase USB stick')) {
            New-OSDCloudUSB -WorkspacePath $WorkspacePath
            $usb = @(Get-OSDCloudUsbVolume)
            if ($usb.Count -ne 1) { throw 'USB stick creation did not result in one OSDCloudUSB volume. Check the output above.' }
            Write-Ok "USB stick created, data partition $($usb[0].DriveLetter):"
        }
        else {
            throw 'USB creation cancelled by user.'
        }
    }
    elseif ($winPEChanged -or (Test-UsbWinPEOutdated -DataDriveLetter ([string]$usb[0].DriveLetter))) {
        if ($PSCmdlet.ShouldProcess("$($usb[0].DriveLetter):", 'Update boot files on the existing USB stick')) {
            Update-OSDCloudUSB
            Write-Ok 'Existing USB stick updated with the new WinPE'
        }
    }
    else {
        Write-Skip "USB stick found on $($usb[0].DriveLetter): and WinPE did not change"
    }

    if ($usb.Count -ne 1) {
        if ($WhatIfPreference) {
            Write-Step 'WhatIf: steps 7-9 need the USB stick. Re-run without -WhatIf to create it.'
            return
        }
        throw "Expected exactly one OSDCloudUSB volume after step 6, found $($usb.Count)."
    }
    $usbLetter = [string]$usb[0].DriveLetter
    $repoLof   = "$($usbLetter):\OSDCloud\Languages\LOF"

    #--- 7. Language ISO ---------------------------------------------------------------------------
    Write-Step '7/9  Languages and Optional Features ISO'
    $languagesOnStick = $true
    foreach ($lang in $Languages) {
        if (-not (Test-Path (Join-Path $repoLof "Microsoft-Windows-Client-Language-Pack_x64_$($lang.ToLower()).cab"))) {
            $languagesOnStick = $false
        }
    }
    $copyLanguages = (-not $languagesOnStick) -or $RefreshLanguages

    if (-not $copyLanguages) {
        Write-Skip "Language files already on the stick ($($Languages -join ', '))"
    }
    elseif ($LofIsoPath) {
        if (-not (Test-Path $LofIsoPath)) { throw "LOF ISO not found: $LofIsoPath" }
        Write-Ok "Using $LofIsoPath"
    }
    else {
        $LofIsoPath = Join-Path $DownloadPath ('Downloads\' + (Split-Path $Urls.LofIso -Leaf))
        if ($PSCmdlet.ShouldProcess($LofIsoPath, 'Download LOF ISO (several GB, can take a while)')) {
            Save-MicrosoftFile -Url $Urls.LofIso -Destination $LofIsoPath -Large
        }
    }

    #--- 8. Language repository + LCU on the stick -------------------------------------------------
    Write-Step '8/9  Language repository and cumulative update on the stick'
    $prepareArgs = @{ UsbDriveLetter = $usbLetter; Languages = $Languages; WhatIf = $WhatIfPreference }
    if ($copyLanguages) { $prepareArgs.LofIsoPath = $LofIsoPath }
    if ($LcuPath)       { $prepareArgs.LcuPath    = $LcuPath }

    if ($prepareArgs.ContainsKey('LofIsoPath') -or $prepareArgs.ContainsKey('LcuPath')) {
        & $PrepareScript @prepareArgs
    }
    else {
        Write-Skip 'Nothing to copy (languages present, no -LcuPath given)'
    }

    $lcuOnStick = @(Get-ChildItem -Path "$($usbLetter):\OSDCloud\Languages\LCU" -Filter '*.msu' -File -ErrorAction SilentlyContinue)
    if ($lcuOnStick.Count -eq 0) {
        Write-Warning 'No cumulative update on the stick yet (REQUIRED for deployments). Opening the Microsoft Update Catalog in your browser.'
        Write-Warning 'Download the newest "Cumulative Update for Windows 11 Version 25H2 for x64-based Systems" (.msu) to a folder, then re-run with -LcuPath <folder>.'
        if (-not $WhatIfPreference) { Start-Process $Urls.Catalog }
    }
    else {
        $lcuOnStick | ForEach-Object { Write-Ok "LCU on stick: $($_.Name) (copied $($_.LastWriteTime.ToString('yyyy-MM-dd')))" }
        $oldest = ($lcuOnStick | Measure-Object -Property LastWriteTime -Minimum).Minimum
        if ($oldest -lt (Get-Date).AddDays(-35)) {
            Write-Warning ('The cumulative update on the stick is older than 5 weeks. Download the latest one (all .msu files) ' +
                'and re-run with -LcuPath, otherwise the added language packs may not be updated.')
        }
    }

    #--- 9. Deployment script ----------------------------------------------------------------------
    Write-Step '9/9  Deployment script, start menu, Office and debloat files on the stick'
    $scriptDest = "$($usbLetter):\OSDCloud\Scripts"
    if ($PSCmdlet.ShouldProcess($scriptDest, 'Copy Deploy-OSDCloud-Win11-25H2.ps1')) {
        $null = New-Item -Path $scriptDest -ItemType Directory -Force
        Copy-Item -Path $DeployScript -Destination $scriptDest -Force
        Write-Ok "Copied to $scriptDest"
    }
    # OSDCloud runs every script in StartNet when WinPE boots. Only the MENU goes here, never the
    # deploy script itself: the menu asks for confirmation before anything is erased.
    $startNetDest = "$($usbLetter):\OSDCloud\Config\Scripts\StartNet"
    if ($PSCmdlet.ShouldProcess($startNetDest, 'Copy Start-OSDCloudDeployMenu.ps1')) {
        $null = New-Item -Path $startNetDest -ItemType Directory -Force
        Copy-Item -Path $MenuScript -Destination $startNetDest -Force
        Write-Ok "Start menu copied to $startNetDest"
    }
    # Not in OSDCloud\Config\Scripts: OSDCloud would pick that up on its own, also with -SkipOffice.
    $officeDest = "$($usbLetter):\OSDCloud\Office"
    if ($PSCmdlet.ShouldProcess($officeDest, 'Copy Office files')) {
        $null = New-Item -Path $officeDest -ItemType Directory -Force
        foreach ($file in $OfficeFiles) {
            Copy-Item -Path (Join-Path $OfficeFolder $file) -Destination $officeDest -Force
        }
        Write-Ok "Office files copied to $officeDest"
    }
    # Debloat script: download the pinned version once, verify it, then put it on the stick.
    $debloatCache = Join-Path $DownloadPath 'Downloads\RemoveBloat.ps1'
    $debloatDest  = "$($usbLetter):\OSDCloud\Debloat"
    if ($PSCmdlet.ShouldProcess($debloatDest, 'Download (pinned version) and copy RemoveBloat.ps1')) {
        if (-not (Test-Path $debloatCache) -or (Get-FileHash $debloatCache -Algorithm SHA256).Hash -ne $DebloatSha256) {
            $null = New-Item -Path (Split-Path $debloatCache) -ItemType Directory -Force
            Invoke-WebRequest -Uri $DebloatUrl -OutFile $debloatCache -UseBasicParsing
        }
        $hash = (Get-FileHash $debloatCache -Algorithm SHA256).Hash
        if ($hash -ne $DebloatSha256) {
            Remove-Item $debloatCache -Force
            throw "RemoveBloat.ps1 does not match the expected SHA-256 (got $hash). Not copied to the stick. See README section 11."
        }
        $null = New-Item -Path $debloatDest -ItemType Directory -Force
        Copy-Item -Path $debloatCache -Destination $debloatDest -Force
        Write-Ok "Debloat script (pinned, SHA-256 verified) copied to $debloatDest"
    }

    Write-Step 'Done'
    Write-Host '  Next: boot a test device (or Hyper-V Gen2 VM) from the stick. The deployment menu starts' -ForegroundColor White
    Write-Host '  automatically and asks for confirmation (type YES) before anything is erased.' -ForegroundColor White
}
catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Fix the issue and run the script again. Finished steps will be skipped.' -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Log: $logFile" -ForegroundColor DarkGray
}
#endregion -----------------------------------------------------------------------------------------
