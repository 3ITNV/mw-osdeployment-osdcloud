# mw-osdeployment-osdcloud

Zero-touch deployment of **Windows 11 25H2 Pro (Retail)** with OSDCloud, built from a USB stick.

When a device is imaged with this stick, the user can choose **English, Dutch or French** during the first-boot setup (OOBE), followed by region and keyboard layout. No driver packs are used: only network drivers are installed during imaging, everything else comes from Windows Update. **Microsoft 365 Apps** are installed before OOBE, with the same configuration as our Intune package.

> **WARNING - the deployment wipes the device's disk without asking.** Only boot a device from this stick if you really want to reinstall it.

---

## Table of contents

1. [What you end up with](#1-what-you-end-up-with)
2. [Files in this repo](#2-files-in-this-repo)
3. [Requirements](#3-requirements)
4. [First-time setup (build the USB stick)](#4-first-time-setup-build-the-usb-stick)
5. [Monthly: download the cumulative update (.msu)](#5-monthly-download-the-cumulative-update-msu)
6. [Monthly: put the update on the stick](#6-monthly-put-the-update-on-the-stick)
7. [Deploying a device](#7-deploying-a-device)
8. [What happens during a deployment](#8-what-happens-during-a-deployment)
9. [Troubleshooting](#9-troubleshooting)
10. [Log files](#10-log-files)
11. [Changing the scripts](#11-changing-the-scripts)
12. [No-secrets policy](#12-no-secrets-policy)

---

## 1. What you end up with

| Item | Value |
|---|---|
| Windows version | Windows 11 25H2, x64 |
| Edition / license | Pro, Retail (activates with the key in the device firmware, if present) |
| Languages | English (base), Dutch (nl-NL), French (fr-FR) - chosen by the user in OOBE |
| Keyboard | Chosen by the user in OOBE (for example Belgian period / Belgian French) |
| Drivers during imaging | Only Ethernet and Wi-Fi (copied from WinPE) |
| Other drivers + firmware | Installed by Windows Update before OOBE starts |
| Updates | Cumulative update from the stick (recommended, not required) + Windows Update |
| Office | Microsoft 365 Apps for business, without Teams (`O365BusinessEEANoTeamsRetail`), 64-bit, Monthly Enterprise Channel, en/nl/fr. Skip with `-SkipOffice` |
| Autopilot | Not included |

---

## 2. Files in this repo

Keep the three scripts and the `Office` folder **together in one folder** (for example `C:\Git\mw-osdeployment-osdcloud`). The main script looks for the rest next to itself.

| Script | Runs on | You start it? | What it does |
|---|---|---|---|
| `Initialize-OSDCloudBuild.ps1` | Your PC | **Yes** - first setup and monthly | Installs the tools, builds WinPE and the USB stick, fills the stick. Calls the other two scripts. |
| `Prepare-OSDCloudLanguageRepo.ps1` | Your PC | No (called automatically) | Copies the language files and the cumulative update to the stick. |
| `Deploy-OSDCloud-Win11-25H2.ps1` | WinPE on the device | **Yes** - once per device | Wipes the disk and installs Windows with languages and updates, and prepares the Office install. Copied to the stick automatically. |
| `Office\Install-M365Apps.ps1` | The new Windows, before OOBE | No (runs automatically) | Installs Microsoft 365 Apps with `setup.exe` and `installM365BP.xml`. |

**The `Office` folder** uses the same `setup.exe` and install XML as our Intune package for Microsoft 365 Apps:

| File | What it is |
|---|---|
| `setup.exe` | Office Deployment Tool (signed by Microsoft) |
| `installM365BP.xml` | Install configuration: product, languages, update channel, default file formats |
| `Install-M365Apps.ps1` | Runs `setup.exe` during the deployment, waits for internet, retries once and checks the result |

**Rule of thumb:** on your PC you only run `Initialize-OSDCloudBuild.ps1`. On a device you only run `Deploy-OSDCloud-Win11-25H2.ps1` from the stick.

---

## 3. Requirements

**Technician PC (the PC that builds the stick)**

- Windows 11 with the **recovery environment enabled** (check with `reagentc /info`, it should say `Enabled`)
- Local administrator rights
- **Windows PowerShell 5.1** (the blue one, `powershell.exe`). **Not** PowerShell 7 (`pwsh.exe`).
- At least 20 GB free on `C:`
- Internet access
- If your security software blocks the build (see [Troubleshooting](#9-troubleshooting)), use a dedicated build VM instead.

**USB stick**

- At least **32 GB** (16 GB is the bare minimum, but leaves little room)
- **USB 3.x recommended** - copying the update and language files to a slow stick takes a long time
- **Everything on the stick is erased** the first time

**Device to image**

- Internet during deployment (Ethernet or Wi-Fi)
- Connected to power (firmware updates are skipped on battery)

---

## 4. First-time setup (build the USB stick)

Do this **once**. It takes about 1 to 1.5 hours, mostly downloading.

### Step 4.1 - Get the scripts

Clone this repo to `C:\Git\mw-osdeployment-osdcloud` (GitHub Desktop: **File > Clone a repository**). You need all of it: the three `.ps1` files **and** the `Office` folder.

### Step 4.2 - Open the right PowerShell

1. Click **Start**, type `Windows PowerShell`.
2. Right-click **Windows PowerShell** (not "PowerShell 7") and choose **Run as administrator**.
3. Check you have the right one:
   ```powershell
   $PSVersionTable.PSVersion
   ```
   The first number must be **5**.

### Step 4.3 - Allow the scripts to run

Files downloaded from the internet (for example as a ZIP) are blocked by Windows. Unblock them once, including the `Office` folder:

```powershell
cd C:\Git\mw-osdeployment-osdcloud
Get-ChildItem -Recurse -File | Unblock-File
Set-ExecutionPolicy RemoteSigned -Scope Process
```

The last line only applies to this PowerShell window. You need to repeat it each time you open a new window.

### Step 4.4 - Download the cumulative update (recommended)

Follow [section 5](#5-monthly-download-the-cumulative-update-msu) and save the `.msu` file(s) to `C:\Updates\25H2`. If you skip this, leave `-LcuPath` out of the command in step 4.7. The stick works without it; see section 5 for what you miss.

### Step 4.5 - Plug in ONE USB stick

- Plug in the stick you want to use.
- **Unplug all other USB sticks and external drives.** This avoids erasing the wrong one.

### Step 4.6 - Dry run (changes nothing)

```powershell
.\Initialize-OSDCloudBuild.ps1 -WhatIf
```

Read the output. Lines starting with `What if:` show what the real run would do.

### Step 4.7 - Real run

```powershell
.\Initialize-OSDCloudBuild.ps1 -LcuPath 'C:\Updates\25H2'
```

What you will see:

| Step | Duration | Notes |
|---|---|---|
| 1/9 Pre-flight checks | seconds | Also checks the `Office` folder is complete |
| 2/9 Windows ADK + WinPE add-on | 10-20 min | Only the first time |
| 3/9 OSD module | 1-5 min | |
| 4/9 Template and workspace | 5-10 min | |
| 5/9 Network drivers in WinPE | 10-20 min | Downloads driver packs |
| 6/9 USB stick | 5-10 min | **Asks to confirm erasing the stick, then a window asks you to pick the stick** |
| 7/9 Language ISO | 10-30 min | Downloads several GB |
| 8/9 Language files + update | 10-30 min | Copies to the stick, **no progress bar** - see note below |
| 9/9 Deployment script + Office files | seconds | |

**Step 8 looks frozen?** That is normal. Copying several GB to a USB stick shows no progress. Open **Task Manager > Performance**, select the USB stick and check the write speed is above 0. Do **not** unplug the stick.

You are done when the output ends with:

```
=== [..:..:..] Done
```

### Step 4.8 - If the script stops with an error

- Read the red `FAILED:` line.
- Fix the problem (see [Troubleshooting](#9-troubleshooting)).
- Run the **same command again**. Steps that already finished are skipped automatically.

---

## 5. Monthly: download the cumulative update (.msu)

Microsoft releases a new cumulative update on the **second Tuesday of every month** ("Patch Tuesday"). Putting it on the stick each month is **recommended, but not required** - deployments keep working if you forget.

> **Why it helps:** the deployment adds Dutch and French to Windows. Microsoft requires the cumulative update to be installed again after adding languages, otherwise some text can stay in English. Windows Update does not do this, because it never offers an update that is already installed.
>
> **What happens if the update on the stick is missing or old:** the deployment shows a yellow warning and continues. Usually Windows Update installs a newer update during setup anyway, which also fixes the languages. Only when the downloaded Windows image is already fully up to date can some text stay in English, until the next Patch Tuesday update arrives.

### Step 5.1 - Open the Microsoft Update Catalog

Go to <https://www.catalog.update.microsoft.com>

### Step 5.2 - Search

Type exactly this in the search box and press Enter:

```
Cumulative Update for Windows 11 Version 25H2 for x64-based Systems
```

### Step 5.3 - Pick the right line

Click the **Last Updated** column header so the newest is at the top. Choose the newest line that matches **all** of these:

| Must contain | Must NOT contain |
|---|---|
| `Cumulative Update for Windows 11 Version 25H2` | `Preview` |
| `x64-based Systems` | `arm64` |
| | `.NET Framework` |
| | `Dynamic Update` |
| | `Server` |

Example of a correct title (the date and KB number change every month):

```
2026-10 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5xxxxxx)
```

### Step 5.4 - Download

1. Click **Download** on that line. A small window opens.
2. Click the `.msu` link(s) in that window.
   - **If there is more than one `.msu` file listed, download all of them.** Since Windows 11 24H2, some updates need an older "checkpoint" update next to them.
3. Save the file(s) to a **new, empty folder** for this month, for example:
   ```
   C:\Updates\2026-11
   ```
   Do not mix files from different months in one folder.

### Step 5.5 - Check the file

The file name should look like this (x64 is the default and correct for all our devices):

```
windows11.0-kb5xxxxxx-x64_<long code>.msu
```

If it says `arm64` instead of `x64`, you downloaded the wrong one.

---

## 6. Monthly: put the update on the stick

Choose **one** of the two options.

### Option A - With the script (recommended)

1. Plug in the OSDCloud stick (only that one).
2. Open **Windows PowerShell as administrator** (see [step 4.2](#step-42---open-the-right-powershell)).
3. Run:
   ```powershell
   cd C:\Git\mw-osdeployment-osdcloud
   Set-ExecutionPolicy RemoteSigned -Scope Process
   .\Initialize-OSDCloudBuild.ps1 -LcuPath 'C:\Updates\2026-11'
   ```
4. Steps 1 to 7 are skipped. Step 8 replaces the old update with the new one.
5. Wait for `=== Done`.

### Option B - Manually (no script)

Use this if the script is not available or you only want to swap the file.

1. Plug in the OSDCloud stick.
2. Open **File Explorer** and find the drive named **OSDCloudUSB**.
   - **Not** the drive named **WinPE** - never put files there, they get deleted when the stick is updated.
3. Go to this folder:
   ```
   OSDCloudUSB:\OSDCloud\Languages\LCU
   ```
4. **Delete** the old `.msu` file(s) in that folder.
5. **Copy** the new `.msu` file(s) from `C:\Updates\2026-11` into that folder.
6. Wait until the copy is completely finished, then use **Safely Remove Hardware** before unplugging.

The `LCU` folder must contain **only this month's** `.msu` file(s) and nothing else.

### What the stick should look like

```
WinPE (small partition)        <- boot files, do not touch
OSDCloudUSB (data partition)
└── OSDCloud
    ├── Languages
    │   ├── LOF                <- language files (filled once)
    │   └── LCU                <- this month's .msu file(s) ONLY
    ├── Office                 <- setup.exe, installM365BP.xml, Install-M365Apps.ps1
    └── Scripts
        └── Deploy-OSDCloud-Win11-25H2.ps1
```

---

## 7. Deploying a device

> **WARNING - this erases the device's disk without asking.** Make sure you have the right device and that any data on it is backed up.

### Step 7.1 - Boot from the stick

1. Connect the device to **power** and, if possible, **Ethernet**.
2. Plug in the stick.
3. Turn on the device and open the **boot menu**. Common keys:

   | Brand | Boot menu key |
   |---|---|
   | Dell | F12 |
   | HP | F9 (or Esc, then F9) |
   | Lenovo | F12 (or the small Novo button) |
   | Microsoft Surface | Hold **Volume Down**, press and release Power, keep holding Volume Down until the logo appears |

4. Choose the **USB** entry (UEFI).

If the device does not boot from the stick, check in the firmware (BIOS) settings that USB boot is allowed. Leave Secure Boot **on**.

### Step 7.2 - Connect to the internet (Wi-Fi only)

WinPE starts and opens a blue PowerShell window. On Ethernet you can skip this step. For Wi-Fi, OSDCloud usually shows a connection prompt. If it does not, run:

```powershell
Start-WinREWiFi
```

and pick the network.

**Keyboard:** WinPE uses the **Belgian (Period)** keyboard (AZERTY), so type the Wi-Fi password as on a normal Belgian keyboard. Sticks built before build script version 1.2.0 still use the US keyboard (QWERTY). On such a stick, switch for this session and open a new window, because the change only applies to programs started afterwards:

```powershell
wpeutil SetKeyboardLayout 0813:00000813
start powershell
```

Then run `Start-WinREWiFi` in the new window. Better: rebuild the stick with `-RebuildWinPE` (see [section 11](#11-changing-the-scripts)).

Use a **dedicated deployment or guest network** if possible: the Wi-Fi password is copied to the new Windows so it can connect during setup.

### Step 7.3 - Find the stick's drive letter

```powershell
Get-Volume | Where-Object FileSystemLabel -eq 'OSDCloudUSB'
```

Note the letter in the `DriveLetter` column (for example `E`). It can differ from device to device.

### Step 7.4 - Dry run (recommended, changes nothing)

Replace `E` with your letter:

```powershell
PowerShell -ExecutionPolicy Bypass -File E:\OSDCloud\Scripts\Deploy-OSDCloud-Win11-25H2.ps1 -WhatIf
```

All lines should say `OK`, including the `Internet:` lines. A yellow warning about the cumulative update means the `LCU` folder is empty. You can still deploy; see [section 5](#5-monthly-download-the-cumulative-update-msu) for what that means.

### Step 7.5 - Real deployment

```powershell
PowerShell -ExecutionPolicy Bypass -File E:\OSDCloud\Scripts\Deploy-OSDCloud-Win11-25H2.ps1
```

Takes roughly 30 to 60 minutes depending on internet speed and the stick. **Do not unplug the stick** until the device restarts by itself.

**Customer without Microsoft 365 Apps?** Add `-SkipOffice` to the command (also to the dry run):

```powershell
PowerShell -ExecutionPolicy Bypass -File E:\OSDCloud\Scripts\Deploy-OSDCloud-Win11-25H2.ps1 -SkipOffice
```

If it fails, the device does **not** restart and you see a red `DEPLOYMENT FAILED` message. Fix the cause and run the same command again.

### Step 7.6 - After the restart

1. The device restarts and shows "Getting ready" for a while. Windows Update is installing drivers and updates, then Microsoft 365 Apps are downloaded and installed. **This can take 30 to 75 minutes.** Do not turn it off.
2. It may restart once more by itself.
3. OOBE starts:
   1. **Choose a language** - English, Nederlands or Français
   2. **Choose a region** - for example Belgium
   3. **Choose a keyboard layout** - for example Belgian (Period) or Belgian French
   4. Optionally add a second keyboard
4. Finish the setup as usual.

### Step 7.7 - Quick check after logging in

- **Settings > Windows Update**: check for updates, install what is offered.
- **Device Manager**: no yellow exclamation marks. If there are, run Windows Update again and restart.
- **Settings > System > Activation**: should show "Windows is activated" (if the device has a Pro key in its firmware).
- **Start menu**: Word, Excel, Outlook and PowerPoint are there (unless you used `-SkipOffice`). If not, see the Office log in [section 10](#10-log-files). A failed Office install does not stop the deployment.

---

## 8. What happens during a deployment

For the curious - you do not need to know this to use it.

1. **Pre-flight checks** - checks it runs in WinPE, the device has internet (Microsoft's Windows and Office download servers are reachable) and the language and Office files are on the stick, **before** anything is erased. This matters because OSDCloud erases the disk first and only then downloads Windows.
2. **OSDCloud** - erases the disk, downloads Windows 11 25H2 Pro (en-US) from Microsoft and applies it. No driver packs.
3. **Network drivers** - copies the Ethernet/Wi-Fi drivers WinPE is using into the new Windows, so it has internet at first boot.
4. **Languages** - adds the nl-NL and fr-FR language packs and language features. Because more than one language is installed, OOBE shows the language choice.
5. **Cumulative update** - applied again after the languages. Microsoft requires this, otherwise parts of Windows can stay in English. Windows Update would not do it, because it does not offer an update that is already installed. If the update on the stick is missing or older than the one in the Windows image, this step is skipped with a warning.
6. **Office staged** - copies `setup.exe`, the XML and `Install-M365Apps.ps1` to `C:\OSDCloud\Scripts\SetupComplete\Office` and creates a `SetupComplete.cmd` that starts it. Office cannot be installed from WinPE, so it has to wait for the new Windows.
7. **Restart** - in the new Windows, SetupComplete runs before OOBE: Windows Update installs the remaining drivers, firmware and updates, then OSDCloud runs our `SetupComplete.cmd` and Microsoft 365 Apps are downloaded from Microsoft and installed. Then the device restarts into OOBE.

---

## 9. Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `Security warning ... Do you want to run ...?` | Files downloaded from the internet are blocked | `Get-ChildItem -Recurse -File \| Unblock-File` in the repo folder |
| `... cannot be loaded because running scripts is disabled` | Execution policy | `Set-ExecutionPolicy RemoteSigned -Scope Process` |
| `#Requires ... Desktop` error | You opened PowerShell 7 | Use **Windows PowerShell** (5.1), see [step 4.2](#step-42---open-the-right-powershell) |
| `More than one OSDCloudUSB stick connected` | Two OSDCloud sticks plugged in | Unplug one, run again |
| `Windows Recovery Environment is not available` | WinRE disabled on your PC | Run `reagentc /enable` as administrator, run again |
| `New-OSDCloudTemplate could not add ... WinPE package(s)` / error `0xd0000043` | Files locked, usually by antivirus/EDR | Clean up (below), add exclusions or use a build VM, then run with `-RebuildWinPE` |
| Step 8 seems frozen | Large copy to USB, no progress bar | Normal. Check write speed in Task Manager. Wait. |
| `No cumulative update on the stick yet` (build) | `LCU` folder empty | Recommended, not required: follow [section 5](#5-monthly-download-the-cumulative-update-msu) and [section 6](#6-monthly-put-the-update-on-the-stick) |
| `The cumulative update on the stick is older than 5 weeks` | You skipped a month | Deployments still work. Download the new update and put it on the stick |
| `The cumulative update on the stick is older than the one already in the Windows image (not applicable)` (deployment warning) | The update on the stick is older than the one inside the downloaded Windows image | The deployment continues. Put the latest update on the stick for the next devices |
| `Language repository ... not found on any drive` (deployment) | Stick not detected or language files missing | Check the stick is plugged in. Rebuild with `.\Initialize-OSDCloudBuild.ps1 -RefreshLanguages` |
| `No third-party network drivers in use in WinPE` (warning) | Device uses a network chip Windows already supports (normal on VMs) | Nothing to do |
| No language choice in OOBE | Language packs missing | Check the deployment log for errors in step "Adding language" |
| Wi-Fi password is not accepted in WinPE | Wrong keyboard layout: the stick still has a US (QWERTY) WinPE | Use `wpeutil SetKeyboardLayout 0813:00000813` (see [step 7.2](#step-72---connect-to-the-internet-wi-fi-only)), or rebuild the stick with `-RebuildWinPE` |
| `No internet: cannot reach ...` (deployment pre-flight) | No network in WinPE, no Wi-Fi driver, or a network that blocks the download (for example a guest network with a login page) | Nothing was erased. Connect Ethernet, or Wi-Fi with `Start-WinREWiFi`, and run the same command again |
| `Office file not found` (deployment pre-flight) | Stick was built before Office was added | Run `.\Initialize-OSDCloudBuild.ps1` again (step 9 copies the Office folder), or deploy with `-SkipOffice` |
| Office missing after OOBE | No internet during SetupComplete, or setup.exe failed | Check the Office logs ([section 10](#10-log-files)). Retry as administrator: `powershell.exe -ExecutionPolicy Bypass -File C:\OSDCloud\Scripts\SetupComplete\Office\Install-M365Apps.ps1` |
| Files disappeared from the stick | They were on the **WinPE** partition, which is mirrored on update | Only store files on the **OSDCloudUSB** partition |

**Clean up after a failed WinPE build** (run as administrator):

```powershell
Get-WindowsImage -Mounted | ForEach-Object { Dismount-WindowsImage -Path $_.Path -Discard }
Clear-WindowsCorruptMountPoint
```

**Rebuild everything from scratch:**

```powershell
.\Initialize-OSDCloudBuild.ps1 -RebuildWinPE -RecreateUsb -RefreshLanguages -LcuPath 'C:\Updates\<this month>'
```

**Useful switches for `Initialize-OSDCloudBuild.ps1`:**

| Switch | What it does |
|---|---|
| `-WhatIf` | Shows what would happen, changes nothing |
| `-LcuPath <folder>` | Puts the `.msu` file(s) from that folder on the stick |
| `-RebuildWinPE` | Rebuilds WinPE even if it already exists |
| `-RecreateUsb` | Erases and recreates the stick (asks to confirm) |
| `-RefreshLanguages` | Copies the language files to the stick again |
| `-LofIsoPath <file>` | Uses an already downloaded language ISO instead of downloading it |

---

## 10. Log files

When asking for help, send the relevant log.

| What | Where |
|---|---|
| Build script | `C:\OSDCloudBuild\Logs\Initialize-OSDCloudBuild_<date>.log` |
| WinPE template (per package) | `C:\ProgramData\OSDCloud\Logs\Template\` |
| Deployment (on the imaged device, after imaging) | `C:\OSDCloud\Logs\Deploy-OSDCloud-Win11-25H2_<date>.log` |
| Deployment (if it failed in WinPE) | `X:\Windows\Temp\` - copy it to the stick's **OSDCloudUSB** partition before rebooting |
| Office install script | `C:\OSDCloud\Logs\Install-M365Apps_<date>.log` |
| Office setup.exe (path set in `installM365BP.xml`) | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\M365AppsBusiness\` |
| OSDCloud SetupComplete (Windows Update + Office) | `C:\Windows\Temp\osdcloud-logs\SetupComplete.log` |

---

## 11. Changing the scripts

- **Always edit the scripts in the repo folder**, never directly on the stick. Then run `Initialize-OSDCloudBuild.ps1` again - step 9 copies the new deployment script to the stick.
- Settings (Windows version, edition, languages) are at the top of `Deploy-OSDCloud-Win11-25H2.ps1` in the `Configuration` section.
- The **WinPE keyboard** is `$WinPEInputLocale` in the `Configuration` section of `Initialize-OSDCloudBuild.ps1`: Belgian (Period) `0813:00000813` by default, Belgian French is `080C:0000080C`. It only affects WinPE (typing the Wi-Fi password); users still choose their own keyboard in OOBE. WinPE is only built once, so after changing it (or to update an older stick) run:
  ```powershell
  .\Initialize-OSDCloudBuild.ps1 -RebuildWinPE
  ```
  This rebuilds WinPE (about 30 minutes) and updates the stick's boot files. The language files, Office files and update on the stick stay as they are.
- Office settings (product, languages, channel, excluded apps) are in `Office\installM365BP.xml`. It is the same file as in our Intune package: **when you change one, change the other too.** Build a new XML with the [Office Customization Tool](https://config.office.com).
- After changing anything in `Office\`, run `Initialize-OSDCloudBuild.ps1` again so the stick gets the new files.
- **Updating the Office Deployment Tool (`Office\setup.exe`)** - Microsoft releases a new version about once a month and recommends always using the latest ([release history](https://learn.microsoft.com/officeupdates/odt-release-history)). To update:
  1. Download `officedeploymenttool_<version>.exe` from the [Microsoft Download Center](https://www.microsoft.com/download/details.aspx?id=49117).
  2. Run it, accept the licence and extract it to an empty temporary folder. It only extracts files, it installs nothing.
  3. Copy **only** `setup.exe` from that folder over `Office\setup.exe`. Ignore the sample `.xml` files.
  4. Update the Intune package with the same `setup.exe`, run `Initialize-OSDCloudBuild.ps1` (it checks the Microsoft signature) and commit.
- Every script starts with a version history. **Bump the version and add a line** for each change.
- Test with `-WhatIf` and on a test device or VM before using it on customer devices.
- Commit with a clear message and push to `main`.

**Do not** put the deployment script in the stick's `OSDCloud\Config\Scripts\StartNet` folder. Scripts there start automatically at boot, so booting a device from the stick by accident would erase it immediately.

---

## 12. No-secrets policy

This repository must **never** contain:

- Passwords, product keys, API keys, tokens or certificates
- Customer data, tenant names, tenant IDs or other tenant configuration
- Wi-Fi names or passwords
- Log files from customer devices

Use placeholders such as `contoso.onmicrosoft.com` in examples. Before every push, check the changes (`git diff`) for anything sensitive. If you accidentally committed a secret, tell the team immediately - removing it from history is not enough, it must be rotated.
