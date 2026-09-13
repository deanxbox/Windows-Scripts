# Scripts

Personal PowerShell utility scripts for everyday Windows use.

## Setup

Clone or copy this repo to `%USERPROFILE%\Scripts`, then run:

```powershell
npm install
.\updateprofile.ps1
```

`npm install` installs the pinned official TOON CLI used by `ConvertTo-Toon.ps1`. The profile script scans this folder and adds profile functions for every `.ps1` script. Reload your profile or restart your terminal for changes to take effect.

---

## Scripts

### `Generate-Mc-Server.ps1`

Interactively installs a Vanilla, Fabric, NeoForge, Forge, or Quilt Minecraft server, copies local mods, writes server settings/EULA/startup files, checks likely mod incompatibilities, and configures detected Chunky/BlueMap/squaremap pre-generation.

```powershell
.\Generate-Mc-Server.ps1
.\Generate-Mc-Server.ps1 -Reconfigure -ServerPath C:\Servers\MyServer
```

Minecraft releases are shown by default; snapshots are opt-in and may not have a compatible loader. Arrow-key menus show a compact scrolling window of up to 10 items, with the newest item selected by default. Use ↑/↓ to navigate and Space to select (Enter also confirms single selections); multi-select menus use Space to toggle and Enter to confirm. If the interactive menu is unavailable, the numbered fallback accepts an empty Enter as item 1. New servers are created from a folder name beneath the current invocation directory; `-Reconfigure -ServerPath` continues to accept an explicit existing path. Vanilla downloads Mojang's server jar directly and skips mod compatibility and map-mod scanning. Forge and NeoForge automation is limited to Minecraft 1.17+ and its generated `run.sh`/argfile layout. `-Reconfigure` skips installation and only asks for RAM before regenerating `start.sh`. Chunky shape, radius, and center are configured independently for each selected dimension, then selected dimensions generate sequentially in overworld → nether → end order; the script enforces Chunky's one-second, non-silent progress logging to avoid false idle timeouts during active generation. When BlueMap or squaremap is detected, the server boots once to generate their configuration before temporary render-thread overrides are applied; BlueMap's required `accept-download` setting is enabled permanently, while only render-thread settings are restored after the second headless pre-generation run. Map-render completion is reported when detected, and a five-second heartbeat shows elapsed time and time since the last log activity during quiet render periods. BlueMap and squaremap render continuously in the background and have no reliably detectable one-time "finished" signal, so their completion does not gate the pre-generation run; when Chunky tasks are also configured, pre-generation finishes as soon as all Chunky tasks complete. If only BlueMap/squaremap are present (no Chunky tasks), pre-generation instead ends via the idle-timeout fallback after genuine log inactivity, and the script prints a warning explaining why.

Requires Java on `PATH`; server icons additionally require `ffmpeg`.

---

### `ConvertTo-Toon.ps1`

