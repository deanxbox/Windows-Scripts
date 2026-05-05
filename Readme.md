# Scripts

Personal PowerShell utility scripts for everyday Windows use.

## Setup

Clone or copy this repo to `%USERPROFILE%\Scripts`, then add the following functions to your PowerShell profile (`$PROFILE`):

```powershell
function projectdump { & "$env:USERPROFILE\Scripts\projectdump.ps1" @args }
function pullall     { & "$env:USERPROFILE\Scripts\pullall.ps1" @args }
function specs       { & "$env:USERPROFILE\Scripts\specs.ps1" @args }
function applygpupreferences { & "$env:USERPROFILE\Scripts\Apply-GPUPreferences.ps1" @args }
```

Reload your profile or restart your terminal for changes to take effect.

---

## Scripts

### `Apply-GPUPreferences.ps1`

Pins a set of applications to your preferred GPU via the Windows GPU Preferences registry key (`HKCU:\Software\Microsoft\DirectX\UserGpuPreferences`). Useful on multi-GPU systems where you want secondary/recording apps to stay off your primary GPU.

**Covered apps:** Brave Browser, Discord (all versioned `app-*` directories), Medal, Spotify.

Run it manually any time — it's a one-shot script, no scheduled task or background process involved.

```powershell
.\Apply-GPUPreferences.ps1
```

---

### `projectdump.ps1`

Recursively dumps a project directory into a single structured text block and copies it to the clipboard, ready to paste into an AI chat or document.

Output includes a directory tree followed by the contents of all relevant source files. Binary files, lock files, build artifacts, and large files are automatically skipped.

```powershell
projectdump                          # dump current directory
projectdump C:\path\to\project       # dump a specific path
projectdump . -MaxFileSizeKB 200     # lower the file size limit
projectdump . -NoClip                # print to stdout instead of clipboard
```

**Ignored by default:** `node_modules`, `bin`/`obj`/`dist`, `.git`, `__pycache__`, `venv`, lock files, binaries, images, media, fonts, and more.

---

### `pullall.ps1`

Finds all git repositories in a directory and pulls them concurrently, with a live per-repo status display.

```powershell
pullall                              # pull all repos in current directory
pullall C:\dev                       # pull all repos in a specific path
```

Each repo shows `[ PULLING ]` while in progress, then updates in-place to `[ DONE ]` (green) or `[ ERROR ]` (red). Any errors are printed in full at the end.

---

### `specs.ps1`

Prints a clean, formatted summary of system hardware and OS information.

```powershell
specs
```

Displays: CPU (name, cores/threads, base clock), RAM (total, config, type), GPUs (name, driver version), motherboard, storage drives, and OS details.

Excludes integrated graphics (AMD Radeon iGPU filtered by name) and USB drives from the output.