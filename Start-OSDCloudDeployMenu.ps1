<#
.SYNOPSIS
    Start menu for the OSDCloud deployment: starts automatically in WinPE, but never wipes a device
    without a typed confirmation.

.DESCRIPTION
    Purpose:
        Initialize-OSDCloudBuild.ps1 copies this script to <USB>:\OSDCloud\Config\Scripts\StartNet.
        OSDCloud runs every script in that folder when WinPE starts, so the technician no longer has
        to find the drive letter and type the deployment command.

        Safety: booting a device from the stick by accident must never erase it. The menu waits
        (without a timeout) for a choice, runs the pre-flight checks of the deployment script with
        -WhatIf, shows the device and its disks, and only starts the real deployment after the
        technician types YES. Anything else cancels.

        Note: OSDCloud runs StartNet scripts BEFORE its own Wi-Fi prompt, so the menu offers its own
        Wi-Fi option. When you leave the menu, the normal OSDCloud start continues (Wi-Fi prompt,
        command prompt) and you can still deploy manually.

        Keys: only letters that are in the same place on US (QWERTY) and Belgian (AZERTY) keyboards
        are used (D, N, C, R, P, X; languages B, L, F, E; and the word YES), so it works whatever keyboard WinPE has. Number
        keys need Shift on AZERTY, so they are not used.

    Author:  <Your name> - 3-IT

.NOTES
    Version history
    Version  Date        Author          Change
    -------  ----------  --------------  ------------------------------------------------------------
    1.0.0    2026-10-23  <Your name>     Initial version
    1.1.0    2026-10-23  <Your name>     Show that debloat always runs
    1.1.1    2026-10-23  <Your name>     Fix: find the stick by label before every run (its drive letter
                                         changes after the disk is repartitioned); show the end of the
                                         deploy log when a deployment fails
    1.2.0    2026-10-24  <Your name>     Spare PowerShell window at start (minimized) and option [P]:
                                         the menu blocks OSDCloud's other windows, so there was no
                                         console while a deployment ran
    1.3.0    2026-10-25  <Your name>     Choose the display languages per deployment (all / NL / FR /
                                         English only), passed to the deploy script as -Languages
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

#region Configuration ------------------------------------------------------------------------------
# The deployment script on the stick. Found by the volume label every time, NOT by drive letter:
# the stick's letter changes when OSDCloud repartitions the internal disk.
$UsbLabel       = 'OSDCloudUSB'
$DeployRelative = 'OSDCloud\Scripts\Deploy-OSDCloud-Win11-25H2.ps1'
$InternetHost   = 'dl.delivery.mp.microsoft.com'   # Same Windows download server the deploy script checks
$InternetPort   = 80
$ConfirmWord    = 'YES'
#endregion -----------------------------------------------------------------------------------------

