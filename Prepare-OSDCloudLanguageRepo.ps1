<#
.SYNOPSIS
    Builds the language repository on the OSDCloud USB stick for Deploy-OSDCloud-Win11-25H2.ps1.

.DESCRIPTION
    Purpose:
        Run this on a technician PC (Windows 11, elevated PowerShell), NOT in WinPE.
        It copies only the files needed for the chosen languages from the Microsoft
        "Languages and Optional Features" (LOF) ISO for Windows 11 24H2/25H2 to:
            <USB>:\OSDCloud\Languages\LOF\
        and optionally the latest cumulative update (.msu) to:
            <USB>:\OSDCloud\Languages\LCU\

        Why only some files: the full LOF ISO is several GB. We copy the language packs, the
        language features and the satellite packages for the chosen languages, plus the
        metadata DISM needs to use the folder as a source.

        Re-run monthly with -LcuPath to refresh the cumulative update on the stick.

    Author:  <Your name> - 3-IT

.PARAMETER LofIsoPath
    Path to the LOF ISO for Windows 11 24H2/25H2 (file name starts with 26100.1.240331-1435).
    Optional: leave it out to only refresh the cumulative update (then -LcuPath is required).

.PARAMETER UsbDriveLetter
    Drive letter of the OSDCloudUSB data partition, for example D.

.PARAMETER Languages
    Languages to copy. Default: nl-NL, fr-FR (en-US is already in the base image).

.PARAMETER LcuPath
    Optional. Folder containing the .msu file(s) of the latest cumulative update for
    Windows 11 25H2 x64 (from the Microsoft Update Catalog). Existing .msu files in the LCU
    folder on the stick are replaced.

.EXAMPLE
    .\Prepare-OSDCloudLanguageRepo.ps1 -LofIsoPath 'C:\ISO\26100.1.240331-1435.ge_release_amd64fre_CLIENT_LOF_PACKAGES_OEM.iso' -UsbDriveLetter D -WhatIf

.EXAMPLE
    .\Prepare-OSDCloudLanguageRepo.ps1 -LofIsoPath 'C:\ISO\LOF.iso' -UsbDriveLetter D -LcuPath 'C:\Updates\25H2'

.EXAMPLE
    # Monthly: only replace the cumulative update on the stick
    .\Prepare-OSDCloudLanguageRepo.ps1 -UsbDriveLetter D -LcuPath 'C:\Updates\25H2'

.NOTES
    Version history
    Version  Date        Author          Change
    -------  ----------  --------------  ------------------------------------------------------------
    1.0.0    2026-10-23  <Your name>     Initial version
    1.1.0    2026-10-23  <Your name>     -LofIsoPath optional, to refresh only the LCU
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$LofIsoPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$UsbDriveLetter,

    [string[]]$Languages = @('nl-NL', 'fr-FR'),

    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$LcuPath
)

$ErrorActionPreference = 'Stop'

if (-not $LofIsoPath -and -not $LcuPath) {
    throw 'Specify -LofIsoPath, -LcuPath, or both.'
}

$usbRoot  = "$($UsbDriveLetter.ToUpper()):\"
$repoRoot = Join-Path $usbRoot 'OSDCloud\Languages'
$lofDest  = Join-Path $repoRoot 'LOF'
$lcuDest  = Join-Path $repoRoot 'LCU'

# Safety check: is this really the OSDCloud USB stick?
$volume = Get-Volume -DriveLetter $UsbDriveLetter
if ($volume.FileSystemLabel -ne 'OSDCloudUSB') {
    Write-Warning "Drive $usbRoot has label '$($volume.FileSystemLabel)', expected 'OSDCloudUSB'."
    if (-not $PSCmdlet.ShouldContinue("Use $usbRoot anyway?", 'Unexpected drive label')) { return }
}

$mounted = $null
if ($LofIsoPath) {
    try {
        Write-Host "Mounting $LofIsoPath ..." -ForegroundColor Cyan
        $mounted  = Mount-DiskImage -ImagePath (Resolve-Path $LofIsoPath).Path -PassThru
        $isoDrive = ($mounted | Get-Volume).DriveLetter
        $lofRoot  = "$($isoDrive):\LanguagesAndOptionalFeatures"
        if (-not (Test-Path $lofRoot)) {
            throw "Folder LanguagesAndOptionalFeatures not found on the ISO. Is this the LOF ISO?"
        }

        # Language files: everything whose name contains one of the language codes (case-insensitive).
        $langRegex = ($Languages | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $langFiles = @(Get-ChildItem -Path $lofRoot -File | Where-Object { $_.Name -match $langRegex })

        # Metadata DISM needs to use the folder as a FOD/language source.
        $metaFiles = @(Get-ChildItem -Path $lofRoot -File | Where-Object { $_.Name -match 'metadata' })
        $metaDir   = Join-Path $lofRoot 'metadata'

        foreach ($lang in $Languages) {
            $lp = "Microsoft-Windows-Client-Language-Pack_x64_$($lang.ToLower()).cab"
            if (-not ($langFiles | Where-Object { $_.Name -eq $lp })) {
                throw "Language pack $lp not found on the ISO."
            }
        }

        $sizeGB = [math]::Round((($langFiles + $metaFiles) | Measure-Object Length -Sum).Sum / 1GB, 2)
        Write-Host "Copying $($langFiles.Count) language files + metadata (~$sizeGB GB) to $lofDest" -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($lofDest, 'Copy language files')) {
            $null = New-Item -Path $lofDest -ItemType Directory -Force
            ($langFiles + $metaFiles) | Copy-Item -Destination $lofDest -Force
            if (Test-Path $metaDir) {
                Copy-Item -Path $metaDir -Destination $lofDest -Recurse -Force
            }
            Write-Host '  OK  Language files copied' -ForegroundColor Green
        }
    }
    finally {
        if ($mounted) {
            Dismount-DiskImage -ImagePath $mounted.ImagePath | Out-Null
            Write-Host 'ISO dismounted' -ForegroundColor DarkGray
        }
    }
}

if ($LcuPath) {
    $msu = @(Get-ChildItem -Path $LcuPath -Filter '*.msu' -File)
    if ($msu.Count -eq 0) { throw "No .msu files found in $LcuPath" }

    if ($PSCmdlet.ShouldProcess($lcuDest, "Replace cumulative update with: $($msu.Name -join ', ')")) {
        $null = New-Item -Path $lcuDest -ItemType Directory -Force
        Get-ChildItem -Path $lcuDest -Filter '*.msu' -File | Remove-Item -Force
        $msu | Copy-Item -Destination $lcuDest -Force
        Write-Host "  OK  LCU copied: $($msu.Name -join ', ')" -ForegroundColor Green
    }
}
else {
    Write-Warning "No -LcuPath given. Remember to put the latest 25H2 x64 cumulative update in $lcuDest."
}

Write-Host ''
Write-Host 'Done. Test the deployment script in WinPE with -WhatIf first.' -ForegroundColor Green
