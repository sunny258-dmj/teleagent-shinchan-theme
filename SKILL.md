---
name: teleagent-shinchan-theme
description: Install, verify, reapply, or uninstall the reversible Crayon Shin-chan interface theme for the TeleAgent Windows desktop app. Use for TeleAgent appearance customization, theme recovery after an update, or removal of this theme; do not use for the separate Shin-chan desktop-pet runtime.
---

# TeleAgent 蜡笔小新主题

Use the scripts in this skill instead of editing TeleAgent resources by hand. The theme changes the Electron renderer CSS and synchronizes the matching embedded ASAR header hash in the Windows executable; it does not change accounts, conversations, tools, or the separate desktop pet. Both original files are backed up and hash-verified for uninstall.

## Install

1. Read [references/compatibility.md](references/compatibility.md) when the installed TeleAgent version is not `2.5.2`, an earlier theme is present, or the app resources were customized.
2. Run `scripts/test-theme.ps1` first when adapting to a new TeleAgent release. This builds and inspects a themed copy without changing the installed app.
3. Install with:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-theme.ps1 -Restart
   ```

4. Confirm that the script reports a verified themed archive and that TeleAgent reopens. When UI automation is available, visually check the home page, conversation page, settings dialog, and both light and dark modes.

Do not use `-ForceUnsupportedVersion` unless the user explicitly accepts testing an unverified TeleAgent version. The installer must preserve its backup and metadata under TeleAgent's `resources\.teleagent-shinchan-theme` directory.

## Uninstall

Restore the exact backed-up archive with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall-theme.ps1 -Restart
```

If the backup is missing or its hash does not match the saved metadata, stop and report the problem instead of guessing which archive to restore.

## Reapply after an update

An official TeleAgent update may replace `app.asar`. Re-run the dry-run test against the new version, update the compatibility reference only after validation, then run the installer again. Never carry forward an old full `app.asar`; always patch the newly installed archive.