Converts JSON files to the token-efficient [TOON format](https://toonformat.dev) by using the official `@toon-format/cli` package.

Requires Node.js/npm with `npx` available on `PATH`. The first conversion may download the CLI package.

```powershell
.\ConvertTo-Toon.ps1 .\data.json
.\ConvertTo-Toon.ps1 . -Recurse
.\ConvertTo-Toon.ps1 . -Recurse -OutputDirectory .\toon-output
.\ConvertTo-Toon.ps1 . -Recurse -ThrottleLimit 4
.\ConvertTo-Toon.ps1 . -Recurse -ThrottleLimit 1
.\ConvertTo-Toon.ps1 .\data.json -Force
```

By default, each `.toon` file is written beside its source JSON. `-OutputDirectory` writes files beneath a separate destination while preserving relative subdirectories. Existing files are not replaced unless `-Force` is supplied.

Multiple files convert concurrently by default. Automatic concurrency uses up to the logical processor count, eight workers, or the number of files, whichever is lowest. Set `-ThrottleLimit 1` for sequential operation or provide an explicit value from 2 to 64.

Large individual JSON files use the official CLI's incremental input and output streaming, including arbitrary nested objects and top-level arrays. The script intentionally does not request token statistics because `--stats` builds the complete TOON output in memory.

Completed conversions are written to temporary files and moved into place only after success, so failed conversions do not leave partial output or destroy an existing file when `-Force` is used.

The pinned repository-local CLI is preferred after `npm install`. If it is absent, the script falls back to `npx --yes @toon-format/cli@4.1.1` for compatibility while retaining the same exact version.

Each attempted conversion returns a structured result containing the source path, destination path, success state, error message, and duration in milliseconds.

---

### `Apply-GPUPreferences.ps1`

Pins a set of applications to your preferred GPU via the Windows GPU Preferences registry key (`HKCU:\Software\Microsoft\DirectX\UserGpuPreferences`). Useful on multi-GPU systems where you want secondary/recording apps to stay off your primary GPU.

**Configured apps:** Brave Browser, Discord, Medal, Spotify, Wallpaper Engine. Edit `gpu-prefs-apps.json` to add or remove programs.

Run it manually any time - it's a one-shot script, no scheduled task or background process involved.

```powershell
.\Apply-GPUPreferences.ps1
.\Apply-GPUPreferences.ps1 -AddProgram
.\Apply-GPUPreferences.ps1 -RemoveProgram
.\Apply-GPUPreferences.ps1 -WhatIf
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

**Ignored by default:** `node_modules`, `bin`/`obj`/`dist`, `.git`, local agent metadata, `.env` files, `__pycache__`, `venv`, lock files, binaries, images, media, fonts, and more. The directory tree is emitted in normal parent-before-child order.

---

### `pullall.ps1`

Scans each immediate child directory and pulls git repositories concurrently. A single progress bar tracks completed directories without printing per-repository git output.

```powershell
pullall                              # pull all repos in current directory
pullall C:\dev                       # pull all repos in a specific path
pullall C:\dev -ThrottleLimit 4      # limit concurrent pulls
```

After the scan, the script lists repositories that changed, repositories that were already current, directories that were not repositories, and failures. Full git output is retained only for failures.

---

### `Set-PowerProfile.ps1`

Switches display, sleep, and processor-state settings between predefined profiles.

```powershell
setpowerprofile
setpowerprofile -ProfileName "Always On Minimal"
setpowerprofile -WhatIf             # preview without changing power settings
setpowerprofile -NoPause            # do not wait before closing
```

Profiles are defined near the top of the script and can be edited directly:

1. `Default` - display off after 30 minutes, sleep after 1 hour, normal CPU range.
2. `Always On` - display and sleep never time out, normal CPU range.
3. `Always On Minimal` - display and sleep never time out, CPU capped at 50% for lower power and quieter fans.

---

### `specs.ps1`

Prints a clean, formatted summary of system hardware and OS information.

```powershell
specs                               # print specs and copy quick-share summary
specs -NoClipboard                  # do not copy the summary
specs -NoClear                      # do not clear the terminal first
specs -IncludeIntegratedGpu         # include GPUs normally filtered out
```

Displays: CPU (name, cores/threads, base clock), RAM (total, config, type), GPUs (name, driver version), motherboard, storage drives, and OS details.

RAM type is detected from SMBIOS data where available. USB drives are excluded from storage. By default, the known AMD integrated GPU name is filtered out; pass `-IncludeIntegratedGpu` to show it.

---

### `updateprofile.ps1`

Adds missing function wrappers for scripts in this folder to your PowerShell profile.

Pester test files (`*.Tests.ps1`) are ignored.

```powershell
.\updateprofile.ps1
.\updateprofile.ps1 -WhatIf          # preview profile changes
.\updateprofile.ps1 -NoReload        # skip the reload prompt
.\updateprofile.ps1 -NoPause         # do not wait before closing
```

When this repo lives at `%USERPROFILE%\Scripts`, generated functions use `$env:USERPROFILE\Scripts\...`; otherwise they use the detected script directory.
