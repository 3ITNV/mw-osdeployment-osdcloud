# mw-osdeployment-osdcloud

Zero-touch deployment of **Windows 11 25H2 Pro (Retail)** with OSDCloud, built from a USB stick.

When a device is imaged with this stick, the user can choose **English, Dutch or French** during the first-boot setup (OOBE), followed by region and keyboard layout. No driver packs are used: only network drivers are installed during imaging, everything else comes from Windows Update. **Microsoft 365 Apps** are installed before OOBE, with the same configuration as our Intune package.

> **WARNING - a deployment wipes the device's disk.** A menu starts automatically when you boot from the stick, but nothing is erased until you type `YES`. Only confirm if you really want to reinstall that device.

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
| Languages | English (base), plus Dutch (nl-NL) and/or French (fr-FR) - **chosen per device in the menu**; the user picks one in OOBE. There are no separate Belgian language packs: Belgium is set as region and keyboard. **Autopilot:** set "Language (Region)" in the Autopilot profile to **User select**, otherwise OOBE skips the language choice (see [step 7.8](#step-78---after-the-restart-setupcomplete-and-oobe)) |
| Keyboard | Chosen by the user in OOBE (for example Belgian period / Belgian French) |
| Drivers during imaging | Only Ethernet and Wi-Fi (copied from WinPE) |
| Other drivers + firmware | Installed by Windows Update before OOBE starts |
| Updates | Cumulative update from the stick (**required**, see section 5) + Windows Update |
| Feature updates | Held at 25H2 during the deployment (Windows Update offered 26H2), lifted again before OOBE. After that, the customer's Intune feature update policy decides |
| Office | Microsoft 365 Apps for business, without Teams (`O365BusinessEEANoTeamsRetail`), 64-bit, Monthly Enterprise Channel, en/nl/fr. Skip with `-SkipOffice` |
| Debloat | Always: [RemoveBloat.ps1 by Andrew Taylor](https://github.com/andrew-s-taylor/public/tree/main/De-Bloat) removes consumer apps (Xbox, Solitaire, News, Clipchamp, ...), Copilot and Recall, and clears the Start menu pins. The Microsoft 365 Copilot app and our Office stay |
| Autopilot | Not included |

---

## 2. Files in this repo

Keep the four scripts and the `Office` folder **together in one folder** (for example `C:\Git\mw-osdeployment-osdcloud`). The main script looks for the rest next to itself.

| Script | Runs on | You start it? | What it does |
|---|---|---|---|
| `Initialize-OSDCloudBuild.ps1` | Your PC | **Yes** - first setup and monthly | Installs the tools, builds WinPE and the USB stick, fills the stick. Calls `Prepare-OSDCloudLanguageRepo.ps1`. |
| `Prepare-OSDCloudLanguageRepo.ps1` | Your PC | No (called automatically) | Copies the language files and the cumulative update to the stick. |
| `Start-OSDCloudDeployMenu.ps1` | WinPE on the device | No (starts automatically at boot) | The deployment menu: checks the device, asks what to install and asks for confirmation (`YES`) before anything is erased. |
| `Deploy-OSDCloud-Win11-25H2.ps1` | WinPE on the device | Via the menu (or manually) | Wipes the disk and installs Windows with languages and updates, and prepares the Office install. Copied to the stick automatically. |
| `Office\Install-M365Apps.ps1` | The new Windows, before OOBE | No (runs automatically) | Installs Microsoft 365 Apps with `setup.exe` and `installM365BP.xml`. |
| `Collect-DeploymentLogs.ps1` | A deployed device, after OOBE | **Yes** - when something went wrong, or to verify a test device | Copies all deployment logs to the stick and checks the result (languages, Office, feature update hold, debloat, Wi-Fi password). The build script puts it in the root of the stick. See [section 10](#10-log-files). |

**The `Office` folder** uses the same install XML as our Intune package for Microsoft 365 Apps:

| File | What it is |
|---|---|
| `installM365BP.xml` | Install configuration: product, languages, update channel, default file formats |
| `Install-M365Apps.ps1` | Runs `setup.exe` during the deployment, waits for internet, retries once and checks the result |
| `setup.exe` | **Not in the repo.** The build script downloads the latest Office Deployment Tool from Microsoft's Office CDN on every run, checks the Microsoft signature and puts it on the stick (`.gitignore` keeps it out of Git) |

**Rule of thumb:** on your PC you only run `Initialize-OSDCloudBuild.ps1`. On a device you boot from the stick and use the menu that appears.

---

## 3. Requirements

**Technician PC (the PC that builds the stick)**

> For the **monthly update** of an existing stick (`-StickOnly`, section 6) you only need a Windows 11 PC with administrator rights, Windows PowerShell 5.1 and internet: no recovery environment, ADK or 20 GB free space.

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

Clone this repo to `C:\Git\mw-osdeployment-osdcloud` (GitHub Desktop: **File > Clone a repository**). You need all of it: the `.ps1` files **and** the `Office` folder (the Office `setup.exe` is downloaded by the build script itself).

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

### Step 4.4 - Download the cumulative update (required)

Follow [section 5](#5-monthly-download-the-cumulative-update-msu) and save **all** `.msu` file(s) (usually two: the update and its checkpoint) to `C:\Updates\25H2`. Without them a deployment stops at the pre-flight check.

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
| 9/9 Deployment script, start menu, Office + debloat files | seconds | Downloads the pinned debloat script and checks its fingerprint |

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

Microsoft releases a new cumulative update on the **second Tuesday of every month** ("Patch Tuesday"). The update on the stick is **required**: put the new one on the stick each month.

> **Why it is required:** the deployment adds Dutch and/or French to Windows. Microsoft requires the cumulative update to be installed again after adding languages; without it the language packs stay at their original version (10.0.26100.1) and parts of Windows can stay in English. Windows Update does not fix it, because it never offers an update that is already installed. Only needed when languages are added: "English only" in the menu does not use it.
>
> **What happens if it is missing:** the deployment stops at the pre-flight check, before anything is erased.
>
> **What happens if it is older than the Windows image:** OSDCloud downloads the newest Windows image it knows. If that image already contains a newer update than the stick, the update on the stick is skipped with a yellow warning ("not applicable") and the language packs may not be updated. Keep the stick current to avoid this.

> **Known issue, October 2026:** the checkpoint `KB5043080` fails with `0x80070228`, in WinPE and in Windows itself. It brings its own update component from 2024 (`UpdateAgent Build version 10.0.26100.1742` in `dism.log`), which cannot read the current 25H2 format (`XML parse error ... Type="UUPProduct"`). The October update `KB5127648` itself still installs and does update the language packs (tested: nl-NL and fr-FR at 10.0.26100.9711). The deployment therefore shows a yellow warning and then checks the language pack versions ("Checking the language pack versions"): `OK` there means the languages are fine. Keep both files on the stick anyway, as Microsoft prescribes.

> **Example - October 2026:** the update is **KB5127648** and the download window lists **two** files: `windows11.0-kb5043080-x64_...msu` (the checkpoint) and `windows11.0-kb5127648-x64_...msu`. Both must be on the stick. With only the second one, the deployment fails with `0x80073712`.

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
   - **If there is more than one `.msu` file listed, download all of them.** Since Windows 11 24H2, updates can need an older "checkpoint" update next to them (in 2026: KB5043080). Because the deployment adds languages, the checkpoint can never be skipped: DISM then fails with `0x80073712`.
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

Works on **any Windows 11 PC** with the repo cloned: no previous build, ADK or WinPE needed. Besides the update, it also puts the **latest versions of everything else** on the stick: deployment script, menu, Office files, the newest Office `setup.exe`, debloat and the log collection script. So this is the only maintenance a stick needs.

1. Pull the latest version of the repo (GitHub Desktop: **Fetch origin**, then **Pull**).
2. Plug in the OSDCloud stick (only that one).
3. Open **Windows PowerShell as administrator** (see [step 4.2](#step-42---open-the-right-powershell)).
4. Run:
   ```powershell
   cd C:\Git\mw-osdeployment-osdcloud
   Set-ExecutionPolicy RemoteSigned -Scope Process
   .\Initialize-OSDCloudBuild.ps1 -StickOnly -LcuPath 'C:\Updates\2026-11'
   ```
5. Steps 2 to 7 are skipped. Step 8 replaces the old update with the new one (a few minutes for ~5 GB on a slow stick), step 9 refreshes everything else.
6. Wait for `=== Done`, then use **Safely Remove Hardware**.

> Without `-StickOnly` the script also checks ADK, OSD module and WinPE first. On the PC that built the stick that is quick (everything is skipped); on any other PC it would build a complete new WinPE (1-1.5 hours).

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
├── Collect-DeploymentLogs.ps1 <- run on a deployed device to collect logs (section 10)
├── Logs                       <- created by Collect-DeploymentLogs.ps1
└── OSDCloud
    ├── Languages
    │   ├── LOF                <- language files (filled once)
    │   └── LCU                <- this month's .msu file(s) ONLY
    ├── Office                 <- setup.exe (downloaded), installM365BP.xml, Install-M365Apps.ps1
    ├── Debloat                <- RemoveBloat.ps1 (Andrew Taylor, pinned version)
    ├── Config
    │   └── Scripts
    │       └── StartNet
    │           └── Start-OSDCloudDeployMenu.ps1   <- starts automatically at boot
    └── Scripts
        └── Deploy-OSDCloud-Win11-25H2.ps1
```

---

## 7. Deploying a device

> **WARNING - a deployment erases the device's disk.** The menu asks you to type `YES` first. Make sure you have the right device and that any data on it is backed up.

**In short:** boot from the stick > the menu appears > (Wi-Fi: **C**) > **D** or **N** > choose the languages > check the device > type **YES** > wait until the device restarts by itself > OOBE.

### Step 7.1 - Before you start

- The stick is up to date: deployment script, Office files, debloat script and **this month's cumulative update** (section 5-6). Not sure? Rebuild it with `Initialize-OSDCloudBuild.ps1` (step 9 takes seconds).
- The device is connected to **power**. Use **Ethernet** if you can; Wi-Fi works too (step 7.4).
- Any data on the device is backed up: everything on the internal disk is erased.
- **Autopilot devices:** the Autopilot deployment profile has **Language (Region)** = **User select**, otherwise OOBE skips the language choice (step 7.8).

### Step 7.2 - Boot from the stick

1. Plug in the stick.
2. Turn on the device and open the **boot menu**. Common keys:

   | Brand | Boot menu key |
   |---|---|
   | Dell | F12 |
   | HP | F9 (or Esc, then F9) |
   | Lenovo | F12 (or the small Novo button) |
   | Microsoft Surface | Hold **Volume Down**, press and release Power, keep holding Volume Down until the logo appears |

3. Choose the **USB** entry (UEFI).

If the device does not boot from the stick, check in the firmware (BIOS) settings that USB boot is allowed. Leave Secure Boot **on**.

### Step 7.3 - The deployment menu

After WinPE has started (about a minute), the **deployment menu** appears by itself:

```
  ================================================================
   3-IT OSDCloud - Windows 11 25H2 Pro deployment
  ================================================================

  Device:   HP ZBook Firefly 16 inch G11 Mobile Workstation PC
  Serial:   XXXXXXXXXX
  Disk 0:   <internal disk> (954 GB)
  Internet: connected

  [D]  Deploy Windows 11 + debloat + Microsoft 365 Apps
  [N]  Deploy Windows 11 + debloat, without Office (No Office)
  [C]  Connect to Wi-Fi
  [R]  Refresh (check the internet connection again)
  [P]  Open an extra PowerShell window
  [X]  Exit to the command prompt - nothing is changed

  Debloat always runs (RemoveBloat.ps1 by Andrew Taylor): removes consumer apps, Copilot
  and Recall, and clears the Start menu pins. Log: C:\ProgramData\Debloat\Debloat.log

  Choice:
```

**How to use it:** type the letter and press **Enter**. Upper or lower case does not matter. The menu only uses letters that are in the same place on US (QWERTY) and Belgian (AZERTY) keyboards, so it works on every stick. The menu waits as long as needed: if a device boots from the stick by accident, nothing happens until someone types `YES`.

| Key | What it does | When to use it |
|---|---|---|
| **D** | Deploy Windows 11 + debloat + **Microsoft 365 Apps** | Normal case: customers with Microsoft 365 Apps licences (step 7.5) |
| **N** | Deploy Windows 11 + debloat, **without Office** | Customers without Microsoft 365 Apps licences (step 7.5) |
| **C** | Opens the Wi-Fi window to connect to a wireless network | No Ethernet (step 7.4) |
| **R** | Checks the internet connection again and updates the `Internet:` line | Ethernet just plugged in, or `NOT connected` while you expect a connection |
| **P** | Opens an **extra PowerShell window** | Reading logs while a deployment runs, or troubleshooting (step 7.6) |
| **X** | Leaves the menu; nothing is changed | Deploying manually (step 7.10) or just looking around. The normal OSDCloud windows (Wi-Fi prompt, info) then appear |

> **Extra window at startup:** while the menu (or a deployment) runs, OSDCloud's other windows do not open. The menu therefore also starts one extra PowerShell window, **minimized**: a small title bar at the bottom left of the screen. Click it to open it. **P** opens another one.

### Step 7.4 - Connect to the internet (C and R)

The deployment needs internet (Windows, Office and updates are downloaded from Microsoft). Check the `Internet:` line in the menu.

**Ethernet:** nothing to do when it says `Internet: connected`. Just plugged in the cable, or it says `NOT connected`? Wait a few seconds and press **R**.

**Wi-Fi:**

1. Press **C**. A separate window opens and shows a table of the Wi-Fi networks it finds (`Signal`, `Index`, `SSID`, ...).
2. Type the **Index** number of your network and press Enter. On a Belgian (AZERTY) keyboard the number keys need **Shift**, or use the numeric keypad.
3. Type the Wi-Fi password when asked and press Enter. WinPE uses the **Belgian (Period)** keyboard, so type it as on a normal Belgian keyboard.
4. The window waits for the connection and closes. The menu checks the internet again: the line should now say `Internet: connected`. If not, press **R** after a few seconds, or **C** to try again.

> **Which network?** Use a **dedicated deployment or guest network** if possible, but one **without a login page** (captive portal): those block the deployment. The Wi-Fi profile is copied to the new Windows so it can connect during setup, OOBE and Autopilot. OSDCloud also writes the password **in plain text** into `C:\Windows\Setup\Scripts\SetupComplete.ps1`; the deployment removes it from there (and from the OSDCloud logs) as the last step before OOBE. The Wi-Fi profile itself stays on the device (Windows stores its key protected); remove it afterwards if the device should not keep that network: `netsh wlan delete profile name="<network name>"`.

> **Old stick with a US keyboard?** Sticks built before build script version 1.2.0 use the US (QWERTY) keyboard in WinPE, so the password does not match what you type. Press **X**, then switch the keyboard and open a new window (the change only applies to programs started afterwards): `wpeutil SetKeyboardLayout 0813:00000813` and `start powershell`. Run `Start-WinREWiFi` in the new window and deploy manually (step 7.10). Better: rebuild the stick with `-RebuildWinPE` (section 11).

### Step 7.5 - Start the deployment (D or N)

1. Press **D** (with Office) or **N** (without Office).
2. **Choose the display languages.** English is always included:

   ```
     [B]  English + Nederlands + Francais  (Belgium, all three)
     [L]  English + Nederlands
     [F]  English + Francais
     [E]  English only                     (fastest: no language packs, no update from the stick)
     [X]  Cancel
   ```

   Only the languages you choose here are offered in OOBE. Each extra language adds a few minutes. With **E** the cumulative update from the stick is not used either (Windows Update updates the device during setup).
3. **Pre-flight checks** (nothing is changed yet). The menu runs the deployment script in test mode and shows the result. Every line should say `OK`:
   - `Internet: dl.delivery.mp.microsoft.com:80 reachable` (Windows) and `officecdn.microsoft.com:443` (Office, only with **D**)
   - the language packs and the cumulative update (`LCU found`) for the chosen languages
   - the debloat script and (with **D**) the Office files on the stick

   A yellow warning "Only one .msu in the LCU folder" means the checkpoint update may be missing (section 5). If a check **fails**, the menu says so and you go back to the menu: nothing was changed.
4. **Confirm.** The device, its internal disk(s) and what will be installed are shown in red, for example `Install: Windows 11 + debloat + Microsoft 365 Apps, languages: English, nl-NL, fr-FR`. Check that this is the right device, then type **`YES`** and press Enter. Anything else cancels.
5. The deployment starts. **Do not unplug the stick and do not turn off the device** until it restarts by itself. What you see, in order (the `HH:mm:ss` times are on screen):

   | Step | Takes | Notes |
   |---|---|---|
   | OSDCloud: erase the disk, download and apply Windows 11 | 10-20 min | Depends on the internet speed |
   | Injecting Ethernet/Wi-Fi drivers | seconds | `OK  <network adapter>` |
   | Holding feature updates at 25H2 | seconds | Prevents 26H2 during setup, lifted again before OOBE |
   | Adding language nl-NL / fr-FR | 1-2 min per language | Only the chosen languages |
   | Re-applying the cumulative update | 5-20 min | **October 2026:** a yellow warning about `kb5043080` / `0x80070228` is a known issue and normal (section 5) |
   | Checking the language pack versions | seconds | Must say `OK  nl-NL language pack at 10.0.26100.<build>` per language |
   | Staging debloat / Office / feature update hold / Wi-Fi password removal | 1 min | Prepares what runs after the restart |
   | Verifying installed languages | seconds | |

   The device then restarts by itself after 10 seconds. Continue with step 7.8.

### Step 7.6 - While it runs: the extra PowerShell window (P)

Use the extra window (click the title bar at the bottom left, or press **P** in the menu before you start) to look at a busy deployment without disturbing it. Useful commands:

```powershell
# What DISM is doing right now (language packs, cumulative update)
Get-Content X:\Windows\Logs\DISM\dism.log -Tail 5

# The deployment log so far
Get-ChildItem X:\Windows\Temp\Deploy-OSDCloud-Win11-25H2_*.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 30

# Find the stick's drive letter (it changes when the internal disk is partitioned)
Get-Volume | Where-Object FileSystemLabel -eq 'OSDCloudUSB'
```

Do not run deployment or DISM commands yourself while a deployment is busy: two DISM jobs on the same Windows get in each other's way.

### Step 7.7 - If the deployment fails

- The device does **not** restart. You see a red `DEPLOYMENT FAILED: ...` line, followed by the **last 25 lines of the deployment log**, and the menu waits for Enter.
- **Do not restart yet:** the log is only kept in WinPE memory until it restarts. Take a photo of the screen, or save the logs to the stick from the extra window (replace `E` with the stick's letter):

  ```powershell
  New-Item E:\Logs\WinPE -ItemType Directory -Force | Out-Null
  Copy-Item X:\Windows\Temp\Deploy-OSDCloud-Win11-25H2_*.log, X:\Windows\Logs\DISM\dism.log E:\Logs\WinPE\
  ```
- Fix the cause (see section 9) and press **D** or **N** again. The menu finds the stick again even if its drive letter changed.

### Step 7.8 - After the restart (SetupComplete and OOBE)

1. The device shows "Getting ready" for a while. In the background (nothing of this is visible on screen, the logs are in section 10), in this order:
   1. Windows Update installs drivers, firmware and updates
   2. the debloat runs
   3. Microsoft 365 Apps are downloaded and installed (with **D**)
   4. the feature update hold is lifted
   5. the plain-text Wi-Fi password OSDCloud left behind is removed

   **This can take 30 to 75 minutes.** Do not turn it off. It may restart once more by itself.
2. OOBE starts:
   1. **Choose a language** - English, Nederlands or Français (only the languages chosen in the menu)
   2. **Choose a region** - for example Belgium. There are no separate Belgian language packs: the region sets the Belgian date, number and currency formats.
   3. **Choose a keyboard layout** - Belgian (Period) or Belgian French
   4. Optionally add a second keyboard

   > **No language choice, only the keyboard?** Then the device is registered in **Autopilot** and its deployment profile has **Language (Region)** set to "Operating system default" (or a fixed language). OOBE then skips the language page (Microsoft Learn, Autopilot "Validation": *"If connected to Ethernet, and the Windows Autopilot profile is configured to skip them, the following pages aren't displayed: Language and locale"*). Fix it in Intune: **Devices > Windows > Enrollment > Deployment profiles** > the profile > **Out-of-box experience (OOBE)** > **Language (Region)** = **User select**. `Collect-DeploymentLogs.ps1` reports the profile's language setting.
3. Finish the setup as usual (Autopilot / company sign-in).

### Step 7.9 - Check the device

**Recommended for test devices and when something looks wrong:** after signing in, plug in the stick, open **PowerShell as administrator** and run `PowerShell -ExecutionPolicy Bypass -File E:\Collect-DeploymentLogs.ps1` (replace `E`). It collects all logs to the stick and shows OK / WARN / FAIL per check (section 10).

By hand:

- **Settings > Windows Update**: check for updates, install what is offered.
- **Device Manager**: no yellow exclamation marks. If there are, run Windows Update again and restart.
- **Settings > System > Activation**: should show "Windows is activated" (if the device has a Pro key in its firmware).
- **Debloat**: no Xbox, Solitaire or Copilot in the Start menu, which starts without the default pins. If they are still there, see `C:\ProgramData\Debloat\Debloat.log`.
- **Office**: Word, Excel, Outlook and PowerPoint are there (unless you chose **N**). If not, see the Office log in section 10. A failed Office install does not stop the deployment.

### Step 7.10 - Without the menu (manual)

Only needed if you left the menu with **X**, or on a stick built before build script version 1.3.0 (no menu).

1. Find the stick's drive letter (for example `E`; it can differ from device to device):
   ```powershell
   Get-Volume | Where-Object FileSystemLabel -eq 'OSDCloudUSB'
   ```
2. Dry run (changes nothing):
   ```powershell
   PowerShell -ExecutionPolicy Bypass -File E:\OSDCloud\Scripts\Deploy-OSDCloud-Win11-25H2.ps1 -WhatIf
   ```
3. Real deployment. **This erases the disk without asking.** Optional: `-SkipOffice` (no Office) and `-Languages 'nl-NL'`, `'fr-FR'`, `'nl-NL,fr-FR'` (default) or `'none'` (English only):
   ```powershell
   PowerShell -ExecutionPolicy Bypass -File E:\OSDCloud\Scripts\Deploy-OSDCloud-Win11-25H2.ps1 -Languages 'nl-NL,fr-FR'
   ```

---

## 8. What happens during a deployment

For the curious - you do not need to know this to use it.

0. **Menu** - OSDCloud starts `Start-OSDCloudDeployMenu.ps1` from the stick's `StartNet` folder when WinPE boots. After your choice, it runs the deployment script once with `-WhatIf` (pre-flight only), asks for `YES`, and then runs it for real.
1. **Pre-flight checks** - checks it runs in WinPE, the device has internet (Microsoft's Windows and Office download servers are reachable) and the language and Office files are on the stick, **before** anything is erased. This matters because OSDCloud erases the disk first and only then downloads Windows.
2. **OSDCloud** - erases the disk, downloads Windows 11 25H2 Pro (en-US) from Microsoft and applies it. No driver packs.
3. **Network drivers** - copies the Ethernet/Wi-Fi drivers WinPE is using into the new Windows, so it has internet at first boot.
4. **Languages** - adds the language packs and language features chosen in the menu (nl-NL and/or fr-FR). With more than one language installed, OOBE shows the language choice (unless an Autopilot profile sets the language, see [step 7.8](#step-78---after-the-restart-setupcomplete-and-oobe)).
3b. **Feature update hold** - writes the Windows Update policy "Select the target feature update version" (Windows 11, 25H2) into the new Windows, so Windows Update during setup does not install 26H2. It is removed again at the end of setup (step 7), because a local policy would overrule the customer's Intune feature update policy.
5. **Cumulative update** - only when languages were added: applied again after the languages (update and checkpoint together). Microsoft requires this, otherwise the language packs stay at their original version. Windows Update would not do it, because it does not offer an update that is already installed. A failure (for example the checkpoint in October 2026, see section 5) is a warning; afterwards the deployment checks that each added language pack was updated past its original version.
6. **Debloat and Office staged** - copies `RemoveBloat.ps1` to `C:\OSDCloud\Scripts\SetupComplete\Debloat` and the Office files to `...\SetupComplete\Office`, and creates a `SetupComplete.cmd` that starts them: debloat first, then Office. Both need the full Windows, so they cannot run in WinPE. Debloat must run first because it removes consumer Office editions.
7. **Restart** - in the new Windows, SetupComplete runs before OOBE: Windows Update installs the remaining drivers, firmware and updates, then OSDCloud runs our `SetupComplete.cmd`: the debloat runs, Microsoft 365 Apps are downloaded from Microsoft and installed, the feature update hold is lifted, and as the very last step the plain-text Wi-Fi password OSDCloud left behind is removed. A failure of one step does not stop the others. Then the device restarts into OOBE.

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
| `No cumulative update on the stick yet` (build) or `No cumulative update (.msu) found` (deployment pre-flight) | `LCU` folder empty | Required: follow [section 5](#5-monthly-download-the-cumulative-update-msu) and [section 6](#6-monthly-put-the-update-on-the-stick). Nothing was erased |
| `The cumulative update on the stick is older than 5 weeks` | You skipped a month | Download the new update and put it on the stick, otherwise the next Windows image may be newer and the language packs may not be updated |
| Deployment fails at "Re-applying the cumulative update" with `0x80073712` ("An error occurred applying the Unattend.xml file from the .msu package") | The checkpoint `.msu` is missing in the `LCU` folder | Download **all** files from the Update Catalog download window (section 5) and put them in the `LCU` folder |
| Yellow warning `Part of the cumulative update failed (0x80070228)` | The checkpoint `KB5043080` brings a 2024 update component that cannot read the 25H2 format (`dism.log`: `XML parse error ... Type="UUPProduct"`). Known issue, see section 5 | Nothing to do if the next step "Checking the language pack versions" says `OK` for each language. The DISM log is saved as `C:\OSDCloud\Logs\dism-offline-LCU.log` |
| Yellow warning `... language pack is still at its original version` | The cumulative update did not update the language pack | Check the update files on the stick (section 5) and redeploy |
| OOBE offers no language choice, only the keyboard | Autopilot profile has **Language (Region)** = "Operating system default" or a fixed language | Intune deployment profile: **Language (Region)** = **User select** ([step 7.8](#step-78---after-the-restart-setupcomplete-and-oobe)). Not caused by the deployment: `dism /online /get-intl` listing nl-NL/fr-FR as "Partially localized, MUI type" is normal for added languages |
| `The cumulative update on the stick is older than the one already in the Windows image (not applicable)` (deployment warning) | The update on the stick is older than the one inside the downloaded Windows image | The deployment continues. Put the latest update on the stick for the next devices |
| `Language repository ... not found on any drive` (deployment) | Stick not detected or language files missing | Check the stick is plugged in. Rebuild with `.\Initialize-OSDCloudBuild.ps1 -RefreshLanguages` |
| `No third-party network drivers in use in WinPE` (warning) | Device uses a network chip Windows already supports (normal on VMs) | Nothing to do |
| No language choice in OOBE | Language packs missing | Check the deployment log for errors in step "Adding language" |
| Wi-Fi password is not accepted in WinPE | Wrong keyboard layout: the stick still has a US (QWERTY) WinPE | Use `wpeutil SetKeyboardLayout 0813:00000813` (see [step 7.4](#step-74---connect-to-the-internet-c-and-r)), or rebuild the stick with `-RebuildWinPE` |
| The deployment menu does not appear | The stick was built before build script version 1.3.0 | Deploy manually ([step 7.10](#step-710---without-the-menu-manual)), and run `.\Initialize-OSDCloudBuild.ps1` again to put the menu on the stick (step 9, takes seconds) |
| `No internet: cannot reach ...` (deployment pre-flight) | No network in WinPE, no Wi-Fi driver, or a network that blocks the download (for example a guest network with a login page) | Nothing was erased. Connect Ethernet, or Wi-Fi with **C** in the menu, and choose **D** or **N** again |
| `Debloat script not found` (deployment pre-flight) | Stick was built before debloat was added (build script before 1.4.0) | Run `.\Initialize-OSDCloudBuild.ps1` again (step 9 downloads and copies it, takes seconds) |
| `RemoveBloat.ps1 does not match the expected SHA-256` (build) | The download is not the version we checked, or the download was corrupted | Run the build again. If it keeps failing, the pinned values in `Initialize-OSDCloudBuild.ps1` are wrong; see [section 11](#11-changing-the-scripts) |
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
| `-StickOnly` | Only updates an existing stick (update, scripts, Office `setup.exe`, debloat); skips ADK, OSD module and WinPE. For the monthly update, on any PC |
| `-LofIsoPath <file>` | Uses an already downloaded language ISO instead of downloading it |

---

## 10. Log files

When asking for help, send the relevant log.

**Easiest: collect everything at once.** On the deployed device (signed in, after OOBE), plug in the stick, open **PowerShell as administrator** and run (replace `E` with the stick's letter):

```powershell
PowerShell -ExecutionPolicy Bypass -File E:\Collect-DeploymentLogs.ps1
```

It takes 1-3 minutes, changes nothing on the device and saves all logs below plus a `_summary.txt` to `OSDCloudUSB:\Logs\<computer name>-<date>`. The summary shows OK / WARN / FAIL for: Windows build, Dutch and French language packs updated to the same build as Windows, the Autopilot profile's language setting (a fixed language hides the OOBE language choice), Microsoft 365 Apps installed, **feature update hold removed**, debloat finished, and Wi-Fi password left on the device. Wi-Fi passwords are blanked out in the copied logs. Never commit these logs to a repository.

Individual logs:

| What | Where |
|---|---|
| Build script | `C:\OSDCloudBuild\Logs\Initialize-OSDCloudBuild_<date>.log` |
| WinPE template (per package) | `C:\ProgramData\OSDCloud\Logs\Template\` |
| Deployment (on the imaged device, after imaging) | `C:\OSDCloud\Logs\Deploy-OSDCloud-Win11-25H2_<date>.log` |
| Deployment (if it failed in WinPE) | `X:\Windows\Temp\` - copy it to the stick's **OSDCloudUSB** partition before rebooting |
| Debloat (everything the script would show on screen) | `C:\ProgramData\Debloat\Debloat.log` |
| Office install script | `C:\OSDCloud\Logs\Install-M365Apps_<date>.log` |
| Cumulative update, DISM log of a (partial) failure in WinPE | `C:\OSDCloud\Logs\dism-offline-LCU.log` |
| Wi-Fi password removed | `C:\OSDCloud\Logs\Remove-WiFiPassword_<date>.log` (should say `OK: no plain-text Wi-Fi password left`; the password itself is never logged) |
| Feature update hold removed | `C:\OSDCloud\Logs\Remove-FeatureUpdateBlock_<date>.log` (should say `OK: feature update hold removed`) |
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
- **Debloat (`RemoveBloat.ps1` by Andrew Taylor)** is **not stored in this repo** (it is GPL-3.0 licensed). `Initialize-OSDCloudBuild.ps1` downloads it from [his GitHub](https://github.com/andrew-s-taylor/public/tree/main/De-Bloat) at **one fixed commit** and checks its **SHA-256 fingerprint** (`$DebloatUrl` and `$DebloatSha256` in the `Configuration` section), so a change on his side never reaches our devices unnoticed. Current version: 5.6.5, commit `ce39945`. To update:
  1. Look at his [commit history](https://github.com/andrew-s-taylor/public/commits/main/De-Bloat/RemoveBloat.ps1) and **read the changes** since our commit. It runs as SYSTEM on customer devices.
  2. Put the new commit ID in `$DebloatUrl`, download that file once and put its fingerprint (`(Get-FileHash .\RemoveBloat.ps1).Hash`) in `$DebloatSha256`.
  3. Test on a test device, then rebuild the sticks (step 9 only) and commit.
- **Office Deployment Tool (`setup.exe`)** - nothing to do: Microsoft releases a new version about once a month and recommends always using the latest ([release history](https://learn.microsoft.com/officeupdates/odt-release-history)). Step 9 of the build script downloads it from `https://officecdn.microsoft.com/pr/wsus/setup.exe` on every run (also with `-StickOnly`), checks that it is signed by Microsoft and only then replaces the copy on the stick. If the download fails, the existing `setup.exe` on the stick is kept (warning). The Intune package has its own copy of `setup.exe`; update that one separately if you want it current too.
- Every script starts with a version history. **Bump the version and add a line** for each change.
- Test with `-WhatIf` and on a test device or VM before using it on customer devices.
- Commit with a clear message and push to `main`.

**Never** put the deployment script itself in the stick's `OSDCloud\Config\Scripts\StartNet` folder. Scripts there start automatically at boot, so booting a device from the stick by accident would erase it immediately. Only `Start-OSDCloudDeployMenu.ps1` belongs there, because it asks for confirmation (`YES`) first. If you change the menu, keep that confirmation.

---

## 12. No-secrets policy

This repository must **never** contain:

- Passwords, product keys, API keys, tokens or certificates
- Customer data, tenant names, tenant IDs or other tenant configuration
- Wi-Fi names or passwords
- Log files from customer devices

Use placeholders such as `contoso.onmicrosoft.com` in examples. Before every push, check the changes (`git diff`) for anything sensitive. If you accidentally committed a secret, tell the team immediately - removing it from history is not enough, it must be rotated.
