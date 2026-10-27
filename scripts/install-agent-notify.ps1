# Runs scripts/agent-notify on this PC: a Startup-folder shortcut (windowless, with pyw) so it
# starts at every logon, and starts it now unless it already runs. It follows this PC's
# herdr-core (the Herdr app's spaces here) and pushes to the ntfy topic in
# %APPDATA%\agent-notify\env (NTFY_URL=, NTFY_TOPIC=; not in Git). Its log is
# %APPDATA%\agent-notify\agent-notify.log. bc250-2 runs its own copy (bootstrap/05-herdr.sh).
#
#   powershell -NoProfile -File scripts\install-agent-notify.ps1
#
# Run it from a normal PowerShell, not an admin one: a watcher started elevated can only be
# stopped by an admin (2026-11-10). It has no window: pyw has none, and agent-notify starts hc
# without a console. Safe to re-run; it doesn't restart a running watcher, so after updating the
# script stop the old one first (Task Manager, or `Get-Process pyw, pythonw | Stop-Process`).
# To remove: delete the shortcut "agent-notify.lnk" in shell:startup and stop pyw/pythonw.
$ErrorActionPreference = 'Stop'

$script = (Resolve-Path (Join-Path $PSScriptRoot 'agent-notify')).Path
$pyw = (Get-Command pyw.exe).Source
$config = Join-Path $env:APPDATA 'agent-notify\env'
if (-not (Select-String -Path $config -Pattern '^NTFY_TOPIC=.' -Quiet -ErrorAction SilentlyContinue)) {
    throw "No NTFY_TOPIC in $config; write NTFY_URL= and NTFY_TOPIC= there first."
}

$startup = [Environment]::GetFolderPath('Startup')
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startup 'agent-notify.lnk'))
$shortcut.TargetPath = $pyw
$shortcut.Arguments = "-3 `"$script`""
$shortcut.WorkingDirectory = Split-Path $script
$shortcut.Description = 'agent-notify: ntfy pushes when a Herdr agent needs you or finishes'
$shortcut.Save()
"Startup shortcut: $($shortcut.FullName)"

$running = Get-CimInstance Win32_Process -Filter "Name='pyw.exe' or Name='pythonw.exe'" |
    Where-Object { $_.CommandLine -like '*agent-notify*' }
if ($running) {
    "already running (pid $($running.ProcessId -join ', ')); restart it to pick up a new version"
} else {
    Start-Process -FilePath $pyw -ArgumentList '-3', "`"$script`"" -WorkingDirectory (Split-Path $script)
    'started'
}