#region Helper functions ---------------------------------------------------------------------------
function Get-DeployScript {
    # Returns the current path of the deploy script on the stick, or $null.
    foreach ($volume in @(Get-Volume | Where-Object { $_.FileSystemLabel -eq $UsbLabel -and $_.DriveLetter })) {
        $path = "$($volume.DriveLetter):\$DeployRelative"
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Show-LastDeployLog {
    # The deploy script writes a transcript in WinPE. Show its end, so an error stays readable.
    $log = Get-ChildItem -Path 'X:\Windows\Temp' -Filter 'Deploy-OSDCloud-Win11-25H2_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
    if ($log) {
        Write-Host ''
        Write-Host "  Last lines of $($log.FullName):" -ForegroundColor DarkGray
        Get-Content -Path $log.FullName -Tail 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

function Open-SparePowerShell {
    # The menu runs inside OSDCloud's startup, so no other windows exist while it (or a deployment)
    # runs. A separate PowerShell window lets you read logs while DISM is busy.
    param([switch]$Minimized)
    $style = if ($Minimized) { 'Minimized' } else { 'Normal' }
    Start-Process -FilePath powershell.exe -WindowStyle $style -ArgumentList '-NoExit', '-NoProfile', '-Command',
        "`$host.UI.RawUI.WindowTitle = 'Extra PowerShell (3-IT)'; Write-Host 'Extra window. Logs: X:\Windows\Temp and X:\Windows\Logs\DISM' -ForegroundColor Cyan"
}

function Test-Internet {
    # Quick TCP check (also tests DNS). The deploy script does the full check before wiping.
    param([int]$Attempts = 1)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $client.ConnectAsync($InternetHost, $InternetPort)
            if ($connect.Wait(3000) -and $client.Connected) { return $true }
        }
        catch { }   # DNS or connection error: try again
        finally { $client.Dispose() }
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 5 }
    }
    return $false
}

function Show-DeviceInfo {
    $cs     = Get-CimInstance -ClassName Win32_ComputerSystem
    $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
    Write-Host "  Device:   $($cs.Manufacturer) $($cs.Model)"
    Write-Host "  Serial:   $serial"
    # Internal disks only: the USB stick is not touched by the deployment
    Get-Disk | Where-Object { $_.BusType -ne 'USB' } | Sort-Object Number | ForEach-Object {
        Write-Host ("  Disk {0}:   {1} ({2:N0} GB)" -f $_.Number, $_.FriendlyName, ($_.Size / 1GB))
    }
}

function Show-Menu {
    param([bool]$Online)
    Clear-Host
    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor Cyan
    Write-Host '   3-IT OSDCloud - Windows 11 25H2 Pro deployment' -ForegroundColor Cyan
    Write-Host '  ================================================================' -ForegroundColor Cyan
    Write-Host ''
    Show-DeviceInfo
    if ($Online) { Write-Host '  Internet: connected' -ForegroundColor Green }
    else         { Write-Host '  Internet: NOT connected - connect Ethernet or choose C for Wi-Fi' -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  [D]  Deploy Windows 11 + debloat + Microsoft 365 Apps'
    Write-Host '  [N]  Deploy Windows 11 + debloat, without Office (No Office)'
    Write-Host '  [C]  Connect to Wi-Fi'
    Write-Host '  [R]  Refresh (check the internet connection again)'
    Write-Host '  [P]  Open an extra PowerShell window'
    Write-Host '  [X]  Exit to the command prompt - nothing is changed'
    Write-Host ''
    Write-Host '  Debloat always runs (RemoveBloat.ps1 by Andrew Taylor): removes consumer apps, Copilot' -ForegroundColor DarkGray
    Write-Host '  and Recall, and clears the Start menu pins. Log: C:\ProgramData\Debloat\Debloat.log' -ForegroundColor DarkGray
    Write-Host ''
}

function Read-LanguageChoice {
    # Asks which extra display languages to install. Returns the value for the deploy script's
    # -Languages parameter, or $null when cancelled. Fewer languages = faster deployment.
    # Letters are in the same place on QWERTY and AZERTY (E, L, F, B, X).
    Write-Host ''
    Write-Host '  Which display languages? (English is always included)' -ForegroundColor Cyan
    Write-Host '  [B]  English + Nederlands + Francais  (Belgium, all three)'
    Write-Host '  [L]  English + Nederlands'
    Write-Host '  [F]  English + Francais'
    Write-Host '  [E]  English only                     (fastest: no language packs, no update from the stick)'
    Write-Host '  [X]  Cancel'
    while ($true) {
        switch ((Read-Host '  Languages').Trim().ToUpper()) {
            'B' { return 'nl-NL,fr-FR' }
            'L' { return 'nl-NL' }
            'F' { return 'fr-FR' }
            'E' { return 'none' }
            'X' { return $null }
            default { }
        }
    }
}

function Invoke-Deploy {
    # Runs the pre-flight checks (-WhatIf), asks for confirmation and starts the real deployment.
    # Each run is a separate PowerShell process, so a failure returns to the menu.
    param([switch]$SkipOffice)
    $DeployScript = Get-DeployScript
    if (-not $DeployScript) {
        Write-Host ''
        Write-Host "  The stick ($UsbLabel) or $DeployRelative was not found. Is the stick still connected?" -ForegroundColor Red
        Read-Host '  Press Enter to go back to the menu' | Out-Null
        return
    }
    $languages = Read-LanguageChoice
    if (-not $languages) { return }
    $deployArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $DeployScript, '-Languages', $languages)
    if ($SkipOffice) { $deployArgs += '-SkipOffice' }

    Write-Host ''
    Write-Host '  Running pre-flight checks (nothing is changed yet) ...' -ForegroundColor Cyan
    & powershell.exe @deployArgs -WhatIf
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '  Pre-flight checks FAILED (see above). Nothing was changed.' -ForegroundColor Red
        Read-Host '  Press Enter to go back to the menu' | Out-Null
        return
    }

    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor Red
    Write-Host '   WARNING: this ERASES the internal disk of this device:' -ForegroundColor Red
    Write-Host '  ================================================================' -ForegroundColor Red
    Show-DeviceInfo
    Write-Host "  Install:  Windows 11 + debloat$(if (-not $SkipOffice) { ' + Microsoft 365 Apps' }), languages: English$(if ($languages -ne 'none') { ', ' + $languages.Replace(',', ', ') })"
    Write-Host ''
    $answer = Read-Host "  Type $ConfirmWord to erase this device and install Windows (anything else cancels)"
    if ($answer.Trim() -ne $ConfirmWord) {
        Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    # On success the deploy script restarts the device itself; we only get back here on failure.
    & powershell.exe @deployArgs
    Show-LastDeployLog
    Write-Host ''
    Write-Host '  The deployment stopped (see the red DEPLOYMENT FAILED line above). Fix the cause and choose D or N again.' -ForegroundColor Red
    Write-Host '  Do not restart before you have read the error: the log above is only kept until WinPE restarts.' -ForegroundColor Red
    Read-Host '  Press Enter to go back to the menu' | Out-Null
}
#endregion -----------------------------------------------------------------------------------------

#region Main ---------------------------------------------------------------------------------------
if ($env:SystemDrive -ne 'X:') {
    Write-Warning 'This menu only runs in OSDCloud WinPE.'
    return
}
if (-not (Get-DeployScript)) {
    Write-Warning "Deployment script not found on the $UsbLabel stick ($DeployRelative). Rebuild the stick with Initialize-OSDCloudBuild.ps1."
    return
}

# Always keep a spare PowerShell window available (minimized: a small title bar at the bottom of the
# screen, click it to open). Without it there is no console while a deployment runs.
Open-SparePowerShell -Minimized

# Ethernet can still be waiting for an IP address this early in the boot: give it up to ~20 seconds.
Write-Host 'Checking the internet connection ...' -ForegroundColor DarkGray
$online = Test-Internet -Attempts 4

while ($true) {
    Show-Menu -Online $online
    $choice = (Read-Host '  Choice').Trim().ToUpper()
    switch ($choice) {
        'D' { Invoke-Deploy }
        'N' { Invoke-Deploy -SkipOffice }
        'C' {
            # Same command OSDCloud uses for its own Wi-Fi prompt, in a separate window
            Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-Command', 'Start-WinREWiFi' -Wait
            $online = Test-Internet -Attempts 3
        }
        'R' { $online = Test-Internet -Attempts 2 }
        'P' { Open-SparePowerShell }
        'X' {
            Write-Host '  Leaving the menu. Nothing was changed.' -ForegroundColor Yellow
            Write-Host "  To deploy manually: PowerShell -ExecutionPolicy Bypass -File $(Get-DeployScript)"
            return
        }
        default { }   # Unknown key: show the menu again
    }
}
#endregion -----------------------------------------------------------------------------------------
