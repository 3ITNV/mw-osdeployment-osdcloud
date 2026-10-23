<#
.SYNOPSIS
    Installs Microsoft 365 Apps during SetupComplete, using the same Office Deployment Tool
    configuration as our Intune package.

.DESCRIPTION
    Purpose:
        Runs in the NEW Windows (not WinPE) as SYSTEM during SetupComplete, after OSDCloud's own
        Windows Update steps and before the device restarts into OOBE.
        Deploy-OSDCloud-Win11-25H2.ps1 copies this script, setup.exe and installM365BP.xml to
        C:\OSDCloud\Scripts\SetupComplete\Office and creates the SetupComplete.cmd that starts it.

        Office is downloaded from the Microsoft CDN, so the device needs internet. The script waits
        for the CDN to be reachable, runs setup.exe /configure, and checks the product is installed.
        A failure is logged but does not stop OOBE: the technician checks Office after logging in.

        Logs:
            C:\OSDCloud\Logs\Install-M365Apps_<date>.log                           (this script)
            C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\M365AppsBusiness  (setup.exe,
            path set in installM365BP.xml)

    Author:  <Your name> - 3-IT

.PARAMETER ConfigFile
    Office Deployment Tool XML. Default: installM365BP.xml next to this script.

.EXAMPLE
    # Normally started by SetupComplete.cmd. Manual run (elevated), for example to retry:
    powershell.exe -ExecutionPolicy Bypass -File C:\OSDCloud\Scripts\SetupComplete\Office\Install-M365Apps.ps1

.NOTES
    Version history
    Version  Date        Author          Change
    -------  ----------  --------------  ------------------------------------------------------------
    1.0.0    2026-10-23  <Your name>     Initial version
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'installM365BP.xml')
)

$ErrorActionPreference = 'Stop'

#region Configuration ------------------------------------------------------------------------------
$SetupExe           = Join-Path $PSScriptRoot 'setup.exe'
$LogFolder          = 'C:\OSDCloud\Logs'
$CdnHost            = 'officecdn.microsoft.com'
$NetworkWaitMinutes = 10
$MaxAttempts        = 2
$C2RConfigKey       = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
#endregion -----------------------------------------------------------------------------------------

#region Helper functions ---------------------------------------------------------------------------
function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Test-ProductInstalled {
    # Click-to-Run lists the installed products in ProductReleaseIds, for example
    # "O365BusinessEEANoTeamsRetail".
    param([Parameter(Mandatory)][string]$ProductId)
    $ids = (Get-ItemProperty -Path $C2RConfigKey -ErrorAction SilentlyContinue).ProductReleaseIds
    return ($ids -and ($ids -split ',') -contains $ProductId)
}
#endregion -----------------------------------------------------------------------------------------

#region Main ---------------------------------------------------------------------------------------
$null = New-Item -Path $LogFolder -ItemType Directory -Force
$logFile = Join-Path $LogFolder "Install-M365Apps_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logFile -Force | Out-Null
$exitCode = 1

try {
    foreach ($file in $SetupExe, $ConfigFile) {
        if (-not (Test-Path $file)) { throw "File not found: $file" }
    }
    $productId = ([xml](Get-Content -Path $ConfigFile -Raw)).Configuration.Add.Product.ID
    if (-not $productId) { throw "No <Product ID> found in $ConfigFile." }
    Write-Step "Product: $productId (config: $(Split-Path $ConfigFile -Leaf))"

    if (Test-ProductInstalled -ProductId $productId) {
        # Safe to re-run: nothing happens when Office is already there.
        Write-Step "$productId is already installed. Nothing to do."
        exit 0   # The finally block below still runs and stops the transcript
    }

    # The network can take a moment after Windows Update restarts services.
    Write-Step "Waiting for $CdnHost (max $NetworkWaitMinutes minutes)"
    $deadline = (Get-Date).AddMinutes($NetworkWaitMinutes)
    while (-not (Test-NetConnection -ComputerName $CdnHost -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { throw "$CdnHost not reachable after $NetworkWaitMinutes minutes. No internet?" }
        Start-Sleep -Seconds 15
    }
    Write-Step "$CdnHost reachable"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Step "Running setup.exe /configure (attempt $attempt of $MaxAttempts, this can take 15-30 minutes)"
        $process = Start-Process -FilePath $SetupExe -ArgumentList "/configure `"$ConfigFile`"" `
            -WorkingDirectory $PSScriptRoot -Wait -PassThru -WindowStyle Hidden
        Write-Step "setup.exe exit code: $($process.ExitCode)"
        if ($process.ExitCode -eq 0 -and (Test-ProductInstalled -ProductId $productId)) { break }
        if ($attempt -eq $MaxAttempts) {
            throw "Microsoft 365 Apps installation failed (exit code $($process.ExitCode)). See the setup.exe logs."
        }
        Start-Sleep -Seconds 60
    }

    Write-Step "OK  $productId installed"
    $exitCode = 0
}
catch {
    Write-Host "OFFICE INSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'OOBE continues. Install Office afterwards (for example via Intune) or re-run this script.' -ForegroundColor Red
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
exit $exitCode
#endregion -----------------------------------------------------------------------------------------
